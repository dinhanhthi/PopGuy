// CloudTTSEngine.swift
// PopGuy — SpeakEngine/CloudTTS
//
// Fetches audio from a cloud TTS provider via HTTPClient and plays it with
// AVAudioPlayer. One instance is owned by SpeakCoordinator.
//
// Isolation: @MainActor — all mutable state (player, isSpeaking) lives on the
// main actor. The AVAudioPlayerDelegate callback is `nonisolated` (required by
// the protocol) and hops back to @MainActor via `Task { @MainActor [weak self]
// in }` — same pattern as TTSEngine and DictionaryAudioEngine.
//
// Return contract: speak(...) returns true as soon as AVAudioPlayer.play() is
// called. It never throws to the caller — every failure path returns false so
// SpeakCoordinator can fall back to local TTS without special-casing errors.
//
// Security: the API key is never logged. The raw audio bytes from the provider
// are treated as untrusted data passed directly to AVAudioPlayer — no logging
// or persistence of audio bytes.

import AVFoundation
import Foundation

// MARK: - CloudSpeaking

/// Protocol seam for the cloud TTS engine. Mirrors the LocalTTSSpeaking pattern
/// so SpeakCoordinator can be tested with a spy that controls cloud.speak()'s
/// return value without making any network calls.
@MainActor
protocol CloudSpeaking: AnyObject {
    var isSpeaking: Bool { get }
    var onSpeakingChange: ((Bool) -> Void)? { get set }
    func speak(
        text: String,
        languageCode: String,
        provider: any TTSProvider.Type,
        config: TTSProviderConfig,
        speed: Double?,
        pitch: Double?,
        apiKey: String
    ) async -> Bool
    func stop()
    /// Replay the audio fetched by the most recent successful `speak(...)` without
    /// issuing a new network request. Returns `false` when no cached audio exists.
    func replayCached() -> Bool
    /// Drop any cached audio (called when the toolbar closes or a new selection arrives).
    func clearCache()
}

// MARK: - CloudTTSEngine

/// Fetches cloud TTS audio for any `TTSProvider` adapter and plays it via
/// `AVAudioPlayer`. One instance is owned by `SpeakCoordinator`.
///
/// All public methods are `@MainActor`. The engine exposes `isSpeaking` and
/// `onSpeakingChange` so `SpeakCoordinator` can subscribe uniformly alongside
/// `TTSEngine` and `DictionaryAudioEngine`.
@MainActor
final class CloudTTSEngine: NSObject, CloudSpeaking {

    // MARK: - Private state

    private var player: AVAudioPlayer?

    /// Decoded audio bytes from the most recent successful fetch. Retained so
    /// `replayCached()` can re-play the same audio without a new request.
    /// Survives `stop()` (so the toolbar's "Listen again" works after Stop);
    /// cleared only by `clearCache()` or overwritten by the next success.
    private var cachedAudio: Data?

    // MARK: - Public state

    /// True while AVAudioPlayer is actively playing audio.
    private(set) var isSpeaking: Bool = false

    /// Called with `true` when playback starts and `false` when it finishes,
    /// fails, or is stopped. `SpeakCoordinator` subscribes to drive its
    /// `@Published isSpeaking`.
    var onSpeakingChange: ((Bool) -> Void)?

    // MARK: - Init

    override init() {
        super.init()
    }

    // MARK: - Public API

    /// Fetch and play synthesised audio for `text` using the given provider.
    ///
    /// Returns `true` if audio started playing; `false` for any failure:
    /// empty text, missing API key, network error, HTTP error, decode error,
    /// or AVAudioPlayer init failure. The caller should fall back to local
    /// TTS on `false`.
    ///
    /// Never throws. Never logs the API key.
    func speak(
        text: String,
        languageCode: String,
        provider: any TTSProvider.Type,
        config: TTSProviderConfig,
        speed: Double?,
        pitch: Double?,
        apiKey: String
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !apiKey.isEmpty else { return false }

        if isSpeaking { stop() }

        // Resolve voice: per-language override, then provider default.
        let voice = resolveTTSVoice(languageCode: languageCode, config: config, provider: provider)

        // Build the synthesis request — pure, no I/O.
        let request: URLRequest
        do {
            request = try provider.makeSynthesisRequest(
                text: trimmed,
                voice: voice,
                languageCode: languageCode,
                speed: speed,
                pitch: pitch,
                config: config,
                apiKey: apiKey
            )
        } catch {
            return false
        }

        // Fetch audio bytes and decode them.
        let audio: Data
        do {
            let raw = try await HTTPClient().rawData(for: request)
            // Guard: if the coordinator cancelled this Task while the network
            // request was in-flight, discard the response before building a
            // player — prevents stale audio from a superseded speak() call.
            guard !Task.isCancelled else { return false }
            audio = try provider.decodeAudio(from: raw)
        } catch {
            return false
        }

        // Init the player and start playback. Cache the bytes only once playback
        // actually started, so a bad/undecodable buffer never becomes a cache.
        guard startPlayer(with: audio) else { return false }
        cachedAudio = audio
        return true
    }

    /// Stop playback immediately and clear speaking state.
    /// Does NOT drop `cachedAudio` — `replayCached()` must still work after Stop.
    func stop() {
        player?.stop()
        player = nil
        setSpeaking(false)
    }

    /// Re-play the cached audio from the last successful `speak(...)`.
    /// Returns `false` when there is no cached audio or the player can't init.
    func replayCached() -> Bool {
        guard let audio = cachedAudio else { return false }
        return startPlayer(with: audio)
    }

    /// Discard the cached audio.
    func clearCache() {
        cachedAudio = nil
    }

    // MARK: - Private helpers

    /// Build an `AVAudioPlayer` from `data`, start it, and flip speaking state.
    /// Returns `false` if the player can't be created. Shared by `speak(...)`
    /// (fresh fetch) and `replayCached()` (cached bytes).
    private func startPlayer(with data: Data) -> Bool {
        let p: AVAudioPlayer
        do {
            p = try AVAudioPlayer(data: data)
        } catch {
            return false
        }
        player = p
        p.delegate = self
        p.play()
        setSpeaking(true)
        return true
    }

    private func setSpeaking(_ value: Bool) {
        isSpeaking = value
        onSpeakingChange?(value)
    }

    private func handleFinished() {
        player = nil
        setSpeaking(false)
    }
}

// MARK: - AVAudioPlayerDelegate

extension CloudTTSEngine: AVAudioPlayerDelegate {

    // Delegate method is nonisolated because the protocol is not @MainActor.
    // Hops back to the main actor via Task { @MainActor [weak self] in } —
    // same pattern as TTSEngine's nonisolated delegate hops. Safe regardless
    // of which thread AVAudioPlayer delivers the callback on (macOS 13+).

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.handleFinished()
        }
    }
}
