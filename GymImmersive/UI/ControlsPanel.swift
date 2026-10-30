import SwiftUI

/// The only controls in the gym: Pause/Resume and Stop. Stop is shown until the session ends.
struct ControlsPanel: View {
    var controller: SessionController

    var body: some View {
        HStack(spacing: 16) {
            if case .paused = controller.status {
                Button { controller.resume() } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .accessibilityHint("Continues the workout where it stopped")
            } else {
                Button { controller.pause() } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .disabled(controller.status != .running)
                .accessibilityHint("Pauses the timer and tasks")
            }
            Button(role: .destructive) { controller.stop() } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityHint("Ends the session immediately")
        }
        .controlSize(.large)
        .padding(20)
        .glassBackgroundEffect()
        .opacity(controller.status.isFinished ? 0 : 1)
        .allowsHitTesting(!controller.status.isFinished)
    }
}
