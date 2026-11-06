import SwiftUI

/// The floating coach in front of the participant: session timer, instructions, progress, the
/// serial subtraction answer choices during holds, the final rating, and the Pause/Stop controls,
/// which live here so they are always in view.
struct CoachPanel: View {
    @Bindable var controller: SessionController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if controller.status == .ready {
                WorkoutIntroView(controller: controller)
            } else if case .rating = controller.phase, controller.status == .running {
                NASATLXView(rating: $controller.draftRating) { controller.submitRating() }
            } else {
                coach
            }
            if !controller.status.isFinished {
                Divider()
                ControlsPanel(controller: controller)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(32)
        .frame(width: 620)
        .glassBackgroundEffect()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: controller.phase)
    }

    private var coach: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(controller.setTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(controller.sessionCountdownText)
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                Text("left").font(.headline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            // Time of day and start time, in the same local clock as the time log.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 16) {
                    Label {
                        Text(context.date, format: .dateTime.hour().minute().second())
                    } icon: {
                        Image(systemName: "clock")
                    }
                    if let started = controller.workoutStartedAt {
                        Text("Started \(started.formatted(.dateTime.hour().minute().second()))")
                    }
                }
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Text(controller.coachHeadline)
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(controller.showArmUpCue ? Color.orange : Color.primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityAddTraits(.updatesFrequently)

            if !controller.coachInstruction.isEmpty {
                Text(controller.coachInstruction)
                    .font(.title2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .curls = controller.phase, controller.isColourGameActive, let color = controller.plateColor {
                ColorTag(color: color)
            }

            if let tip = controller.coachTip {
                Text(tip)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .transition(.opacity)
            }

            if case .hold = controller.phase, controller.status == .running,
               let prompt = controller.subtractionPromptText, let problem = controller.subtractionProblem {
                SubtractionChoices(prompt: prompt, problem: problem) { controller.answerSubtraction($0) }
            }

            ProgressView(value: controller.session.phaseProgress) {
                if let reps = controller.repText {
                    Text(reps).font(.headline.monospacedDigit())
                }
            }
            .tint(controller.showArmUpCue ? .orange : .green)
            .accessibilityLabel(controller.repText ?? "Progress")
            .accessibilityValue("\(Int(controller.session.phaseProgress * 100)) percent")
        }
    }
}

/// The current plate colour, shown as a large swatch with its name.
private struct ColorTag: View {
    var color: PlateColor

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: color.rgb.r, green: color.rgb.g, blue: color.rgb.b))
                .frame(width: 56, height: 40)
            Text(color.displayName)
                .font(.title.weight(.bold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour \(color.displayName)")
    }
}

private struct SubtractionChoices: View {
    var prompt: String
    var problem: SubtractionProblem
    var onChoose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt)
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                .accessibilityLabel(prompt.replacingOccurrences(of: "−", with: "minus"))
            HStack(spacing: 12) {
                ForEach(problem.choices, id: \.self) { choice in
                    Button { onChoose(choice) } label: {
                        Text("\(choice)")
                            .font(.title2.monospacedDigit().weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Answer \(choice)")
                }
            }
        }
        .id(problem.index)
    }
}
