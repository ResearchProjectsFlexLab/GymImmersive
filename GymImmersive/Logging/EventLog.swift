import Foundation

/// NASA-TLX raw scores, each 0–100 (Performance: 0 = perfect, 100 = failure).
struct NASATLXRating: Sendable, Equatable {
    var mental = 50.0, physical = 50.0, temporal = 50.0, performance = 50.0, effort = 50.0, frustration = 50.0

    var rawMean: Double { (mental + physical + temporal + performance + effort + frustration) / 6 }

    subscript(scale: TLXScale) -> Double {
        get {
            switch scale {
            case .mental: mental
            case .physical: physical
            case .temporal: temporal
            case .performance: performance
            case .effort: effort
            case .frustration: frustration
            }
        }
        set {
            let v = min(100, max(0, newValue))
            switch scale {
            case .mental: mental = v
            case .physical: physical = v
            case .temporal: temporal = v
            case .performance: performance = v
            case .effort: effort = v
            case .frustration: frustration = v
            }
        }
    }
}

enum TLXScale: String, CaseIterable, Identifiable, Sendable {
    case mental, physical, temporal, performance, effort, frustration
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mental: "Mental Demand"
        case .physical: "Physical Demand"
        case .temporal: "Temporal Demand"
        case .performance: "Performance"
        case .effort: "Effort"
        case .frustration: "Frustration"
        }
    }

    var question: String {
        switch self {
        case .mental: "How mentally demanding was the set?"
        case .physical: "How physically demanding was the set?"
        case .temporal: "How hurried or rushed was the pace?"
        case .performance: "How successful were you at what you were asked to do?"
        case .effort: "How hard did you have to work?"
        case .frustration: "How insecure, discouraged, irritated or stressed were you?"
        }
    }

    var anchors: (low: String, high: String) {
        self == .performance ? ("Perfect", "Failure") : ("Very low", "Very high")
    }
}

/// Columns of the events CSV after the fixed leading columns. Order here is the column order.
enum EventField: String, CaseIterable, Sendable {
    case repIndex = "rep_index", upS = "up_s", downS = "down_s", tempoScore = "tempo_score"
    case onTempo = "on_tempo", peakProgress = "peak_progress"
    case trialIndex = "trial_index", color, isMatch = "is_match", responded
    case responseSource = "response_source", rtMs = "rt_ms", outcome
    case problemIndex = "problem_index", previousValue = "previous_value"
    case correctAnswer = "correct_answer", chosenAnswer = "chosen_answer", choices
    case handX = "hand_x", handY = "hand_y", handZ = "hand_z"
    case shoulderY = "shoulder_y", inZone = "in_zone", steady, deviationMm = "deviation_mm"
    case tremorRmsMm = "tremor_rms_mm", verticalDriftMm = "vertical_drift_mm"
    case totalDriftMm = "total_drift_mm", timeInZoneFrac = "time_in_zone_frac"
    case steadyFrac = "steady_frac", armDrops = "arm_drops"
    case tlxMental = "tlx_mental", tlxPhysical = "tlx_physical", tlxTemporal = "tlx_temporal"
    case tlxPerformance = "tlx_performance", tlxEffort = "tlx_effort", tlxFrustration = "tlx_frustration"
    case tlxRawMean = "tlx_raw_mean"
    case reason, status, detail
}

struct LogEvent: Sendable {
    var wallClock: Date
    /// Seconds since session start on the monotonic clock (includes pauses).
    var sessionTime: TimeInterval
    /// Seconds of un-paused session time.
    var activeTime: TimeInterval
    var type: String
    var phase: String
    var setIndex: Int?
    var weightKg: Double?
    var fields: [EventField: String] = [:]
}

enum CSV {
    static let leadingEventColumns = ["session_id", "participant_id", "condition", "wall_clock_iso",
                                      "session_time_s", "active_time_s", "event", "phase", "set_index",
                                      "virtual_weight_kg"]

    static var eventHeader: String {
        line(leadingEventColumns + EventField.allCases.map(\.rawValue))
    }

    static func escape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func line(_ values: [String]) -> String { values.map(escape).joined(separator: ",") }

    /// Parses one CSV record (RFC 4180 quoting, no embedded newlines needed for our files).
    static func parseLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let n = iterator.next() {
                        if n == "\"" { current.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else { current.append(c) }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                fields.append(current); current = ""
            } else {
                current.append(c)
            }
        }
        fields.append(current)
        return fields
    }

    static func number(_ value: Double?, decimals: Int = 3) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.\(decimals)f", value)
    }

    static func bool(_ value: Bool?) -> String { value.map { $0 ? "1" : "0" } ?? "" }

    static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func eventRow(_ e: LogEvent, sessionID: String, info: SessionInfo) -> String {
        let leading = [sessionID, info.participantID, info.condition, iso(e.wallClock),
                       number(e.sessionTime), number(e.activeTime), e.type, e.phase,
                       e.setIndex.map(String.init) ?? "", number(e.weightKg, decimals: 1)]
        return line(leading + EventField.allCases.map { e.fields[$0] ?? "" })
    }
}
