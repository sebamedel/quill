import ArgumentParser
import FluidAudio
import Foundation

/// Separa las voces de una pista y dice quien hablo cuando.
///
/// quill graba dos pistas, el microfono y el audio del sistema, y por eso
/// distinguir entre uno mismo y el otro sale gratis en una reunion remota. Pero
/// cuando la reunion es presencial o por telefono con altavoz, todas las voces
/// entran por el microfono y la pista vuelve a ser una sola: la minuta escribe
/// que no puede saber quien dijo cada cosa.
///
/// Este subcomando existe para medir, sobre grabaciones reales, si la
/// diarizacion de FluidAudio resuelve ese caso antes de meterla en la tuberia.
/// Se corre a mano:
///
///     quill diarizar ~/Recordings/2026.08.14-1108/mic.caf
///
/// Imprime los turnos detectados y, si hay un transcript al lado, el texto que
/// cae en cada turno, que es la unica forma de juzgar si el corte quedo donde
/// corresponde.
struct Diarizar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diarizar",
        abstract: "Separa las voces de una pista y muestra los turnos."
    )

    @Argument(help: "Pista de audio (mic.caf o system.caf).")
    var audio: String

    @Option(help: "Umbral de agrupamiento; mas bajo separa mas voces.")
    var umbral: Float?

    @Flag(help: "Muestra el texto del transcript que cae en cada turno.")
    var conTexto = false

    /// El transcript refinado viene en bloques de media hora partida en
    /// ventanas de ~28 s, y un turno dura segundos: cada turno se lleva el
    /// bloque entero y el texto se repite. La primera pasada tiene marcas
    /// finas, que son las que sirven para juzgar el corte.
    @Flag(help: "Usa transcript-parakeet.md (marcas finas) en vez del refinado.")
    var conParakeet = false

    func run() async throws {
        let url = URL(fileURLWithPath: (audio as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("no existe \(url.path)")
        }

        var config = DiarizerConfig.default
        if let umbral { config.clusteringThreshold = umbral }
        print("umbral de agrupamiento: \(config.clusteringThreshold)")

        let arranque = Date()
        let muestras = try AudioConverter().resampleAudioFile(url)
        let duracion = Double(muestras.count) / 16000
        print(String(format: "pista: %.1f s (%.1f min)", duracion, duracion / 60))

        print("cargando modelos…")
        let modelos = try await DiarizerModels.downloadIfNeeded()
        let diarizador = DiarizerManager(config: config)
        diarizador.initialize(models: modelos)
        let cargados = Date()

        let resultado = try diarizador.performCompleteDiarization(muestras)
        let listo = Date()

        let turnos = resultado.segments
        let voces = Set(turnos.map(\.speakerId)).sorted()
        print(String(
            format: "modelos %.1f s · diarizacion %.1f s (%.0f× tiempo real)",
            cargados.timeIntervalSince(arranque),
            listo.timeIntervalSince(cargados),
            duracion / max(listo.timeIntervalSince(cargados), 0.001)))
        print("\(turnos.count) turnos, \(voces.count) voces: \(voces.joined(separator: ", "))")

        // Cuanto habla cada voz: si una reunion de dos sale 97/3, el corte esta
        // mal y no hay que creerle al numero de voces.
        var hablado: [String: Double] = [:]
        for t in turnos {
            hablado[t.speakerId, default: 0] += Double(t.durationSeconds)
        }
        let total = hablado.values.reduce(0, +)
        print("")
        for (voz, seg) in hablado.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %@  %6.1f s  %4.1f %%", voz, seg, seg / max(total, 0.001) * 100))
        }

        guard conTexto else { return }
        let segmentos = conParakeet
            ? Self.segmentosDeParakeet(junto: url)
            : Self.transcriptSegments(junto: url)
        guard !segmentos.isEmpty else {
            print("\n(no hay transcript.json al lado, o no tiene segmentos de esta pista)")
            return
        }
        print("\nturnos con el texto que les cae encima:\n")
        for t in turnos.prefix(40) {
            let ini = Double(t.startTimeSeconds), fin = Double(t.endTimeSeconds)
            // Se le asigna a un turno el texto cuyo tramo se solapa con el.
            let texto = segmentos
                .filter { $0.fin > ini && $0.ini < fin }
                .map(\.texto)
                .joined(separator: " ")
            let recorte = texto.count > 160 ? String(texto.prefix(160)) + "…" : texto
            print(String(format: "[%6.1f–%6.1f] %@: %@", ini, fin, t.speakerId, recorte))
        }
        if turnos.count > 40 { print("… y \(turnos.count - 40) turnos mas") }
    }

    /// Lee las marcas de la primera pasada desde transcript-parakeet.md.
    /// Se lee del .md porque el .json se sobreescribe al refinar: del primer
    /// motor solo queda el texto renderizado.
    private static func segmentosDeParakeet(junto audio: URL) -> [Trozo] {
        let dir = audio.deletingLastPathComponent()
        let pista = audio.lastPathComponent.hasPrefix("mic") ? "me" : "them"
        guard let texto = try? String(
            contentsOf: dir.appendingPathComponent("transcript-parakeet.md"), encoding: .utf8)
        else { return [] }

        var trozos: [Trozo] = []
        for linea in texto.split(separator: "\n") {
            // Formato: **[m:ss] me:** texto
            guard linea.hasPrefix("**["), let cierre = linea.firstIndex(of: "]") else { continue }
            let marca = String(linea[linea.index(linea.startIndex, offsetBy: 3)..<cierre])
            let resto = linea[linea.index(after: cierre)...]
            guard let dosPuntos = resto.range(of: ":** ") else { continue }
            let quien = resto[..<dosPuntos.lowerBound]
                .trimmingCharacters(in: CharacterSet(charactersIn: " *"))
            guard quien == pista else { continue }

            let partes = marca.split(separator: ":").compactMap { Double($0) }
            guard !partes.isEmpty else { continue }
            let ini = partes.count == 3
                ? partes[0] * 3600 + partes[1] * 60 + partes[2]
                : partes[0] * 60 + partes[1]
            // El .md no trae el fin; se asume hasta el inicio del siguiente.
            trozos.append(Trozo(ini: ini, fin: ini, texto: String(resto[dosPuntos.upperBound...])))
        }
        // Cerrar cada trozo donde empieza el siguiente, con tope de 15 s para
        // que un silencio largo no estire el ultimo hasta el infinito.
        return trozos.enumerated().map { i, t in
            let siguiente = i + 1 < trozos.count ? trozos[i + 1].ini : t.ini + 15
            return Trozo(ini: t.ini, fin: min(siguiente, t.ini + 15), texto: t.texto)
        }
    }

    private struct Trozo {
        let ini: Double
        let fin: Double
        let texto: String
    }

    /// Lee del transcript los segmentos de la pista que estamos diarizando.
    /// Las marcas de tiempo del transcript son de la sesion completa y las del
    /// diarizador son de la pista, asi que hay que restar el desfase.
    private static func transcriptSegments(junto audio: URL) -> [Trozo] {
        let dir = audio.deletingLastPathComponent()
        let pista = audio.lastPathComponent.hasPrefix("mic") ? "me" : "them"
        guard
            let datos = try? Data(contentsOf: dir.appendingPathComponent("transcript.json")),
            let raiz = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
            let segs = raiz["segments"] as? [[String: Any]]
        else { return [] }

        var desfase = 0.0
        if let meta = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
           let m = try? JSONSerialization.jsonObject(with: meta) as? [String: Any],
           let offsets = m["offsets_ms"] as? [String: Any],
           let ms = offsets[pista == "me" ? "mic" : "system"] as? Double {
            desfase = ms / 1000
        }

        return segs.compactMap { s in
            guard (s["speaker"] as? String) == pista,
                  let ini = s["start_ms"] as? Double,
                  let fin = s["end_ms"] as? Double,
                  let texto = s["text"] as? String
            else { return nil }
            return Trozo(ini: ini / 1000 - desfase, fin: fin / 1000 - desfase, texto: texto)
        }
    }
}
