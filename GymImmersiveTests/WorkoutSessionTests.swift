import Foundation
import Testing
@testable import GymImmersive

struct WorkoutSessionTests {
    let settings = WorkoutSettings()

    @Test func planOrder() {
        let plan = Phase.plan(for: settings)
        #expect(plan.first == .prepare(set: 0, activity: .curls))
        #expect(plan[1] == .curls(set: 0))
        #expect(plan[2] == .rest(afterSet: 0))
        #expect(plan[3...8] == [.prepare(set: 1, activity: .curls), .curls(set: 1),
                                .prepare(set: 1, activity: .hold), .hold(set: 1), .rating(set: 1), .rest(afterSet: 1)])
        #expect(plan.last == .rating(set: 3))
        #expect(!plan.contains(.rest(afterSet: 3)))
        #expect(plan.count == 20)
    }

    @Test func startEntersFirstPhaseOnce() {
        var s = WorkoutSession(settings: settings)
        #expect(s.currentPhase == nil)
        let t = s.start(at: 0)
        #expect(t == [PhaseTransition(from: nil, to: .prepare(set: 0, activity: .curls), cause: "start")])
        #expect(s.start(at: 1).isEmpty)
        #expect(s.status == .running)
    }

    @Test func timedPhasesAdvanceWithCarryOver() {
        var s = WorkoutSession(settings: settings)
        _ = s.start(at: 0)
        #expect(s.tick(at: 4.9).isEmpty)
        #expect(abs(s.phaseRemaining! - 0.1) < 1e-9)
        let t = s.tick(at: 5.3)
        #expect(t.count == 1)
        #expect(t[0].to == .curls(set: 0))
        #expect(abs(s.phaseElapsed - 0.3) < 1e-9)
        #expect(abs(s.activeTime - 5.3) < 1e-9)
    }

    @Test func curlTimeLimitEndsPhase() {
        var s = WorkoutSession(settings: settings)
        _ = s.start(at: 0)
        _ = s.tick(at: 5)  // -> curls(0); limit 5 reps × 4 s × 2 = 40 s
        #expect(s.currentPhase == .curls(set: 0))
        #expect(s.phaseRemaining == 40)
        let t = s.tick(at: 45)
        #expect(t.first?.cause == "time_limit")
        #expect(s.currentPhase == .rest(afterSet: 0))
    }

    @Test func repsEndCurlPhaseImmediately() {
        var s = WorkoutSession(settings: settings)
        _ = s.start(at: 0)
        _ = s.tick(at: 5)
        for _ in 0..<4 { #expect(s.recordRep().isEmpty) }
        #expect(s.repsInPhase == 4)
        #expect(s.phaseProgress == 0.8)
        let t = s.recordRep()
        #expect(t == [PhaseTransition(from: .curls(set: 0), to: .rest(afterSet: 0), cause: "reps_done")])
        #expect(s.repsInPhase == 0)
        #expect(s.recordRep().isEmpty, "reps outside a curl phase are ignored")
    }

    @Test func pausePreservesRemainingTimeAndPhase() {
        var s = WorkoutSession(settings: settings)
        _ = s.start(at: 0)
        _ = s.tick(at: 2)
        let r1 = s.pause(.user, at: 3); #expect(r1)
        let r2 = !s.pause(.user, at: 3.5); #expect(r2, "double pause is a no-op")
        #expect(s.status == .paused(.user))
        #expect(s.tick(at: 500).isEmpty)
        #expect(s.phaseRemaining == 2)
        #expect(s.recordRep().isEmpty)
        let r3 = s.resume(at: 500); #expect(r3)
        let r4 = !s.resume(at: 500); #expect(r4)
        #expect(s.tick(at: 501.5).isEmpty)
        #expect(abs(s.phaseRemaining! - 0.5) < 1e-9)
        #expect(s.tick(at: 502).count == 1)
        #expect(s.currentPhase == .curls(set: 0))
        #expect(abs(s.activeTime - 5) < 1e-9, "paused time is excluded")
    }

    @Test func ratingWaitsForSubmission() {
        var s = WorkoutSession(settings: settings)
        _ = s.start(at: 0)
        // Jump forward one phase at a time until the first rating.
        var t = 0.0
        while s.currentPhase != .rating(set: 1) {
            if case .curls = s.currentPhase { _ = s.recordRep(); continue }
            t += 1
            _ = s.tick(at: t)
        }
        #expect(s.phaseRemaining == nil)
        #expect(s.tick(at: t + 10_000).isEmpty)
        #expect(s.currentPhase == .rating(set: 1))
        #expect(s.submitRating().first?.to == .rest(afterSet: 1))
        #expect(s.submitRating().isEmpty)
    }

    @Test func completesAfterLastRating() {
        var s = WorkoutSession(settings: settings)
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
        #expect(s.currentPhase == nil)
        #expect(s.phaseProgress == 1)
        let r5 = !s.stop(.userStopped, at: t); #expect(r5, "a completed session cannot become stopped")
    }

    @Test func stopIsTerminal() {
        var s = WorkoutSession(settings: settings)
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
        var a = WorkoutSession(settings: settings)
        let r10 = a.stop(.immersiveSpaceOpenFailed, at: 0); #expect(r10)
        #expect(a.status == .stopped(.immersiveSpaceOpenFailed))
        #expect(a.start(at: 1).isEmpty)

        var b = WorkoutSession(settings: settings)
        _ = b.start(at: 0)
        b.pause(.trackingLost, at: 1)
        let r11 = b.stop(.userStopped, at: 50); #expect(r11)
        #expect(abs(b.activeTime - 1) < 1e-9)
    }

    @Test func longGapAdvancesThroughSeveralPhases() {
        var s = WorkoutSession(settings: settings)
        _ = s.start(at: 0)
        // prepare 5 s + curls limit 40 s + rest 20 s = 65 s, then prepare(1) 5 s.
        let t = s.tick(at: 66)
        #expect(t.map(\.to) == [.curls(set: 0), .rest(afterSet: 0), .prepare(set: 1, activity: .curls)])
        #expect(abs(s.phaseElapsed - 1) < 1e-9)
    }
}
