import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Cohere Transcribe 03-2026 via FluidAudio's Core ML port. Slower than
/// parakeet (~6x realtime instead of ~450x) and much heavier on disk (2.2 GB
/// of weights, loaded from a local directory rather than downloaded), but it
/// conditions the decoder on an explicit language and stops the language drift
/// that makes parakeet hallucinate English and Italian mid-sentence on Chilean
/// Spanish.
///
/// The model is encoder-decoder, so unlike the TDT models it emits no token
/// timings at all — its result is bare text. Timing is recovered by cutting
/// the audio ourselves and transcribing window by window: each window's offset
/// is known, so every segment lands within a few seconds of the truth even
/// though the model never reports a timestamp.
actor CohereEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case modelsMissing(URL)
        case unknownLanguage(String)
        case unreadableAudio(URL, Error)

        var description: String {
            switch self {
            case .notPrepared: return "cohere engine used before prepare()"
            case .modelsMissing(let dir):
                return "cohere models not found in \(dir.path) — expected "
                    + "cohere_encoder.mlmodelc, cohere_decoder_cache_external_v2.mlmodelc "
                    + "and vocab.json"
            case .unknownLanguage(let code):
                let validos = CohereAsrConfig.Language.allCases
                    .map(\.rawValue).sorted().joined(separator: ", ")
                return "cohere doesn't support language \"\(code)\" — pick one of: \(validos)"
            case .unreadableAudio(let url, let e):
                return "unreadable audio \(url.lastPathComponent): \(e)"
            }
        }
    }

    nonisolated let name = "cohere"
    nonisolated let model = "cohere-transcribe-03-2026-q8-coreml"

    /// The model caps a single call at 35 s of audio, so windows stay safely
    /// under it. The cut lands wherever the audio is quietest in the search
    /// band, which keeps words from being sliced in half and makes segment
    /// boundaries fall on natural pauses.
    private static let targetWindow: Double = 30
    private static let minWindow: Double = 22
    private static let maxWindow: Double = 34

    /// Silence gate. Windows quieter than the threshold are never sent to the
    /// model.
    ///
    /// Encoder-decoder models confabulate on silence: asked to transcribe a
    /// near-silent window, this one emits memorised passages from its training
    /// data rather than nothing. On a 71-minute meeting the two minutes of
    /// waiting before anyone spoke came back as a paragraph about the Palermo
    /// mafia, repeated almost verbatim eight times. Parakeet doesn't do this —
    /// it returns empty — so the gate is only needed here.
    ///
    /// The threshold is relative to each track, not absolute: a different
    /// microphone, a different room or a different input gain moves every level
    /// at once, and a fixed number calibrated on today's setup would either
    /// stop biting or start eating quiet speech. The reference is the 90th
    /// percentile of the track's own windows — robust to a single loud cough —
    /// and the gate sits `margenDB` below it.
    ///
    /// Measured on that meeting, per 30 s window: the system track runs -30 to
    /// -23 dBFS while speaking and -82 in silence; the microphone runs -40 to
    /// -22 and its noise floor is -53. A 20 dB margin gates both silences and
    /// still leaves 5 dB of headroom under the quietest real speech, which is
    /// the tightest of the two cases.
    private static let margenDB: Float = 20

    /// Guardrails for tracks where the percentile is meaningless. A recording
    /// that is silence end to end would otherwise place the gate below its own
    /// silence and let everything through; one recorded very hot would place it
    /// above normal speech and swallow it.
    private static let umbralMinimoDBFS: Float = -60
    private static let umbralMaximoDBFS: Float = -40

    private let modelDir: URL
    private let languageCode: String
    private let pipeline = CoherePipeline()
    private var models: CoherePipeline.LoadedModels?

    /// Tramos donde la primera pasada encontro voz, en segundos de esta pista.
    /// Cuando estan, mandan sobre la compuerta de energia: son una senal de
    /// contenido y no de volumen, asi que no se dejan enganar por una pista con
    /// mucho ruido de fondo. Se consumen al transcribir para que no se filtren
    /// de una pista a la siguiente.
    private var pistasDeVoz: [ClosedRange<TimeInterval>]?

    func usarPistasDeVoz(_ tramos: [ClosedRange<TimeInterval>]) async {
        pistasDeVoz = tramos
    }

    /// `languageCode` is validated in `prepare()` rather than here, so the
    /// coordinator never has to know FluidAudio's types.
    init(modelDir: URL, languageCode: String) {
        self.modelDir = modelDir
        self.languageCode = languageCode
    }

    func prepare() async throws {
        guard models == nil else { return }
        guard CohereAsrConfig.Language(rawValue: languageCode) != nil else {
            throw EngineError.unknownLanguage(languageCode)
        }
        let fm = FileManager.default
        for pieza in ["cohere_encoder.mlmodelc",
                      "cohere_decoder_cache_external_v2.mlmodelc",
                      "vocab.json"] {
            guard fm.fileExists(atPath: modelDir.appendingPathComponent(pieza).path) else {
                throw EngineError.modelsMissing(modelDir)
            }
        }
        models = try await CoherePipeline.loadModels(
            encoderDir: modelDir,
            decoderDir: modelDir,
            vocabDir: modelDir,
            decoderVariant: .v2,
            computeUnits: .all
        )
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let models else { throw EngineError.notPrepared }

        let samples: [Float]
        do {
            samples = try AudioConverter().resampleAudioFile(audio)
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }
        guard !samples.isEmpty else { return [] }

        let sr = CohereAsrConfig.sampleRate
        var out: [TranscriptSegment] = []

        let ventanas = Self.ventanas(samples, sampleRate: sr)
        let niveles = ventanas.map { Self.nivelDBFS(samples, en: $0) }
        let umbral = Self.umbralSilencio(niveles)
        let pistas = pistasDeVoz
        pistasDeVoz = nil                 // valen para una pista, no para la siguiente

        var silenciadas = 0
        for (i, ventana) in ventanas.enumerated() {
            guard let language = CohereAsrConfig.Language(rawValue: languageCode) else {
                throw EngineError.unknownLanguage(languageCode)
            }
            // Se descarta antes de llamar al modelo: no hay nada que reconocer
            // y lo que devuelve para silencio es invencion pura. Si la primera
            // pasada dijo donde hay voz se le hace caso a eso; si no, se cae al
            // nivel de audio, que es peor pero es lo unico disponible.
            let hayVoz: Bool
            if let pistas {
                let desde = Double(ventana.lowerBound) / Double(sr)
                let hasta = Double(ventana.upperBound) / Double(sr)
                hayVoz = pistas.contains { $0.lowerBound < hasta && $0.upperBound > desde }
            } else {
                hayVoz = niveles[i] >= umbral
            }
            guard hayVoz else {
                silenciadas += 1
                continue
            }
            let trozo = Array(samples[ventana])
            let result = try await pipeline.transcribe(
                audio: trozo,
                models: models,
                language: language
            )
            let texto = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !texto.isEmpty else { continue }
            out.append(TranscriptSegment(
                start: Double(ventana.lowerBound) / Double(sr),
                end: Double(ventana.upperBound) / Double(sr),
                text: texto
            ))
        }
        // Se deja constancia: si un transcript sale corto, esta linea dice si
        // fue por la compuerta y no hay que ir a adivinarlo.
        if silenciadas > 0 {
            let motivo = pistas == nil
                ? String(format: "bajo %.1f dBFS", umbral)
                : "sin voz segun la primera pasada"
            let aviso = "cohere: \(silenciadas) ventana(s) omitidas por estar \(motivo) "
                + "en \(audio.lastPathComponent)\n"
            FileHandle.standardError.write(Data(aviso.utf8))
        }
        return Self.sinRepeticiones(out, archivo: audio.lastPathComponent)
    }

    /// Segunda defensa contra la confabulacion, por la forma del texto y no por
    /// el volumen.
    ///
    /// La compuerta de energia falla cuando el ruido de fondo se acerca al
    /// nivel de la voz: ahi la ventana entra al modelo y puede volver inventada
    /// igual. Pero la invencion tiene una firma reconocible: el modelo emite el
    /// MISMO pasaje memorizado una y otra vez. En la reunion donde se detecto
    /// esto, el mismo parrafo sobre la mafia de Palermo aparecio cinco veces
    /// palabra por palabra.
    ///
    /// Se descartan solo los textos largos repetidos tres veces o mas. El largo
    /// importa: "Ya.", "Si." o "Correcto." se repiten de verdad en cualquier
    /// conversacion y hay que conservarlos, mientras que una frase de mas de
    /// 120 caracteres identica tres veces no ocurre hablando.
    static func sinRepeticiones(
        _ segmentos: [TranscriptSegment], archivo: String = ""
    ) -> [TranscriptSegment] {
        var cuenta: [String: Int] = [:]
        for s in segmentos {
            let t = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 120 { cuenta[t, default: 0] += 1 }
        }
        let sospechosos = Set(cuenta.filter { $0.value >= 3 }.keys)
        guard !sospechosos.isEmpty else { return segmentos }

        let limpio = segmentos.filter {
            !sospechosos.contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let aviso = "cohere: \(segmentos.count - limpio.count) segmento(s) descartados por "
            + "repetirse identicos en \(archivo) — invencion sobre silencio\n"
        FileHandle.standardError.write(Data(aviso.utf8))
        return limpio
    }

    /// Umbral de silencio para esta pista: 20 dB bajo su percentil 90, acotado
    /// para que una grabacion enteramente silenciosa o uno muy saturada no
    /// terminen con la compuerta en un lugar absurdo.
    static func umbralSilencio(_ niveles: [Float]) -> Float {
        let finitos = niveles.filter { $0.isFinite }.sorted()
        guard !finitos.isEmpty else { return umbralMaximoDBFS }
        let p90 = finitos[Int(0.9 * Float(finitos.count - 1))]
        return min(max(p90 - margenDB, umbralMinimoDBFS), umbralMaximoDBFS)
    }

    /// Nivel RMS de una ventana en dBFS. -infinito para silencio digital.
    private static func nivelDBFS(_ samples: [Float], en rango: Range<Int>) -> Float {
        guard !rango.isEmpty else { return -.infinity }
        var suma: Float = 0
        for i in rango { suma += samples[i] * samples[i] }
        let rms = (suma / Float(rango.count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -.infinity
    }

    func release() async {
        models = nil
    }

    // MARK: - troceo

    /// Split the track into windows that end on the quietest point available,
    /// so a cut rarely falls in the middle of a word.
    static func ventanas(_ samples: [Float], sampleRate sr: Int) -> [Range<Int>] {
        let maxLen = Int(maxWindow * Double(sr))
        let minLen = Int(minWindow * Double(sr))
        let target = Int(targetWindow * Double(sr))

        var out: [Range<Int>] = []
        var inicio = 0
        while inicio < samples.count {
            if samples.count - inicio <= maxLen {
                out.append(inicio..<samples.count)
                break
            }
            let corte = puntoMasSilencioso(
                samples,
                desde: inicio + minLen,
                hasta: min(inicio + maxLen, samples.count),
                sampleRate: sr
            ) ?? (inicio + target)
            out.append(inicio..<corte)
            inicio = corte
        }
        return out
    }

    /// Index of the lowest-energy 100 ms frame in the search band. Returns nil
    /// when the band is degenerate, and the caller falls back to a fixed cut.
    private static func puntoMasSilencioso(
        _ samples: [Float], desde: Int, hasta: Int, sampleRate sr: Int
    ) -> Int? {
        let marco = sr / 10                      // 100 ms
        guard hasta - desde > marco else { return nil }

        var mejorIndice = desde
        var mejorEnergia = Float.greatestFiniteMagnitude
        var i = desde
        while i + marco <= hasta {
            var energia: Float = 0
            for j in i..<(i + marco) { energia += samples[j] * samples[j] }
            if energia < mejorEnergia {
                mejorEnergia = energia
                mejorIndice = i + marco / 2      // cortar al medio del silencio
            }
            i += marco
        }
        return mejorIndice
    }
}
