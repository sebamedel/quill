import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    /// Sessions that already have a transcript but never got the second pass.
    /// Kept apart from `queue`: they don't need transcribing again from
    /// scratch, only refining, and they must never delay a fresh recording.
    private var pendingRefine: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private let diarizador = Diarizador()
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    /// Scan for sessions whose transcript came from the fast engine and never
    /// got the second pass. A session recorded before `refine_with` was
    /// configured — or one whose refinement failed — keeps the first-pass
    /// transcript forever otherwise, which on Spanish audio means keeping the
    /// language drift. Rescanning at launch makes that self-healing.
    ///
    /// Sessions whose audio is gone are skipped: there is nothing left to
    /// re-run, and that is the expected state after the audio is pruned.
    func refinePending(root: URL) {
        guard let refinador = Config.refineWith() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let pending = entries
            .filter { dir in
                guard transcriptEngine(in: dir).map({ $0 != refinador }) == true else { return false }
                return hasAudio(in: dir)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for dir in pending where !pendingRefine.contains(dir) && !queue.contains(dir) {
            pendingRefine.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "refining \(pending.count) session(s) that never got the second pass\n".utf8
            ))
        }
        drainIfIdle()
    }

    /// Which engine produced the transcript currently on disk, from the
    /// `engine` field of transcript.json. nil when there is no transcript yet.
    private func transcriptEngine(in dir: URL) -> String? {
        let url = dir.appendingPathComponent("transcript.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["engine"] as? String
    }

    private func hasAudio(in dir: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return false }
        return files.contains { $0.hasSuffix(".caf") }
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !(queue.isEmpty && pendingRefine.isEmpty) else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        var refinables: [URL] = []
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir, using: preparedEngine())
                notifyUser(title: "quill — transcript ready", body: dir.lastPathComponent)
                runHook(for: dir)
                refinables.append(dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "quill — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
        }
        await engine?.release()
        engine = nil

        // Second pass, once the fast transcripts and their minutas are already
        // out: the slow engine reruns the same audio and replaces the
        // transcript. It runs after the queue drains so a refinement never
        // delays the next meeting's first pass. Sessions found unrefined at
        // launch ride along here, for the same reason and in the same way.
        let atrasadas = pendingRefine
        pendingRefine = []
        await refine(refinables + atrasadas.filter { !refinables.contains($0) })
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    /// Re-transcribe finished sessions with the configured `refine_with`
    /// engine and replace their transcripts. The first pass is kept alongside
    /// as transcript-<engine>.md: it has finer timestamps than an
    /// encoder-decoder model can produce, so it stays useful for navigating.
    private func refine(_ dirs: [URL]) async {
        guard let nombre = Config.refineWith(), !dirs.isEmpty else { return }
        guard let refinador = makeEngine(named: nombre) else {
            FileHandle.standardError.write(Data(
                "warning: unknown refine_with engine \"\(nombre)\" — skipping\n".utf8
            ))
            return
        }
        do {
            try await refinador.prepare()
        } catch {
            for dir in dirs { log(dir, "refine with \(nombre) unavailable: \(error)") }
            return
        }

        for dir in dirs {
            publish(.transcribing(session: dir.lastPathComponent, queued: 0))
            do {
                // La primera pasada no inventa sobre silencio: donde ella no oyo
                // nada, no hay nada. Se le pasa esa lectura al refinador para
                // que no le entregue silencio a un modelo que lo rellena.
                let pistas = PistasDeVoz.leer(de: dir)
                try preservePreviousTranscript(in: dir, from: Config.transcriptionEngine())
                log(dir, "refining transcript with \(nombre)")
                try await transcribe(dir, using: refinador, pistas: pistas)
                runHook(for: dir)
                notifyUser(
                    title: "quill — transcript refined",
                    body: "\(dir.lastPathComponent) · \(nombre)"
                )
            } catch {
                // The first transcript is already on disk and the minuta was
                // written from it, so a failed refinement costs nothing.
                log(dir, "refinement failed, keeping first transcript: \(error)")
            }
        }
        await refinador.release()
    }

    /// Copy transcript.md aside under the engine that produced it, so the
    /// refinement doesn't destroy the finer-grained timings of the first pass.
    private func preservePreviousTranscript(in dir: URL, from previo: String) throws {
        let fm = FileManager.default
        let actual = dir.appendingPathComponent("transcript.md")
        guard fm.fileExists(atPath: actual.path) else { return }
        let destino = dir.appendingPathComponent("transcript-\(previo).md")
        if fm.fileExists(atPath: destino.path) { try fm.removeItem(at: destino) }
        try fm.copyItem(at: actual, to: destino)
    }

    private func transcribe(
        _ dir: URL, using engine: TranscriptionEngine, pistas: PistasDeVoz? = nil
    ) async throws {
        let meta = try SessionMeta.read(from: dir)

        // Primero se transcribe todo y despues se decide si hay que separar
        // voces, porque esa decision depende de lo que trajo la OTRA pista.
        var porPista: [(track: SessionMeta.Track, audio: URL, segmentos: [TranscriptSegment])] = []
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            // Donde la pasada anterior oyo voz en ESTA pista. El engine puede
            // saltarse el resto en vez de adivinarlo por el nivel de audio.
            if let pistas {
                let offset = TimeInterval(track.offsetMs) / 1000
                await engine.usarPistasDeVoz(pistas.tramos(de: track.speaker, restando: offset))
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            porPista.append((track: track, audio: audio, segmentos: segments))
        }

        // Separar voces dentro de una pista solo se hace donde esta medido que
        // sirve: el microfono de una reunion sin audio remoto, o sea presencial
        // o por telefono con altavoz. Ahi todas las voces entran por el
        // microfono y hoy la minuta escribe que no supo quien hablo.
        //
        // Fuera de ese caso NO se toca. En una reunion remota el microfono trae
        // una sola persona y la pista ya es la respuesta; medido sobre una de 71
        // minutos, el agrupador parte esa unica voz en cuatro personas. No hay
        // umbral que arregle las dos cosas a la vez: probados de 0,6 a 0,8, el
        // que separa a dos personas en una sala es el mismo que parte en cuatro
        // a una persona sola. Mientras eso siga asi, separar de mas es peor que
        // no separar, porque una etiqueta equivocada se lee como un hecho.
        let textoRemoto = porPista
            .filter { $0.track.speaker != "me" }
            .reduce(0) { $0 + $1.segmentos.reduce(0) { $0 + $1.text.count } }
        let huboAudioRemoto = textoRemoto > 200

        var merged: [Transcript.Segment] = []
        // Los turnos crudos, por pista. Se guardan aparte para que el visor
        // pueda ponerle nombre a cada voz: ahi hay una persona que sabe cual es
        // cual, aqui solo hay audio.
        var vocesPorPista: [String: Voces] = [:]

        for (track, audio, segments) in porPista {
            var repartidos: [(voz: String?, segmento: TranscriptSegment)] =
                segments.map { (voz: nil, segmento: $0) }

            // Atribuir exige marcas por palabra. El motor refinador trabaja en
            // ventanas de media hora partida en tramos de ~28 s y no las
            // entrega: etiquetar uno de esos bloques con una sola voz pondria
            // una afirmacion segura encima de un tramo donde hablaron dos, y una
            // etiqueta equivocada se lee como un hecho. La version atribuida
            // queda en transcript-parakeet.md, que la pasada de refinamiento
            // conserva, junto al mapa de turnos en voces.json.
            let hayMarcasDePalabra = segments.contains { !$0.palabras.isEmpty }

            if Config.diarizeEnabled(), track.speaker == "me", !huboAudioRemoto,
               !segments.isEmpty, hayMarcasDePalabra {
                do {
                    let voces = try await diarizador.diarizar(
                        audio, umbral: Config.diarizeThreshold())
                    let reales = voces.vocesReales()
                    log(dir, "voces en \(track.file): \(reales.count) reales de "
                        + "\(voces.reparto.count) candidatas — "
                        + voces.reparto.prefix(4)
                            .map { String(format: "%@ %.0fs", $0.voz, $0.segundos) }
                            .joined(separator: ", "))
                    if reales.count > 1 {
                        repartidos = voces.repartir(segments)
                        vocesPorPista[track.speaker] = voces
                    }
                } catch {
                    // Una pista sin separar sigue siendo utilizable: queda
                    // etiquetada por canal, como antes de que esto existiera.
                    log(dir, "sin diarizar \(track.file): \(error)")
                }
            } else if Config.diarizeEnabled(), track.speaker == "me", !segments.isEmpty {
                log(dir, huboAudioRemoto
                    ? "sin separar voces: hubo audio remoto, el microfono trae "
                        + "una sola persona"
                    : "sin separar voces: \(engine.name) no entrega marcas por "
                        + "palabra; la version atribuida queda en el transcript "
                        + "de la primera pasada")
            }

            let offset = TimeInterval(track.offsetMs) / 1000
            merged += repartidos.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    voz: $0.voz,
                    start_ms: Int(($0.segmento.start + offset) * 1000),
                    end_ms: Int(($0.segmento.end + offset) * 1000),
                    text: $0.segmento.text
                )
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        if !vocesPorPista.isEmpty {
            try? MapaDeVoces(pistas: vocesPorPista.mapValues { $0.turnos },
                             huellas: vocesPorPista.mapValues { $0.huellas }).write(to: dir)
        }
        log(dir, "done — \(merged.count) segments")
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.transcriptionEngine()

        guard let engine = makeEngine(named: configured) else {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — using parakeet\n".utf8
            ))
            return try await prepared(ParakeetEngine())
        }

        // Missing cohere weights shouldn't cost the recording its transcript:
        // fall back to parakeet, which downloads its own models.
        do {
            return try await prepared(engine)
        } catch {
            guard configured == "cohere" else { throw error }
            FileHandle.standardError.write(Data(
                "warning: cohere unavailable (\(error)) — falling back to parakeet\n".utf8
            ))
            return try await prepared(ParakeetEngine())
        }
    }

    private func makeEngine(named name: String) -> TranscriptionEngine? {
        switch name {
        case "parakeet": return ParakeetEngine()
        case "cohere":
            return CohereEngine(
                modelDir: Config.cohereModelDir(),
                languageCode: Config.transcriptionLanguage()
            )
        default: return nil
        }
    }

    private func prepared(_ engine: TranscriptionEngine) async throws -> TranscriptionEngine {
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// Donde la pasada anterior oyo voz, leido de transcript.json.
///
/// Es el detector de voz mas barato disponible: la primera pasada ya corrio y
/// su motor devuelve vacio ante el silencio, asi que sus segmentos marcan
/// exactamente donde hay algo que transcribir. Mejor que medir el nivel de
/// audio, porque distingue voz de ruido y no solo fuerte de flojo.
private struct PistasDeVoz {
    /// Segmentos de la linea de tiempo comun, con su hablante.
    private let porHablante: [String: [ClosedRange<TimeInterval>]]

    /// Margen a cada lado de un segmento. La primera pasada recorta los bordes
    /// y una ventana del refinador es mucho mas larga que un segmento suyo; sin
    /// holgura se perderian arranques y colas de frase.
    private static let holgura: TimeInterval = 2

    static func leer(de dir: URL) -> PistasDeVoz? {
        let url = dir.appendingPathComponent("transcript.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let segs = json["segments"] as? [[String: Any]], !segs.isEmpty
        else { return nil }

        var mapa: [String: [ClosedRange<TimeInterval>]] = [:]
        for s in segs {
            guard
                let quien = s["speaker"] as? String,
                let ini = s["start_ms"] as? Int,
                let fin = s["end_ms"] as? Int
            else { continue }
            let desde = TimeInterval(ini) / 1000 - holgura
            let hasta = TimeInterval(fin) / 1000 + holgura
            mapa[quien, default: []].append(desde...max(desde, hasta))
        }
        return mapa.isEmpty ? nil : PistasDeVoz(porHablante: mapa)
    }

    /// Tramos de un hablante llevados al reloj propio de su pista.
    func tramos(de hablante: String, restando offset: TimeInterval) -> [ClosedRange<TimeInterval>] {
        (porHablante[hablante] ?? []).map {
            let a = $0.lowerBound - offset, b = $0.upperBound - offset
            return a...max(a, b)
        }
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
private struct Transcript: Codable {
    struct Segment: Codable {
        /// La pista por la que entro: "me" el microfono, "them" el sistema.
        let speaker: String
        /// Cual de las voces de esa pista, cuando hubo mas de una. La pista
        /// dice por que canal llego el audio, no quien hablo: en una reunion
        /// presencial todas las voces entran por el microfono.
        let voz: String?
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            // Con una sola voz por pista la etiqueta de siempre es la correcta
            // y mas clara. Con varias, decir "me" de todas seria falso.
            let quien = seg.voz ?? seg.speaker
            lines.append("**[\(Self.clock(seg.start_ms))] \(quien):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
