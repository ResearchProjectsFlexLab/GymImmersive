import Foundation
import Observation
import simd

/// Owns one workout session: the `WorkoutSession` state machine, the cognitive tasks, the
/// movement analysers and the recorder. It is the only place session state changes, and it runs
/// at most one tick task and one input task, both cancelled when the session ends.
@MainActor
@Observable
final class SessionController {
    let settings: WorkoutSettings
    let info: SessionInfo
    let inputName: String
    let drivesDumbbellFromSamples: Bool

    private(set) var session: WorkoutSession
    private(set) var summary: SessionSummary
    private(set) var lastSample: MovementSample?
    private(set) var isHandTracked = true
    private(set) var plateColor: PlateColor?
    private(set) var subtractionProblem: SubtractionProblem?
    private(set) var holdFrame: HoldFrame?
    private(set) var holdReference: SIMD3<Float>?
    private(set) var lastTempo: TempoScore?
    private(set) var errorMessage: String?
    /// Movement input is running and the participant can press Start.
    private(set) var isReadyToStart = false
    /// The arm holding the phone right now (right first in every round, then left).
    private(set) var activeArm: DumbbellHand
    /// Wall-clock time Start was pressed (shown on the coach panel).
    private(set) var workoutStartedAt: Date?
    private(set) var coachTip: String?
    /// Increments on every counted rep; the immersive view plays a sound when it changes.
    private(set) var repFeedbackCount = 0
    /// Timestamped, readable record of this session's events (newest last, capped at `TimeLog.maxEntries`).
    private(set) var timeLog: [TimeLogEntry] = []
    var draftRating = NASATLXRating()

    @ObservationIgnored private let recorder: SessionRecorder?
    @ObservationIgnored private let input: MovementInputProvider
    @ObservationIgnored private let voice: CoachSpeaking
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var startTime: TimeInterval?
    @ObservationIgnored private var rng: SeededRandom
    @ObservationIgnored private var nBack: NBackTask?
    @ObservationIgnored private var subtraction: SerialSubtractionTask?
    @ObservationIgnored private var curlDetector: CurlDetector
    @ObservationIgnored private var holdAnalyzer: HoldAnalyzer?
    @ObservationIgnored private var pinch = PinchDetector()
    @ObservationIgnored private var trackingLostSince: TimeInterval?
    @ObservationIgnored private var lastSampleTime: TimeInterval?
    @ObservationIgnored private var lastMotionLogTime: TimeInterval = -.infinity
    @ObservationIgnored private var coachTipExpiry: TimeInterval = 0
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var hasBegun = false

    static let motionLogInterval: TimeInterval = 0.1

    init(settings: WorkoutSettings, info: SessionInfo, input: MovementInputProvider,
         directory: URL?, voice: CoachSpeaking, clock: @escaping () -> TimeInterval = MonotonicClock.now,
         now: Date = Date()) throws {
        self.settings = settings
        self.info = info
        self.input = input
        self.inputName = input.name
        self.drivesDumbbellFromSamples = input.drivesDumbbellFromSamples
        self.voice = voice
        self.clock = clock
        self.rng = SeededRandom(seed: info.seed)
        self.activeArm = info.dumbbellHand
        self.session = WorkoutSession(settings: settings, duration: info.duration)
        self.curlDetector = CurlDetector(settings: settings)
        self.recorder = try directory.map { try SessionRecorder(directory: $0, info: info, startedAt: now) }
        self.summary = SessionSummary(sessionID: recorder?.sessionID ?? "unsaved", info: info,
                                      inputSource: input.name, startedAt: now, sets: [])
        log("session_created", [.detail: "duration_s=\(Int(info.duration)) cognitive=\(info.cognitiveTaskEnabled) hand=\(info.dumbbellHand.rawValue) seed=\(info.seed) input=\(input.name)"])
        persistSummary()
    }

