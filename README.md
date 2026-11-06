# GymImmersive

Native visionOS app (SwiftUI + RealityKit + ARKit) that replaces a real 10 kg dumbbell task with a
virtual gym workout that creates physical load (real curls and extended-arm holds, tracked by hand
tracking) and mental load (serial subtraction by 7s during the arm hold). The participant holds a
phone in the right hand as the dumbbell; the virtual dumbbell is drawn on top of it.

Open `GymImmersive.xcodeproj` in Xcode 27 or later and run the `GymImmersive` scheme on Apple Vision Pro
or on the visionOS Simulator. The deployment target is visionOS 26.0.

## Running

The app opens one small window that asks how long to work out: **1, 3, 5 or 10 min**. Tapping one
opens the immersive gym, where the coach shows these instructions and a **Start** button:

1. Hold the phone in your right hand like a dumbbell. Lift it up and down slowly, then hold your
   arm straight out for a few seconds.
2. Then switch the phone to your left hand and do the same.
3. While you hold, take away 7 from the number. Look at the answer and tap it.
4. If it hurts, tap Stop.

The session clock starts only when Start is pressed. Inside the gym the only controls are
**Pause/Resume** and **Stop**, at the bottom of the coach panel. When the time is up the
participant gives one quick rating, then the gym closes and the Start window comes back. Stop
closes it right away.

Every session uses the same defaults: the cognitive tasks are on, the dumbbell is in the right
hand, and the coach speaks. To change these, edit `AppModel.prepareSession(duration:)` or
`WorkoutSettings`.

- **Device:** pick a development team under Signing & Capabilities, then run. On first start the
  participant is asked for hand-tracking permission.
- **Simulator:** the Simulator has no hand tracking, so debug builds use `SimulatedInputProvider`
  automatically. It makes synthetic curls and holds. Release builds
  don't include the simulator code.
- **Tests:** run `xcodebuild test -project GymImmersive.xcodeproj -scheme GymImmersive -destination 'platform=visionOS Simulator,name=Apple Vision Pro'`.

## Protocol

All values are in `WorkoutSettings` ([WorkoutSettings.swift](GymImmersive/Session/WorkoutSettings.swift)).

The workout repeats **rounds** until the chosen time is up. Each round uses both arms:

1. **Right arm:** get ready (5 s) → 10 curls → get ready (5 s) → arm hold.
2. **Left arm:** "Switch to your left hand" (5 s) → 10 curls → get ready (5 s) → arm hold.
3. Rest (20 s).

Each arm's part of a round is recorded separately: one summary row per round per arm
(`round1-right`, `round1-left`, …), and every event has an `arm` column (`arm_switch` marks each change).
Rounds get heavier, then stay at the heaviest level:

| Round | Virtual weight | Curls (per arm) | Hold (per arm) | Tempo tolerance | Steadiness radius | Arm-drop tolerance |
|---|---|---|---|---|---|---|
| 1 | 5 kg | 10 | 10 s | ±0.8 s | 8 cm | 12 cm |
| 2 | 10 kg | 10 | 15 s | ±0.6 s | 6 cm | 10 cm |
| 3 and later | 15 kg | 10 | 20 s | ±0.4 s | 4 cm | 8 cm |

- Tempo is 2 s up and 2 s down.
- The session clock runs only while the workout is running, so pauses don't use up time. When it
  reaches zero, the current step stops wherever it is. A subtraction problem (or 2-back trial) cut
  off by the clock is logged as `interrupted` and not scored.
- After the time is up the participant fills in one NASA-TLX rating for the whole workout.
- A curl phase ends when the target reps are done, or after reps × 4 s × 2 at most. A round can't hang.
- If hand tracking is lost, the session keeps going. The loss is only logged (`tracking_lost` /
  `tracking_restored`, and `tracking_loss_count` in the summary).
- The wall board above the dumbbell rack shows the time left, the current round and the time of day.
  The coach panel also shows the time of day. Both use the local clock that the time log uses, so
  what's on screen lines up with the log.

## Data

Files are saved to the app's Documents folder. Because file sharing is on, you can get them
through the Files app or Finder (connect the headset, then open the GymImmersive files).

Each session writes three files:

- `GymImmersive_<yyyyMMdd-HHmmss>_events.csv`: one row per event. Rows are added and
  flushed one at a time.
- `GymImmersive_<yyyyMMdd-HHmmss>_summary.csv`: one row per round that was started (round1,
  round2, …), with session-level columns repeated on each row, including `session_duration_s` and
  the single NASA-TLX rating. A session that ended before any round started still gets one row. The
  file is rewritten atomically after every phase.
