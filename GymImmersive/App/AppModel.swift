import Foundation
import Observation

/// App-wide state: the active session (if any) and the immersive space state.
@MainActor
@Observable
final class AppModel {
    enum ImmersiveState: Equatable { case closed, opening, open }

    static let immersiveSpaceID = "GymSpace"
    static let startWindowID = "Start"

    var settings = WorkoutSettings()
    var immersiveState: ImmersiveState = .closed
    private(set) var controller: SessionController?
    var alertMessage: String?

    let directory: URL

    init(directory: URL = SessionArchive.documentsDirectory) {
        self.directory = directory
        SessionArchive.recoverInterruptedSessions(in: directory)
    }

    var canStart: Bool {
        immersiveState == .closed && (controller.map { $0.status.isFinished } ?? true)
    }

    /// Creates the session controller for a new run of `duration` seconds with the default
    /// protocol: cognitive task on, dumbbell in the right hand, spoken cues on. The immersive view
    /// starts it once open.
    func prepareSession(duration: TimeInterval) throws -> SessionController {
        let info = SessionInfo(participantID: "", condition: "", cognitiveTaskEnabled: true,
                               dumbbellHand: .right, seed: UInt64.random(in: 1...UInt64(UInt32.max)),
                               duration: duration)
        let input: MovementInputProvider
        #if DEBUG && targetEnvironment(simulator)
        // The Simulator has no hand tracking, so debug Simulator builds use synthetic movement.
        input = SimulatedInputProvider(dumbbellHand: info.dumbbellHand, seed: info.seed)
        #else
        input = HandTrackingInputProvider(dumbbellHand: info.dumbbellHand)
        #endif
        let controller = try SessionController(settings: settings, info: info, input: input,
                                               directory: directory, voice: CoachVoice())
        self.controller = controller
        return controller
    }
}
