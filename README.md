# GymImmersive

Native visionOS app (SwiftUI + RealityKit + ARKit) that replaces a real 10 kg dumbbell task with a
virtual gym workout that creates physical load (real curls and extended-arm holds, tracked by hand
tracking) and mental load (2-back on plate colours, serial subtraction by 7s).

Open `GymImmersive.xcodeproj` in Xcode 27 or later and run the `GymImmersive` scheme on Apple Vision Pro
or on the visionOS Simulator. The deployment target is visionOS 26.0.

## Running

The app opens one small window with a **Start** button. Start opens the immersive gym and the
workout begins. Inside the gym the only controls are **Pause/Resume** and **Stop**. When the
workout ends, or you press Stop, the gym closes and the Start window comes back.

Every session uses the same defaults: the cognitive tasks are on, the dumbbell is in the right
hand, and the coach speaks. To change these, edit `AppModel.prepareSession()` or
`WorkoutSettings`.

- **Device:** pick a development team under Signing & Capabilities, then run. On first start the
  participant is asked for hand-tracking permission.
- **Simulator:** the Simulator has no hand tracking, so debug builds use `SimulatedInputProvider`
  automatically. It makes synthetic curls and holds and does no 2-back pinches. Release builds
  don't include the simulator code.
- **Tests:** run `xcodebuild test -project GymImmersive.xcodeproj -scheme GymImmersive -destination 'platform=visionOS Simulator,name=Apple Vision Pro'`.

## Protocol

All values are in `WorkoutSettings` ([WorkoutSettings.swift](GymImmersive/Session/WorkoutSettings.swift)).

| Set | Virtual weight | Curls | Hold | Tempo tolerance | Steadiness radius | Arm-drop tolerance |
|---|---|---|---|---|---|---|
| Practice | 2 kg | 5 | none | ±1.0 s | n/a | n/a |
| 1 | 5 kg | 10 | 30 s | ±0.8 s | 8 cm | 12 cm |
| 2 | 10 kg | 10 | 45 s | ±0.6 s | 6 cm | 10 cm |
| 3 | 15 kg | 10 | 60 s | ±0.4 s | 4 cm | 8 cm |

- Tempo is 2 s up and 2 s down.
- There is a 5 s get-ready phase before each curl and hold phase.
- Rest is 45 s between sets (20 s after practice).
- After each main set the participant fills in a NASA-TLX rating.
- A curl phase ends when the target reps are done, or after reps × 4 s × 2 at most. A set can't hang.
- If hand tracking is lost for more than 3 s during curls or a hold, the session pauses. The
  participant has to press Resume to continue.

## Data

Files are saved to the app's Documents folder. Because file sharing is on, you can get them
through the Files app or Finder (connect the headset, then open the GymImmersive files).

Each session writes three files:

- `GymImmersive_<yyyyMMdd-HHmmss>_events.csv`: one row per event. Rows are added and
  flushed one at a time.
- `GymImmersive_<yyyyMMdd-HHmmss>_summary.csv`: one row per set (practice, set1–set3),
  with session-level columns repeated on each row. The file is rewritten atomically after every phase.
- `GymImmersive_<yyyyMMdd-HHmmss>_timelog.txt`: a readable time log. Every event (except the
  10 Hz `motion_sample` rows) is one line with the local time to the millisecond, the seconds since
  session start, the set and phase, the event and its values, for example
  `2026-11-02 14:03:12.481  t=12.300s  [set1 curls]  rep  rep_index=3 tempo_score=0.950`.
  Lines are added and flushed one at a time, and the same lines go to the Xcode console
  (subsystem `GymImmersive`, category `TimeLog`). After a session the Start window shows the newest
  lines and a **Save** button that exports the log as a text file.

`completion_status` takes one of three values:

- `completed`: only when every phase finished.
- `incomplete`: the session was stopped early. `stop_reason` gives the cause: `user_stopped`,
  `immersive_space_dismissed`, `immersive_space_open_failed`, `hand_tracking_unavailable` or
  `app_terminated`.
- `in_progress`: only while a session is running. If the app is killed mid-session, the summary is
  changed to `incomplete` / `app_terminated` on the next launch, and a `session_recovered` row is
  added to the events file.

Event types: `session_created`, `session_started`, `phase_start`, `phase_end`, `rep`, `partial_rep`,
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
- **Interrupted trials:** a trial cut off by a pause or stop is logged but not scored.

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
| `Immersive/` | Procedural gym, dumbbell, synthesised spatial audio, immersive view |
| `UI/` | Coach panel, controls panel, NASA-TLX view |

## Known limitations

- **Shoulder position is estimated from the head pose:** 25 cm down and 18 cm to the side. Curl
  progress and the hold zone are measured against that estimate, so very tall or short participants,
  or unusual seating, may need changes to `curlBottomOffset`, `curlTopOffset` and the thresholds.
- **The dumbbell's pose in the palm needs checking on a device:** set it with
  `DumbbellEntity.palmOffset` and `palmRotation`.
- **Pinches can also tap a panel:** a free-hand pinch for the 2-back task also counts as a system
  tap on whatever the participant is looking at. The controls panel sits low and out of the main
  line of sight to lower that risk.
- **The mirror isn't a real reflection:** it is a polished metal surface that reflects the image-based
  lighting.
