import Foundation

/// Which hand holds the virtual dumbbell. The other hand answers the 2-back task.
enum DumbbellHand: String, CaseIterable, Codable, Sendable, Identifiable {
    case right, left
    var id: String { rawValue }
    var other: DumbbellHand { self == .right ? .left : .right }
    var label: String { self == .right ? "Right" : "Left" }
}

/// Per-set difficulty. Heavier virtual weights get stricter tolerances and longer holds,
/// because the real physical load cannot change.
struct SetConfig: Equatable, Sendable {
    var virtualWeightKg: Double
    var curlReps: Int
    /// 0 means the round has no extended-arm hold.
    var holdDuration: TimeInterval
    /// Allowed absolute error per curl half (up or down), in seconds.
    var tempoTolerance: TimeInterval
    /// Radius (m) around the hold reference position counted as "steady".
    var steadinessRadius: Double
    /// How far (m) the hand may sink below shoulder height before "Arm up!".
    var armDropTolerance: Double
}

/// All protocol values live here so a study can be reconfigured in one place.
///
/// A session runs for a chosen length of time. It repeats rounds of curls → hold with the right
/// arm, then curls → hold with the left arm, then rest; round 1
/// uses `sets[0]`, round 2 `sets[1]`, and every later round the last (heaviest) entry. When the
/// time is up the current round stops and a single workload rating follows.
struct WorkoutSettings: Equatable, Sendable {
    /// Session lengths offered on the Start screen, in minutes.
    static let durationOptions = [1, 3, 5, 10]

    var sets: [SetConfig] = [
        SetConfig(virtualWeightKg: 5, curlReps: 10, holdDuration: 10,
                  tempoTolerance: 0.8, steadinessRadius: 0.08, armDropTolerance: 0.12),
        SetConfig(virtualWeightKg: 10, curlReps: 10, holdDuration: 15,
                  tempoTolerance: 0.6, steadinessRadius: 0.06, armDropTolerance: 0.10),
        SetConfig(virtualWeightKg: 15, curlReps: 10, holdDuration: 20,
                  tempoTolerance: 0.4, steadinessRadius: 0.04, armDropTolerance: 0.08),
    ]

    var tempoUp: TimeInterval = 2
    var tempoDown: TimeInterval = 2
    /// The curl phase ends after reps × (up + down) × this factor even if reps are missing,
    /// so a participant can never get stuck in a set.
    var curlTimeLimitFactor: Double = 2
    var prepareDuration: TimeInterval = 5
    var restDuration: TimeInterval = 20

    /// No samples for this long counts (and is logged) as lost tracking. The session keeps running.
    var inputStallThreshold: TimeInterval = 3
    /// The hand must stay below the hold zone this long before "Arm up!" appears.
    var armUpCueDelay: TimeInterval = 0.5

    // 2-back on plate colours during curls. Off by default: the participant holds a phone as
    // the dumbbell, and the task needs a free-hand pinch to answer.
    var nBackDuringCurls = false
    var nBackLevel = 2
    var nBackMatchRate = 0.3

    // Serial subtraction
    var subtractionStartRange: ClosedRange<Int> = 900...1100
    var subtractionStep = 7
    var subtractionChoiceCount = 4
    var subtractionTimeLimit: TimeInterval = 8

    // Movement geometry, relative to the estimated shoulder (metres).
    var curlBottomOffset: Double = -0.55
    var curlTopOffset: Double = -0.10
    var curlLowThreshold: Double = 0.3
    var curlHighThreshold: Double = 0.7
    var holdMinExtension: Double = 0.35

    func curlTimeLimit(for set: SetConfig) -> TimeInterval {
        Double(set.curlReps) * (tempoUp + tempoDown) * curlTimeLimitFactor
    }

    /// Difficulty for round `index` (1-based). Rounds past the end of `sets` repeat the last entry.
    func config(forSet index: Int) -> SetConfig {
        sets[min(max(index, 1), sets.count) - 1]
    }
}

/// Researcher-entered information for one session.
struct SessionInfo: Equatable, Sendable {
    var participantID: String
    var condition: String
    var cognitiveTaskEnabled: Bool
    var dumbbellHand: DumbbellHand
    var seed: UInt64
    /// Total workout time; the final rating is not counted.
    var duration: TimeInterval = 180
}
