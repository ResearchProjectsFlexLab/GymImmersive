import Foundation

enum Activity: String, Sendable { case curls, hold }

/// One step of the workout plan. Set 0 is the practice set.
enum Phase: Equatable, Sendable {
    case prepare(set: Int, activity: Activity)
    case curls(set: Int)
    case hold(set: Int)
    case rating(set: Int)
    case rest(afterSet: Int)

    var setIndex: Int {
        switch self {
        case .prepare(let s, _), .curls(let s), .hold(let s), .rating(let s), .rest(let s): s
        }
    }

    var logName: String {
        switch self {
        case .prepare(_, let a): "prepare_\(a.rawValue)"
        case .curls: "curls"
        case .hold: "hold"
        case .rating: "rating"
        case .rest: "rest"
        }
    }

    /// Builds the ordered phase list for a settings value.
    static func plan(for settings: WorkoutSettings) -> [Phase] {
        var plan: [Phase] = [.prepare(set: 0, activity: .curls), .curls(set: 0), .rest(afterSet: 0)]
        for index in 1...settings.sets.count {
            plan += [.prepare(set: index, activity: .curls), .curls(set: index)]
            if settings.sets[index - 1].holdDuration > 0 {
                plan += [.prepare(set: index, activity: .hold), .hold(set: index)]
            }
            plan.append(.rating(set: index))
            if index < settings.sets.count { plan.append(.rest(afterSet: index)) }
        }
        return plan
    }
}

enum PauseReason: String, Sendable {
    case user, trackingLost = "tracking_lost", appInactive = "app_inactive"
}

enum StopReason: String, Sendable {
    case userStopped = "user_stopped"
    case immersiveSpaceDismissed = "immersive_space_dismissed"
    case immersiveSpaceOpenFailed = "immersive_space_open_failed"
    case handTrackingUnavailable = "hand_tracking_unavailable"
    case appTerminated = "app_terminated"
}

enum SessionStatus: Equatable, Sendable {
    case ready
    case running
    case paused(PauseReason)
    case completed
    case stopped(StopReason)

    var isFinished: Bool {
        switch self {
        case .completed, .stopped: true
        default: false
        }
    }
}

struct PhaseTransition: Equatable, Sendable {
    var from: Phase?
    var to: Phase?
    /// Why the old phase ended: "timer", "reps_done", "time_limit", "rating_submitted", "start".
    var cause: String
}

/// Pure, deterministic workout state machine: the single source of truth for status,
/// phase, phase time and rep count. All time values come from the caller, so it is fully
/// testable and pausing simply stops time from accumulating.
struct WorkoutSession: Sendable {
    let settings: WorkoutSettings
    let plan: [Phase]
    private(set) var status: SessionStatus = .ready
    private(set) var phaseIndex = 0
    private(set) var phaseElapsed: TimeInterval = 0
    /// Total running (not paused) time since start.
    private(set) var activeTime: TimeInterval = 0
    private(set) var repsInPhase = 0
    private var lastTick: TimeInterval?

    init(settings: WorkoutSettings) {
        self.settings = settings
        self.plan = Phase.plan(for: settings)
    }

    var currentPhase: Phase? {
        status.isFinished || status == .ready ? nil : plan[phaseIndex]
    }

    var currentSet: SetConfig? { currentPhase.map { settings.config(forSet: $0.setIndex) } }

    /// nil for phases without a timer (rating).
    func duration(of phase: Phase) -> TimeInterval? {
        let set = settings.config(forSet: phase.setIndex)
        switch phase {
        case .prepare: return settings.prepareDuration
        case .curls: return settings.curlTimeLimit(for: set)
        case .hold: return set.holdDuration
        case .rating: return nil
        case .rest(let after): return after == 0 ? settings.practiceRestDuration : settings.restDuration
        }
    }

    var phaseRemaining: TimeInterval? {
        guard let phase = currentPhase, let total = duration(of: phase) else { return nil }
        return max(0, total - phaseElapsed)
    }

    /// 0...1 progress of the current phase (reps for curls, time otherwise).
    var phaseProgress: Double {
        guard let phase = currentPhase else { return status == .completed ? 1 : 0 }
        if case .curls = phase, let set = currentSet {
            return min(1, Double(repsInPhase) / Double(max(1, set.curlReps)))
        }
        guard let total = duration(of: phase), total > 0 else { return 0 }
        return min(1, phaseElapsed / total)
    }

    // MARK: Commands

    mutating func start(at now: TimeInterval) -> [PhaseTransition] {
        guard status == .ready else { return [] }
        status = .running
        lastTick = now
        return [PhaseTransition(from: nil, to: plan[0], cause: "start")]
    }

    /// Advances time. Returns every phase change that happened (possibly several after a long gap).
    mutating func tick(at now: TimeInterval) -> [PhaseTransition] {
        guard status == .running, let last = lastTick else { return [] }
        let delta = max(0, now - last)
        lastTick = now
        activeTime += delta
        phaseElapsed += delta
        var transitions: [PhaseTransition] = []
        while status == .running, let phase = currentPhase, let total = duration(of: phase),
              phaseElapsed >= total {
            let cause: String = if case .curls = phase { "time_limit" } else { "timer" }
            transitions.append(advance(carry: phaseElapsed - total, cause: cause))
        }
        return transitions
    }

    @discardableResult
    mutating func pause(_ reason: PauseReason, at now: TimeInterval) -> Bool {
        guard status == .running else { return false }
        _ = tick(at: now)
        guard status == .running else { return false }
        status = .paused(reason)
        lastTick = nil
        return true
    }

    @discardableResult
    mutating func resume(at now: TimeInterval) -> Bool {
        guard case .paused = status else { return false }
        status = .running
        lastTick = now
        return true
    }

    @discardableResult
    mutating func stop(_ reason: StopReason, at now: TimeInterval) -> Bool {
        guard !status.isFinished else { return false }
        if status == .running { _ = tick(at: now) }
        guard !status.isFinished else { return false }
        status = .stopped(reason)
        lastTick = nil
        return true
    }

    /// Counts a full-range curl. Finishing the target reps ends the curl phase immediately.
    mutating func recordRep() -> [PhaseTransition] {
        guard status == .running, case .curls = currentPhase, let set = currentSet else { return [] }
        repsInPhase += 1
        if repsInPhase >= set.curlReps { return [advance(carry: 0, cause: "reps_done")] }
        return []
    }

    mutating func submitRating() -> [PhaseTransition] {
        guard status == .running, case .rating = currentPhase else { return [] }
        return [advance(carry: 0, cause: "rating_submitted")]
    }

    private mutating func advance(carry: TimeInterval, cause: String) -> PhaseTransition {
        let from = plan[phaseIndex]
        repsInPhase = 0
        if phaseIndex + 1 >= plan.count {
            status = .completed
            lastTick = nil
            phaseElapsed = 0
            return PhaseTransition(from: from, to: nil, cause: cause)
        }
        phaseIndex += 1
        let next = plan[phaseIndex]
        phaseElapsed = duration(of: next) == nil ? 0 : carry
        return PhaseTransition(from: from, to: next, cause: cause)
    }
}
