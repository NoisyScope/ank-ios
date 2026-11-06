import AVFoundation

/// Speaks Anki's {{tts}} tags with the voices installed on the device.
/// ponytail: [sound:] files aren't played yet, only TTS. Add a player when audio decks need it.
@MainActor final class Speech {
    struct Option { let id, name, language: String, quality: Int }

    private let synth = AVSpeechSynthesizer()
    #if SELFTEST
    var history: [String] = []
    #endif

    func play(_ tags: [Anki_CardRendering_TTSTag]) {
        stop()
        let spoken = tags.filter { !$0.fieldText.isEmpty }
        guard !spoken.isEmpty else { return }
        // Playback, so speech is still heard with the ringer switched to silent.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        for tag in spoken {
            #if SELFTEST
            history.append(tag.fieldText)
            #endif
            let u = AVSpeechUtterance(string: tag.fieldText)
            u.voice = Self.voice(for: tag)
            u.rate = min(AVSpeechUtteranceDefaultSpeechRate * tag.speed, AVSpeechUtteranceMaximumSpeechRate)
            synth.speak(u)
        }
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    private static func voice(for tag: Anki_CardRendering_TTSTag) -> AVSpeechSynthesisVoice? {
        let installed = AVSpeechSynthesisVoice.speechVoices().map {
            Option(id: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality.rawValue)
        }
        if let id = choose(lang: tag.lang, voices: tag.voices, from: installed) { return AVSpeechSynthesisVoice(identifier: id) }
        return AVSpeechSynthesisVoice(language: tag.lang.replacingOccurrences(of: "_", with: "-"))
    }

    /// The first requested voice that's installed, or else the best voice for the language.
    /// Names come from desktop: macOS's "Anna (Premium)" is written Apple_Anna_(Premium).
    nonisolated static func choose(lang: String, voices: [String], from installed: [Option]) -> String? {
        let code = lang.replacingOccurrences(of: "_", with: "-").lowercased()
        var matches = installed.filter { $0.language.lowercased() == code }
        if matches.isEmpty { matches = installed.filter { $0.language.lowercased().hasPrefix(code.prefix(2) + "-") } }
        matches.sort { $0.quality > $1.quality }
        for wanted in voices {
            let name = wanted.replacingOccurrences(of: "Apple_", with: "").replacingOccurrences(of: "_", with: " ").lowercased()
            if let m = matches.first(where: { $0.name.lowercased() == name }) ?? matches.first(where: { name.hasPrefix($0.name.lowercased()) }) {
                return m.id
            }
        }
        return matches.first?.id
    }
}
