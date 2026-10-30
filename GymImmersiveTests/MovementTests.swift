import Foundation
import simd
import Testing
@testable import GymImmersive

struct CurlDetectorTests {
    let settings = WorkoutSettings()
    let shoulderY = Double(Synthetic.shoulder.y)

    private func run(duration: Double, rate: Double = 90, noise: Double = 0,
                     progress: (Double) -> Double) -> [CurlEvent] {
        var detector = CurlDetector(settings: settings)
        var rng = SeededRandom(seed: 1)
        var events: [CurlEvent] = []
        var t = 0.0
        while t <= duration {
            let hand = Synthetic.curlHand(progress: progress(t))
            let y = Double(hand.y) + (noise > 0 ? Double.random(in: -noise...noise, using: &rng) : 0)
            if let e = detector.process(time: t, handY: y, shoulderY: shoulderY) { events.append(e) }
            t += 1 / rate
        }
        return events
    }

    private func reps(_ events: [CurlEvent]) -> [CurlRep] {
        events.compactMap { if case .rep(let r) = $0 { r } else { nil } }
    }

    @Test func countsFullCurlsAtCoachedTempo() {
        let events = run(duration: 5 * 4 + 1) { Synthetic.curlProgress(at: $0, up: 2, down: 2, rest: 0) }
        let r = reps(events)
        #expect(r.count == 5)
        for rep in r {
            #expect(abs(rep.upDuration - 2) < 0.08, "up \(rep.upDuration)")
            #expect(abs(rep.downDuration - 2) < 0.08, "down \(rep.downDuration)")
        }
    }

    @Test func measuresFastAndSlowTempo() {
        let fast = reps(run(duration: 3 * 2 + 1) { Synthetic.curlProgress(at: $0, up: 1, down: 1, rest: 0) })
        #expect(fast.count == 3)
        #expect(fast.allSatisfy { abs($0.upDuration - 1) < 0.08 && abs($0.downDuration - 1) < 0.08 })
        let slow = reps(run(duration: 2 * 6 + 1) { Synthetic.curlProgress(at: $0, up: 3, down: 3, rest: 0) })
        #expect(slow.count == 2)
        #expect(slow.allSatisfy { abs($0.upDuration - 3) < 0.1 && abs($0.downDuration - 3) < 0.1 })
    }

    @Test func pausesAtTheBottomAddLimitedTime() {
        // A 2 s rest between reps credits at most 0.25 s to the next up phase.
        let r = reps(run(duration: 3 * 6 + 1) { Synthetic.curlProgress(at: $0, up: 2, down: 2, rest: 2) })
        #expect(r.count == 3)
        for rep in r {
            #expect(rep.upDuration > 1.9 && rep.upDuration < 2.35, "up \(rep.upDuration)")
            #expect(rep.downDuration > 1.9 && rep.downDuration < 2.35, "down \(rep.downDuration)")
        }
    }

    @Test func longWaitBeforeFirstRepDoesNotInflateTempo() {
        let r = reps(run(duration: 10 + 4 + 1) { t in t < 10 ? 0 : Synthetic.curlProgress(at: t - 10, up: 2, down: 2, rest: 0) })
        #expect(r.count == 1)
        #expect(r[0].upDuration < 2.35, "up \(r[0].upDuration)")
    }

    @Test func robustToSensorNoise() {
        let r = reps(run(duration: 5 * 4.3 + 1, noise: 0.004) { Synthetic.curlProgress(at: $0, up: 2, down: 2, rest: 0.3) })
        #expect(r.count == 5)
    }

    @Test func partialRangeIsNotCounted() {
        // Curls that only reach 55 % of the range.
        let events = run(duration: 3 * 4.3) {
            Synthetic.curlProgress(at: $0, up: 2, down: 2, rest: 0.3, low: -0.05, high: 0.55)
        }
        #expect(reps(events).isEmpty)
        let partials = events.filter { if case .partial = $0 { true } else { false } }
        #expect(partials.count == 3)
    }

    @Test func handStillAtBottomOrTopCountsNothing() {
        #expect(run(duration: 10) { _ in 0 }.isEmpty)
        #expect(run(duration: 10) { _ in 1 }.isEmpty)
    }

