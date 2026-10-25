// DictionaryAudioEngine.swift
// PopGuy — SpeakEngine
//
// Free Dictionary API client + AVPlayer-based mp3 playback.
//
// Isolation: @MainActor — all mutable state (player, isSpeaking, observer tokens)
// lives on the main actor. The NotificationCenter completion observers are
// registered on the main queue with closures that hop back to @MainActor via
// `Task { @MainActor [weak self] in }` — same pattern as TTSEngine delegates.
//
// Security model: the Free Dictionary API response is UNTRUSTED external data.
// Only the `audio` string is extracted from each phonetic entry. Before use, the
// string MUST parse to a URL whose scheme is exactly "https" — any other scheme
// (http, data, file, javascript, …) causes speak() to return false without
// constructing a player.
//
// Return contract: speak(word:variant:) returns true as soon as a valid https URL
// is found and AVPlayer.play() is called. It does NOT await playback completion —
// the speaking state is cleared later by the .AVPlayerItemDidPlayToEndTime /
// .AVPlayerItemFailedToPlayToEndTime observer (mirrors TTSEngine's delegate).
// Every earlier exit returns false and the caller falls back to TTSEngine.

import AVFoundation
import Foundation

// MARK: - JSON model

/// Minimal decodable shape for the Free Dictionary API response.
/// Only the fields we actually read are declared; all others are ignored.
struct DictEntry: Decodable {
    let phonetics: [DictPhonetic]
}

struct DictPhonetic: Decodable {
    let audio: String?
    // `text` (IPA) is intentionally omitted — not used, per security constraint.
}

// MARK: - DictionaryAudioEngine

@MainActor
protocol DictionaryAudioSpeaking: AnyObject {
    var isSpeaking: Bool { get }
    var onSpeakingChange: ((Bool) -> Void)? { get set }

    func play(urlString: String) -> Bool
    func speak(word: String, variant: String) async -> Bool
    func stop()
}

/// Fetches pronunciation audio from the Free Dictionary API and plays it via
/// `AVPlayer`. One instance is owned by `SpeakCoordinator`.
///
/// All public methods are `@MainActor`. The engine exposes `isSpeaking` and
/// `onSpeakingChange` so `SpeakCoordinator` can subscribe uniformly alongside
/// `TTSEngine`.
@MainActor
final class DictionaryAudioEngine: NSObject, DictionaryAudioSpeaking {

    // MARK: - Constants

    private static let apiBase = "https://api.dictionaryapi.dev/api/v2/entries/en/"
    private static let requestTimeout: TimeInterval = 4

    // MARK: - Private state

    private var player: AVPlayer?
    private var observerTokens: [NSObjectProtocol] = []

    // MARK: - Public state

    /// True while the AVPlayer is actively playing audio.
    private(set) var isSpeaking: Bool = false

    /// Called with `true` when playback starts and `false` when it finishes,
    /// fails, or is stopped. `SpeakCoordinator` subscribes to drive its
    /// `@Published isSpeaking`.
    var onSpeakingChange: ((Bool) -> Void)?

    // MARK: - Public API

    /// Play pronunciation audio from an explicit https URL string.
    ///
    /// Returns `true` if playback started, `false` when the URL is invalid,
    /// non-https, or playback could not start. Does not alter `speak(word:variant:)`.
    func play(urlString: String) -> Bool {
        guard
            let url = URL(string: urlString),
            url.scheme == "https"
        else { return false }

        if isSpeaking { stop() }
        return startPlayback(url: url)
    }

    /// Fetch pronunciation audio for `word` (trimmed/lowercased) matching
    /// `variant` ("us" / "uk"), then stream-play the mp3.
    ///
    /// Returns `true` if audio started playing, `false` for any failure:
    /// encoding error, network error, non-200, decode failure, no audio found,
    /// non-https URL. The caller should fall back to `TTSEngine` on `false`.
    func speak(word: String, variant: String) async -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }

        // Stop any currently playing item before starting a new one.
        if isSpeaking { stop() }

        // Build the request URL — percent-encode the word for a path segment.
        guard
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let requestURL = URL(string: Self.apiBase + encoded)
        else { return false }

        // Configure session with a short timeout.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = Self.requestTimeout
        let session = URLSession(configuration: config)

        // Fetch and decode. ALL errors map to false.
        let audioURL: URL
        do {
            let (data, response) = try await session.data(from: requestURL)
            guard
                let http = response as? HTTPURLResponse,
                http.statusCode == 200
            else { return false }

            let entries = try JSONDecoder().decode([DictEntry].self, from: data)
            guard let chosen = Self.pickAudioString(from: entries, variant: variant) else {
                return false
            }
            // Security: require https scheme.
            guard
                let url = URL(string: chosen),
                url.scheme == "https"
            else { return false }

            audioURL = url
        } catch {
            return false
        }

        // Play the audio.
        return startPlayback(url: audioURL)
    }

    // MARK: - Internal static helpers (testable without @MainActor)

    /// Scan all phonetics across all entries: prefer the first whose `audio` URL
    /// contains `-<variant>.mp3`; fall back to the first non-empty `audio`.
    nonisolated static func pickAudioString(from entries: [DictEntry], variant: String) -> String? {
        let allPhonetics = entries.flatMap { $0.phonetics }
        let suffix = "-\(variant).mp3"
        // Preferred: variant-specific match (audio is guaranteed non-empty by the filter).
        if let matched = allPhonetics.first(where: { ($0.audio ?? "").contains(suffix) }) {
            return matched.audio
        }
        // Fallback: first phonetic with any non-empty audio.
        return allPhonetics.first(where: { !($0.audio ?? "").isEmpty })?.audio
    }

    /// Stop playback immediately and set speaking state to false.
    func stop() {
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        setSpeaking(false)
    }

    // MARK: - Private helpers

    /// Installs a fresh AVPlayer for the URL, registers completion observers,
    /// calls play(), and returns true.
    private func startPlayback(url: URL) -> Bool {
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer

        // Use ObjectIdentifier as a Sendable item token so the Task closures
        // can reference item identity without capturing the non-Sendable AVPlayerItem.
        let itemID = ObjectIdentifier(item)

        // Register observers on the main queue; hop to @MainActor in the handler
        // to satisfy strict concurrency without suppressions (same pattern as
        // TTSEngine's nonisolated delegate hops). Store both tokens so they are
        // always removed together, preventing accumulation across plays.
        let endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnded(forItemID: itemID)
            }
        }

        let failToken = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnded(forItemID: itemID)
            }
        }

        observerTokens.append(contentsOf: [endToken, failToken])
        newPlayer.play()
        setSpeaking(true)
        return true
    }

    /// Shared handler for normal end-of-playback and failure.
    ///
    /// Stale-teardown guard: if `itemID` no longer matches the current player item,
    /// this notification came from an old item and is ignored — prevents a stale
    /// observer from nilling out a newer player or clearing `isSpeaking` mid-play.
    private func handlePlaybackEnded(forItemID itemID: ObjectIdentifier) {
        guard let current = player?.currentItem,
              ObjectIdentifier(current) == itemID else { return }
        removeObservers()
        player = nil
        setSpeaking(false)
    }

    /// Remove all stored observer tokens and clear the list.
    private func removeObservers() {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
    }

    private func setSpeaking(_ value: Bool) {
        isSpeaking = value
        onSpeakingChange?(value)
    }
}
