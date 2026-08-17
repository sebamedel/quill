import Foundation

/// One timed span of recognized speech from a single track, relative to that
/// track's own start.
struct TranscriptSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Las palabras con su marca propia, si el motor las entrega.
    ///
    /// Existen para poder cortar un segmento por hablante. Un turno de
    /// conversacion dura un par de segundos y un segmento suele abarcar varios,
    /// asi que preguntarle a un segmento "de quien es" fuerza a elegir una sola
    /// voz para un tramo donde hablaron dos. Con las palabras el corte cae
    /// donde de verdad cambio el hablante. Los motores que trabajan por
    /// ventanas largas no las tienen y dejan esto vacio.
    let palabras: [Palabra]

    init(start: TimeInterval, end: TimeInterval, text: String, palabras: [Palabra] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.palabras = palabras
    }
}

/// Una palabra con su tramo propio dentro de la pista.
struct Palabra: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let texto: String
}

/// A speech-to-text engine quill can run locally. Engines are prepared lazily
/// (model download + load) when the transcription queue has work and released
/// when it drains, so quill never idles holding gigabytes of model weights.
protocol TranscriptionEngine: Sendable {
    /// Short engine identifier recorded as transcript.json provenance.
    var name: String { get }
    /// Concrete model identifier recorded as transcript.json provenance.
    var model: String { get }
    func prepare() async throws
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment]
    func release() async

    /// Where the previous pass found speech in this track, in track-local
    /// seconds. A refining engine can use it to skip the rest instead of
    /// guessing from the audio level.
    ///
    /// It exists because the two passes complement each other: the fast engine
    /// returns nothing for silence, so its segments are a speech detector that
    /// has already been paid for. Engines that don't need the hint ignore it.
    func usarPistasDeVoz(_ tramos: [ClosedRange<TimeInterval>]) async
}

extension TranscriptionEngine {
    func usarPistasDeVoz(_ tramos: [ClosedRange<TimeInterval>]) async {}
}