    @Test func resetDiscardsRepInProgress() {
        var detector = CurlDetector(settings: settings)
        var t = 0.0
        var events: [CurlEvent] = []
        while t < 3 {  // bottom, then up to the top
            let p = Synthetic.curlProgress(at: t, up: 2, down: 2, rest: 0.3)
            if let e = detector.process(time: t, handY: Double(Synthetic.curlHand(progress: p).y), shoulderY: shoulderY) { events.append(e) }
            t += 1 / 90
        }
        detector.reset()
        while t < 5 {  // remainder of the descent after the reset
            let p = Synthetic.curlProgress(at: t, up: 2, down: 2, rest: 0.3)
            if let e = detector.process(time: t, handY: Double(Synthetic.curlHand(progress: p).y), shoulderY: shoulderY) { events.append(e) }
            t += 1 / 90
        }
        #expect(reps(events).isEmpty)
    }
}

struct TempoScoreTests {
    @Test func perfectTempo() {
        let s = TempoScore.evaluate(up: 2, down: 2, targetUp: 2, targetDown: 2, tolerance: 0.5)
        #expect(s.score == 1)
        #expect(s.onTempo)
        #expect(s.coachTip == nil)
    }

    @Test func atToleranceAndBeyond() {
        let edge = TempoScore.evaluate(up: 2.5, down: 1.5, targetUp: 2, targetDown: 2, tolerance: 0.5)
        #expect(abs(edge.score - 0.5) < 1e-9)
        #expect(edge.onTempo)
        let bad = TempoScore.evaluate(up: 1, down: 2, targetUp: 2, targetDown: 2, tolerance: 0.5)
        #expect(abs(bad.score - 0.5) < 1e-9)  // up half 0, down half 1
        #expect(!bad.onTempo)
        #expect(bad.coachTip == "Slow it down")
        let slow = TempoScore.evaluate(up: 2, down: 3.5, targetUp: 2, targetDown: 2, tolerance: 0.5)
        #expect(slow.coachTip == "A little quicker")
    }

    @Test func stricterToleranceForHeavierSets() {
        let settings = WorkoutSettings()
        let tolerances = settings.sets.map(\.tempoTolerance)
        #expect(tolerances == tolerances.sorted(by: >))
        let light = TempoScore.evaluate(up: 2.5, down: 2, targetUp: 2, targetDown: 2, tolerance: tolerances[0])
        let heavy = TempoScore.evaluate(up: 2.5, down: 2, targetUp: 2, targetDown: 2, tolerance: tolerances[2])
        #expect(heavy.score < light.score)
        #expect(settings.sets.map(\.steadinessRadius) == settings.sets.map(\.steadinessRadius).sorted(by: >))
        #expect(settings.sets.map(\.holdDuration) == [30, 45, 60])
    }
}

struct HoldAnalyzerTests {
    let settings = WorkoutSettings()

    private func analyze(set: SetConfig, duration: Double, rate: Double = 90,
                         hand: (Double) -> SIMD3<Float>?) -> (HoldAnalyzer, [HoldFrame]) {
        var a = HoldAnalyzer(set: set, settings: settings)
        var frames: [HoldFrame] = []
        var t = 0.0
        var wasTracked = true
        while t <= duration {
            if let h = hand(t) {
                if !wasTracked { a.markGap() }
                frames.append(a.add(time: t, hand: h, shoulder: Synthetic.shoulder))
                wasTracked = true
            } else {
                wasTracked = false
            }
            t += 1 / rate
        }
        return (a, frames)
    }

    @Test func steadyHoldIsInZone() {
        let (a, frames) = analyze(set: settings.sets[0], duration: 10) { Synthetic.holdHand(at: $0) }
        let s = a.summary()
        #expect(s.timeInZoneFraction == 1)
        #expect(s.steadyFraction == 1)
        #expect(s.armDropCount == 0)
        #expect(abs(s.trackedDuration - 10) < 0.05)
        #expect(s.tremorRMSmm! < 0.01)
        #expect(abs(s.verticalDriftMm!) < 0.01)
        #expect(!frames.contains { $0.showArmUpCue })
        #expect(a.reference != nil)
    }

    @Test func tremorMatchesSinusoidRMS() {
        // 8 Hz (two whole cycles per 0.25 s window), 2 mm amplitude vertical tremor → RMS ≈ 2/√2 ≈ 1.41 mm.
        let (a, _) = analyze(set: settings.sets[0], duration: 10, rate: 180) {
            Synthetic.holdHand(at: $0, tremorAmplitude: 0.002)
        }
        let rms = a.summary().tremorRMSmm!
        #expect(abs(rms - 2 / 2.0.squareRoot()) < 0.15, "rms \(rms)")
    }

