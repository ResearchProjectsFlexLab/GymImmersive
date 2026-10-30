import Foundation

/// Reproducible random numbers (SplitMix64); the seed is logged with each session.
struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Plate colours: distinct hues and names that are easy to say and hear.
enum PlateColor: String, CaseIterable, Sendable {
    case red, blue, green, yellow, purple, orange

    var displayName: String { rawValue.capitalized }

    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .red: (0.86, 0.16, 0.16)
        case .blue: (0.15, 0.40, 0.90)
        case .green: (0.14, 0.68, 0.30)
        case .yellow: (0.98, 0.82, 0.10)
        case .purple: (0.55, 0.25, 0.80)
        case .orange: (0.98, 0.50, 0.08)
        }
    }
}

enum NBackOutcome: String, Sendable {
    case hit, miss
    case falseAlarm = "false_alarm"
    case correctRejection = "correct_rejection"
    /// The trial window was cut short by a pause or stop and is not scored.
    case interrupted
}

struct NBackTrialResult: Sendable, Equatable {
    var index: Int
    var color: PlateColor
    var isMatch: Bool
    var responded: Bool
    var reactionTime: TimeInterval?
    var outcome: NBackOutcome
}

enum NBackResponse: Sendable, Equatable {
    case recorded(trial: Int, reactionTime: TimeInterval, isMatch: Bool)
    case duplicate(trial: Int)
    case noActiveTrial
}

/// 2-back on plate colours: a new stimulus appears with every rep; the participant pinches with
/// the free hand when the colour equals the one shown two stimuli earlier.
struct NBackTask: Sendable {
    let n: Int
    let sequence: [PlateColor]
    let matchFlags: [Bool]
    private(set) var currentIndex = -1
    private var onset: TimeInterval = 0
    private var response: TimeInterval?
    private(set) var results: [NBackTrialResult] = []

    init(length: Int, n: Int, matchRate: Double, rng: inout SeededRandom) {
        self.n = n
        let (sequence, flags) = Self.generate(length: length, n: n, matchRate: matchRate, rng: &rng)
        self.sequence = sequence
        self.matchFlags = flags
    }

    /// Exactly round((length − n) × matchRate) matches at random eligible positions. Consecutive
    /// colours always differ (so every rep visibly changes colour) and non-match trials never
    /// equal the colour n back.
    static func generate(length: Int, n: Int, matchRate: Double,
                         rng: inout SeededRandom) -> ([PlateColor], [Bool]) {
        guard length > 0 else { return ([], []) }
        let eligible = max(0, length - n)
        let matchCount = min(eligible, Int((Double(eligible) * matchRate).rounded()))
        let matchPositions = Set(Array(n..<max(n, length)).shuffled(using: &rng).prefix(matchCount))
        var colors: [PlateColor] = []
        var flags: [Bool] = []
        for i in 0..<length {
            if matchPositions.contains(i) {
                colors.append(colors[i - n])
                flags.append(true)
            } else {
                var excluded: Set<PlateColor> = []
                if i >= 1 { excluded.insert(colors[i - 1]) }
                if i >= n { excluded.insert(colors[i - n]) }
                let options = PlateColor.allCases.filter { !excluded.contains($0) }
                colors.append(options.randomElement(using: &rng)!)
                flags.append(false)
            }
        }
        return (colors, flags)
    }

    var currentColor: PlateColor? { sequence.indices.contains(currentIndex) ? sequence[currentIndex] : nil }
    var isExhausted: Bool { currentIndex >= sequence.count - 1 }

    /// Closes the open trial (if any) and shows the next stimulus.
    mutating func presentNext(at time: TimeInterval) -> (closed: NBackTrialResult?, next: PlateColor?) {
        let closed = closeCurrent(interrupted: false)
        guard currentIndex + 1 < sequence.count else { return (closed, nil) }
        currentIndex += 1
        onset = time
        response = nil
        return (closed, sequence[currentIndex])
    }

    mutating func respond(at time: TimeInterval) -> NBackResponse {
        guard sequence.indices.contains(currentIndex), !isClosed(currentIndex) else { return .noActiveTrial }
        guard response == nil else { return .duplicate(trial: currentIndex) }
        response = time
        return .recorded(trial: currentIndex, reactionTime: time - onset, isMatch: matchFlags[currentIndex])
    }

    /// Scores the open trial. Interrupted trials are recorded but excluded from scoring.
    mutating func closeCurrent(interrupted: Bool) -> NBackTrialResult? {
        guard sequence.indices.contains(currentIndex), !isClosed(currentIndex) else { return nil }
        let isMatch = matchFlags[currentIndex]
        let responded = response != nil
        let outcome: NBackOutcome
        switch (interrupted, isMatch, responded) {
        case (true, _, _): outcome = .interrupted
        case (false, true, true): outcome = .hit
        case (false, true, false): outcome = .miss
        case (false, false, true): outcome = .falseAlarm
        case (false, false, false): outcome = .correctRejection
        }
        let result = NBackTrialResult(index: currentIndex, color: sequence[currentIndex], isMatch: isMatch,
                                      responded: responded, reactionTime: response.map { $0 - onset },
                                      outcome: outcome)
        results.append(result)
        return result
    }

    private func isClosed(_ index: Int) -> Bool { results.last.map { $0.index >= index } ?? false }

    /// After an interruption, the next stimulus restarts the window from now.
    mutating func restartWindow(at time: TimeInterval) -> PlateColor? {
        presentNext(at: time).next
    }
}

struct NBackStats: Sendable, Equatable {
    var hits = 0, misses = 0, falseAlarms = 0, correctRejections = 0, interrupted = 0
    var meanHitRT: TimeInterval?

    init(_ results: [NBackTrialResult]) {
        var rts: [TimeInterval] = []
        for r in results {
            switch r.outcome {
            case .hit: hits += 1; if let rt = r.reactionTime { rts.append(rt) }
            case .miss: misses += 1
            case .falseAlarm: falseAlarms += 1
            case .correctRejection: correctRejections += 1
            case .interrupted: interrupted += 1
            }
        }
        meanHitRT = rts.isEmpty ? nil : rts.reduce(0, +) / Double(rts.count)
    }

    var scored: Int { hits + misses + falseAlarms + correctRejections }
    var accuracy: Double? { scored > 0 ? Double(hits + correctRejections) / Double(scored) : nil }
}