    var eventsURL: URL? { recorder?.eventsURL }
    var summaryURL: URL? { recorder?.summaryURL }
    var timeLogURL: URL? { recorder?.timeLogURL }
    var timeLogText: String { TimeLog.text(sessionID: summary.sessionID, entries: timeLog) }
    var status: SessionStatus { session.status }
    var phase: Phase? { session.currentPhase }
    var currentSet: SetConfig? { session.currentSet }
    var isCognitiveActive: Bool { info.cognitiveTaskEnabled && phase != nil && phase != .rating }
    /// The colour 2-back runs during curls only when enabled in the settings.
    var isColourGameActive: Bool { isCognitiveActive && settings.nBackDuringCurls }
    var showArmUpCue: Bool { holdFrame?.showArmUpCue ?? false }

    // MARK: Lifecycle

    /// Starts movement input (asking for hand-tracking permission if needed). The workout itself
    /// waits for `startWorkout()`, so the participant can read the instructions first.
    /// Safe to call more than once; only the first call acts.
    func begin() async {
        guard !hasBegun, session.status == .ready else { return }
        hasBegun = true
        do {
            let stream = try await input.start()
            guard session.status == .ready else { input.stop(); return }  // stopped while waiting
            inputTask = Task { [weak self] in
                for await sample in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.handle(sample)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            log("input_failed", [.detail: error.localizedDescription])
            stop(.handTrackingUnavailable)
            return
        }
        isReadyToStart = true
        log("instructions_shown")
    }

    /// The participant pressed Start: the session clock begins.
    func startWorkout() {
        guard isReadyToStart, session.status == .ready else { return }
        isReadyToStart = false
        workoutStartedAt = Date()
        let now = clock()
        startTime = now
        lastSampleTime = now
        log("session_started")
        apply(session.start(at: now))
        startTicking()
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    func tick() {
        let now = clock()
        guard !session.status.isFinished else { return }
        apply(session.tick(at: now))
        guard session.status == .running else { return }

        if var task = subtraction, let result = task.checkTimeout(at: now) {
            subtraction = task
            logSubtraction(result)
            showTip("Too slow. It was \(result.problem.correctAnswer).", now: now)
            presentSubtraction(at: now)
        }

        // A stalled stream counts as lost tracking too. Tracking loss is only logged; the workout
        // keeps running so the participant is never interrupted.
        if let last = lastSampleTime, now - last > settings.inputStallThreshold, trackingLostSince == nil {
            markTrackingLost(at: last)
        }
        if coachTip != nil, now >= coachTipExpiry { coachTip = nil }
    }

    func pause(_ reason: PauseReason = .user) {
        let now = clock()
        guard session.pause(reason, at: now) else { return }
        summary.pauseCount += 1
        log("pause", [.reason: reason.rawValue])
        interruptTasks(at: now)
        input.setMotionHint(.idle)
        voice.stop()
        persistSummary()
    }

    func resume() {
        let now = clock()
        guard session.resume(at: now) else { return }
        trackingLostSince = nil
        lastSampleTime = now
        log("resume")
        guard let phase else { return }
        switch phase {
        case .curls: presentNBackStimulus(at: now)
        case .hold: presentSubtraction(at: now)
        default: break
        }
        input.setMotionHint(motionHint(for: phase))
    }

    func stop(_ reason: StopReason = .userStopped) {
        let now = clock()
        let wasActive = session.status != .ready
        guard session.stop(reason, at: now) else { return }
        if wasActive, let phase = session.plan.indices.contains(session.phaseIndex) ? session.plan[session.phaseIndex] : nil {
            finalizePhaseData(phase, at: now, interrupted: true)
        }
        finish(status: .incomplete, reason: reason.rawValue)
    }

    /// The immersive space went away (Digital Crown, system dismissal, crash of the scene).
    func immersiveSpaceDidDisappear() {
        if !session.status.isFinished { stop(.immersiveSpaceDismissed) }
    }

    func appBecameInactive() {
        if session.status == .running { pause(.appInactive) }
    }

    // MARK: Participant responses

    func respondNBack(source: String, at time: TimeInterval? = nil) {
        guard session.status == .running, case .curls = phase, var task = nBack else { return }
        let t = time ?? clock()
        let response = task.respond(at: t)
        nBack = task
        switch response {
        case let .recorded(trial, rt, isMatch):
            log("nback_response", [.trialIndex: String(trial), .rtMs: CSV.number(rt * 1000, decimals: 0),
                                   .isMatch: CSV.bool(isMatch), .responseSource: source])
        case .duplicate(let trial):
            log("nback_extra_response", [.trialIndex: String(trial), .responseSource: source])
        case .noActiveTrial:
            log("nback_extra_response", [.responseSource: source, .detail: "no_active_trial"])
        }
    }

    func answerSubtraction(_ choice: Int) {
        let now = clock()
        guard session.status == .running, case .hold = phase, var task = subtraction,
              let result = task.answer(choice, at: now) else { return }
        subtraction = task
        logSubtraction(result)
        showTip(result.outcome == .correct ? "Right!" : "It was \(result.problem.correctAnswer).",
                now: now)
        presentSubtraction(at: now)
    }

    func submitRating() {
        guard session.status == .running, phase == .rating else { return }
        let r = draftRating
        summary.tlx = r
        log("nasa_tlx", [.tlxMental: CSV.number(r.mental, decimals: 0), .tlxPhysical: CSV.number(r.physical, decimals: 0),
                         .tlxTemporal: CSV.number(r.temporal, decimals: 0), .tlxPerformance: CSV.number(r.performance, decimals: 0),
                         .tlxEffort: CSV.number(r.effort, decimals: 0), .tlxFrustration: CSV.number(r.frustration, decimals: 0),
                         .tlxRawMean: CSV.number(r.rawMean, decimals: 1)])
        apply(session.submitRating())
    }

    // MARK: Movement

    func handle(_ sample: MovementSample) {
        guard !session.status.isFinished else { return }
        lastSample = sample
        lastSampleTime = sample.time
        let t = sample.time

        if pinch.update(distance: sample.freeHandPinchDistance) {
            respondNBack(source: "pinch", at: t)
        }

        guard let hand = sample.dumbbellHand else {
            if trackingLostSince == nil { markTrackingLost(at: t) }
            return
        }
        if trackingLostSince != nil {
            trackingLostSince = nil
            isHandTracked = true
            log("tracking_restored")
        }
        guard session.status == .running, let phase else { return }
        let shoulder = BodyGeometry.shoulder(head: sample.head, forward: sample.headForward, hand: activeArm)

        switch phase {
        case .curls:
            logMotion(t, hand: hand, shoulder: shoulder, frame: nil)
            if let event = curlDetector.process(time: t, handY: Double(hand.y), shoulderY: Double(shoulder.y)) {
                handleCurl(event, at: t)
            }
        case .hold:
            guard var analyzer = holdAnalyzer else { return }
            let frame = analyzer.add(time: t, hand: hand, shoulder: shoulder)
            holdAnalyzer = analyzer
            holdFrame = frame
            if holdReference == nil, let ref = analyzer.reference { holdReference = SIMD3<Float>(ref) }
            if frame.armDropped {
                log("arm_drop", [.armDrops: String(analyzer.armDropCount)])
                voice.speak("Lift your arm!")
            }
            logMotion(t, hand: hand, shoulder: shoulder, frame: frame)
        default:
            break
        }
    }

    private func handleCurl(_ event: CurlEvent, at t: TimeInterval) {
        guard case .curls(let setIndex, let arm) = phase else { return }
        switch event {
        case .partial(_, let peak):
            updateRecord(setIndex, arm) { $0.partialReps += 1 }
            log("partial_rep", [.peakProgress: CSV.number(peak)])
            showTip("Go all the way up!", now: clock())
        case .rep(let rep):
            let set = settings.config(forSet: setIndex)
            let tempo = TempoScore.evaluate(up: rep.upDuration, down: rep.downDuration,
                                            targetUp: settings.tempoUp, targetDown: settings.tempoDown,
                                            tolerance: set.tempoTolerance)
            lastTempo = tempo
            var reps = 0
            updateRecord(setIndex, arm) { record in
                record.reps += 1
                record.tempoScores.append(tempo.score)
                record.upDurations.append(rep.upDuration)
                record.downDurations.append(rep.downDuration)
                if tempo.onTempo { record.onTempoReps += 1 }
                reps = record.reps
            }
            log("rep", [.repIndex: String(reps), .upS: CSV.number(rep.upDuration), .downS: CSV.number(rep.downDuration),
                        .tempoScore: CSV.number(tempo.score), .onTempo: CSV.bool(tempo.onTempo),
                        .peakProgress: CSV.number(rep.peakProgress)])
            repFeedbackCount += 1
            showTip(tempo.coachTip ?? "Good rep!", now: clock())
            let transitions = session.recordRep()
            if transitions.isEmpty { presentNBackStimulus(at: clock()) }
            apply(transitions)
        }
    }

    private func markTrackingLost(at t: TimeInterval) {
        trackingLostSince = t
        isHandTracked = false
        summary.trackingLossCount += 1
        log("tracking_lost")
        curlDetector.reset()
        holdAnalyzer?.markGap()
    }

    // MARK: Phases

    private func apply(_ transitions: [PhaseTransition]) {
        let now = clock()
        for transition in transitions {
            if let from = transition.from { exit(from, cause: transition.cause, at: now) }
            if let to = transition.to {
                enter(to, at: now)
            } else if session.status == .completed {
                finish(status: .completed, reason: "")
            }
        }
        if !transitions.isEmpty { persistSummary() }
    }

    private func enter(_ phase: Phase, at now: TimeInterval) {
        let setIndex = phase.setIndex
        if let arm = phase.arm {
            if arm != activeArm {
                log("arm_switch", [.arm: arm.rawValue])
            }
            activeArm = arm
            input.setActiveArm(arm)
            curlDetector.reset()
            updateRecord(setIndex, arm) { if $0.status == .notStarted { $0.status = .partial } }
        }
        log("phase_start", [.detail: durationDetail(phase)])
        coachTip = nil
        holdFrame = nil
        input.setMotionHint(motionHint(for: phase))
        let set = settings.config(forSet: setIndex)

        switch phase {
        case .prepare(1, .curls, .right):
            voice.speak("Let's go. Right arm. Lift slowly up, and slowly down.")
        case .prepare(_, .curls, .left):
            voice.speak("Switch. Put the phone in your left hand.")
        case .prepare(_, .curls, _):
            voice.speak("Round \(setIndex). Phone in your right hand.")
        case .prepare(_, .hold, _):
            voice.speak("Get ready to hold your arm out.")
        case .curls:
            curlDetector.reset()
            lastTempo = nil
            if isColourGameActive {
                nBack = NBackTask(length: set.curlReps, n: settings.nBackLevel,
                                  matchRate: settings.nBackMatchRate, rng: &rng)
                log("nback_sequence", [.detail: nBack!.sequence.map(\.rawValue).joined(separator: " "),
                                       .choices: nBack!.matchFlags.map { $0 ? "1" : "0" }.joined()])
                presentNBackStimulus(at: now)
            } else {
                plateColor = nil
                voice.speak("Up, and down.")
            }
        case .hold:
            holdAnalyzer = HoldAnalyzer(set: set, settings: settings)
            holdReference = nil
            if isCognitiveActive {
                let start = Int.random(in: settings.subtractionStartRange, using: &rng)
                subtraction = SerialSubtractionTask(startValue: start, step: settings.subtractionStep,
                                                    choiceCount: settings.subtractionChoiceCount,
                                                    timeLimit: settings.subtractionTimeLimit)
                voice.speak("Hold your arm out. Start at \(start). Take away \(settings.subtractionStep).")
                presentSubtraction(at: now)
            } else {
                voice.speak("Hold your arm out.")
            }
        case .rating:
            plateColor = nil
            draftRating = NASATLXRating()
            voice.speak("All done! How did it feel?")
        case .rest:
            plateColor = nil
            voice.speak("Rest.")
        }
    }

    private func exit(_ phase: Phase, cause: String, at now: TimeInterval) {
        // When the session time runs out mid-trial, that trial's window was cut short: not scored.
        finalizePhaseData(phase, at: now, interrupted: cause == "time_up")
        if case .curls(let round, let arm) = phase {
            updateRecord(round, arm) { $0.curlTimeLimitReached = cause == "time_limit" }
        }
        log("phase_end", [.reason: cause], phase: phase)
        // An arm's part of a round is complete once its hold (or, without a hold, its curls) ran to the end.
        let blockDone: Bool = switch phase {
        case .hold: cause == "timer"
        case .curls(let round, _): settings.config(forSet: round).holdDuration == 0 && cause != "time_up"
        default: false
        }
        if blockDone, let arm = phase.arm { updateRecord(phase.setIndex, arm) { $0.status = .completed } }
    }

    /// Edits the record of `round` for `arm`, creating it when that part of the round starts.
    private func updateRecord(_ round: Int, _ arm: DumbbellHand, _ change: (inout SetRecord) -> Void) {
        guard round >= 1 else { return }
        if let i = summary.sets.lastIndex(where: { $0.index == round && $0.arm == arm }) {
            change(&summary.sets[i])
        } else {
            var record = SetRecord(index: round, config: settings.config(forSet: round), arm: arm)
            change(&record)
            summary.sets.append(record)
        }
    }

    /// Closes the open cognitive trials and stores hold measurements for `phase`.
    private func finalizePhaseData(_ phase: Phase, at now: TimeInterval, interrupted: Bool) {
        switch phase {
        case .curls(let setIndex, let arm):
            if var task = nBack {
                if let closed = task.closeCurrent(interrupted: interrupted) { logNBackTrial(closed, phase: phase) }
                updateRecord(setIndex, arm) { $0.nBack = task.results }
            }
            nBack = nil
        case .hold(let setIndex, let arm):
            if var task = subtraction {
                if let r = task.interrupt() { logSubtraction(r, phase: phase) }
                updateRecord(setIndex, arm) { $0.subtraction = task.results }
            }
            subtraction = nil
            subtractionProblem = nil
            if let analyzer = holdAnalyzer {
                let s = analyzer.summary()
                updateRecord(setIndex, arm) { $0.hold = s }
                log("hold_summary", [.tremorRmsMm: CSV.number(s.tremorRMSmm, decimals: 2),
                                     .verticalDriftMm: CSV.number(s.verticalDriftMm, decimals: 1),
                                     .totalDriftMm: CSV.number(s.totalDriftMm, decimals: 1),
                                     .timeInZoneFrac: CSV.number(s.timeInZoneFraction),
                                     .steadyFrac: CSV.number(s.steadyFraction),
                                     .armDrops: String(s.armDropCount),
                                     .detail: "tracked_s=\(CSV.number(s.trackedDuration)) samples=\(s.sampleCount)"],
                    phase: phase)
            }
            holdAnalyzer = nil
            holdFrame = nil
            holdReference = nil
        default:
            break
        }
    }

    private func finish(status: CompletionStatus, reason: String) {
        tickTask?.cancel()
        tickTask = nil
        inputTask?.cancel()
        inputTask = nil
        input.stop()
        voice.stop()
        if status == .completed { voice.speak("Great job!") }
        summary.status = status
        summary.stopReason = reason
        summary.endedAt = Date()
        summary.activeTime = session.activeTime
        log("session_end", [.status: status.rawValue, .reason: reason])
        persistSummary()
        recorder?.close()
    }

    private func interruptTasks(at now: TimeInterval) {
        if var task = nBack, let closed = task.closeCurrent(interrupted: true) {
            nBack = task
            logNBackTrial(closed, phase: phase)
        }
        if var task = subtraction, let r = task.interrupt() {
            subtraction = task
            subtractionProblem = nil
            logSubtraction(r)
        }
        curlDetector.reset()
        holdAnalyzer?.markGap()
    }

    private func motionHint(for phase: Phase) -> MotionHint {
        switch phase {
        case .curls: .curls(up: settings.tempoUp, down: settings.tempoDown)
        case .hold, .prepare(_, .hold, _): .hold
        default: .idle
        }
    }

    // MARK: Cognitive tasks

    private func presentNBackStimulus(at now: TimeInterval) {
        guard var task = nBack else { return }
        let (closed, next) = task.presentNext(at: now)
        nBack = task
        if let closed { logNBackTrial(closed, phase: phase) }
        guard let next else { return }
        plateColor = next
        log("nback_stimulus", [.trialIndex: String(task.currentIndex), .color: next.rawValue,
                               .isMatch: CSV.bool(task.matchFlags[task.currentIndex])])
        voice.speak(next.displayName)
    }

    private func presentSubtraction(at now: TimeInterval) {
        guard var task = subtraction else { return }
        let p = task.present(at: now, rng: &rng)
        subtraction = task
        subtractionProblem = p
        log("subtraction_prompt", [.problemIndex: String(p.index), .previousValue: String(p.previousValue),
                                   .correctAnswer: String(p.correctAnswer),
                                   .choices: p.choices.map(String.init).joined(separator: " ")])
    }

    /// The value shown to the participant for the open problem: the start number first,
    /// afterwards only the instruction, so the running total is held in working memory.
    var subtractionPromptText: String? {
        guard let p = subtractionProblem else { return nil }
        return p.index == 0
            ? "\(p.previousValue) − \(settings.subtractionStep) = ?"
            : "Take away \(settings.subtractionStep) again"
    }

    // MARK: Logging

    private func logNBackTrial(_ r: NBackTrialResult, phase: Phase?) {
        log("nback_trial", [.trialIndex: String(r.index), .color: r.color.rawValue, .isMatch: CSV.bool(r.isMatch),
                            .responded: CSV.bool(r.responded),
                            .rtMs: CSV.number(r.reactionTime.map { $0 * 1000 }, decimals: 0),
                            .outcome: r.outcome.rawValue], phase: phase)
    }

    private func logSubtraction(_ r: SubtractionResult, phase: Phase? = nil) {
        log("subtraction_response", [.problemIndex: String(r.problem.index),
                                     .previousValue: String(r.problem.previousValue),
                                     .correctAnswer: String(r.problem.correctAnswer),
                                     .chosenAnswer: r.chosen.map(String.init) ?? "",
                                     .rtMs: CSV.number(r.reactionTime.map { $0 * 1000 }, decimals: 0),
                                     .outcome: r.outcome.rawValue], phase: phase ?? self.phase)
    }

    private func logMotion(_ t: TimeInterval, hand: SIMD3<Float>, shoulder: SIMD3<Float>, frame: HoldFrame?) {
        guard t - lastMotionLogTime >= Self.motionLogInterval else { return }
        lastMotionLogTime = t
        var fields: [EventField: String] = [
            .handX: CSV.number(Double(hand.x), decimals: 4), .handY: CSV.number(Double(hand.y), decimals: 4),
            .handZ: CSV.number(Double(hand.z), decimals: 4), .shoulderY: CSV.number(Double(shoulder.y), decimals: 4),
        ]
        if let frame {
            fields[.inZone] = CSV.bool(frame.inZone)
            fields[.steady] = CSV.bool(frame.steady)
            fields[.deviationMm] = CSV.number(frame.deviation.map { $0 * 1000 }, decimals: 1)
        } else {
            fields[.peakProgress] = CSV.number(curlDetector.currentProgress)
        }
        log("motion_sample", fields)
    }

    private func log(_ type: String, _ fields: [EventField: String] = [:], phase explicitPhase: Phase? = nil) {
        let now = clock()
        let p = explicitPhase ?? phase
        let round = p.flatMap { $0 == .rating ? nil : $0.setIndex }
        var fields = fields
        if fields[.arm] == nil, let arm = p?.arm { fields[.arm] = arm.rawValue }
        let event = LogEvent(wallClock: Date(), sessionTime: startTime.map { now - $0 } ?? 0,
                             activeTime: session.activeTime, type: type, phase: p?.logName ?? "",
                             setIndex: round, weightKg: round.map { settings.config(forSet: $0).virtualWeightKg },
                             fields: fields)
        recorder?.append(event)
        guard TimeLog.includes(type) else { return }
        let line = TimeLog.line(for: event)
        TimeLog.logger.info("\(line, privacy: .public)")
        timeLog.append(TimeLogEntry(timestamp: event.wallClock, sessionTime: event.sessionTime, type: type, line: line))
        if timeLog.count > TimeLog.maxEntries { timeLog.removeFirst(timeLog.count - TimeLog.maxEntries) }
    }

    private func persistSummary() {
        summary.activeTime = session.activeTime
        recorder?.writeSummary(summary)
    }

    private func showTip(_ text: String, now: TimeInterval) {
        coachTip = text
        coachTipExpiry = now + 2
    }

    private func durationDetail(_ phase: Phase) -> String {
        session.duration(of: phase).map { "duration_s=\(CSV.number($0, decimals: 1))" } ?? ""
    }
}