- `GymImmersive_<yyyyMMdd-HHmmss>_timelog.txt`: a readable time log. Every event (except the
  10 Hz `motion_sample` rows) is one line with the local time to the millisecond, the seconds since
  session start, the set and phase, the event and its values, for example
  `2026-11-02 14:03:12.481  t=12.300s  [round1 curls]  rep  rep_index=3 tempo_score=0.950`.
  Lines are added and flushed one at a time, and the same lines go to the Xcode console
  (subsystem `GymImmersive`, category `TimeLog`). During the workout a **Time log** panel next to
  the coach shows the newest lines. After a session the Start window shows the log with two
  buttons: **Save log** saves the complete log as a `.txt` file in a folder you choose, and
  **Share** sends the file with AirDrop, Mail, Files and so on.

`completion_status` takes one of three values:

- `completed`: only when the chosen time ran out and the rating was submitted.
- `incomplete`: the session was stopped early. `stop_reason` gives the cause: `user_stopped`,
  `immersive_space_dismissed`, `immersive_space_open_failed`, `hand_tracking_unavailable` or
  `app_terminated`.
- `in_progress`: only while a session is running. If the app is killed mid-session, the summary is
  changed to `incomplete` / `app_terminated` on the next launch, and a `session_recovered` row is
  added to the events file.

Event types: `session_created`, `instructions_shown`, `session_started` (when Start is pressed), `phase_start`, `phase_end`, `rep`, `partial_rep`,
`motion_sample` (10 Hz hand/shoulder positions during curls and holds), `arm_drop`, `hold_summary`,
`nback_sequence`, `nback_stimulus`, `nback_response`, `nback_extra_response`, `nback_trial`
(outcome hit / miss / false_alarm / correct_rejection / interrupted), `subtraction_prompt`,
`subtraction_response` (correct / incorrect / timeout / interrupted), `nasa_tlx`, `pause`, `resume`,
`tracking_lost`, `tracking_restored`, `input_failed`, `session_end`.

Measures:

- **Tempo score:** for each half of the curl, `1 − 0.5·|error| / tolerance`, clamped to 0–1, then the
  two halves are averaged. A half exactly at the tolerance limit scores 0.5. `on_tempo` means both
  halves are within tolerance.
- **Tremor:** RMS (mm) of the 3D hand position minus its centred 0.25 s moving average. Samples next
  to tracking gaps are left out.
- **Drift:** mean hand position over the last second minus the hold reference. The reference is the
  mean position during the first second in the zone.
- **Interrupted trials:** a trial cut off by a pause, a stop or the end of the session time is logged
  but not scored.

Data is stored only on the device and the app makes no network requests. No personal data is
saved; sessions are identified only by their start time.

## Code layout

| Folder | Contents |
|---|---|
| `App/` | App entry point, `AppModel`, Start window |
| `Session/` | `WorkoutSettings`, `WorkoutSession` (pure state machine), `SessionController` (single source of truth), coach voice |
| `Movement/` | Input protocol, ARKit hand tracking provider, simulated provider, `CurlDetector`, `HoldAnalyzer`, pinch detection |
| `Cognitive/` | `NBackTask`, `SerialSubtractionTask`, seeded RNG |
| `Logging/` | Event and summary CSV, `SessionRecorder`, `SessionArchive` (listing and crash recovery) |
| `Immersive/` | Procedural gym (lighting, shadows, equipment), dumbbell, synthesised spatial audio, immersive view |
| `UI/` | Coach panel (with Pause/Stop), wall timer board, NASA-TLX view, time log view |

## Known limitations

- **Shoulder position is estimated from the head pose:** 25 cm down and 18 cm to the side. Curl
  progress and the hold zone are measured against that estimate, so very tall or short participants,
  or unusual seating, may need changes to `curlBottomOffset`, `curlTopOffset` and the thresholds.
- **The dumbbell's pose in the palm needs checking on a device:** set it with
  `DumbbellEntity.palmOffset` and `palmRotation`.
- **Colour 2-back is off by default:** with the phone in the right hand, the colour task's
  free-hand pinch answer doesn't fit the study. Set `nBackDuringCurls = true` in `WorkoutSettings` to
  turn it back on; then a free-hand pinch also counts as a system tap on whatever the participant is
  looking at, including Pause or Stop.
- **Answers are tapped:** the count-down answers, like every button, use the headset's normal
  look-and-tap (thumb and finger together, either hand).
- **The mirror isn't a real reflection:** it is a polished metal surface that reflects the image-based
  lighting.
