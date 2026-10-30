import Foundation

/// Text shown by the coach, derived from session state so it can never disagree with it.
extension SessionController {
    var setTitle: String {
        guard let phase else { return "GymImmersive" }
        let set = settings.config(forSet: phase.setIndex)
        let name = phase.setIndex == 0 ? "Practice" : "Set \(phase.setIndex) of \(settings.sets.count)"
        return "\(name) · \(Self.weightText(set.virtualWeightKg))"
    }

    static func weightText(_ kg: Double) -> String { "\(Int(kg.rounded())) kg" }

    var coachHeadline: String {
        switch status {
        case .ready: return "Getting ready…"
        case .paused(.trackingLost): return "Paused: hand not visible"
        case .paused(.appInactive): return "Paused"
        case .paused: return "Paused"
        case .completed: return "Workout complete. Great job!"
        case .stopped: return "Session stopped"
        case .running: break
        }
        guard let phase else { return "" }
        switch phase {
        case .prepare(0, _): return "Practice set: get ready"
        case .prepare(_, .curls): return "Get ready to curl"
        case .prepare(_, .hold): return "Get into position"
        case .curls:
            if isCognitiveActive, let color = plateColor { return "\(color.displayName)! Match? Pinch!" }
            return isUpHalfOfTempo ? "Curl up…" : "…and down"
        case .hold: return showArmUpCue ? "Arm up!" : "Hold it!"
        case .rating: return "How'd that set feel?"
        case .rest: return "Rest and breathe"
        }
    }

    var coachInstruction: String {
        switch status {
        case .paused(.trackingLost):
            return "Bring your \(info.dumbbellHand.label.lowercased()) hand back in front of you, then tap Resume."
        case .paused: return "Tap Resume when you're ready, or Stop to end."
        case .stopped: return "Your data so far has been saved."
        case .completed: return "All sets done. Your data has been saved."
        default: break
        }
        guard let phase, let set = currentSet else { return "" }
        let tempo = "\(Int(settings.tempoUp)) s up, \(Int(settings.tempoDown)) s down"
        switch phase {
        case .prepare(0, _):
            return "\(set.curlReps) curls, \(tempo). Stop at any time if you feel pain or dizziness."
        case .prepare(_, .curls):
            let task = isCognitiveActive
                ? " Watch the plate colour: pinch your \(info.dumbbellHand.other.label.lowercased()) hand when it matches the colour from 2 reps ago."
                : ""
            return "\(set.curlReps) curls, \(tempo).\(task)"
        case .prepare(_, .hold):
            return "Straighten your arm in front of you at shoulder height. Hold \(Int(set.holdDuration)) s."
                + (isCognitiveActive ? " Count down by \(settings.subtractionStep)s and pick each answer." : "")
        case .curls:
            return isCognitiveActive
                ? "Pinch your \(info.dumbbellHand.other.label.lowercased()) hand if this colour matches 2 reps ago."
                : "Full range: arm straight at the bottom, hand to shoulder at the top."
        case .hold:
            return isCognitiveActive ? "Keep the arm straight at shoulder height." : "Arm straight, at shoulder height. Stay steady."
        case .rating: return "Rate each scale, then tap Done."
        case .rest: return "Next: \(nextSetDescription)"
        }
    }

    /// Visual metronome: first half of each up+down cycle is "up".
    var isUpHalfOfTempo: Bool {
        let cycle = settings.tempoUp + settings.tempoDown
        return session.phaseElapsed.truncatingRemainder(dividingBy: cycle) < settings.tempoUp
    }

    /// 0 at the bottom, 1 at the top of the coached curl tempo.
    var tempoGuide: Double {
        let cycle = settings.tempoUp + settings.tempoDown
        let t = session.phaseElapsed.truncatingRemainder(dividingBy: cycle)
        return t < settings.tempoUp ? t / settings.tempoUp : 1 - (t - settings.tempoUp) / settings.tempoDown
    }

    var repText: String? {
        guard case .curls = phase, let set = currentSet else { return nil }
        return "\(session.repsInPhase) / \(set.curlReps) reps"
    }

    var countdownText: String? {
        guard let remaining = session.phaseRemaining else { return nil }
        let s = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var nextSetDescription: String {
        guard let phase, case .rest(let after) = phase, after + 1 <= settings.sets.count else { return "" }
        let next = settings.sets[after]
        return "Set \(after + 1) · \(Self.weightText(next.virtualWeightKg)) · \(next.curlReps) curls + \(Int(next.holdDuration)) s hold"
    }
}
