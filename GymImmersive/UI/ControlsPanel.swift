import SwiftUI

/// The only controls in the gym: Pause/Resume and Stop. Shown inside the coach panel until the
/// session ends; before Start only Stop is shown.
struct ControlsPanel: View {
    var controller: SessionController

    var body: some View {
        HStack(spacing: 16) {
            if case .paused = controller.status {
                Button { controller.resume() } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .accessibilityHint("Continues the workout where it stopped")
            } else if controller.status != .ready {
                Button { controller.pause() } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .disabled(controller.status != .running)
                .accessibilityHint("Pauses the timer and tasks")
            }
            Button { controller.stop() } label: {
                Label("Stop", systemImage: "stop.fill")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityHint("Ends the session immediately")
        }
        .controlSize(.large)
    }
}
