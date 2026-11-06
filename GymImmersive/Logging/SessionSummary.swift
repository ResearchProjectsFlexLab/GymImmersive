import Foundation

enum SetStatus: String, Sendable { case notStarted = "not_started", partial, completed }

/// Everything measured for one arm in one round (rounds are 1-based).
struct SetRecord: Sendable {
    var index: Int
    var config: SetConfig
    var arm: DumbbellHand = .right
    var status: SetStatus = .notStarted
    var reps = 0
    var partialReps = 0
    var onTempoReps = 0
    var tempoScores: [Double] = []
    var upDurations: [Double] = []
    var downDurations: [Double] = []
    var curlTimeLimitReached = false
    var hold: HoldSummary?
    var nBack: [NBackTrialResult] = []
    var subtraction: [SubtractionResult] = []

    var label: String { "round\(index)-\(arm.rawValue)" }
}

enum CompletionStatus: String, Sendable {
    case inProgress = "in_progress", completed, incomplete
}

/// Session-level summary; serialised as one CSV row per set.
struct SessionSummary: Sendable {
    var sessionID: String
    var info: SessionInfo
    var inputSource: String
    var startedAt: Date
    var endedAt: Date?
    var status: CompletionStatus = .inProgress
    var stopReason: String = ""
    var activeTime: TimeInterval = 0
    var pauseCount = 0
    var trackingLossCount = 0
    /// One record per arm per round that was started, in order.
    var sets: [SetRecord]
    /// The single workload rating given after the time is up.
    var tlx: NASATLXRating?

    static let columns = [
        "session_id", "participant_id", "condition", "cognitive_task", "dumbbell_hand", "seed",
        "input_source", "session_duration_s", "started_at", "ended_at", "completion_status", "stop_reason", "total_active_s",
        "pause_count", "tracking_loss_count",
        "set_index", "set_label", "arm", "virtual_weight_kg", "set_status", "reps_completed", "reps_target",
        "partial_reps", "on_tempo_reps", "mean_tempo_score", "mean_up_s", "mean_down_s",
        "tempo_tolerance_s", "curl_time_limit_reached",
        "hold_target_s", "hold_tracked_s", "hold_time_in_zone_frac", "hold_steady_frac", "hold_arm_drops",
        "hold_tremor_rms_mm", "hold_vertical_drift_mm", "hold_total_drift_mm", "steadiness_radius_m",
        "nback_hits", "nback_misses", "nback_false_alarms", "nback_correct_rejections",
        "nback_interrupted", "nback_accuracy", "nback_mean_hit_rt_ms",
        "sub_attempts", "sub_correct", "sub_incorrect", "sub_timeouts", "sub_accuracy",
        "sub_mean_correct_rt_ms",
        "tlx_mental", "tlx_physical", "tlx_temporal", "tlx_performance", "tlx_effort",
        "tlx_frustration", "tlx_raw_mean",
    ]

    /// One row per started round. A session that ended before any round started still gets one
    /// row (with empty round columns), so its status and rating are never lost.
    func csv() -> String {
        var lines = [CSV.line(Self.columns)]
        let rows = sets.isEmpty ? [SetRecord(index: 0, config: SetConfig(virtualWeightKg: 0, curlReps: 0, holdDuration: 0,
                                                                          tempoTolerance: 0, steadinessRadius: 0,
                                                                          armDropTolerance: 0))] : sets
        for set in rows { lines.append(CSV.line(row(for: set))) }
        return lines.joined(separator: "\n") + "\n"
    }

    private func row(for s: SetRecord) -> [String] {
        func mean(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        let n = NBackStats(s.nBack)
        let sub = SubtractionStats(s.subtraction)
        let started = s.status != .notStarted
        let session: [String] = [
            sessionID, info.participantID, info.condition, CSV.bool(info.cognitiveTaskEnabled),
            info.dumbbellHand.rawValue, String(info.seed), inputSource, CSV.number(info.duration, decimals: 0),
            CSV.iso(startedAt),
            endedAt.map(CSV.iso) ?? "", status.rawValue, stopReason, CSV.number(activeTime),
            String(pauseCount), String(trackingLossCount),
        ]
        let curls: [String] = [
            String(s.index), s.label, s.arm.rawValue, CSV.number(s.config.virtualWeightKg, decimals: 1), s.status.rawValue,
            started ? String(s.reps) : "", String(s.config.curlReps),
            started ? String(s.partialReps) : "", started ? String(s.onTempoReps) : "",
            CSV.number(mean(s.tempoScores)), CSV.number(mean(s.upDurations)), CSV.number(mean(s.downDurations)),
            CSV.number(s.config.tempoTolerance, decimals: 2), started ? CSV.bool(s.curlTimeLimitReached) : "",
        ]
        let h = s.hold
        let hold: [String] = [
            CSV.number(s.config.holdDuration, decimals: 0), CSV.number(h?.trackedDuration),
            CSV.number(h?.timeInZoneFraction), CSV.number(h?.steadyFraction),
            h.map { String($0.armDropCount) } ?? "", CSV.number(h?.tremorRMSmm, decimals: 2),
            CSV.number(h?.verticalDriftMm, decimals: 1), CSV.number(h?.totalDriftMm, decimals: 1),
            CSV.number(s.config.steadinessRadius, decimals: 3),
        ]
        let hasNBack = !s.nBack.isEmpty
        let nback: [String] = hasNBack ? [
            String(n.hits), String(n.misses), String(n.falseAlarms), String(n.correctRejections),
            String(n.interrupted), CSV.number(n.accuracy), CSV.number(n.meanHitRT.map { $0 * 1000 }, decimals: 0),
        ] : Array(repeating: "", count: 7)
        let hasSub = !s.subtraction.isEmpty
        let subtraction: [String] = hasSub ? [
            String(sub.attempts), String(sub.correct), String(sub.incorrect), String(sub.timeouts),
            CSV.number(sub.accuracy), CSV.number(sub.meanCorrectRT.map { $0 * 1000 }, decimals: 0),
        ] : Array(repeating: "", count: 6)
        let tlx: [String] = self.tlx.map { t in
            TLXScale.allCases.map { CSV.number(t[$0], decimals: 0) } + [CSV.number(t.rawMean, decimals: 1)]
        } ?? Array(repeating: "", count: 7)
        return session + curls + hold + nback + subtraction + tlx
    }
}
