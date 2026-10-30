import Foundation
import simd

/// One movement frame in world space (metres, y up). Timestamps use `MonotonicClock`.
struct MovementSample: Sendable, Equatable {
    var time: TimeInterval
    /// Grip position of the dumbbell hand; nil while that hand is not tracked.
    var dumbbellHand: SIMD3<Float>?
    /// Device (head) position.
    var head: SIMD3<Float>
    /// Horizontal unit vector the head is facing.
    var headForward: SIMD3<Float>
    /// Thumb-to-index distance of the free hand; nil while that hand is not tracked.
    var freeHandPinchDistance: Float?
}

/// What the session is asking the participant to do; the simulator uses it to fake motion.
enum MotionHint: Sendable, Equatable {
    case idle
    case curls(up: TimeInterval, down: TimeInterval)
    case hold
}

enum MovementInputError: Error, LocalizedError {
    case notSupported
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .notSupported: "Hand tracking is not supported on this device."
        case .notAuthorized: "Hand tracking permission was not granted. Enable it in Settings > Privacy & Security > Hand Tracking."
        }
    }
}

/// Source of movement data: real ARKit hand tracking, or a synthetic generator for the Simulator.
@MainActor
protocol MovementInputProvider: AnyObject {
    var name: String { get }
    /// True when the immersive view should place the dumbbell from samples instead of a hand anchor.
    var drivesDumbbellFromSamples: Bool { get }
    /// Starts producing samples. Throws if authorization is denied or tracking is unsupported.
    func start() async throws -> AsyncStream<MovementSample>
    func stop()
    func setMotionHint(_ hint: MotionHint)
}

enum MonotonicClock {
    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Estimates the shoulder of the dumbbell arm from the head pose.
enum BodyGeometry {
    static let shoulderDrop: Float = 0.25
    static let shoulderLateral: Float = 0.18

    static func shoulder(head: SIMD3<Float>, forward: SIMD3<Float>, hand: DumbbellHand) -> SIMD3<Float> {
        let f = normalizedHorizontal(forward)
        // Right-hand side of a y-up frame facing `f`.
        let right = SIMD3<Float>(-f.z, 0, f.x)
        let side: Float = hand == .right ? 1 : -1
        return head + SIMD3(0, -shoulderDrop, 0) + right * shoulderLateral * side
    }

    static func normalizedHorizontal(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let flat = SIMD3<Float>(v.x, 0, v.z)
        let len = simd_length(flat)
        return len > 1e-4 ? flat / len : SIMD3(0, 0, -1)
    }
}

/// Edge-triggered pinch detection with hysteresis, so one pinch is one response.
struct PinchDetector: Sendable {
    var closeThreshold: Float = 0.015
    var openThreshold: Float = 0.03
    private(set) var isPinching = false

    /// Returns true exactly once per pinch, at the moment it closes.
    mutating func update(distance: Float?) -> Bool {
        guard let distance else {
            isPinching = false
            return false
        }
        if !isPinching, distance < closeThreshold {
            isPinching = true
            return true
        }
        if isPinching, distance > openThreshold { isPinching = false }
        return false
    }
}
