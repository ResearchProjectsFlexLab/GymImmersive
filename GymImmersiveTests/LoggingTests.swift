import Foundation
import Testing
@testable import GymImmersive

struct CSVTests {
    @Test func escapingRoundTrips() {
        let values = ["plain", "a,b", "say \"hi\"", "", "line\nbreak", "ünïcode"]
        let line = CSV.line(values)
        #expect(line.hasPrefix("plain,\"a,b\",\"say \"\"hi\"\"\",,"))
        #expect(CSV.parseLine(CSV.line(values.filter { !$0.contains("\n") })) == values.filter { !$0.contains("\n") })
    }

    @Test func numbersAndBools() {
        #expect(CSV.number(1.23456) == "1.235")
        #expect(CSV.number(nil) == "")
        #expect(CSV.number(.nan) == "")
        #expect(CSV.number(2, decimals: 0) == "2")
        #expect(CSV.bool(true) == "1" && CSV.bool(false) == "0" && CSV.bool(nil) == "")
    }

    @Test func eventRowsMatchHeaderWidth() {
        let info = SessionInfo.test()
        let event = LogEvent(wallClock: Date(timeIntervalSince1970: 0), sessionTime: 1.5, activeTime: 1.0,
                             type: "rep", phase: "curls", setIndex: 2, weightKg: 10,
                             fields: [.repIndex: "3", .detail: "x, \"y\""])
        let row = CSV.parseLine(CSV.eventRow(event, sessionID: "S", info: info))
        let header = CSV.parseLine(CSV.eventHeader)
        #expect(row.count == header.count)
        let dict = Dictionary(uniqueKeysWithValues: zip(header, row))
        #expect(dict["event"] == "rep" && dict["rep_index"] == "3" && dict["virtual_weight_kg"] == "10.0")
        #expect(dict["condition"] == "dual, task")
        #expect(dict["detail"] == "x, \"y\"")
        #expect(dict["wall_clock_iso"]?.hasPrefix("1970-01-01T00:00:00") == true)
        #expect(Set(header).count == header.count, "column names are unique")
    }
}

struct SummaryTests {
    @Test func rowsMatchColumnsForEveryState() {
        let settings = WorkoutSettings()
        var sets = (0...3).map { SetRecord(index: $0, config: settings.config(forSet: $0)) }
        sets[0].status = .completed
        sets[0].reps = 5
        sets[0].tempoScores = [1, 0.5]
        sets[1].status = .partial
        sets[1].hold = HoldSummary(trackedDuration: 12, timeInZoneFraction: 0.9, steadyFraction: 0.8, armDropCount: 1,
                                   tremorRMSmm: 1.234, verticalDriftMm: -20, totalDriftMm: 22, sampleCount: 1000)
        sets[1].tlx = NASATLXRating()
        sets[1].nBack = [NBackTrialResult(index: 0, color: .red, isMatch: false, responded: false, reactionTime: nil,
                                          outcome: .correctRejection)]
        let summary = SessionSummary(sessionID: "P_1", info: .test(), inputSource: "fake",
                                     startedAt: Date(), status: .incomplete, stopReason: "user_stopped", sets: sets)
        let lines = summary.csv().split(separator: "\n").map(String.init)
        #expect(lines.count == 5)
        let header = CSV.parseLine(lines[0])
        #expect(header == SessionSummary.columns)
        let rows = lines.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(header, CSV.parseLine($0))) }
        for line in lines.dropFirst() { #expect(CSV.parseLine(line).count == header.count) }
        #expect(rows[0]["mean_tempo_score"] == "0.750")
        #expect(rows[1]["hold_tremor_rms_mm"] == "1.23")
        #expect(rows[1]["tlx_raw_mean"] == "50.0")
        #expect(rows[1]["nback_correct_rejections"] == "1")
        #expect(rows[3]["set_status"] == "not_started")
        #expect(rows.allSatisfy { $0["completion_status"] == "incomplete" })
    }
}

