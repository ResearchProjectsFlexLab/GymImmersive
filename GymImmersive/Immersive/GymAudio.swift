import AVFoundation
import RealityKit

/// Procedurally synthesised gym audio: a soft music bed from a corner speaker, distant weight
/// clanks from the rack, and a short chime for each counted rep (Vision Pro has no haptics).
/// Levels are kept low so the coach's voice stays clearly audible.
@MainActor
final class GymAudio {
    nonisolated static let sampleRate = 44_100.0

    let musicSource = Entity()
    let clankSource = Entity()
    private var repChime: AudioBufferResource?
    private var controllers: [AudioPlaybackController] = []
    private var isStopped = false

    func install(in root: Entity, chimeSource: Entity) async {
        musicSource.position = [-5.5, 3.2, -5.5]
        musicSource.components.set(SpatialAudioComponent(gain: -24, reverbLevel: -6))
        clankSource.position = [1.5, 0.8, -5.4]
        clankSource.components.set(SpatialAudioComponent(gain: -20, reverbLevel: 0))
        chimeSource.components.set(SpatialAudioComponent(gain: -10))
        root.addChild(musicSource)
        root.addChild(clankSource)

        // Synthesis takes a moment, so keep it off the main actor.
        let (music, clanks) = await Task.detached(priority: .utility) {
            (Self.musicBed(seconds: 16), Self.clankBed(seconds: 23))
        }.value
        guard !isStopped else { return }
        if let music = try? Self.resource(music, loop: true) {
            controllers.append(musicSource.playAudio(music))
        }
        if let clanks = try? Self.resource(clanks, loop: true) {
            controllers.append(clankSource.playAudio(clanks))
        }
        repChime = try? Self.resource(Self.chime(), loop: false)
    }

    func playRepChime(on entity: Entity) {
        guard let repChime else { return }
        entity.playAudio(repChime)
    }

    func stopAll() {
        isStopped = true
        for c in controllers { c.stop() }
        controllers.removeAll()
        musicSource.stopAllAudio()
        clankSource.stopAllAudio()
    }

    private static func resource(_ samples: [Float], loop: Bool) throws -> AudioBufferResource {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return try AudioBufferResource(buffer: buffer, configuration: .init(shouldLoop: loop))
    }

    // MARK: Synthesis (pure functions, deterministic)

    /// Mellow four-chord pad with a gentle pulse at 120 BPM; loops seamlessly.
    nonisolated static func musicBed(seconds: Double) -> [Float] {
        let n = Int(seconds * sampleRate)
        let chords: [[Double]] = [[220, 277.18, 329.63], [196, 246.94, 293.66],
                                  [174.61, 220, 261.63], [196, 246.94, 329.63]]
        let chordLength = seconds / Double(chords.count)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let chord = chords[min(chords.count - 1, Int(t / chordLength))]
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let pulse = 0.55 + 0.45 * exp(-beat * 6)
            var v = 0.0
            for f in chord { v += sin(2 * .pi * f * t) + 0.3 * sin(2 * .pi * f * 2 * t) }
            let kick = beat < 0.12 && Int(t / 0.5) % 2 == 0 ? sin(2 * .pi * 55 * beat) * exp(-beat * 30) * 1.2 : 0
            out[i] = Float((v / 4.5 * pulse + kick) * 0.25)
        }
        return fadeEdges(out, seconds: 0.02)
    }

    /// Sparse metallic clanks at irregular times.
    nonisolated static func clankBed(seconds: Double) -> [Float] {
        let n = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var rng = SeededRandom(seed: 42)
        var t = 1.5
        while t < seconds - 1 {
            let start = Int(t * sampleRate)
            let partials = [Double.random(in: 380...520, using: &rng), Double.random(in: 900...1300, using: &rng),
                            Double.random(in: 2100...2700, using: &rng)]
            let loudness = Double.random(in: 0.3...0.7, using: &rng)
            for j in 0..<Int(0.6 * sampleRate) where start + j < n {
                let s = Double(j) / sampleRate
                var v = 0.0
                for (k, f) in partials.enumerated() { v += sin(2 * .pi * f * s) * exp(-s * (8 + Double(k) * 6)) }
                v += Double.random(in: -1...1, using: &rng) * exp(-s * 60) * 0.5
                out[start + j] += Float(v * loudness * 0.3)
            }
            t += Double.random(in: 2.5...6, using: &rng)
        }
        return out
    }

    /// Short bright two-note chime.
    nonisolated static func chime() -> [Float] {
        let n = Int(0.35 * sampleRate)
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            let f = t < 0.08 ? 880.0 : 1318.5
            let local = t < 0.08 ? t : t - 0.08
            return Float(sin(2 * .pi * f * t) * exp(-local * 12) * 0.5 * min(1, t * 400))
        }
    }

    nonisolated private static func fadeEdges(_ s: [Float], seconds: Double) -> [Float] {
        var s = s
        let k = min(s.count / 2, Int(seconds * sampleRate))
        for i in 0..<k {
            let g = Float(i) / Float(k)
            s[i] *= g
            s[s.count - 1 - i] *= g
        }
        return s
    }
}
