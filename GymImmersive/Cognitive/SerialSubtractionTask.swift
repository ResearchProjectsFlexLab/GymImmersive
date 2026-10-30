import Foundation

struct SubtractionProblem: Sendable, Equatable {
    var index: Int
    /// The number the participant should subtract from (shown only for the first problem).
    var previousValue: Int
    var correctAnswer: Int
    var choices: [Int]
    var onset: TimeInterval
}

enum SubtractionOutcome: String, Sendable {
    case correct, incorrect, timeout, interrupted
}

struct SubtractionResult: Sendable, Equatable {
    var problem: SubtractionProblem
    var chosen: Int?
    var reactionTime: TimeInterval?
    var outcome: SubtractionOutcome
}

/// Serial subtraction by `step` with multiple-choice answers. After a wrong answer or a timeout,
/// counting continues from the correct value so one mistake does not cascade.
struct SerialSubtractionTask: Sendable {
    let startValue: Int
    let step: Int
    let choiceCount: Int
    let timeLimit: TimeInterval
    private(set) var currentValue: Int
    private(set) var problem: SubtractionProblem?
    private(set) var results: [SubtractionResult] = []
    private var nextIndex = 0

    init(startValue: Int, step: Int, choiceCount: Int, timeLimit: TimeInterval) {
        self.startValue = startValue
        self.step = step
        self.choiceCount = max(2, choiceCount)
        self.timeLimit = timeLimit
        currentValue = startValue
    }

    /// Plausible wrong answers: off by one, off by ten, or a wrong step size.
    static func choices(correct: Int, count: Int, rng: inout SeededRandom) -> [Int] {
        let candidates = [correct + 1, correct - 1, correct + 10, correct - 10, correct + 2, correct - 2, correct + 3]
        var distractors = Array(Set(candidates.filter { $0 != correct && $0 >= 0 })).sorted().shuffled(using: &rng)
        distractors = Array(distractors.prefix(count - 1))
        return (distractors + [correct]).shuffled(using: &rng)
    }

    mutating func present(at time: TimeInterval, rng: inout SeededRandom) -> SubtractionProblem {
        if currentValue < step { currentValue = startValue }  // never go negative
        let correct = currentValue - step
        let p = SubtractionProblem(index: nextIndex, previousValue: currentValue, correctAnswer: correct,
                                   choices: Self.choices(correct: correct, count: choiceCount, rng: &rng),
                                   onset: time)
        nextIndex += 1
        problem = p
        return p
    }

    mutating func answer(_ choice: Int, at time: TimeInterval) -> SubtractionResult? {
        guard let p = problem else { return nil }
        let outcome: SubtractionOutcome = choice == p.correctAnswer ? .correct : .incorrect
        return finish(SubtractionResult(problem: p, chosen: choice, reactionTime: time - p.onset, outcome: outcome))
    }

    /// Returns a timeout result if the open problem has exceeded the time limit.
    mutating func checkTimeout(at time: TimeInterval) -> SubtractionResult? {
        guard let p = problem, time - p.onset >= timeLimit else { return nil }
        return finish(SubtractionResult(problem: p, chosen: nil, reactionTime: nil, outcome: .timeout))
    }

    /// Abandons the open problem (pause or phase end); it is logged but not scored.
    mutating func interrupt() -> SubtractionResult? {
        guard let p = problem else { return nil }
        problem = nil
        let r = SubtractionResult(problem: p, chosen: nil, reactionTime: nil, outcome: .interrupted)
        results.append(r)
        return r
    }

    private mutating func finish(_ result: SubtractionResult) -> SubtractionResult {
        problem = nil
        if result.outcome != .interrupted { currentValue = result.problem.correctAnswer }
        results.append(result)
        return result
    }
}

struct SubtractionStats: Sendable, Equatable {
    var attempts = 0, correct = 0, incorrect = 0, timeouts = 0
    var meanCorrectRT: TimeInterval?

    init(_ results: [SubtractionResult]) {
        var rts: [TimeInterval] = []
        for r in results {
            switch r.outcome {
            case .correct: correct += 1; attempts += 1; if let rt = r.reactionTime { rts.append(rt) }
            case .incorrect: incorrect += 1; attempts += 1
            case .timeout: timeouts += 1; attempts += 1
            case .interrupted: break
            }
        }
        meanCorrectRT = rts.isEmpty ? nil : rts.reduce(0, +) / Double(rts.count)
    }

    var accuracy: Double? { attempts > 0 ? Double(correct) / Double(attempts) : nil }
}
