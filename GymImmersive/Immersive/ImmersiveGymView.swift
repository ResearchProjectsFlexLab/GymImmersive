import RealityKit
import SwiftUI

/// Non-observable RealityKit objects owned by the immersive view.
@MainActor
final class GymSceneObjects {
    let dumbbell = DumbbellEntity()
    let audio = GymAudio()
    var holder = Entity()
    /// Hand anchors for both hands (device only); the dumbbell moves to the active arm's anchor.
    var handAnchors: [DumbbellHand: Entity] = [:]
    var dumbbellArm: DumbbellHand?
    let zoneMarker: ModelEntity = {
        var material = UnlitMaterial(color: UIColor(red: 0.3, green: 0.9, blue: 0.5, alpha: 1))
        material.blending = .transparent(opacity: 0.18)
        let e = ModelEntity(mesh: .generateSphere(radius: 1), materials: [material])
        e.isEnabled = false
        return e
    }()
    var coach: Entity?
    var panelsPlacedForHeadHeight: Float?
    var updateSubscription: EventSubscription?
    var appliedRepFeedback = 0

    func tearDown() {
        updateSubscription?.cancel()
        updateSubscription = nil
        audio.stopAll()
    }
}

/// The full immersive gym. Hosts the environment, the dumbbell, the coach (which also holds the
/// Pause/Stop controls) and the wall timer board, and starts / ends the session together with
/// the immersive space.
struct ImmersiveGymView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var scene = GymSceneObjects()

    var body: some View {
        if let controller = appModel.controller {
            content(controller)
        }
    }

    private func content(_ controller: SessionController) -> some View {
        RealityView { content, attachments in
            let gym = await GymEnvironment.make()
            content.add(gym)

            let holder: Entity
            if controller.drivesDumbbellFromSamples {
                holder = Entity()
                holder.isEnabled = false
                holder.addChild(scene.dumbbell.root)
            } else {
                for arm in DumbbellHand.allCases {
                    let anchor = AnchorEntity(.hand(arm == .right ? .right : .left, location: .palm), trackingMode: .predicted)
                    scene.handAnchors[arm] = anchor
                    content.add(anchor)
                }
                holder = scene.handAnchors[controller.activeArm]!
                scene.dumbbell.root.position = DumbbellEntity.palmOffset
                scene.dumbbell.root.orientation = DumbbellEntity.palmRotation
                holder.addChild(scene.dumbbell.root)
                scene.dumbbellArm = controller.activeArm
            }
            scene.holder = holder
            if holder.parent == nil { content.add(holder) }
            content.add(scene.zoneMarker)

            if let coach = attachments.entity(for: "coach") {
                scene.coach = coach
                content.add(coach)
            }
            if let log = attachments.entity(for: "log") {
                // To the right of the coach, turned slightly toward the participant.
                log.position = [0.8, 1.4, -1.25]
                log.orientation = simd_quatf(angle: -0.4, axis: [0, 1, 0])
                content.add(log)
            }
            if let board = attachments.entity(for: "board") {
                // Large LED-style timer on the front wall, above the dumbbell rack.
                board.position = [0, 2.6, -6.86]
                board.scale = SIMD3(repeating: 3.2)
                content.add(board)
            }
            placePanels(headHeight: 1.5)

            scene.updateSubscription = content.subscribe(to: SceneEvents.Update.self) { _ in
                MainActor.assumeIsolated { syncScene(with: controller) }
            }
            await scene.audio.install(in: gym, chimeSource: scene.dumbbell.root)
        } attachments: {
            Attachment(id: "coach") {
                CoachPanel(controller: controller)
            }
            Attachment(id: "log") {
                LiveTimeLogPanel(controller: controller)
            }
            Attachment(id: "board") {
                WallTimerBoard(controller: controller)
            }
        }
        .task {
            await controller.begin()
            #if DEBUG
            // Debug-only: `-skipIntro` presses Start automatically (for Simulator checks).
            if CommandLine.arguments.contains("-skipIntro") { controller.startWorkout() }
            #endif
        }
        .onChange(of: controller.status.isFinished, initial: true) { _, finished in
            guard finished else { return }
            Task {
                // Let the participant read the final message, then leave the gym.
                try? await Task.sleep(for: .seconds(controller.status == .completed ? 4 : 1.5))
                await dismissImmersiveSpace()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { controller.appBecameInactive() }
        }
        .onDisappear {
            controller.immersiveSpaceDidDisappear()
            scene.tearDown()
            appModel.immersiveState = .closed
            if let error = controller.errorMessage {
                appModel.alertMessage = error
            }
            openWindow(id: AppModel.startWindowID)
        }
    }

    /// Per-frame sync of entity state from the controller. Runs outside SwiftUI's update cycle so
    /// high-rate hand samples never re-render the panels.
    private func syncScene(with controller: SessionController) {
        let dumbbell = scene.dumbbell
        if let set = controller.currentSet { dumbbell.setWeight(set.virtualWeightKg) }
        // Move the dumbbell to the hand now holding the phone.
        if scene.dumbbellArm != controller.activeArm, let anchor = scene.handAnchors[controller.activeArm] {
            anchor.addChild(dumbbell.root, preservingWorldTransform: false)
            scene.holder = anchor
            scene.dumbbellArm = controller.activeArm
        }
        dumbbell.setPlateColor(controller.plateColor)

        if let sample = controller.lastSample {
            if controller.drivesDumbbellFromSamples {
                scene.holder.isEnabled = sample.dumbbellHand != nil
                if let hand = sample.dumbbellHand { scene.holder.position = hand }
            }
            let placed = scene.panelsPlacedForHeadHeight ?? -10
            if abs(placed - sample.head.y) > 0.2, mayRepositionPanels(controller) {
                placePanels(headHeight: sample.head.y)
            }
        }

        if let reference = controller.holdReference, let set = controller.currentSet {
            scene.zoneMarker.isEnabled = true
            scene.zoneMarker.position = reference
            scene.zoneMarker.scale = SIMD3(repeating: Float(set.steadinessRadius))
        } else {
            scene.zoneMarker.isEnabled = false
        }

        if controller.repFeedbackCount != scene.appliedRepFeedback {
            scene.appliedRepFeedback = controller.repFeedbackCount
            scene.audio.playRepChime(on: dumbbell.root)
        }
    }

    private func mayRepositionPanels(_ controller: SessionController) -> Bool {
        switch controller.phase {
        case nil: controller.status == .ready
        case .prepare(1, .curls, .right)?: true
        default: false
        }
    }

    /// Centres the coach (with its Pause/Stop row) just below eye level, 1.35 m ahead, so all of
    /// it is in view. It is only re-placed while getting ready, so it never moves mid-workout.
    private func placePanels(headHeight: Float) {
        scene.panelsPlacedForHeadHeight = headHeight
        scene.coach?.position = [0, headHeight - 0.08, -1.35]
    }
}
