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

    private func make(cognitive: Bool = true, id: String = "P01") throws -> SessionController {
        let clock = self.clock
        return try SessionController(settings: WorkoutSettings(), info: .test(cognitive: cognitive, id: id),
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

    /// Drives the session through every phase like a cooperative participant.
    private func runToEnd(_ c: SessionController) {
        var guardCount = 0
        while !c.status.isFinished, guardCount < 400 {
            guardCount += 1
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
                idle(c, seconds: 1)
            }
        }
    }

    private func events(_ c: SessionController) throws -> [[String: String]] {
        let text = try String(contentsOf: c.eventsURL!, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        let header = CSV.parseLine(lines[0])
        return lines.dropFirst().map { line in
            let row = CSV.parseLine(line)
            return Dictionary(uniqueKeysWithValues: zip(header, row))
        }
    }

    private func summaryRows(_ c: SessionController) throws -> [[String: String]] {
        let text = try String(contentsOf: c.summaryURL!, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        let header = CSV.parseLine(lines[0])
        return lines.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(header, CSV.parseLine($0))) }
    }

    @Test func fullSessionCompletes() async throws {
        let c = try make()
        await c.begin()
        #expect(c.phase == .prepare(set: 0, activity: .curls))
        runToEnd(c)
        #expect(c.status == .completed)
        #expect(c.summary.status == .completed)
        for set in c.summary.sets {
            #expect(set.status == .completed, "set \(set.index)")
            #expect(set.reps == set.config.curlReps, "set \(set.index) reps \(set.reps)")
            #expect(!set.curlTimeLimitReached)
        }
        for set in c.summary.sets.dropFirst() {
            #expect(set.tlx?.physical == 70)
            #expect(set.hold != nil)
            #expect(set.nBack.count == set.config.curlReps)
            #expect(!set.subtraction.isEmpty)
            #expect(set.subtraction.allSatisfy { $0.outcome == .correct || $0.outcome == .interrupted })
            let hold = set.hold!
            #expect(abs(hold.trackedDuration - set.config.holdDuration) < 1.5)
            #expect(hold.tremorRMSmm != nil)
        }
        #expect(c.summary.sets[0].nBack.isEmpty, "no cognitive task in practice")
        #expect(input.stopCount == 1)

        let rows = try summaryRows(c)
        #expect(rows.count == 4)
        #expect(rows.allSatisfy { $0["completion_status"] == "completed" && $0["set_status"] == "completed" })
        #expect(rows[3]["reps_completed"] == "10" && rows[3]["hold_target_s"] == "60")
        #expect(rows[1]["tlx_physical"] == "70")
        #expect(rows[0]["condition"] == "dual, task")

        let ev = try events(c)
        #expect(ev.first?["event"] == "session_created")
        #expect(ev.last?["event"] == "session_end")
        #expect(ev.last?["status"] == "completed")
        #expect(ev.filter { $0["event"] == "rep" }.count == 35)
        #expect(ev.filter { $0["event"] == "nasa_tlx" }.count == 3)
        #expect(ev.filter { $0["event"] == "nback_stimulus" }.count == 30)
        #expect(ev.filter { $0["event"] == "nback_trial" }.count == 30)
        #expect(ev.contains { $0["event"] == "hold_summary" && $0["set_index"] == "3" })
        #expect(ev.contains { $0["event"] == "motion_sample" && $0["phase"] == "hold" && $0["in_zone"] == "1" })
        // Session time is monotonic.
        let times = ev.compactMap { Double($0["session_time_s"] ?? "") }
        #expect(times == times.sorted())
    }

    @Test func cognitiveTaskCanBeDisabled() async throws {
        let c = try make(cognitive: false)
        await c.begin()
        runToEnd(c)
        #expect(c.status == .completed)
        #expect(c.summary.sets.allSatisfy { $0.nBack.isEmpty && $0.subtraction.isEmpty })
        #expect(c.plateColor == nil)
        let rows = try summaryRows(c)
        #expect(rows.allSatisfy { $0["cognitive_task"] == "0" && $0["nback_hits"] == "" })
    }

    @Test func nBackPinchResponsesAreLogged() async throws {
        let c = try make()
        await c.begin()
        while c.phase != .curls(set: 1) { if case .curls? = c.phase { curl(c, reps: 1) } else { idle(c, seconds: 0.05) } }
        #expect(c.plateColor != nil)
        // Pinch during the first stimulus (frame 30 ≈ 0.5 s after onset), then curl.
        run(c, seconds: 4.9, pinchAt: [30]) {
            Synthetic.curlHand(progress: Synthetic.curlProgress(at: $0, up: 2, down: 2, rest: 0.3))
        }
        let ev = try events(c)
        let response = try #require(ev.first { $0["event"] == "nback_response" })
        #expect(response["trial_index"] == "0")
        #expect(response["response_source"] == "pinch")
        let rt = try #require(Double(response["rt_ms"] ?? ""))
        #expect(rt > 400 && rt < 600)
        let trial0 = try #require(ev.first { $0["event"] == "nback_trial" && $0["trial_index"] == "0" })
        #expect(trial0["outcome"] == "false_alarm", "trial 0 can never be a 2-back match")
    }

    @Test func pauseAndResumeKeepPhaseAndTime() async throws {
        let c = try make()
        await c.begin()
        idle(c, seconds: 2)
        let remaining = c.session.phaseRemaining!
        c.pause()
        #expect(c.status == .paused(.user))
        clock.now += 120
        c.tick()
        #expect(c.session.phaseRemaining == remaining)
        #expect(c.phase == .prepare(set: 0, activity: .curls))
        c.resume()
        #expect(c.status == .running)
        idle(c, seconds: 3.5)
        #expect(c.phase == .curls(set: 0))
        #expect(c.summary.pauseCount == 1)
        let ev = try events(c)
        #expect(ev.contains { $0["event"] == "pause" && $0["reason"] == "user" })
        #expect(ev.contains { $0["event"] == "resume" })
    }

    @Test func pauseDuringCurlsInterruptsTrialAndDiscardsHalfRep() async throws {
        let c = try make()
        await c.begin()
        while c.phase != .curls(set: 1) { if case .curls? = c.phase { curl(c, reps: 1) } else { idle(c, seconds: 1) } }
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

    @Test func trackingLossAutoPauses() async throws {
        let c = try make()
        await c.begin()
        idle(c, seconds: 5.5)
        #expect(c.phase == .curls(set: 0))
        run(c, seconds: 2) { _ in nil }
        #expect(c.status == .running, "short loss does not pause")
        #expect(!c.isHandTracked)
        run(c, seconds: 1.5) { _ in nil }
        #expect(c.status == .paused(.trackingLost))
        #expect(c.summary.trackingLossCount == 1)
        idle(c, seconds: 0.5)
        #expect(c.isHandTracked)
        #expect(c.status == .paused(.trackingLost), "resuming after tracking loss is deliberate")
        c.resume()
        #expect(c.status == .running)
        let ev = try events(c)
        #expect(ev.contains { $0["event"] == "tracking_lost" })
        #expect(ev.contains { $0["event"] == "tracking_restored" })
        #expect(ev.contains { $0["event"] == "pause" && $0["reason"] == "tracking_lost" })
    }

    @Test func stalledInputStreamCountsAsTrackingLoss() async throws {
        let c = try make()
        await c.begin()
        idle(c, seconds: 5.5)
        for _ in 0..<200 { clock.now += 0.05; c.tick() }  // 10 s with no samples
        #expect(c.status == .paused(.trackingLost))
    }

    @Test func trackingLossOutsideActivePhasesDoesNotPause() async throws {
        let c = try make()
        await c.begin()
        run(c, seconds: 4.5) { _ in nil }
        #expect(c.status == .running)
        #expect(c.phase == .prepare(set: 0, activity: .curls))
    }

    @Test func earlyStopIsIncompleteWithPartialData() async throws {
        let c = try make()
        await c.begin()
        while c.phase != .hold(set: 1) {
            if case .curls? = c.phase { curl(c, reps: 1) } else { idle(c, seconds: 1) }
        }
        if let p = c.subtractionProblem { c.answerSubtraction(p.correctAnswer) }
        run(c, seconds: 10) { Synthetic.holdHand(at: $0, tremorAmplitude: 0.001) }
        c.stop()
        #expect(c.status == .stopped(.userStopped))
        #expect(c.summary.status == .incomplete)
        #expect(c.summary.stopReason == "user_stopped")
        #expect(c.summary.sets[1].status == .partial)
        #expect(c.summary.sets[1].hold != nil, "partial hold data is kept")
        #expect(c.summary.sets[1].reps == 10)
        #expect(c.summary.sets[2].status == .notStarted)
        #expect(input.stopCount == 1)

        // Further commands are ignored and do not write.
        let before = try events(c).count
        c.resume(); c.pause(); c.stop(); c.submitRating(); c.respondNBack(source: "pinch"); c.tick()
        c.handle(Synthetic.sample(clock.now, hand: Synthetic.holdHand(at: 0)))
        #expect(try events(c).count == before)

        let rows = try summaryRows(c)
        #expect(rows.allSatisfy { $0["completion_status"] == "incomplete" && $0["stop_reason"] == "user_stopped" })
        #expect(rows[1]["set_status"] == "partial")
        #expect(rows[2]["set_status"] == "not_started" && rows[2]["reps_completed"] == "")
        #expect(!(rows[1]["hold_tremor_rms_mm"] ?? "").isEmpty)
        let ev = try events(c)
        #expect(ev.last?["event"] == "session_end" && ev.last?["status"] == "incomplete")
        #expect(ev.contains { $0["event"] == "subtraction_response" && $0["outcome"] == "interrupted" })
    }

    @Test func handTrackingDeniedEndsIncomplete() async throws {
        input.failWith = MovementInputError.notAuthorized
        let c = try make()
        await c.begin()
        #expect(c.status == .stopped(.handTrackingUnavailable))
        #expect(c.errorMessage != nil)
        #expect(c.summary.status == .incomplete)
        let ev = try events(c)
        #expect(ev.contains { $0["event"] == "input_failed" })
    }

    @Test func immersiveSpaceFailuresAndDismissal() async throws {
        let a = try make(id: "A")
        a.stop(.immersiveSpaceOpenFailed)
        #expect(a.summary.status == .incomplete && a.summary.stopReason == "immersive_space_open_failed")
        await a.begin()
        #expect(a.status == .stopped(.immersiveSpaceOpenFailed), "begin after a stop does nothing")

        let b = try make(id: "B")
        await b.begin()
        idle(b, seconds: 3)
        b.immersiveSpaceDidDisappear()
        #expect(b.status == .stopped(.immersiveSpaceDismissed))
        b.immersiveSpaceDidDisappear()
        #expect(b.summary.stopReason == "immersive_space_dismissed")
    }

    @Test func appInactivePauses() async throws {
        let c = try make()
        await c.begin()
        c.appBecameInactive()
        #expect(c.status == .paused(.appInactive))
    }

    @Test func subtractionTimeoutAdvances() async throws {
        let c = try make()
        await c.begin()
        while c.phase != .hold(set: 1) { if case .curls? = c.phase { curl(c, reps: 1) } else { idle(c, seconds: 1) } }
        let first = try #require(c.subtractionProblem)
        run(c, seconds: 8.5) { Synthetic.holdHand(at: $0) }
        let second = try #require(c.subtractionProblem)
        #expect(second.index == first.index + 1)
        #expect(second.previousValue == first.correctAnswer)
        let ev = try events(c)
        #expect(ev.contains { $0["event"] == "subtraction_response" && $0["outcome"] == "timeout" })
    }

    @Test func curlTimeLimitPreventsStuckSet() async throws {
        let c = try make()
        await c.begin()
        idle(c, seconds: 5.5)
        #expect(c.phase == .curls(set: 0))
        idle(c, seconds: 41)
        #expect(c.phase == .rest(afterSet: 0))
        #expect(c.summary.sets[0].curlTimeLimitReached)
        #expect(c.summary.sets[0].reps == 0)
    }
}
