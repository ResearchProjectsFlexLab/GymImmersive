import SwiftUI

/// The only window: pick a session length, and the immersive gym opens and the workout starts.
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
            Text(appModel.immersiveState == .opening ? "Opening the gym…" : "How long?")
                .font(.title2)
            HStack(spacing: 16) {
                ForEach(WorkoutSettings.durationOptions, id: \.self) { minutes in
                    Button {
                        Task { await start(minutes: minutes) }
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(minutes)").font(.system(size: 44, weight: .bold, design: .rounded))
                            Text("min").font(.headline)
                        }
                        .frame(width: 110, height: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 24))
                    .tint(.orange)
                    .accessibilityLabel("\(minutes) minute\(minutes == 1 ? "" : "s")")
                    .accessibilityHint("Starts a \(minutes) minute workout in the immersive gym")
                }
            }
            .disabled(!appModel.canStart)
            Text("If it hurts, stop.")
                .font(.headline)
                .foregroundStyle(.secondary)
            if let controller = appModel.controller, controller.status.isFinished {
                TimeLogView(controller: controller)
            }
        }
        .padding(48)
        #if DEBUG
        // Debug-only: `-autostartMinutes N` starts a session at launch (for Simulator checks).
        .task {
            let minutes = UserDefaults.standard.integer(forKey: "autostartMinutes")
            if minutes > 0, appModel.controller == nil { await start(minutes: minutes) }
        }
        #endif
        .alert("GymImmersive", isPresented: Binding(get: { appModel.alertMessage != nil },
                                                    set: { if !$0 { appModel.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appModel.alertMessage ?? "")
        }
    }

    private func start(minutes: Int) async {
        guard appModel.canStart else { return }
        let controller: SessionController
        do {
            controller = try appModel.prepareSession(duration: TimeInterval(minutes * 60))
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
