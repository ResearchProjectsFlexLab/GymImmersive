import Foundation
import os

/// Local-time clock used for the human-readable time log, e.g. `2026-11-02 14:03:12.481`.
/// The events CSV keeps its ISO 8601 (UTC) `wall_clock_iso` column for analysis.
enum LogClock {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
}

/// One line of the time log.
struct TimeLogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let sessionTime: TimeInterval
    let type: String
    let line: String
}

/// Builds the readable lines written to `GymImmersive_<session>_timelog.txt` and to the Xcode console.
/// `motion_sample` events (10 Hz) are left out so the log stays readable; they remain in the events CSV.
enum TimeLog {
    static let maxEntries = 1000
    static let logger = Logger(subsystem: "GymImmersive", category: "TimeLog")

    static func includes(_ type: String) -> Bool { type != "motion_sample" }

    static func header(sessionID: String, startedAt: Date) -> String {
        "---------- session \(sessionID)  started \(LogClock.string(from: startedAt)) ----------"
    }

    static func line(for e: LogEvent) -> String {
        var parts = [LogClock.string(from: e.wallClock), "t=" + CSV.number(e.sessionTime) + "s"]
        let location = [e.setIndex.map { $0 == 0 ? "practice" : "set\($0)" }, e.phase.isEmpty ? nil : e.phase]
            .compactMap { $0 }.joined(separator: " ")
        if !location.isEmpty { parts.append("[\(location)]") }
        parts.append(e.type)
        let details = EventField.allCases.compactMap { field -> String? in
            guard let value = e.fields[field], !value.isEmpty else { return nil }
            return "\(field.rawValue)=\(value)"
        }
        if !details.isEmpty { parts.append(details.joined(separator: " ")) }
        return parts.joined(separator: "  ")
    }

    /// Plain-text export of a session's time log.
    static func text(sessionID: String, entries: [TimeLogEntry]) -> String {
        var lines = ["GymImmersive time log",
                     "Session: \(sessionID)",
                     "Generated: \(LogClock.string(from: entries.last?.timestamp ?? Date()))",
                     "Entries: \(entries.count)",
                     ""]
        lines.append(contentsOf: entries.map(\.line))
        return lines.joined(separator: "\n") + "\n"
    }
}
