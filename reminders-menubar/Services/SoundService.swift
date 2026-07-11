import AVFoundation
import AppKit

/// Plays short, synthesized UI feedback (no bundled audio files): a "success"
/// chime when an entry is created, and a lighter "ding" when a reminder is
/// completed.
final class SoundService {
    static let shared = SoundService()

    private typealias Note = (freq: Double, start: Double, dur: Double)
    private typealias Harmonic = (multiple: Double, amplitude: Double)

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Save confirmation: a subtle haptic only (no chime, by preference).
    func playSuccessFeedback() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// A quick two-note "dong-ding" — an ascending major third (E5 → G#5), the
    /// interval the ear reads as bright and resolved.
    func playSuccessChime() {
        let buffer = makeBuffer(
            notes: [(659.25, 0.00, 0.34), (830.61, 0.085, 0.46)],
            peak: 0.15, total: 0.62, attack: 0.007, decayRate: 5.0,
            harmonics: [(2, 0.16), (3, 0.05)]
        )
        play(buffer)
    }

    /// A lighter, brighter two-note ding rising a perfect fifth (G5 → D6) — a
    /// happy little "done!" for checking a reminder off. Distinct from the save
    /// chime (different interval + register, no haptic).
    func playCompleteChime() {
        let buffer = makeBuffer(
            notes: [(783.99, 0.00, 0.20), (1174.66, 0.07, 0.30)],
            peak: 0.12, total: 0.42, attack: 0.006, decayRate: 6.0,
            harmonics: [(2, 0.14), (3, 0.04)]
        )
        play(buffer)
    }

    private func play(_ buffer: AVAudioPCMBuffer?) {
        guard let buffer else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func makeBuffer(
        notes: [Note],
        peak: Double,
        total: Double,
        attack: Double,
        decayRate: Double,
        harmonics: [Harmonic]
    ) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * total)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) { samples[i] = 0 }

        for note in notes {
            let startSample = Int(note.start * sampleRate)
            let noteFrames = Int(note.dur * sampleRate)
            for n in 0..<noteFrames {
                let idx = startSample + n
                if idx >= Int(frameCount) { break }
                let t = Double(n) / sampleRate
                let attackEnv = min(1.0, t / attack)   // soft fade-in (no click)
                let decayEnv = exp(-t * decayRate)      // bell-like ring
                let env = attackEnv * decayEnv
                var tone = sin(2 * .pi * note.freq * t)
                for harmonic in harmonics {
                    tone += harmonic.amplitude * sin(2 * .pi * note.freq * harmonic.multiple * t)
                }
                samples[idx] += Float(peak * env * tone)
            }
        }
        return buffer
    }
}
