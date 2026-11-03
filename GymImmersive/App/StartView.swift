import SwiftUI

/// The only window: one Start button that opens the immersive gym.
struct StartView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        @Bindable var appModel = appModel
        VStack(spacing: 28) {
            Image(systemName: "dumbbell.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("GymImmersive")
                .font(.extraLargeTitle)
            Button {
                Task { await start() }
            } label: {
                Text(appModel.immersiveState == .opening ? "Opening…" : "Start")
                    .font(.title)
                    .frame(minWidth: 240)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .disabled(!appModel.canStart)
            .accessibilityHint("Opens the immersive gym and starts the workout")
            Text("Stop right away if you feel pain or dizziness.")
                .font(.headline)
                .foregroundStyle(.secondary)
            if let controller = appModel.controller, controller.status.isFinished {
                TimeLogView(controller: controller)
            }
        }
        .padding(48)
        .alert("GymImmersive", isPresented: Binding(get: { appModel.alertMessage != nil },
                                                    set: { if !$0 { appModel.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appModel.alertMessage ?? "")
        }
    }

    private func start() async {
        guard appModel.canStart else { return }
        let controller: SessionController
        do {
            controller = try appModel.prepareSession()
        } catch {
            appModel.alertMessage = "Could not create the session files: \(error.localizedDescription)"
            return
        }
        appModel.immersiveState = .opening
        switch await openImmersiveSpace(id: AppModel.immersiveSpaceID) {
        case .opened:
            appModel.immersiveState = .open
            dismissWindow(id: AppModel.startWindowID)
        case .userCancelled, .error:
            fallthrough
        @unknown default:
            controller.stop(.immersiveSpaceOpenFailed)
            appModel.immersiveState = .closed
            appModel.alertMessage = "The immersive gym could not be opened."
        }
    }
}
