import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name: "parakeet" (default, fast) or "cohere" (slower
    /// but conditioned on an explicit language). The coordinator warns and
    /// falls back to parakeet for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    /// Optional second engine that re-transcribes each session after the first
    /// one finishes. The point is to get both: parakeet returns in seconds so
    /// the minuta lands right after the meeting, then the slower engine
    /// replaces the transcript with a faithful one. Nil disables the pass.
    static func refineWith() -> String? {
        guard let name = transcription()?["refine_with"] as? String,
              !name.isEmpty, name != transcriptionEngine()
        else { return nil }
        return name
    }

    /// Language code fed to engines that condition on one ("es", "en", …).
    /// Ignored by parakeet, which detects the language on its own.
    static func transcriptionLanguage() -> String {
        transcription()?["language"] as? String ?? "es"
    }

    /// Directory holding the cohere Core ML weights. Unlike parakeet, these
    /// are not downloaded automatically — they are ~2.2 GB fetched once by
    /// hand, so their location is configurable.
    static func cohereModelDir() -> URL {
        if let dir = transcription()?["cohere_model_dir"] as? String, !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quill/models/cohere", isDirectory: true)
    }

    /// Separar las voces dentro de una pista. Encendido por omision: en una
    /// reunion remota no cambia nada (una voz por pista) y en una presencial es
    /// la diferencia entre una minuta con nombres y una que dice que no supo
    /// quien hablo.
    static func diarizeEnabled() -> Bool {
        transcription()?["diarize"] as? Bool ?? true
    }

    /// Umbral de agrupamiento de voces. Ver `Diarizador.umbralPorOmision` para
    /// de donde sale el numero; se deja configurable porque depende de la sala.
    static func diarizeThreshold() -> Float {
        if let n = transcription()?["diarize_threshold"] as? Double { return Float(n) }
        return Diarizador.umbralPorOmision
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    /// Combinacion global para iniciar y parar la grabacion, o nil si se apago
    /// dejandola vacia. Por omision hay una: el caso que resuelve (acordarse de
    /// grabar cuando la reunion ya empezo y estas en otra ventana) es el comun,
    /// y quien no la quiera la borra.
    static func atajo() -> String? {
        guard let v = load()?["hotkey"] as? String else { return "cmd+alt+r" }
        let limpio = v.trimmingCharacters(in: .whitespaces)
        return limpio.isEmpty ? nil : limpio
    }

    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
