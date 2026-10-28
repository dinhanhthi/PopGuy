// TTSEngine.swift
// PopGuy — SpeakEngine
//
// AVSpeechSynthesizer wrapper that manages a single TTS session.
//
// Isolation: @MainActor — speak/stop mutate isSpeaking on the main actor.
// The delegate callbacks are `nonisolated` (required by the protocol) and hop
// back to @MainActor via `Task { @MainActor in }`. `MainActor.assumeIsolated`
// was intentionally avoided: AVSpeechSynthesizer delegates are not documented
// as main-thread-only on macOS and a crash on off-main delivery is unacceptable;
// the async hop is safe regardless of delivery thread and back-deploys to 13.0.
//
// State ownership: this engine exposes `private(set) var isSpeaking` and a
// `onSpeakingChange` callback. The SpeakCoordinator (T1.4) subscribes to the
// callback and drives its own `@Published isSpeaking` that the UI observes.

import AVFoundation
import Foundation

// MARK: - LocalTTSSpeaking

/// Minimal seam for the local TTS path in `SpeakCoordinator`.
///
/// `TTSEngine` is the production conformer. Tests inject a spy to verify
/// that fallback paths actually deliver text to the local engine.
/// `@MainActor` matches `TTSEngine`'s isolation; `: AnyObject` is required
/// so the coordinator can assign to `onSpeakingChange` through a `let` binding.
@MainActor
protocol LocalTTSSpeaking: AnyObject {
    var isSpeaking: Bool { get }
    var onSpeakingChange: ((Bool) -> Void)? { get set }
    func speak(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float, pitch: Float)
    func stop()
}

// MARK: - TTSEngine

/// Lightweight wrapper around `AVSpeechSynthesizer` for the Speak toolbar action.
///
/// One instance is owned by `SpeakCoordinator`. Callers pass voice/rate/pitch
/// directly; engine state is reported via `onSpeakingChange`.
@MainActor
final class TTSEngine: NSObject, LocalTTSSpeaking {

    // MARK: - Private state

    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - Public state

    /// True while the synthesizer is actively speaking.
    /// Updated on `didStart`, `didFinish`, `didCancel`, and `stop()`.
    private(set) var isSpeaking: Bool = false

    /// Called with `true` when speech starts and `false` when it finishes or
    /// is cancelled. `SpeakCoordinator` subscribes to drive its `@Published`.
    var onSpeakingChange: ((Bool) -> Void)?

    // MARK: - Init

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    /// Speak `text` using the given voice, rate, and pitch.
    ///
    /// - If `text` is empty or whitespace-only, the call is a no-op.
    /// - Any currently-playing utterance is stopped first.
    /// - `voice` may be `nil`; AVFoundation picks the system default.
    func speak(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float, pitch: Float) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Stop any in-progress utterance before starting a new one.
        if isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        utterance.rate = rate
        utterance.pitchMultiplier = pitch

        synthesizer.speak(utterance)
    }

    /// Stop the current utterance immediately.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        setSpeaking(false)
    }

    // MARK: - Private helpers

    private func setSpeaking(_ value: Bool) {
        isSpeaking = value
        onSpeakingChange?(value)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSEngine: AVSpeechSynthesizerDelegate {

    // Delegate methods are nonisolated because the protocol is not @MainActor.
    // Each hops back to the main actor via Task { @MainActor in } — see file
    // header for the rationale (off-main safety + macOS 13 compatibility).

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.setSpeaking(true)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.setSpeaking(false)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.setSpeaking(false)
        }
    }
}
