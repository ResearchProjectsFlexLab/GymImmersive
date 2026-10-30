import Foundation
import simd

struct HoldFrame: Sendable, Equatable {
    /// Arm extended and at (or above) shoulder height within the drop tolerance.
    var inZone: Bool
    /// Inside the steadiness radius around the reference position; nil until the reference exists.
    var steady: Bool?
    /// Distance (m) from the reference position.
    var deviation: Double?
    var showArmUpCue: Bool
    /// True on the frame where the "Arm up!" cue first appears.
    var armDropped: Bool
}

struct HoldSummary: Sendable, Equatable {
    var trackedDuration: TimeInterval
    var timeInZoneFraction: Double?
    var steadyFraction: Double?
    var armDropCount: Int
    /// RMS of hand position around its 0.25 s moving average (mm): physiological + fatigue tremor.
    var tremorRMSmm: Double?
    /// Vertical change of the hand from the reference to the last second (mm, negative = sagging).
    var verticalDriftMm: Double?
    /// 3D distance from the reference to the mean of the last second (mm).
    var totalDriftMm: Double?
    var sampleCount: Int
}

/// Measures an extended-arm hold: zone keeping, steadiness, tremor and drift.
struct HoldAnalyzer: Sendable {
    var dropTolerance: Double
    var steadinessRadius: Double
    var minExtension: Double
    var cueDelay: TimeInterval
    var referenceWindow: TimeInterval = 1.0
    var tremorWindow: TimeInterval = 0.25
    var driftWindow: TimeInterval = 1.0
    /// Gaps longer than this between samples are not counted as hold time.
    var maxSampleGap: TimeInterval = 0.25

    struct Sample: Sendable { var t: TimeInterval; var p: SIMD3<Double>; var segment: Int }

    private(set) var samples: [Sample] = []
    private(set) var reference: SIMD3<Double>?
    private var referenceStart: TimeInterval?
    private var referenceSum = SIMD3<Double>.zero
    private var referenceCount = 0
    private var segment = 0
    private var lowSince: TimeInterval?
    private var cueShown = false
    private(set) var armDropCount = 0
    private var trackedTime = 0.0
    private var zoneTime = 0.0
    private var steadyTime = 0.0
    private var timeSinceReference = 0.0

    init(set: SetConfig, settings: WorkoutSettings) {
        dropTolerance = set.armDropTolerance
        steadinessRadius = set.steadinessRadius
        minExtension = settings.holdMinExtension
        cueDelay = settings.armUpCueDelay
    }

    /// Call when tracking was lost or the session paused, so the gap is not treated as motion.
    mutating func markGap() {
        segment += 1
        lowSince = nil
    }

    mutating func add(time t: TimeInterval, hand: SIMD3<Float>, shoulder: SIMD3<Float>) -> HoldFrame {
        let p = SIMD3<Double>(hand)
        let s = SIMD3<Double>(shoulder)
        let horizontal = simd_length(SIMD2(p.x - s.x, p.z - s.z))
        let inZone = p.y >= s.y - dropTolerance && horizontal >= minExtension

        // Reference: mean of the first second spent in the zone.
        if reference == nil, inZone {
            if referenceStart == nil { referenceStart = t }
            referenceSum += p
            referenceCount += 1
            if t - referenceStart! >= referenceWindow {
                reference = referenceSum / Double(referenceCount)
            }
        }
        let deviation = reference.map { simd_distance($0, p) }
        let steady = deviation.map { inZone && $0 <= steadinessRadius }

        if let previous = samples.last, previous.segment == segment {
            let dt = t - previous.t
            if dt > 0, dt <= maxSampleGap {
                trackedTime += dt
                if inZone { zoneTime += dt }
                if reference != nil {
                    timeSinceReference += dt
                    if steady == true { steadyTime += dt }
                }
            }
        }
        samples.append(Sample(t: t, p: p, segment: segment))

        var dropped = false
        if inZone {
            lowSince = nil
            cueShown = false
        } else {
            if lowSince == nil { lowSince = t }
            if !cueShown, t - lowSince! >= cueDelay {
                cueShown = true
                dropped = true
                armDropCount += 1
            }
        }
        return HoldFrame(inZone: inZone, steady: steady, deviation: deviation,
                         showArmUpCue: cueShown, armDropped: dropped)
    }

    func summary() -> HoldSummary {
        HoldSummary(
            trackedDuration: trackedTime,
            timeInZoneFraction: trackedTime > 0 ? zoneTime / trackedTime : nil,
            steadyFraction: timeSinceReference > 0 ? steadyTime / timeSinceReference : nil,
            armDropCount: armDropCount,
            tremorRMSmm: Self.tremorRMS(samples, window: tremorWindow).map { $0 * 1000 },
            verticalDriftMm: drift().map { $0.y * 1000 },
            totalDriftMm: drift().map { simd_length($0) * 1000 },
            sampleCount: samples.count)
    }

    private func drift() -> SIMD3<Double>? {
        guard let reference, let lastT = samples.last?.t else { return nil }
        let tail = samples.filter { $0.t >= lastT - driftWindow }
        guard !tail.isEmpty else { return nil }
        let mean = tail.reduce(SIMD3<Double>.zero) { $0 + $1.p } / Double(tail.count)
        return mean - reference
    }

    /// RMS (m) of the 3D residual between each sample and its centred moving average.
    /// Samples whose window would cross a segment boundary are excluded.
    static func tremorRMS(_ samples: [Sample], window: TimeInterval) -> Double? {
        let half = window / 2
        var sumSquares = 0.0
        var count = 0
        var start = 0
        while start < samples.count {
            var end = start
            while end + 1 < samples.count, samples[end + 1].segment == samples[start].segment { end += 1 }
            let segmentStart = samples[start].t, segmentEnd = samples[end].t
            var lo = start, hi = start
            var windowSum = SIMD3<Double>.zero
            for i in start...end {
                let ti = samples[i].t
                while hi <= end, samples[hi].t <= ti + half { windowSum += samples[hi].p; hi += 1 }
                while samples[lo].t < ti - half { windowSum -= samples[lo].p; lo += 1 }
                guard ti - segmentStart >= half, segmentEnd - ti >= half else { continue }
                let mean = windowSum / Double(hi - lo)
                sumSquares += simd_length_squared(samples[i].p - mean)
                count += 1
            }
            start = end + 1
        }
        return count > 0 ? (sumSquares / Double(count)).squareRoot() : nil
    }
}
