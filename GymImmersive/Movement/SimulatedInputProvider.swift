#if DEBUG
import Foundation
import simd

/// Debug-only synthetic movement so the whole session can run in the visionOS Simulator.
/// It performs curls at roughly the coached tempo (with natural variation and the occasional
/// partial rep) and holds with tremor, slow sag and an occasional arm drop.
@MainActor
final class SimulatedInputProvider: MovementInputProvider {
    let name = "simulated"
    let drivesDumbbellFromSamples = true
    private var dumbbellHand: DumbbellHand
    private var hint: MotionHint = .idle
    private var hintStart: TimeInterval = 0
    private var rng: SeededRandom
    private var task: Task<Void, Never>?
    private var repDurations: (up: Double, down: Double, peak: Double) = (2, 2, 1)
    private var repStart: TimeInterval = 0

    let head = SIMD3<Float>(0, 1.55, 0)
    let forward = SIMD3<Float>(0, 0, -1)

    init(dumbbellHand: DumbbellHand, seed: UInt64 = 7) {
        self.dumbbellHand = dumbbellHand
        rng = SeededRandom(seed: seed)
    }

    func start() async throws -> AsyncStream<MovementSample> {
        let (stream, continuation) = AsyncStream.makeStream(of: MovementSample.self,
                                                            bufferingPolicy: .bufferingNewest(16))
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self else { break }
                continuation.yield(self.sample(at: MonotonicClock.now()))
            }
            continuation.finish()
        }
        return stream
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func setActiveArm(_ arm: DumbbellHand) {
        dumbbellHand = arm
    }

    func setMotionHint(_ hint: MotionHint) {
        guard hint != self.hint else { return }
        self.hint = hint
        hintStart = MonotonicClock.now()
        repStart = hintStart + 0.8
        nextRep()
    }

    private func nextRep() {
        guard case .curls(let up, let down) = hint else { return }
        let partial = Double.random(in: 0...1, using: &rng) < 0.06
        repDurations = (up * Double.random(in: 0.8...1.2, using: &rng),
                        down * Double.random(in: 0.8...1.2, using: &rng),
                        partial ? 0.5 : 1.0)
    }

    func sample(at t: TimeInterval) -> MovementSample {
        let shoulder = BodyGeometry.shoulder(head: head, forward: forward, hand: dumbbellHand)
        let side: Float = dumbbellHand == .right ? 1 : -1
        let noise = SIMD3<Float>(Float.random(in: -1...1, using: &rng), Float.random(in: -1...1, using: &rng),
                                 Float.random(in: -1...1, using: &rng)) * 0.0015
        var hand: SIMD3<Float>
        switch hint {
        case .idle:
            hand = shoulder + SIMD3(0.02 * side, -0.56, -0.06)
        case .curls:
            var phase = t - repStart
            let rest = 0.3
            if phase > repDurations.up + repDurations.down + rest {
                repStart = t
                nextRep()
                phase = 0
            }
            let p: Double
            if phase < 0 { p = 0 }
            else if phase < repDurations.up { p = repDurations.peak * (1 - cos(.pi * phase / repDurations.up)) / 2 }
            else if phase < repDurations.up + repDurations.down {
                p = repDurations.peak * (1 + cos(.pi * (phase - repDurations.up) / repDurations.down)) / 2
            } else { p = 0 }
            let y = Float(-0.56 + p * 0.48)
            hand = shoulder + SIMD3(0.02 * side, y, -0.06 - 0.22 * Float(p))
        case .hold:
            let elapsed = Float(t - hintStart)
            let tremor = Float(sin(t * 2 * .pi * 9)) * 0.002
            var sag = -0.0015 * elapsed
            let cycle = elapsed.truncatingRemainder(dividingBy: 22)
            if cycle > 17 && cycle < 18.5 { sag -= 0.16 }  // occasional drop to trigger "Arm up!"
            hand = shoulder + SIMD3(0.04 * side, -0.01 + sag + tremor, -0.58)
        }
        hand += noise
        return MovementSample(time: t, dumbbellHand: hand, head: head,
                              headForward: forward, freeHandPinchDistance: 0.06)
    }
}
#endif
