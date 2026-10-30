import AVFoundation

@MainActor
protocol CoachSpeaking: AnyObject {
    func speak(_ text: String)
    func stop()
}

/// Spoken coach cues. New cues interrupt stale ones so speech never lags behind the workout.
@MainActor
final class CoachVoice: CoachSpeaking {
    private let synthesizer = AVSpeechSynthesizer()
    var isEnabled = true

    func speak(_ text: String) {
        guard isEnabled else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.volume = 0.9
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

/// Used by tests and when spoken cues are switched off.
@MainActor
final class SilentCoach: CoachSpeaking {
    private(set) var spoken: [String] = []
    func speak(_ text: String) { spoken.append(text) }
    func stop() {}
}