@MainActor
struct RecorderTests {
    @Test func filesNamedByParticipantAndTimestamp() throws {
        let dir = Synthetic.tempDirectory()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let rec = try SessionRecorder(directory: dir, info: .test(id: "P 07/x"), startedAt: date)
        #expect(rec.eventsURL.lastPathComponent.hasPrefix("GymImmersive_P_07_x_"))
        #expect(rec.eventsURL.lastPathComponent.hasSuffix("_events.csv"))
        #expect(rec.summaryURL.lastPathComponent.hasSuffix("_summary.csv"))
        // A second session with the same ID and second must not overwrite the first.
        #expect(throws: (any Error).self) { try SessionRecorder(directory: dir, info: .test(id: "P 07/x"), startedAt: date) }
        rec.close()
    }

    @Test func sessionsWithoutParticipantAreNamedByTime() throws {
        let dir = Synthetic.tempDirectory()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let rec = try SessionRecorder(directory: dir, info: .test(id: ""), startedAt: date)
        let stamp = SessionRecorder.fileStamp(date)
        #expect(rec.sessionID == stamp)
        #expect(rec.eventsURL.lastPathComponent == "GymImmersive_\(stamp)_events.csv")
        rec.close()
    }

    @Test func eventsAreOnDiskImmediately() throws {
        let dir = Synthetic.tempDirectory()
        let rec = try SessionRecorder(directory: dir, info: .test(), startedAt: Date())
        rec.append(LogEvent(wallClock: Date(), sessionTime: 0, activeTime: 0, type: "a", phase: "", setIndex: nil, weightKg: nil))
        rec.append(LogEvent(wallClock: Date(), sessionTime: 1, activeTime: 1, type: "b", phase: "", setIndex: nil, weightKg: nil))
        // Read without closing: simulates a crash right after logging.
        let lines = try String(contentsOf: rec.eventsURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(rec.writeError == nil)
        rec.close()
        rec.append(LogEvent(wallClock: Date(), sessionTime: 2, activeTime: 2, type: "c", phase: "", setIndex: nil, weightKg: nil))
        #expect(try String(contentsOf: rec.eventsURL, encoding: .utf8).split(separator: "\n").count == 3)
    }

    @Test func interruptedSessionIsRecoveredAsIncomplete() async throws {
        let dir = Synthetic.tempDirectory()
        let clock = FakeClock()
        let input = FakeInput()
        // Simulate an app kill: the controller is abandoned mid-session, never stopped.
        do {
            let c = try SessionController(settings: WorkoutSettings(), info: .test(), input: input, directory: dir,
                                          voice: SilentCoach(), clock: { clock.now })
            await c.begin()
            clock.now += 6
            c.tick()
            #expect(SessionArchive.completionStatus(of: c.summaryURL!) == "in_progress")
        }
        let listed = SessionArchive.list(in: dir)
        #expect(listed.count == 1)
        #expect(listed[0].status == "in_progress")
        #expect(SessionArchive.recoverInterruptedSessions(in: dir) == 1)
        let after = SessionArchive.list(in: dir)[0]
        #expect(after.status == "incomplete")
        let summary = try String(contentsOf: after.summaryURL!, encoding: .utf8)
        #expect(summary.contains("app_terminated"))
        #expect(!summary.contains("in_progress"))
        #expect(!summary.contains(",completed,"))
        let events = try String(contentsOf: after.eventsURL, encoding: .utf8)
        #expect(events.contains("session_recovered"))
        #expect(SessionArchive.recoverInterruptedSessions(in: dir) == 0, "recovery is idempotent")
    }

    @Test func completedSessionsAreNotTouchedByRecovery() async throws {
        let dir = Synthetic.tempDirectory()
        var summary = SessionSummary(sessionID: "X", info: .test(), inputSource: "fake", startedAt: Date(),
                                     sets: [SetRecord(index: 0, config: WorkoutSettings().practice)])
        summary.status = .completed
        let rec = try SessionRecorder(directory: dir, info: .test(), startedAt: Date())
        rec.writeSummary(summary)
        rec.close()
        #expect(SessionArchive.recoverInterruptedSessions(in: dir) == 0)
        #expect(SessionArchive.list(in: dir)[0].status == "completed")
    }
}
