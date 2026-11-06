import Foundation
import Testing
@testable import GymImmersive

struct NBackGenerationTests {
    @Test(arguments: [UInt64(1), 2, 3, 99, 2024, 777_777])
    func controlledMatchRate(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        let (colors, flags) = NBackTask.generate(length: 10, n: 2, matchRate: 0.3, rng: &rng)
        #expect(colors.count == 10)
        #expect(flags.filter { $0 }.count == 2)  // round(8 × 0.3) = 2
        #expect(!flags[0] && !flags[1])
        for i in 1..<10 { #expect(colors[i] != colors[i - 1], "colour must change every rep") }
        for i in 2..<10 { #expect((colors[i] == colors[i - 2]) == flags[i], "flag must match the sequence") }
    }

    @Test func matchCountScalesWithRate() {
        for (rate, expected) in [(0.0, 0), (0.25, 5), (0.5, 10), (1.0, 20)] {
            var rng = SeededRandom(seed: 5)
            let (colors, flags) = NBackTask.generate(length: 22, n: 2, matchRate: rate, rng: &rng)
            #expect(flags.filter { $0 }.count == expected)
            for i in 2..<22 { #expect((colors[i] == colors[i - 2]) == flags[i]) }
        }
    }

    @Test func sameSeedSameSequence() {
        var a = SeededRandom(seed: 42), b = SeededRandom(seed: 42), c = SeededRandom(seed: 43)
        let s1 = NBackTask.generate(length: 30, n: 2, matchRate: 0.3, rng: &a).0
        let s2 = NBackTask.generate(length: 30, n: 2, matchRate: 0.3, rng: &b).0
        let s3 = NBackTask.generate(length: 30, n: 2, matchRate: 0.3, rng: &c).0
        #expect(s1 == s2)
        #expect(s1 != s3)
    }

    @Test func degenerateLengths() {
        var rng = SeededRandom(seed: 1)
        #expect(NBackTask.generate(length: 0, n: 2, matchRate: 0.3, rng: &rng).0.isEmpty)
        let one = NBackTask.generate(length: 2, n: 2, matchRate: 1, rng: &rng)
        #expect(one.1 == [false, false])
    }
}

struct NBackScoringTests {
    /// Builds a task and returns the trial indices that are matches.
    private func makeTask() -> NBackTask {
        var rng = SeededRandom(seed: 11)
        return NBackTask(length: 10, n: 2, matchRate: 0.3, rng: &rng)
    }

    @Test func scoresHitsMissesFalseAlarmsAndRejections() {
        var task = makeTask()
        let matches = task.matchFlags
        var t = 0.0
        // Respond on the first match and on trial 0 (non-match); ignore everything else.
        let firstMatch = matches.firstIndex(of: true)!
        for i in 0..<10 {
            _ = task.presentNext(at: t)
            if i == firstMatch || i == 0 {
                guard case let .recorded(trial, rt, isMatch) = task.respond(at: t + 0.6) else {
                    Issue.record("response not recorded"); return
                }
                #expect(trial == i && isMatch == matches[i] && abs(rt - 0.6) < 1e-9)
                #expect(task.respond(at: t + 0.9) == .duplicate(trial: i))
            }
            t += 4
        }
        _ = task.closeCurrent(interrupted: false)
        #expect(task.results.count == 10)
        let stats = NBackStats(task.results)
        #expect(stats.hits == 1)
        #expect(stats.misses == matches.filter { $0 }.count - 1)
        #expect(stats.falseAlarms == 1)
        #expect(stats.correctRejections == 10 - matches.filter { $0 }.count - 1)
        #expect(abs(stats.meanHitRT! - 0.6) < 1e-9)
        #expect(task.results[firstMatch].outcome == .hit)
        #expect(task.results[0].outcome == .falseAlarm)
        #expect(stats.accuracy == Double(stats.hits + stats.correctRejections) / 10)
    }

    @Test func noResponseBeforeFirstStimulusOrAfterClose() {
        var task = makeTask()
        #expect(task.respond(at: 0) == .noActiveTrial)
        _ = task.presentNext(at: 1)
        _ = task.closeCurrent(interrupted: false)
        #expect(task.respond(at: 2) == .noActiveTrial)
        #expect(task.closeCurrent(interrupted: false) == nil, "closing twice records once")
        #expect(task.results.count == 1)
    }

    @Test func interruptedTrialsAreExcludedFromScoring() {
        var task = makeTask()
        _ = task.presentNext(at: 0)
        _ = task.respond(at: 0.5)
        let closed = task.closeCurrent(interrupted: true)
        #expect(closed?.outcome == .interrupted)
        #expect(closed?.responded == true)
        let stats = NBackStats(task.results)
        #expect(stats.interrupted == 1)
        #expect(stats.scored == 0)
        #expect(stats.accuracy == nil)
        // The next stimulus opens a new window.
        let next = task.presentNext(at: 10)
        #expect(next.closed == nil)
        #expect(next.next == task.sequence[1])
    }

    @Test func sequenceExhaustion() {
        var task = makeTask()
        for i in 0..<10 { #expect(task.presentNext(at: Double(i)).next != nil) }
        #expect(task.isExhausted)
        let last = task.presentNext(at: 20)
        #expect(last.closed?.index == 9)
        #expect(last.next == nil)
    }
}

struct SerialSubtractionTests {
    @Test func choicesContainCorrectAnswerOnce() {
        var rng = SeededRandom(seed: 3)
        for correct in [993, 7, 0, 1, 500] {
            let c = SerialSubtractionTask.choices(correct: correct, count: 4, rng: &rng)
            #expect(c.count == 4)
            #expect(Set(c).count == 4)
            #expect(c.filter { $0 == correct }.count == 1)
            #expect(c.allSatisfy { $0 >= 0 })
        }
    }

    @Test func correctAndIncorrectAnswersContinueFromCorrectValue() {
        var rng = SeededRandom(seed: 9)
        var task = SerialSubtractionTask(startValue: 1000, step: 7, choiceCount: 4, timeLimit: 8)
        let p1 = task.present(at: 0, rng: &rng)
        #expect(p1.previousValue == 1000 && p1.correctAnswer == 993 && p1.index == 0)
        let r1 = task.answer(993, at: 2.5)!
        #expect(r1.outcome == .correct && r1.reactionTime == 2.5)
        let p2 = task.present(at: 3, rng: &rng)
        #expect(p2.correctAnswer == 986)
        let wrong = p2.choices.first { $0 != 986 }!
        #expect(task.answer(wrong, at: 4)!.outcome == .incorrect)
        let p3 = task.present(at: 5, rng: &rng)
        #expect(p3.previousValue == 986, "after an error, counting continues from the correct value")
        #expect(p3.correctAnswer == 979)
        #expect(task.answer(979, at: 6) != nil)
        #expect(task.answer(979, at: 6.1) == nil, "no double answers")

        let stats = SubtractionStats(task.results)
        #expect(stats.attempts == 3 && stats.correct == 2 && stats.incorrect == 1)
        #expect(abs(stats.accuracy! - 2.0 / 3.0) < 1e-9)
        #expect(abs(stats.meanCorrectRT! - 1.75) < 1e-9)
    }

    @Test func timeoutsAndInterruptions() {
        var rng = SeededRandom(seed: 9)
        var task = SerialSubtractionTask(startValue: 100, step: 7, choiceCount: 4, timeLimit: 8)
        _ = task.present(at: 0, rng: &rng)
        #expect(task.checkTimeout(at: 7.9) == nil)
        let timeout = task.checkTimeout(at: 8)
        #expect(timeout?.outcome == .timeout && timeout?.chosen == nil)
        #expect(task.currentValue == 93)
        _ = task.present(at: 10, rng: &rng)
        #expect(task.interrupt()?.outcome == .interrupted)
        #expect(task.currentValue == 93, "interruptions do not advance the count")
        #expect(task.interrupt() == nil)
        let stats = SubtractionStats(task.results)
        #expect(stats.attempts == 1 && stats.timeouts == 1 && stats.correct == 0)
        #expect(stats.accuracy == 0)
    }

    @Test func neverGoesNegative() {
        var rng = SeededRandom(seed: 1)
        var task = SerialSubtractionTask(startValue: 10, step: 7, choiceCount: 4, timeLimit: 8)
        let p1 = task.present(at: 0, rng: &rng)
        _ = task.answer(p1.correctAnswer, at: 1)  // now 3
        let p2 = task.present(at: 2, rng: &rng)
        #expect(p2.previousValue == 10 && p2.correctAnswer == 3)
    }
}

struct NASATLXTests {
    @Test func subscalesClampAndAverage() {
        var r = NASATLXRating()
        #expect(r.rawMean == 50)
        r[.mental] = 120
        r[.physical] = -5
        r[.temporal] = 30
        r[.performance] = 20
        r[.effort] = 80
        r[.frustration] = 10
        #expect(r.mental == 100 && r.physical == 0)
        #expect(abs(r.rawMean - 240.0 / 6) < 1e-9)
        #expect(TLXScale.allCases.count == 6)
        #expect(TLXScale.performance.anchors.low == "Great")
    }
}
