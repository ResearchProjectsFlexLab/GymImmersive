import Foundation
import Testing
@testable import GymImmersive

struct TimeLogLineTests {
    @Test func lineHasLocalTimestampSessionTimeAndFields() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 2
        parts.hour = 14; parts.minute = 3; parts.second = 12; parts.nanosecond = 481_000_000
        let date = Calendar.current.date(from: parts)!
        let event = LogEvent(wallClock: date, sessionTime: 12.3, activeTime: 12.3, type: "rep", phase: "curls",
                             setIndex: 1, weightKg: 5, fields: [.repIndex: "3", .tempoScore: "0.950"])
        let line = TimeLog.line(for: event)
        #expect(line == "2026-11-02 14:03:12.481  t=12.300s  [round1 curls]  rep  rep_index=3 tempo_score=0.950")
    }

    @Test func ratingPhaseAndNoPhase() {
        let date = Date(timeIntervalSince1970: 0)
        let rating = LogEvent(wallClock: date, sessionTime: 0, activeTime: 0, type: "phase_start", phase: "rating",
                              setIndex: nil, weightKg: nil)
        #expect(TimeLog.line(for: rating).contains("[rating]  phase_start"))
        let bare = LogEvent(wallClock: date, sessionTime: 0, activeTime: 0, type: "session_created", phase: "",
                            setIndex: nil, weightKg: nil)
        #expect(!TimeLog.line(for: bare).contains("["))
        #expect(TimeLog.line(for: bare).hasSuffix("t=0.000s  session_created"))
    }

    @Test func motionSamplesAreLeftOut() {
        #expect(!TimeLog.includes("motion_sample"))
        #expect(TimeLog.includes("rep"))
    }
}

@MainActor
struct TimeLogRecordingTests {
    @Test func recorderWritesTimeLogFileImmediately() throws {
        let dir = Synthetic.tempDirectory()
        let rec = try SessionRecorder(directory: dir, info: .test(), startedAt: Date())
        #expect(rec.timeLogURL.lastPathComponent.hasSuffix("_timelog.txt"))
        rec.append(LogEvent(wallClock: Date(), sessionTime: 0, activeTime: 0, type: "session_started", phase: "",
                            setIndex: nil, weightKg: nil))
        rec.append(LogEvent(wallClock: Date(), sessionTime: 0.1, activeTime: 0.1, type: "motion_sample", phase: "curls",
                            setIndex: 1, weightKg: 5))
        // Read without closing: simulates a crash right after logging.
        let lines = try String(contentsOf: rec.timeLogURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("---------- session P01_"))
        #expect(lines[1].hasSuffix("session_started"))
        rec.close()
    }

    @Test func controllerKeepsTimeLogForWholeSession() async throws {
        let dir = Synthetic.tempDirectory()
        let clock = FakeClock()
        let c = try SessionController(settings: WorkoutSettings(), info: .test(), input: FakeInput(), directory: dir,
                                      voice: SilentCoach(), clock: { clock.now })
        await c.begin()
        c.startWorkout()
        clock.now += 6
        c.tick()
        c.pause()
        clock.now += 2
        c.resume()
        c.stop()
        let types = c.timeLog.map(\.type)
        #expect(types.first == "session_created")
        #expect(types.contains("session_started") && types.contains("phase_start"))
        #expect(types.contains("pause") && types.contains("resume"))
        #expect(types.last == "session_end")
        #expect(zip(c.timeLog, c.timeLog.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp })

        let file = try String(contentsOf: c.timeLogURL!, encoding: .utf8)
        #expect(file.split(separator: "\n").count == c.timeLog.count + 1, "header plus one line per entry")
        #expect(file.contains("session_end  reason=user_stopped status=incomplete"))
        #expect(c.timeLogText.hasPrefix("GymImmersive time log\nSession: P01_"))
        #expect(c.timeLogText.contains("Entries: \(c.timeLog.count)"))
    }

    @Test func recoveryNotesTheTimeLog() async throws {
        let dir = Synthetic.tempDirectory()
        let clock = FakeClock()
        do {
            let c = try SessionController(settings: WorkoutSettings(), info: .test(), input: FakeInput(), directory: dir,
                                          voice: SilentCoach(), clock: { clock.now })
            await c.begin()
            c.startWorkout()
        }
        #expect(SessionArchive.recoverInterruptedSessions(in: dir) == 1)
        let url = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasSuffix("_timelog.txt") })
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("session_recovered  status=incomplete reason=app_terminated"))
    }
}
