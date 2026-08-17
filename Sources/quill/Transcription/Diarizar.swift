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
/// Este subcomando existe para juzgar el corte sobre grabaciones reales sin
/// tocar los transcripts ya escritos. Con `--con-texto` transcribe la pista con
/// el motor rapido y reparte el texto entre las voces usando exactamente el
/// mismo codigo que la tuberia, `Voces.repartir`: lo que se lee aqui es lo que
/// va a quedar en el transcript.
///
///     quill diarizar ~/Recordings/2026.08.14-1226/mic.caf --con-texto
struct Diarizar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diarizar",
        abstract: "Separa las voces de una pista y muestra los turnos."
    )

    @Argument(help: "Pista de audio (mic.caf o system.caf).")
    var audio: String

    @Option(help: "Umbral de agrupamiento; mas bajo separa mas voces.")
    var umbral: Float?

    @Flag(help: "Transcribe la pista y reparte el texto entre las voces.")
    var conTexto = false

    @Option(help: "Cuantas lineas de texto mostrar.")
    var lineas: Int = 40

    /// Sincrono a proposito, aunque adentro sea todo asincrono.
    ///
    /// ArgumentParser exige que la raiz sea asincrona para admitir un
    /// subcomando asincrono, y volver asincrona la raiz cambia donde corre el
    /// subcomando `run`: pasa a una Task en vez del hilo principal, y ahi el
    /// `MainActor.assumeIsolated` con el que arranca el daemon deja de ser una
    /// suposicion valida y trampea antes de imprimir nada. Un comando de
    /// diagnostico no vale romper el arranque del programa, asi que la espera
    /// se hace aqui.
    func run() throws {
        // Los argumentos se copian a valores sueltos: la Task no puede capturar
        // self, que no es Sendable.
        let ruta = (audio as NSString).expandingTildeInPath
        let umbralUsado = umbral ?? Diarizador.umbralPorOmision
        let texto = conTexto
        let cuantas = lineas

        let espera = DispatchSemaphore(value: 0)
        let caja = CajaDeFallo()
        Task {
            do { try await Self.ejecutar(ruta, umbralUsado, texto, cuantas) }
            catch { caja.guardar(error) }
            espera.signal()
        }
        espera.wait()
        if let fallo = caja.leerSincrono() { throw fallo }
    }

    /// Guarda el error de la Task para relanzarlo desde run(). Una variable
    /// local capturada por la Task no compila bajo concurrencia estricta.
    private final class CajaDeFallo: @unchecked Sendable {
        private let candado = NSLock()
        private var fallo: Error?
        func guardar(_ e: Error) { candado.lock(); fallo = e; candado.unlock() }
        func leerSincrono() -> Error? { candado.lock(); defer { candado.unlock() }; return fallo }
    }

    private static func ejecutar(
        _ ruta: String, _ umbralUsado: Float, _ conTexto: Bool, _ lineas: Int
    ) async throws {
        let url = URL(fileURLWithPath: ruta)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("no existe \(url.path)")
        }
        print("umbral de agrupamiento: \(umbralUsado)")

        let arranque = Date()
        let voces = try await Diarizador().diarizar(url, umbral: umbralUsado)
        let listo = Date()

        let reales = voces.vocesReales()
        print(String(format: "diarizacion en %.1f s", listo.timeIntervalSince(arranque)))
        print("\(voces.turnos.count) turnos · \(reales.count) voces reales "
            + "de \(voces.reparto.count) candidatas\n")
        for (voz, seg) in voces.reparto {
            let total = voces.reparto.reduce(0.0) { $0 + $1.segundos }
            let marca = reales.contains(voz) ? "•" : " "
            print(String(format: "  %@ %-8@ %6.1f s  %4.1f %%",
                         marca, voz, seg, seg / max(total, 0.001) * 100))
        }
        guard conTexto else { return }

        print("\ntranscribiendo con el motor rapido…")
        let motor = ParakeetEngine()
        try await motor.prepare()
        let segmentos = try await motor.transcribe(url)
        await motor.release()

        let repartidos = voces.repartir(segmentos)
        print("\(segmentos.count) segmentos entran, \(repartidos.count) salen "
            + "tras cortar donde cambia la voz\n")
        for (voz, seg) in repartidos.prefix(lineas) {
            print(String(format: "[%6.1f] %-8@ %@", seg.start, voz ?? "?", seg.text))
        }
        if repartidos.count > lineas {
            print("… y \(repartidos.count - lineas) mas")
        }
    }
}
