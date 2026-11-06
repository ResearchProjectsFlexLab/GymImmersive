import Foundation
import Testing
@testable import GymImmersive

struct WorkoutSessionTests {
    let settings = WorkoutSettings()

    @Test func planIsRoundsThenOneRating() {
        let plan = Phase.plan(for: settings, duration: 180)
        #expect(Array(plan.prefix(9)) == [
            .prepare(set: 1, activity: .curls, arm: .right), .curls(set: 1, arm: .right),
            .prepare(set: 1, activity: .hold, arm: .right), .hold(set: 1, arm: .right),
            .prepare(set: 1, activity: .curls, arm: .left), .curls(set: 1, arm: .left),
            .prepare(set: 1, activity: .hold, arm: .left), .hold(set: 1, arm: .left),
            .rest(afterSet: 1)])
        #expect(plan.last == .rating)
        #expect(plan.filter { $0 == .rating }.count == 1)
        #expect(plan.count == 3 * 9 + 1)
        #expect(plan[5].arm == .left && plan[8].arm == nil)
    }

    @Test func planIsLongEnoughForEveryDuration() {
        for minutes in WorkoutSettings.durationOptions {
            let duration = TimeInterval(minutes * 60)
            let plan = Phase.plan(for: settings, duration: duration)
            // Minimum time if every curl phase finishes at 1 s per rep: must still cover the duration.
            let minimum = plan.reduce(0.0) { total, phase in
                let set = settings.config(forSet: phase.setIndex)
                switch phase {
                case .prepare: return total + settings.prepareDuration
                case .curls: return total + Double(set.curlReps)
                case .hold: return total + set.holdDuration
                case .rest: return total + settings.restDuration
                case .rating: return total
                }
            }
            #expect(minimum >= duration, "\(minutes) min")
        }
        #expect(Phase.plan(for: settings, duration: 60).count == 10, "one round (both arms) fills a minute")
    }

    @Test func roundsGetHeavierThenStayAtTheTop() {
        #expect(settings.config(forSet: 1).virtualWeightKg == 5)
        #expect(settings.config(forSet: 2).virtualWeightKg == 10)
        #expect(settings.config(forSet: 3).virtualWeightKg == 15)
        #expect(settings.config(forSet: 7).virtualWeightKg == 15)
    }

    @Test func startEntersFirstPhaseOnce() {
        var s = WorkoutSession(settings: settings, duration: 180)
        #expect(s.currentPhase == nil)
        let t = s.start(at: 0)
        #expect(t == [PhaseTransition(from: nil, to: .prepare(set: 1, activity: .curls), cause: "start")])
        #expect(s.start(at: 1).isEmpty)
        #expect(s.status == .running)
        #expect(s.sessionRemaining == 180)
    }

    @Test func timedPhasesAdvanceWithCarryOver() {
        var s = WorkoutSession(settings: settings, duration: 180)
        _ = s.start(at: 0)
        #expect(s.tick(at: 4.9).isEmpty)
        #expect(abs(s.phaseRemaining! - 0.1) < 1e-9)
        let t = s.tick(at: 5.3)
        #expect(t.count == 1)
        #expect(t[0].to == .curls(set: 1))
        #expect(abs(s.phaseElapsed - 0.3) < 1e-9)
        #expect(abs(s.sessionRemaining - (180 - 5.3)) < 1e-9)
    }

    @Test func curlTimeLimitEndsPhase() {
        var s = WorkoutSession(settings: settings, duration: 600)
        _ = s.start(at: 0)
        _ = s.tick(at: 5)  // -> curls(1); limit 10 reps × 4 s × 2 = 80 s
        #expect(s.currentPhase == .curls(set: 1))
        #expect(s.phaseRemaining == 80)
        let t = s.tick(at: 86)
        #expect(t.first?.cause == "time_limit")
        #expect(s.currentPhase == .prepare(set: 1, activity: .hold))
    }

    @Test func repsEndCurlPhaseImmediately() {
        var s = WorkoutSession(settings: settings, duration: 180)
        _ = s.start(at: 0)
        _ = s.tick(at: 5)
        for _ in 0..<9 { #expect(s.recordRep().isEmpty) }
        #expect(s.repsInPhase == 9)
        #expect(abs(s.phaseProgress - 0.9) < 1e-9)
        let t = s.recordRep()
        #expect(t == [PhaseTransition(from: .curls(set: 1), to: .prepare(set: 1, activity: .hold), cause: "reps_done")])
        #expect(s.repsInPhase == 0)
        #expect(s.recordRep().isEmpty, "reps outside a curl phase are ignored")
    }

    @Test func timeUpJumpsToRatingFromAnyPhase() {
        var s = WorkoutSession(settings: settings, duration: 60)
        _ = s.start(at: 0)
        _ = s.tick(at: 5)
        #expect(s.currentPhase == .curls(set: 1))
        let t = s.tick(at: 60.5)
        #expect(t == [PhaseTransition(from: .curls(set: 1), to: .rating, cause: "time_up")])
        #expect(s.currentPhase == .rating)
        #expect(s.sessionRemaining == 0)
        #expect(s.tick(at: 10_000).isEmpty, "the rating has no timer")
        #expect(s.recordRep().isEmpty)
        #expect(s.submitRating() == [PhaseTransition(from: .rating, to: nil, cause: "rating_submitted")])
        #expect(s.status == .completed)
        #expect(s.phaseProgress == 1)
    }

    @Test func timeUpDuringRest() {
        var s = WorkoutSession(settings: settings, duration: 180)
        _ = s.start(at: 0)
        var t = 0.0
        while s.currentPhase != .rest(afterSet: 1) {
            if case .curls = s.currentPhase { _ = s.recordRep(); continue }
            t += 0.5
            _ = s.tick(at: t)
        }
        let transitions = s.tick(at: 1000)
        #expect(transitions.last?.to == .rating)
        #expect(transitions.last?.cause == "time_up")
    }

    @Test func pausePreservesRemainingTimeAndPhase() {
        var s = WorkoutSession(settings: settings, duration: 180)
        _ = s.start(at: 0)
        _ = s.tick(at: 2)
        let r1 = s.pause(.user, at: 3); #expect(r1)
        let r2 = !s.pause(.user, at: 3.5); #expect(r2, "double pause is a no-op")
        #expect(s.status == .paused(.user))
        #expect(s.tick(at: 500).isEmpty)
        #expect(s.phaseRemaining == 2)
        #expect(s.sessionRemaining == 177, "the session clock stops while paused")
        #expect(s.recordRep().isEmpty)
        let r3 = s.resume(at: 500); #expect(r3)
        let r4 = !s.resume(at: 500); #expect(r4)
        #expect(s.tick(at: 501.5).isEmpty)
        #expect(abs(s.phaseRemaining! - 0.5) < 1e-9)
        #expect(s.tick(at: 502).count == 1)
        #expect(s.currentPhase == .curls(set: 1))
        #expect(abs(s.activeTime - 5) < 1e-9, "paused time is excluded")
    }

    @Test func completesOnlyAfterTimeAndRating() {
        var s = WorkoutSession(settings: settings, duration: 180)
        _ = s.start(at: 0)
        var t = 0.0
        var guardCount = 0
        while s.status == .running, guardCount < 10_000 {
            guardCount += 1
            switch s.currentPhase {
            case .curls: _ = s.recordRep()
            case .rating: _ = s.submitRating()
            default: t += 1; _ = s.tick(at: t)
            }
        }
        #expect(s.status == .completed)
        #expect(s.activeTime >= 180)
        #expect(s.currentPhase == nil)
        let r5 = !s.stop(.userStopped, at: t); #expect(r5, "a completed session cannot become stopped")
    }

    @Test func stopIsTerminal() {
        var s = WorkoutSession(settings: settings, duration: 180)
        _ = s.start(at: 0)
        _ = s.tick(at: 6)
        let r6 = s.stop(.userStopped, at: 7); #expect(r6)
        #expect(s.status == .stopped(.userStopped))
        #expect(s.status.isFinished)
        #expect(s.tick(at: 100).isEmpty)
        let r7 = !s.resume(at: 100); #expect(r7)
        let r8 = !s.pause(.user, at: 100); #expect(r8)
        #expect(s.recordRep().isEmpty)
        let r9 = !s.stop(.userStopped, at: 101); #expect(r9)
    }

    @Test func stopBeforeStartAndWhilePaused() {
        var a = WorkoutSession(settings: settings, duration: 180)
        let r10 = a.stop(.immersiveSpaceOpenFailed, at: 0); #expect(r10)
        #expect(a.status == .stopped(.immersiveSpaceOpenFailed))
        #expect(a.start(at: 1).isEmpty)

        var b = WorkoutSession(settings: settings, duration: 180)
        _ = b.start(at: 0)
        b.pause(.appInactive, at: 1)
        let r11 = b.stop(.userStopped, at: 50); #expect(r11)
        #expect(abs(b.activeTime - 1) < 1e-9)
    }

    @Test func longGapAdvancesThroughSeveralPhases() {
        var s = WorkoutSession(settings: settings, duration: 600)
        _ = s.start(at: 0)
        // prepare 5 s + curl limit 80 s + prepare 5 s = 90 s, then 1 s into the hold.
        let t = s.tick(at: 91)
        #expect(t.map(\.to) == [.curls(set: 1), .prepare(set: 1, activity: .hold), .hold(set: 1)])
        #expect(abs(s.phaseElapsed - 1) < 1e-9)
    }
}
