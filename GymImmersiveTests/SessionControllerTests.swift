import Foundation
import Testing
@testable import GymImmersive

/// End-to-end controller tests with a fake clock and synthetic movement.
@MainActor
struct SessionControllerTests {
    let clock = FakeClock()
    let input = FakeInput()
    let voice = SilentCoach()
    let directory = Synthetic.tempDirectory()

    private func make(cognitive: Bool = true, id: String = "P01", duration: TimeInterval = 180,
                      colourGame: Bool = true) throws -> SessionController {
        let clock = self.clock
        var settings = WorkoutSettings()
        settings.nBackDuringCurls = colourGame
        return try SessionController(settings: settings, info: .test(cognitive: cognitive, id: id, duration: duration),
                                     input: input, directory: directory, voice: voice, clock: { clock.now })
    }

    /// Advances time in 1/60 s steps, feeding samples from `hand`.
    private func run(_ c: SessionController, seconds: Double, pinchAt: Set<Int> = [],
                     hand: (Double) -> SIMD3<Float>?) {
        let start = clock.now
        var frame = 0
        while clock.now - start < seconds, !c.status.isFinished {
            clock.now += 1.0 / 60
            frame += 1
            let local = clock.now - start
            c.handle(Synthetic.sample(clock.now, hand: hand(local), pinch: pinchAt.contains(frame) ? 0.005 : 0.06))
            c.tick()
        }
    }

    private func idle(_ c: SessionController, seconds: Double) {
        run(c, seconds: seconds) { _ in Synthetic.curlHand(progress: 0) }
    }

    private func curl(_ c: SessionController, reps: Int) {
        run(c, seconds: Double(reps) * 4.3 + 0.6) {
            Synthetic.curlHand(progress: Synthetic.curlProgress(at: $0, up: 2, down: 2, rest: 0.3))
        }
    }

    /// Plays like a cooperative participant until `phase` begins.
    private func advance(_ c: SessionController, to target: Phase) {
        var guardCount = 0
        while c.phase != target, !c.status.isFinished, guardCount < 5000 {
            guardCount += 1
            step(c)
        }
    }

    private func step(_ c: SessionController) {
        switch c.phase {
        case .curls?:
            curl(c, reps: 1)
        case .hold?:
            if let p = c.subtractionProblem { c.answerSubtraction(p.correctAnswer) }
            run(c, seconds: 1) { Synthetic.holdHand(at: $0, tremorAmplitude: 0.001) }
        case .rating?:
            c.draftRating[.physical] = 70
            c.submitRating()
        default:
            idle(c, seconds: 0.05)
        }
    }

    private func runToEnd(_ c: SessionController) {
        var guardCount = 0
        while !c.status.isFinished, guardCount < 20_000 {
            guardCount += 1
            step(c)
        }
    }

