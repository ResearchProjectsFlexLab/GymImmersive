import SwiftUI

/// The floating coach in front of the participant: instructions, timer, progress, the serial
/// subtraction answer choices during holds, and the NASA-TLX rating after each set.
struct CoachPanel: View {
    @Bindable var controller: SessionController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if case .rating = controller.phase, controller.status == .running {
                NASATLXView(rating: $controller.draftRating) { controller.submitRating() }
            } else {
                coach
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
                Label(controller.setTitle, systemImage: "dumbbell.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let countdown = controller.countdownText {
                    Text(countdown)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .accessibilityLabel("Time remaining \(countdown)")
                }
            }

            Text(controller.coachHeadline)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(controller.showArmUpCue ? Color.orange : Color.primary)
                .minimumScaleFactor(0.6)
                .lineLimit(2)
                .accessibilityAddTraits(.updatesFrequently)

            Text(controller.coachInstruction)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let tip = controller.coachTip {
                Text(tip)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .transition(.opacity)
            }

            if case .curls = controller.phase, controller.status == .running {
                TempoGuide(value: controller.tempoGuide, isUp: controller.isUpHalfOfTempo)
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
            .accessibilityLabel(controller.repText ?? "Phase progress")
            .accessibilityValue("\(Int(controller.session.phaseProgress * 100)) percent")
        }
    }
}

/// A slow bar that rises for 2 s and lowers for 2 s, showing the coached tempo.
private struct TempoGuide: View {
    var value: Double
    var isUp: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isUp ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title)
                .foregroundStyle(isUp ? .green : .blue)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(isUp ? Color.green : Color.blue)
                        .frame(width: max(12, geo.size.width * value))
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tempo guide")
        .accessibilityValue(isUp ? "Curl up" : "Lower down")
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