    @Test func tremorFunctionOnKnownData() {
        // Alternating ±1 mm at 100 Hz is pure high-frequency jitter: RMS ≈ 1 mm.
        let samples = (0..<200).map { i in
            HoldAnalyzer.Sample(t: Double(i) / 100, p: [0, i.isMultiple(of: 2) ? 0.001 : -0.001, 0], segment: 0)
        }
        let rms = HoldAnalyzer.tremorRMS(samples, window: 0.25)!
        #expect(abs(rms - 0.001) < 0.0001)
        #expect(HoldAnalyzer.tremorRMS([], window: 0.25) == nil)
    }

    @Test func linearSagGivesDrift() {
        // 5 mm/s sag over 20 s. Reference = mean of first ~1 s (≈ −2.5 mm), end = mean of last 1 s (≈ −97.5 mm).
        let (a, _) = analyze(set: settings.sets[2], duration: 20) { Synthetic.holdHand(at: $0, sagPerSecond: 0.005) }
        let s = a.summary()
        #expect(abs(s.verticalDriftMm! - (-95)) < 2, "drift \(s.verticalDriftMm!)")
        #expect(abs(s.totalDriftMm! - 95) < 2)
        // Set 3 drop tolerance is 8 cm: the hand leaves the zone after 14 s.
        #expect(s.armDropCount == 1)
        #expect(s.timeInZoneFraction! < 0.75 && s.timeInZoneFraction! > 0.65)
    }

    @Test func armDropCueNeedsSustainedDrop() {
        let set = settings.sets[0]
        // 0.3 s dip (shorter than the 0.5 s cue delay) at t=3, then a 2 s drop at t=6.
        let (a, frames) = analyze(set: set, duration: 10) { t in
            var h = Synthetic.holdHand(at: t)
            if (3..<3.3).contains(t) || (6..<8).contains(t) { h.y -= 0.3 }
            return h
        }
        #expect(a.summary().armDropCount == 1)
        #expect(frames.filter(\.armDropped).count == 1)
        #expect(frames.last?.showArmUpCue == false, "cue clears once the arm is back up")
    }

    @Test func bentArmIsOutOfZone() {
        let (a, _) = analyze(set: settings.sets[0], duration: 3) { _ in Synthetic.shoulder + [0, 0, -0.2] }
        #expect(a.summary().timeInZoneFraction == 0)
        #expect(a.reference == nil)
    }

    @Test func trackingGapIsNotCountedAsHoldTime() {
        let (a, _) = analyze(set: settings.sets[0], duration: 10) { t in
            (4..<6).contains(t) ? nil : Synthetic.holdHand(at: t, tremorAmplitude: 0.001)
        }
        let s = a.summary()
        #expect(abs(s.trackedDuration - 8) < 0.1, "tracked \(s.trackedDuration)")
    }

    @Test func steadinessZoneShrinksWithWeight() {
        // A constant 5 cm offset after the reference second is steady for set 1 (8 cm) but not set 3 (4 cm).
        let hand: (Double) -> SIMD3<Float>? = { t in Synthetic.holdHand(at: t) + (t > 2 ? [0.05, 0, 0] : .zero) }
        let light = analyze(set: settings.sets[0], duration: 10, hand: hand).0.summary()
        let heavy = analyze(set: settings.sets[2], duration: 10, hand: hand).0.summary()
        #expect(light.steadyFraction! > 0.99)
        #expect(heavy.steadyFraction! < 0.2)
    }
}

struct PinchDetectorTests {
    @Test func oneEventPerPinchWithHysteresis() {
        var p = PinchDetector()
        let distances: [Float?] = [0.06, 0.02, 0.01, 0.012, 0.02, 0.025, 0.01, 0.04, 0.01, nil, 0.01]
        let events = distances.map { p.update(distance: $0) }
        #expect(events == [false, false, true, false, false, false, false, false, true, false, true])
    }
}

struct BodyGeometryTests {
    @Test func shoulderSidesAndHeight() {
        let head = SIMD3<Float>(0, 1.6, 0)
        let right = BodyGeometry.shoulder(head: head, forward: [0, 0, -1], hand: .right)
        let left = BodyGeometry.shoulder(head: head, forward: [0, 0, -1], hand: .left)
        #expect(right.x > 0 && left.x < 0)
        #expect(abs(right.y - 1.35) < 1e-5)
        // Turning to face +x puts the right shoulder at +z.
        let turned = BodyGeometry.shoulder(head: head, forward: [1, -0.3, 0], hand: .right)
        #expect(turned.z > 0.1)
    }
}
