import ARKit
import QuartzCore
import simd

/// Real input: ARKit hand tracking for both hands plus the device pose for shoulder estimation.
/// The visible dumbbell is attached to a RealityKit hand anchor (rendered with the system's
/// own hand prediction, so there is no added lag); this provider only feeds the analysis.
@MainActor
final class HandTrackingInputProvider: MovementInputProvider {
    let name = "hand_tracking"
    let drivesDumbbellFromSamples = false
    private let dumbbellHand: DumbbellHand
    private var session: ARKitSession?
    private var task: Task<Void, Never>?

    init(dumbbellHand: DumbbellHand) {
        self.dumbbellHand = dumbbellHand
    }

    func start() async throws -> AsyncStream<MovementSample> {
        guard HandTrackingProvider.isSupported, WorldTrackingProvider.isSupported else {
            throw MovementInputError.notSupported
        }
        let session = ARKitSession()
        let authorization = await session.requestAuthorization(for: [.handTracking])
        guard authorization[.handTracking] == .allowed else { throw MovementInputError.notAuthorized }
        let hands = HandTrackingProvider()
        let world = WorldTrackingProvider()
        try await session.run([hands, world])
        self.session = session

        let (stream, continuation) = AsyncStream.makeStream(of: MovementSample.self,
                                                            bufferingPolicy: .bufferingNewest(16))
        let side = dumbbellHand
        task = Task.detached {
            var head: (position: SIMD3<Float>, forward: SIMD3<Float>)?
            var grip: SIMD3<Float>?
            var gripTime: TimeInterval = 0
            var pinchDistance: Float?
            for await update in hands.anchorUpdates {
                if Task.isCancelled { break }
                let anchor = update.anchor
                let now = MonotonicClock.now()
                let isDumbbellHand = (anchor.chirality == .right) == (side == .right)
                if isDumbbellHand {
                    grip = HandMath.gripPosition(anchor)
                    gripTime = now
                } else {
                    pinchDistance = HandMath.pinchDistance(anchor)
                    // Free-hand updates only emit while the dumbbell hand is silent, to avoid duplicates.
                    guard now - gripTime > 0.1 else { continue }
                    grip = nil
                }
                if let device = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), device.isTracked {
                    let m = device.originFromAnchorTransform
                    head = (SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z),
                            BodyGeometry.normalizedHorizontal(-SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
                }
                guard let head else { continue }
                continuation.yield(MovementSample(time: now, dumbbellHand: grip, head: head.position,
                                                  headForward: head.forward, freeHandPinchDistance: pinchDistance))
            }
            continuation.finish()
        }
        return stream
    }

    func stop() {
        task?.cancel()
        task = nil
        session?.stop()
        session = nil
    }

    func setMotionHint(_ hint: MotionHint) {}
}

private enum HandMath {
    static func world(_ anchor: HandAnchor, _ joint: HandSkeleton.JointName) -> SIMD3<Float>? {
        guard let j = anchor.handSkeleton?.joint(joint), j.isTracked else { return nil }
        let m = anchor.originFromAnchorTransform * j.anchorFromJointTransform
        return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// Palm centre: midpoint of wrist and middle-finger knuckle.
    static func gripPosition(_ anchor: HandAnchor) -> SIMD3<Float>? {
        guard anchor.isTracked, let wrist = world(anchor, .wrist),
              let knuckle = world(anchor, .middleFingerKnuckle) else { return nil }
        return (wrist + knuckle) / 2
    }

    static func pinchDistance(_ anchor: HandAnchor) -> Float? {
        guard anchor.isTracked, let thumb = world(anchor, .thumbTip),
              let index = world(anchor, .indexFingerTip) else { return nil }
        return simd_distance(thumb, index)
    }
}
