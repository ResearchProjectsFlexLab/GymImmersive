import Foundation

/// Writes one session's files. Events are appended and flushed one line at a time, and the
/// summary is rewritten atomically after every phase, so an interruption at any point leaves
/// consistent files on disk. A summary still marked `in_progress` at next launch is converted to
/// `incomplete` by `SessionArchive.recoverInterruptedSessions`.
@MainActor
final class SessionRecorder {
    let sessionID: String
    let info: SessionInfo
    let eventsURL: URL
    let summaryURL: URL
    private var handle: FileHandle?
    private(set) var writeError: Error?

    init(directory: URL, info: SessionInfo, startedAt: Date) throws {
        self.info = info
        let stamp = Self.fileStamp(startedAt)
        // Sessions without a participant ID are named by start time only.
        let trimmed = info.participantID.trimmingCharacters(in: .whitespaces)
        sessionID = trimmed.isEmpty ? stamp : "\(Self.sanitize(trimmed))_\(stamp)"
        let base = "GymImmersive_\(sessionID)"
        eventsURL = directory.appendingPathComponent("\(base)_events.csv")
        summaryURL = directory.appendingPathComponent("\(base)_summary.csv")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: eventsURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try Data((CSV.eventHeader + "\n").utf8).write(to: eventsURL, options: .atomic)
        handle = try FileHandle(forWritingTo: eventsURL)
        try handle?.seekToEnd()
    }

    func append(_ event: LogEvent) {
        guard let handle else { return }
        let row = CSV.eventRow(event, sessionID: sessionID, info: info) + "\n"
        do {
            try handle.write(contentsOf: Data(row.utf8))
        } catch {
            writeError = error
        }
    }

    func writeSummary(_ summary: SessionSummary) {
        do {
            try Data(summary.csv().utf8).write(to: summaryURL, options: .atomic)
        } catch {
            writeError = error
        }
    }

    func close() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    static func sanitize(_ id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let cleaned = String(id.trimmingCharacters(in: .whitespaces).map { allowed.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "unknown" : String(cleaned.prefix(40))
    }

    static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}

struct SavedSession: Identifiable, Sendable, Equatable {
    var id: String { baseName }
    var baseName: String
    var eventsURL: URL
    var summaryURL: URL?
    var modified: Date
    var status: String
}

enum SessionArchive {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func list(in directory: URL) -> [SavedSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        return files.filter { $0.lastPathComponent.hasSuffix("_events.csv") }.map { events in
            let base = String(events.lastPathComponent.dropLast("_events.csv".count))
            let summary = directory.appendingPathComponent("\(base)_summary.csv")
            let hasSummary = fm.fileExists(atPath: summary.path)
            let date = (try? events.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return SavedSession(baseName: base, eventsURL: events, summaryURL: hasSummary ? summary : nil,
                                modified: date, status: hasSummary ? completionStatus(of: summary) ?? "unknown" : "incomplete")
        }.sorted { $0.modified > $1.modified }
    }

    static func completionStatus(of summaryURL: URL) -> String? {
        guard let text = try? String(contentsOf: summaryURL, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 2, let column = CSV.parseLine(lines[0]).firstIndex(of: "completion_status") else { return nil }
        let row = CSV.parseLine(lines[1])
        return row.indices.contains(column) ? row[column] : nil
    }

    /// Marks summaries left `in_progress` (app killed or crashed mid-session) as incomplete.
    /// Returns the number of sessions repaired. Never upgrades anything to completed.
    @discardableResult
    static func recoverInterruptedSessions(in directory: URL, now: Date = Date()) -> Int {
        var repaired = 0
        for session in list(in: directory) {
            guard let summaryURL = session.summaryURL,
                  let text = try? String(contentsOf: summaryURL, encoding: .utf8) else { continue }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let header = lines.first.map(CSV.parseLine),
                  let statusColumn = header.firstIndex(of: "completion_status"),
                  let reasonColumn = header.firstIndex(of: "stop_reason") else { continue }
            var changed = false
            for i in 1..<lines.count {
                var row = CSV.parseLine(lines[i])
                guard row.count == header.count, row[statusColumn] == CompletionStatus.inProgress.rawValue else { continue }
                row[statusColumn] = CompletionStatus.incomplete.rawValue
                row[reasonColumn] = StopReason.appTerminated.rawValue
                lines[i] = CSV.line(row)
                changed = true
            }
            guard changed else { continue }
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: summaryURL, options: .atomic)
            if let handle = try? FileHandle(forWritingTo: session.eventsURL) {
                _ = try? handle.seekToEnd()
                let sessionID = String(session.baseName.dropFirst("GymImmersive_".count))
                let note = CSV.line([sessionID, "", "", CSV.iso(now), "", "", "session_recovered", "", "", ""]
                                    + EventField.allCases.map { field in
                                        switch field {
                                        case .status: CompletionStatus.incomplete.rawValue
                                        case .reason: StopReason.appTerminated.rawValue
                                        default: ""
                                        }
                                    })
                try? handle.write(contentsOf: Data((note + "\n").utf8))
                try? handle.close()
            }
            repaired += 1
        }
        return repaired
    }
}
