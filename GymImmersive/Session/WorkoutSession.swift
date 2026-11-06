import Foundation

enum Activity: String, Sendable { case curls, hold }

/// One step of the workout plan. Rounds are numbered from 1 and each round is done with the
/// right arm, then the left; `rating` is the single workload rating after the time is up.
enum Phase: Equatable, Sendable {
    case prepare(set: Int, activity: Activity, arm: DumbbellHand = .right)
    case curls(set: Int, arm: DumbbellHand = .right)
    case hold(set: Int, arm: DumbbellHand = .right)
    case rest(afterSet: Int)
    case rating

    /// Round number; 0 for the final rating, which belongs to the whole session.
    var setIndex: Int {
        switch self {
        case .prepare(let s, _, _), .curls(let s, _), .hold(let s, _), .rest(let s): s
        case .rating: 0
        }
    }

    /// The arm working in this step; nil for rest and rating.
    var arm: DumbbellHand? {
        switch self {
        case .prepare(_, _, let a), .curls(_, let a), .hold(_, let a): a
        case .rest, .rating: nil
        }
    }

    var logName: String {
        switch self {
        case .prepare(_, let a, _): "prepare_\(a.rawValue)"
        case .curls: "curls"
        case .hold: "hold"
        case .rating: "rating"
        case .rest: "rest"
        }
    }

    /// Rounds of (prepare → curls → prepare → hold) for the right arm, the same for the left arm,
    /// then rest; enough rounds to fill `duration` even if every curl phase finishes as fast as
    /// possible, followed by the final rating.
    static func plan(for settings: WorkoutSettings, duration: TimeInterval) -> [Phase] {
        var plan: [Phase] = []
        var minimumTime = 0.0
        var round = 0
        repeat {
            round += 1
            let set = settings.config(forSet: round)
            for arm in [DumbbellHand.right, .left] {
                plan += [.prepare(set: round, activity: .curls, arm: arm), .curls(set: round, arm: arm)]
                minimumTime += settings.prepareDuration + Double(set.curlReps) * 1.0
                if set.holdDuration > 0 {
                    plan += [.prepare(set: round, activity: .hold, arm: arm), .hold(set: round, arm: arm)]
                    minimumTime += settings.prepareDuration + set.holdDuration
                }
            }
            plan.append(.rest(afterSet: round))
            minimumTime += settings.restDuration
        } while minimumTime < duration && round < 1000
        plan.append(.rating)
        return plan
    }
}

enum PauseReason: String, Sendable {
    case user, appInactive = "app_inactive"
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
    /// Why the old phase ended: "timer", "reps_done", "time_limit", "time_up",
    /// "rating_submitted", "start".
    var cause: String
}

/// Pure, deterministic workout state machine: the single source of truth for status,
/// phase, phase time, session time and rep count. All time values come from the caller, so it is
/// fully testable and pausing simply stops time from accumulating.
struct WorkoutSession: Sendable {
    let settings: WorkoutSettings
    /// Workout time before the final rating.
    let totalDuration: TimeInterval
    let plan: [Phase]
    private(set) var status: SessionStatus = .ready
    private(set) var phaseIndex = 0
    private(set) var phaseElapsed: TimeInterval = 0
    /// Total running (not paused) time since start.
    private(set) var activeTime: TimeInterval = 0
    private(set) var repsInPhase = 0
    private var lastTick: TimeInterval?

    init(settings: WorkoutSettings, duration: TimeInterval) {
        self.settings = settings
        self.totalDuration = duration
        self.plan = Phase.plan(for: settings, duration: duration)
    }

    var currentPhase: Phase? {
        status.isFinished || status == .ready ? nil : plan[phaseIndex]
    }

    var currentSet: SetConfig? {
        guard let phase = currentPhase, phase != .rating else { return nil }
        return settings.config(forSet: phase.setIndex)
    }

    /// Workout time left before the final rating.
    var sessionRemaining: TimeInterval { max(0, totalDuration - activeTime) }

    /// nil for phases without a timer (rating).
    func duration(of phase: Phase) -> TimeInterval? {
        let set = settings.config(forSet: phase.setIndex)
        switch phase {
        case .prepare: return settings.prepareDuration
        case .curls: return settings.curlTimeLimit(for: set)
        case .hold: return set.holdDuration
        case .rest: return settings.restDuration
        case .rating: return nil
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
        if currentPhase != .rating {
            activeTime += delta
            phaseElapsed += delta
        }
        var transitions: [PhaseTransition] = []
        while status == .running, let phase = currentPhase, phase != .rating {
            if activeTime >= totalDuration {
                transitions.append(jumpToRating())
                break
            }
            guard let total = duration(of: phase), phaseElapsed >= total else { break }
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
        guard status == .running, currentPhase == .rating else { return [] }
        return [advance(carry: 0, cause: "rating_submitted")]
    }

    private mutating func jumpToRating() -> PhaseTransition {
        let from = plan[phaseIndex]
        phaseIndex = plan.count - 1
        phaseElapsed = 0
        repsInPhase = 0
        return PhaseTransition(from: from, to: .rating, cause: "time_up")
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
