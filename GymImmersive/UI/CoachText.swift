import Foundation

/// Text shown by the coach, derived from session state so it can never disagree with it.
extension SessionController {
    var setTitle: String {
        guard let phase, phase != .rating else { return "Workout done" }
        let set = settings.config(forSet: phase.setIndex)
        let arm = phase.arm.map { " · \($0.label) arm" } ?? ""
        return "Round \(phase.setIndex) · \(Self.weightText(set.virtualWeightKg))\(arm)"
    }

    static func weightText(_ kg: Double) -> String { "\(Int(kg.rounded())) kg" }

    /// One or two big words.
    var coachHeadline: String {
        switch status {
        case .ready: return "Getting ready…"
        case .paused: return "Paused"
        case .completed: return "All done. Great job!"
        case .stopped: return "Stopped"
        case .running: break
        }
        guard let phase else { return "" }
        switch phase {
        case .prepare(let round, .curls, let arm):
            return arm == .left || round > 1 ? "Switch to your \(arm.label.lowercased()) hand" : "Get ready"
        case .prepare: return "Get ready"
        case .curls: return isUpHalfOfTempo ? "Up…" : "Down…"
        case .hold: return showArmUpCue ? "Lift your \(armWord) arm!" : "Hold your \(armWord) arm out"
        case .rating: return "All done!"
        case .rest: return "Rest"
        }
    }

    /// One short, plain sentence.
    var coachInstruction: String {
        switch status {
        case .paused: return "Tap Resume to go on."
        case .stopped, .completed: return "Your data is saved."
        default: break
        }
        guard let phase else { return "" }
        guard let set = currentSet else { return "" }
        let freeHand = activeArm.other.label.lowercased()
        let arm = armWord
        switch phase {
        case .prepare(_, .curls, _):
            return "Next: lift your \(arm) arm \(set.curlReps) times, slowly."
        case .prepare(_, .hold, _):
            return "Next: hold your \(arm) arm straight out for \(Int(set.holdDuration)) seconds."
        case .curls:
            return isColourGameActive
                ? "Same colour as 2 lifts ago? Tap your \(freeHand) thumb and finger together."
                : "Lift your \(arm) arm all the way up, then all the way down."
        case .hold:
            return isCognitiveActive ? "Take away \(settings.subtractionStep). Look at the answer and tap it." : "Keep it still."
        case .rest:
            return "Shake out your arm."
        case .rating:
            return ""
        }
    }

    /// "right" or "left": the arm holding the dumbbell.
    var armWord: String { activeArm.label.lowercased() }

    /// Visual metronome: first half of each up+down cycle is "up".
    var isUpHalfOfTempo: Bool {
        let cycle = settings.tempoUp + settings.tempoDown
        return session.phaseElapsed.truncatingRemainder(dividingBy: cycle) < settings.tempoUp
    }

    var repText: String? {
        guard case .curls = phase, let set = currentSet else { return nil }
        return "\(session.repsInPhase) of \(set.curlReps)"
    }

    /// Workout time left, shown large on the coach and on the wall board.
    var sessionCountdownText: String { Self.clockText(session.sessionRemaining) }

    static func clockText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
