import Foundation

/// A completed, full-range curl. Times are turnaround points (lowest / highest hand position).
struct CurlRep: Sendable, Equatable {
    var startTime: TimeInterval
    var topTime: TimeInterval
    var endTime: TimeInterval
    var peakProgress: Double
    var upDuration: TimeInterval { topTime - startTime }
    var downDuration: TimeInterval { endTime - topTime }
}

enum CurlEvent: Sendable, Equatable {
    case rep(CurlRep)
    /// The hand rose out of the bottom zone but sank back without reaching the top.
    case partial(time: TimeInterval, peakProgress: Double)
}

/// Turns hand height (relative to the estimated shoulder) into counted curls.
///
/// Progress 0 is the arm hanging straight, 1 is the hand at the top of the curl. A rep counts only
/// when the hand goes bottom → above `high` → back below `low`.
///
/// Up/down durations run between turnaround points. A turnaround is the midpoint of the time the
/// hand spends within `dwellEpsilon` of its extreme, so a smooth 2 s / 2 s curl reads as exactly
/// 2 s / 2 s, while a pause at the top or bottom adds at most `maxDwellCredit` to each half.
/// A rep completes once the hand turns back up or rests at the bottom for `settleTime`.
struct CurlDetector: Sendable {
    var bottomOffset: Double
    var topOffset: Double
    var low: Double
    var high: Double
    var smoothingTimeConstant: TimeInterval = 0.05
    var settleTime: TimeInterval = 0.35
    var turnHysteresis: Double = 0.05
    var dwellEpsilon: Double = 0.01
    var maxDwellCredit: TimeInterval = 0.25
    /// Samples kept per zone. Must exceed the time a slow curl spends above `high` / below `low`;
    /// anything older only matters for long pauses, whose credit is capped anyway.
    private let bufferSpan: TimeInterval = 5.0

    private enum State: Sendable { case waiting, bottom, rising, top, falling, settling }
    private struct Point: Sendable { var t: TimeInterval; var p: Double }
    private var state: State = .waiting
    private var smoothed: Double?
    private var lastTime: TimeInterval?
    private var bottomZone: [Point] = []
    private var topZone: [Point] = []
    private var upStart: TimeInterval = 0
    private var risingPeak = 0.0

    init(settings: WorkoutSettings) {
        bottomOffset = settings.curlBottomOffset
        topOffset = settings.curlTopOffset
        low = settings.curlLowThreshold
        high = settings.curlHighThreshold
    }

    /// Smoothed progress of the most recent sample, for UI feedback.
    var currentProgress: Double { smoothed ?? 0 }

    mutating func reset() {
        state = .waiting
        smoothed = nil
        lastTime = nil
        bottomZone = []
        topZone = []
    }

    func progress(handY: Double, shoulderY: Double) -> Double {
        let bottom = shoulderY + bottomOffset
        let top = shoulderY + topOffset
        return min(1.2, max(-0.2, (handY - bottom) / (top - bottom)))
    }

    mutating func process(time t: TimeInterval, handY: Double, shoulderY: Double) -> CurlEvent? {
        let raw = progress(handY: handY, shoulderY: shoulderY)
        if let s = smoothed, let last = lastTime {
            let dt = max(0, t - last)
            let alpha = dt / (smoothingTimeConstant + dt)
            smoothed = s + alpha * (raw - s)
        } else {
            smoothed = raw
        }
        lastTime = t
        let p = smoothed!
        let point = Point(t: t, p: p)

        switch state {
        case .waiting:
            if p <= low { state = .bottom; bottomZone = [point] }
        case .bottom:
            if p > low { beginRising(at: p) } else { Self.append(point, to: &bottomZone, span: bufferSpan) }
        case .rising:
            risingPeak = max(risingPeak, p)
            if p >= high {
                state = .top
                topZone = [point]
            } else if p <= low {
                state = .bottom
                bottomZone = [point]
                return .partial(time: t, peakProgress: risingPeak)
            }
        case .top:
            if p < high { state = .falling } else { Self.append(point, to: &topZone, span: bufferSpan) }
        case .falling:
            if p >= high {
                state = .top
                Self.append(point, to: &topZone, span: bufferSpan)
            } else if p <= low {
                state = .settling
                bottomZone = [point]
            }
        case .settling:
            if p <= low { Self.append(point, to: &bottomZone, span: bufferSpan) }
            let dwell = Self.dwell(bottomZone, epsilon: dwellEpsilon, isMax: false)
            let turnedUp = p > dwell.extreme + turnHysteresis
            let rested = t - dwell.arrive >= settleTime
            guard turnedUp || rested || p > low else { return nil }
            let top = Self.dwell(topZone, epsilon: dwellEpsilon, isMax: true)
            let rep = CurlRep(startTime: upStart, topTime: turnaround(top),
                              endTime: turnaround(dwell), peakProgress: top.extreme)
            topZone = []
            if p > low { beginRising(at: p) } else { state = .bottom }
            return .rep(rep)
        }
        return nil
    }

    private func turnaround(_ d: (arrive: TimeInterval, leave: TimeInterval, extreme: Double)) -> TimeInterval {
        d.arrive + min((d.leave - d.arrive) / 2, maxDwellCredit)
    }

    private static func append(_ point: Point, to zone: inout [Point], span bufferSpan: TimeInterval) {
        zone.append(point)
        if let first = zone.first, point.t - first.t > bufferSpan {
            zone.removeFirst(zone.prefix { point.t - $0.t > bufferSpan }.count)
        }
    }

    private static func dwell(_ zone: [Point], epsilon: Double,
                              isMax: Bool) -> (arrive: TimeInterval, leave: TimeInterval, extreme: Double) {
        guard let first = zone.first else { return (0, 0, 0) }
        let extreme = isMax ? zone.map(\.p).max()! : zone.map(\.p).min()!
        let near = zone.filter { abs($0.p - extreme) <= epsilon }
        return (near.first?.t ?? first.t, near.last?.t ?? first.t, extreme)
    }

    private mutating func beginRising(at p: Double) {
        let d = Self.dwell(bottomZone, epsilon: dwellEpsilon, isMax: false)
        // Credit at most `maxDwellCredit` of a rest at the bottom to the up phase.
        upStart = max(turnaround(d), d.leave - maxDwellCredit)
        state = .rising
        risingPeak = p
        bottomZone = []
    }
}

struct TempoScore: Sendable, Equatable {
    var upError: TimeInterval
    var downError: TimeInterval
    /// 1 = perfect, 0.5 = at the tolerance limit, 0 = twice the tolerance or worse.
    var score: Double
    var onTempo: Bool

    static func evaluate(up: TimeInterval, down: TimeInterval,
                         targetUp: TimeInterval, targetDown: TimeInterval,
                         tolerance: TimeInterval) -> TempoScore {
        let upError = up - targetUp
        let downError = down - targetDown
        func half(_ e: Double) -> Double { min(1, max(0, 1 - 0.5 * abs(e) / tolerance)) }
        return TempoScore(upError: upError, downError: downError,
                          score: (half(upError) + half(downError)) / 2,
                          onTempo: abs(upError) <= tolerance && abs(downError) <= tolerance)
    }

    /// Short coaching tip based on the larger error.
    var coachTip: String? {
        if onTempo { return nil }
        let worst = abs(upError) > abs(downError) ? upError : downError
        return worst < 0 ? "Slow it down" : "A little quicker"
    }
}
