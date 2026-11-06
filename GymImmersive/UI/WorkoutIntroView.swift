import SwiftUI

/// First thing the participant sees in the gym: three short instructions and a Start button.
/// The session clock does not run until Start is pressed.
struct WorkoutIntroView: View {
    var controller: SessionController

    private var minutes: Int { Int((controller.info.duration / 60).rounded()) }
    private var arm: String { controller.info.dumbbellHand.label.lowercased() }
    private var otherArm: String { controller.info.dumbbellHand.other.label.lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(minutes)-minute workout")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("How it works")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 12) {
                step("1.circle.fill", "Hold the phone in your \(arm) hand like a dumbbell. Lift it up and down slowly, then hold your arm straight out for a few seconds.")
                step("2.circle.fill", "Then switch the phone to your \(otherArm) hand and do the same.")
                if controller.info.cognitiveTaskEnabled {
                    step("3.circle.fill", "While you hold, take away \(controller.settings.subtractionStep) from the number. Look at the answer and tap it.")
                }
                step(controller.info.cognitiveTaskEnabled ? "4.circle.fill" : "3.circle.fill",
                     "If it hurts, tap Stop.")
            }

            Button {
                controller.startWorkout()
            } label: {
                Label(controller.isReadyToStart ? "Start" : "Getting ready…", systemImage: "play.fill")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(!controller.isReadyToStart)
            .accessibilityHint("Starts the workout and the timer")
        }
    }

    private func step(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(.orange)
        }
    }
}
