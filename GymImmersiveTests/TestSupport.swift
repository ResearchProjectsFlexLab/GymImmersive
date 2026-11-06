import Foundation
import simd
@testable import GymImmersive

/// Manually advanced clock for deterministic controller tests.
@MainActor
final class FakeClock {
    var now: TimeInterval = 1000
}

/// Input provider that never produces samples on its own; tests call `handle(_:)` directly.
@MainActor
final class FakeInput: MovementInputProvider {
    let name = "fake"
    let drivesDumbbellFromSamples = true
    var failWith: Error?
    private(set) var hints: [MotionHint] = []
    private(set) var stopCount = 0
    private var continuation: AsyncStream<MovementSample>.Continuation?

    func start() async throws -> AsyncStream<MovementSample> {
        if let failWith { throw failWith }
        let (stream, continuation) = AsyncStream.makeStream(of: MovementSample.self)
        self.continuation = continuation
        return stream
    }

    func stop() {
        stopCount += 1
        continuation?.finish()
    }

    func setMotionHint(_ hint: MotionHint) { hints.append(hint) }

    private(set) var arms: [DumbbellHand] = []
    func setActiveArm(_ arm: DumbbellHand) { arms.append(arm) }
}

enum Synthetic {
    static let head = SIMD3<Float>(0, 1.55, 0)
    static let forward = SIMD3<Float>(0, 0, -1)
    static var shoulder: SIMD3<Float> { BodyGeometry.shoulder(head: head, forward: forward, hand: .right) }

    /// Hand height for curl progress p (0 bottom ... 1 top) matching default settings geometry.
    static func curlHand(progress p: Double) -> SIMD3<Float> {
        let s = WorkoutSettings()
        let y = s.curlBottomOffset + p * (s.curlTopOffset - s.curlBottomOffset)
        return shoulder + SIMD3(0.02, Float(y), -0.06 - 0.2 * Float(p))
    }

    /// Cosine-profile curl: progress over time for given up/down durations, with `rest` at the bottom.
    static func curlProgress(at t: Double, up: Double, down: Double, rest: Double,
                             low: Double = -0.05, high: Double = 1.05) -> Double {
        let cycle = up + down + rest
        let x = t.truncatingRemainder(dividingBy: cycle)
        let span = high - low
        if x < up { return low + span * (1 - cos(.pi * x / up)) / 2 }
        if x < up + down { return low + span * (1 + cos(.pi * (x - up) / down)) / 2 }
        return low
    }

    static func sample(_ t: TimeInterval, hand: SIMD3<Float>?, pinch: Float? = 0.06) -> MovementSample {
        MovementSample(time: t, dumbbellHand: hand, head: head, headForward: forward, freeHandPinchDistance: pinch)
    }

    static func holdHand(at t: Double, sagPerSecond: Double = 0, tremorAmplitude: Double = 0) -> SIMD3<Float> {
        let tremor = tremorAmplitude * sin(2 * .pi * 8 * t)
        return shoulder + SIMD3(0.04, Float(-0.01 - sagPerSecond * t + tremor), -0.58)
    }

    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GymImmersiveTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension SessionInfo {
    static func test(cognitive: Bool = true, id: String = "P01", duration: TimeInterval = 180) -> SessionInfo {
        SessionInfo(participantID: id, condition: "dual, task", cognitiveTaskEnabled: cognitive,
                    dumbbellHand: .right, seed: 12345, duration: duration)
    }
}