    private func rows(_ url: URL?) throws -> [[String: String]] {
        let text = try String(contentsOf: try #require(url), encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        let header = CSV.parseLine(lines[0])
        return lines.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(header, CSV.parseLine($0))) }
    }

    private func events(_ c: SessionController) throws -> [[String: String]] { try rows(c.eventsURL) }

    @Test func sessionRunsForChosenTimeThenAsksForOneRating() async throws {
        let c = try make(duration: 180)
        await c.begin()
        c.startWorkout()
        #expect(c.phase == .prepare(set: 1, activity: .curls))
        #expect(c.sessionCountdownText == "3:00")
        advance(c, to: .rating)
        #expect(c.status == .running)
        #expect(c.session.activeTime >= 180 && c.session.activeTime < 181)
        runToEnd(c)
        #expect(c.status == .completed)
        #expect(c.summary.status == .completed)
        #expect(c.summary.tlx?.physical == 70)

        let first = c.summary.sets[0]
        #expect(first.status == .completed)
        #expect(first.reps == 10)
        #expect(first.hold != nil)
        #expect(first.nBack.count == 10)
        #expect(!first.subtraction.isEmpty)
        #expect(c.summary.sets.count >= 3)
        #expect(c.summary.sets.last?.status == .partial, "the last round was cut by the clock")
        #expect(c.summary.sets[0].arm == .right && c.summary.sets[1].arm == .left)
        #expect(c.summary.sets[1].index == 1 && c.summary.sets[1].status == .completed && c.summary.sets[1].reps == 10)
        #expect(c.summary.sets[2].index == 2 && c.summary.sets[2].config.virtualWeightKg == 10)
        #expect(input.stopCount == 1)

        let summary = try rows(c.summaryURL)
        #expect(summary.count == c.summary.sets.count)
        #expect(summary.allSatisfy { $0["completion_status"] == "completed" && $0["tlx_physical"] == "70" })
        #expect(summary[0]["set_label"] == "round1-right" && summary[0]["reps_completed"] == "10")
        #expect(summary[1]["set_label"] == "round1-left" && summary[1]["arm"] == "left")
        #expect(summary[0]["session_duration_s"] == "180")

        let ev = try events(c)
        #expect(ev.first?["event"] == "session_created")
        #expect(ev.last?["event"] == "session_end" && ev.last?["status"] == "completed")
        #expect(ev.filter { $0["event"] == "nasa_tlx" }.count == 1)
        #expect(ev.contains { $0["event"] == "phase_end" && $0["reason"] == "time_up" })
        #expect(ev.contains { $0["event"] == "motion_sample" && $0["phase"] == "hold" && $0["in_zone"] == "1" })
        let times = ev.compactMap { Double($0["session_time_s"] ?? "") }
        #expect(times == times.sorted())
    }

    @Test func workoutWaitsForStart() async throws {
        let c = try make()
        await c.begin()
        #expect(c.status == .ready)
        #expect(c.isReadyToStart)
        clock.now += 300
        c.tick()
        #expect(c.status == .ready, "the clock does not run before Start")
        #expect(c.session.sessionRemaining == 180)
        c.startWorkout()
        #expect(c.phase == .prepare(set: 1, activity: .curls))
        #expect(!c.isReadyToStart)
        c.startWorkout()
        let ev = try events(c)
        #expect(ev.filter { $0["event"] == "session_started" }.count == 1)
        #expect(ev.contains { $0["event"] == "instructions_shown" })
    }

    @Test func stopOnTheInstructionsScreen() async throws {
        let c = try make()
        await c.begin()
        c.stop()
        #expect(c.status == .stopped(.userStopped))
        #expect(c.summary.status == .incomplete)
        c.startWorkout()
        #expect(c.status == .stopped(.userStopped))
    }

    @Test func colourGameIsOffByDefault() async throws {
        #expect(!WorkoutSettings().nBackDuringCurls)
        let c = try make(duration: 60, colourGame: false)
        await c.begin()
        c.startWorkout()
        advance(c, to: .hold(set: 1))
        #expect(c.summary.sets[0].nBack.isEmpty)
        #expect(c.plateColor == nil)
        #expect(c.subtractionProblem != nil, "counting down by 7 still runs during the hold")
    }

    @Test func bothArmsAreUsedInEachRound() async throws {
        let c = try make()
        await c.begin()
        c.startWorkout()
        #expect(c.activeArm == .right)
        advance(c, to: .curls(set: 1, arm: .left))
        #expect(c.activeArm == .left)
        #expect(input.arms.last == .left, "the input now follows the left hand")
        #expect(c.summary.sets.map(\.arm) == [.right, .left])
        #expect(c.summary.sets[0].status == .completed)
        let ev = try events(c)
        #expect(ev.contains { $0["event"] == "arm_switch" && $0["arm"] == "left" })
        #expect(ev.contains { $0["event"] == "rep" && $0["arm"] == "right" })
        // Left-arm reps are counted for the left record.
        curl(c, reps: 2)
        #expect(c.summary.sets[1].reps >= 1)
        advance(c, to: .curls(set: 2, arm: .right))
        #expect(c.activeArm == .right)
    }

    @Test func oneMinuteSession() async throws {
        let c = try make(duration: 60)
        await c.begin()
        c.startWorkout()
        advance(c, to: .rating)
        #expect(c.summary.sets.count == 1)
        #expect(c.summary.sets[0].reps == 10)
        runToEnd(c)
        #expect(c.status == .completed)
    }

    @Test func cognitiveTaskCanBeDisabled() async throws {
        let c = try make(cognitive: false, duration: 60)
        await c.begin()
        c.startWorkout()
        runToEnd(c)
        #expect(c.status == .completed)
        #expect(c.summary.sets.allSatisfy { $0.nBack.isEmpty && $0.subtraction.isEmpty })
        #expect(c.plateColor == nil)
        #expect(try rows(c.summaryURL).allSatisfy { $0["cognitive_task"] == "0" && $0["nback_hits"] == "" })
    }

    @Test func nBackPinchResponsesAreLogged() async throws {
        let c = try make()
        await c.begin()
        c.startWorkout()
        advance(c, to: .curls(set: 1))
        #expect(c.plateColor != nil)
        // Pinch ~0.5 s after the first stimulus, then curl.
        run(c, seconds: 4.9, pinchAt: [30]) {
            Synthetic.curlHand(progress: Synthetic.curlProgress(at: $0, up: 2, down: 2, rest: 0.3))
        }
        let ev = try events(c)
        let response = try #require(ev.first { $0["event"] == "nback_response" })
        #expect(response["trial_index"] == "0")
        #expect(response["response_source"] == "pinch")
        let rt = try #require(Double(response["rt_ms"] ?? ""))
        #expect(rt > 400 && rt < 650)
        let trial0 = try #require(ev.first { $0["event"] == "nback_trial" && $0["trial_index"] == "0" })
        #expect(trial0["outcome"] == "false_alarm", "trial 0 can never be a 2-back match")
    }

    @Test func pauseAndResumeKeepPhaseAndTime() async throws {
        let c = try make()
        await c.begin()
        c.startWorkout()
        idle(c, seconds: 2)
        let remaining = c.session.phaseRemaining!
        let sessionLeft = c.session.sessionRemaining
        c.pause()
        #expect(c.status == .paused(.user))
        clock.now += 120
        c.tick()
        #expect(c.session.phaseRemaining == remaining)
        #expect(c.session.sessionRemaining == sessionLeft)
        #expect(c.phase == .prepare(set: 1, activity: .curls))
        c.resume()
        #expect(c.status == .running)
        idle(c, seconds: 3.5)
        #expect(c.phase == .curls(set: 1))
        #expect(c.summary.pauseCount == 1)
        let ev = try events(c)
        #expect(ev.contains { $0["event"] == "pause" && $0["reason"] == "user" })
        #expect(ev.contains { $0["event"] == "resume" })
    }

    @Test func pauseDuringCurlsInterruptsTrialAndDiscardsHalfRep() async throws {
        let c = try make()
        await c.begin()
        c.startWorkout()
        advance(c, to: .curls(set: 1))
        // Half a curl (bottom → top), pause, resume, finish the descent: must not count.
        run(c, seconds: 2.2) { Synthetic.curlHand(progress: Synthetic.curlProgress(at: $0, up: 2, down: 2, rest: 0.3)) }
        c.pause()
        clock.now += 5
        c.resume()
        run(c, seconds: 2.5) { Synthetic.curlHand(progress: Synthetic.curlProgress(at: $0 + 2.2, up: 2, down: 2, rest: 0.3)) }
        #expect(c.session.repsInPhase == 0)
        let ev = try events(c)
        #expect(ev.contains { $0["event"] == "nback_trial" && $0["outcome"] == "interrupted" })
        #expect(ev.filter { $0["event"] == "nback_stimulus" }.count == 2, "a new stimulus is shown on resume")
    }

    @Test func lostHandIsLoggedButNeverPauses() async throws {
        let c = try make()
        await c.begin()
        c.startWorkout()
        advance(c, to: .curls(set: 1))
        run(c, seconds: 10) { _ in nil }
        #expect(c.status == .running)
        #expect(!c.isHandTracked)
        #expect(c.summary.trackingLossCount == 1)
        idle(c, seconds: 0.5)
        #expect(c.isHandTracked)
        #expect(c.status == .running)
        let ev = try events(c)
        #expect(ev.contains { $0["event"] == "tracking_lost" })
        #expect(ev.contains { $0["event"] == "tracking_restored" })
        #expect(!ev.contains { $0["event"] == "pause" })
    }

    @Test func stalledInputIsLoggedButNeverPauses() async throws {
        let c = try make()
        await c.begin()
        c.startWorkout()
        idle(c, seconds: 5.5)
        for _ in 0..<200 { clock.now += 0.05; c.tick() }  // 10 s with no samples
        #expect(c.status == .running)
        #expect(c.summary.trackingLossCount == 1)
    }

    @Test func earlyStopIsIncompleteWithPartialData() async throws {
        let c = try make()
        await c.begin()
        c.startWorkout()
        advance(c, to: .hold(set: 1))
        if let p = c.subtractionProblem { c.answerSubtraction(p.correctAnswer) }
        run(c, seconds: 5) { Synthetic.holdHand(at: $0, tremorAmplitude: 0.001) }
        c.stop()
        #expect(c.status == .stopped(.userStopped))
        #expect(c.summary.status == .incomplete)
        #expect(c.summary.stopReason == "user_stopped")
        #expect(c.summary.sets.count == 1)
        #expect(c.summary.sets[0].status == .partial)
        #expect(c.summary.sets[0].hold != nil, "partial hold data is kept")
        #expect(c.summary.sets[0].reps == 10)
        #expect(c.summary.tlx == nil)
        #expect(input.stopCount == 1)

        // Further commands are ignored and do not write.
        let before = try events(c).count
        c.resume(); c.pause(); c.stop(); c.submitRating(); c.respondNBack(source: "pinch"); c.tick()
        c.handle(Synthetic.sample(clock.now, hand: Synthetic.holdHand(at: 0)))
        #expect(try events(c).count == before)

        let summary = try rows(c.summaryURL)
        #expect(summary.count == 1)
        #expect(summary[0]["completion_status"] == "incomplete" && summary[0]["stop_reason"] == "user_stopped")
        #expect(summary[0]["set_status"] == "partial")
        #expect(!(summary[0]["hold_tremor_rms_mm"] ?? "").isEmpty)
        let ev = try events(c)
        #expect(ev.last?["event"] == "session_end" && ev.last?["status"] == "incomplete")
        #expect(ev.contains { $0["event"] == "subtraction_response" && $0["outcome"] == "interrupted" })
    }

    @Test func timeUpMidCurlsDoesNotScoreTheCutTrial() async throws {
        let c = try make(duration: 60)
        await c.begin()
        c.startWorkout()
        advance(c, to: .curls(set: 1))
        // Stand still until the minute is up: the open 2-back trial is cut short.
        idle(c, seconds: 60)
        #expect(c.phase == .rating)
        let ev = try events(c)
        #expect(ev.contains { $0["event"] == "phase_end" && $0["phase"] == "curls" && $0["reason"] == "time_up" })
        let trial = try #require(ev.last { $0["event"] == "nback_trial" })
        #expect(trial["outcome"] == "interrupted")
        #expect(c.summary.sets[0].status == .partial)
    }

    @Test func handTrackingDeniedEndsIncomplete() async throws {
        input.failWith = MovementInputError.notAuthorized
        let c = try make()
        await c.begin()
        c.startWorkout()
        #expect(c.status == .stopped(.handTrackingUnavailable))
        #expect(c.errorMessage != nil)
        #expect(c.summary.status == .incomplete)
        #expect(try events(c).contains { $0["event"] == "input_failed" })
        #expect(try rows(c.summaryURL).count == 1, "a session with no rounds still has a summary row")
    }

    @Test func immersiveSpaceFailuresAndDismissal() async throws {
        let a = try make(id: "A")
        a.stop(.immersiveSpaceOpenFailed)
        #expect(a.summary.status == .incomplete && a.summary.stopReason == "immersive_space_open_failed")
        await a.begin()
        a.startWorkout()
        #expect(a.status == .stopped(.immersiveSpaceOpenFailed), "begin after a stop does nothing")

        let b = try make(id: "B")
        await b.begin()
        b.startWorkout()
        idle(b, seconds: 3)
        b.immersiveSpaceDidDisappear()
        #expect(b.status == .stopped(.immersiveSpaceDismissed))
        b.immersiveSpaceDidDisappear()
        #expect(b.summary.stopReason == "immersive_space_dismissed")
    }

    @Test func appInactivePauses() async throws {
        let c = try make()
        await c.begin()
        c.startWorkout()
        c.appBecameInactive()
        #expect(c.status == .paused(.appInactive))
    }

    @Test func subtractionTimeoutAdvances() async throws {
        let c = try make()
        await c.begin()
        c.startWorkout()
        advance(c, to: .hold(set: 1))
        let first = try #require(c.subtractionProblem)
        run(c, seconds: 8.5) { Synthetic.holdHand(at: $0) }
        let second = try #require(c.subtractionProblem)
        #expect(second.index == first.index + 1)
        #expect(second.previousValue == first.correctAnswer)
        #expect(try events(c).contains { $0["event"] == "subtraction_response" && $0["outcome"] == "timeout" })
    }

    @Test func curlTimeLimitPreventsStuckRound() async throws {
        let c = try make(duration: 600)
        await c.begin()
        c.startWorkout()
        idle(c, seconds: 5.5)
        #expect(c.phase == .curls(set: 1))
        idle(c, seconds: 81)
        #expect(c.phase == .prepare(set: 1, activity: .hold))
        #expect(c.summary.sets[0].curlTimeLimitReached)
        #expect(c.summary.sets[0].reps == 0)
    }
}
