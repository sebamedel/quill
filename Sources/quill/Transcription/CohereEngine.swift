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

    private let modelDir: URL
    private let languageCode: String
    private let pipeline = CoherePipeline()
    private var models: CoherePipeline.LoadedModels?

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

        for ventana in Self.ventanas(samples, sampleRate: sr) {
            guard let language = CohereAsrConfig.Language(rawValue: languageCode) else {
                throw EngineError.unknownLanguage(languageCode)
            }
            let result = try await pipeline.transcribe(
                audio: Array(samples[ventana]),
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
        return out
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
