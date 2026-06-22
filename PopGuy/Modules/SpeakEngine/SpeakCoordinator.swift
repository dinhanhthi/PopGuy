// SpeakCoordinator.swift
// PopGuy — SpeakEngine
//
// Routes speak requests between the dictionary-audio path and the TTS path,
// and exposes a single combined isSpeaking state for the UI.
//
// Isolation: @MainActor — all mutable state lives on the main actor.
// ObservableObject (not @Observable) is used because @Observable requires
// macOS 14.0+; PopGuy targets macOS 13.0+.
//
// Routing:
//   - Single word + accent supports dictionary + dictionaryAudioEnabled → try
//     Free Dictionary API; fall back to selected engine when the API returns false.
//   - Everything else (phrase, French, dictionary disabled) → selected engine.
//
// Engine selection:
//   - .system → local AVSpeechSynthesizer (TTSEngine).
//   - .cloud(kind) → CloudTTSEngine (fetch + AVAudioPlayer). Falls back to
//     local TTS if: kind not implemented, text over cloudCharLimit, no API key
//     stored, provider type unknown, or cloud speak() returns false.
//
// Race safety: a new speak() call cancels any in-flight dictionary or cloud
// Task before starting fresh. After each async await resumes, a
// Task.isCancelled check prevents stale fallbacks from racing with whatever
// the new call already started.

import AVFoundation
import Combine
import Foundation

// MARK: - SpeakCoordinator

/// Routes text to either the Free Dictionary API (single-word pronunciation),
/// the local AVSpeechSynthesizer, or a cloud TTS provider, and publishes
/// combined playing state for the toolbar UI.
///
/// One instance is intended to live in the app for the full session.
@MainActor
final class SpeakCoordinator: ObservableObject {

    // MARK: - Engines

    private let tts: any LocalTTSSpeaking
    private let dictionary: any DictionaryAudioSpeaking
    private let cloud: any CloudSpeaking

    // MARK: - Keychain

    private let keychain: KeychainManager

    // MARK: - Public state

    /// Current phase of the speak lifecycle: idle / loading / playing.
    @Published private(set) var phase: SpeakPhase = .idle

    /// True when the selected engine was cloud but playback fell back to the
    /// system voice (guard failure or cloud.speak returning false).
    /// Resets to false at the start of each speak() call; NOT reset by stop().
    @Published private(set) var didFallBackToSystem: Bool = false

    /// True while ANY of the three engines is playing (phase == .playing).
    /// Kept as a convenience for existing call sites.
    @Published private(set) var isSpeaking: Bool = false

    /// Trimmed text of the most recent `speak(...)`. Drives the toolbar's
    /// persistent "spoken text" body. Set at speak() start, cleared by
    /// `clearReplay()` (toolbar close / new selection).
    @Published private(set) var lastSpokenText: String?

    /// True once a backend has actually engaged for the current selection, so the
    /// toolbar can offer "Listen again". Reset at each speak() start and cleared
    /// by `clearReplay()`.
    @Published private(set) var canReplay: Bool = false

    // MARK: - Private state

    /// True while a network/synthesis task is in flight and no engine has started
    /// playing yet. Used by recomputePhase() to distinguish loading from idle.
    private var isLoading: Bool = false

    /// Tracks the currently-running dictionary lookup + playback Task so it can
    /// be cancelled when a new speak() call arrives or stop() is called.
    private var dictionaryTask: Task<Void, Never>?

    /// Tracks the currently-running cloud TTS Task so it can be cancelled when
    /// a new speak() call arrives or stop() is called.
    private var cloudTask: Task<Void, Never>?

    /// Which backend actually produced the last playback, so `replay()` can
    /// re-play via the right path WITHOUT re-routing — crucially, a cloud
    /// fallback replays via the system voice instead of re-hitting (and re-billing)
    /// the cloud provider.
    private enum ReplaySource { case cloudCache, system, dictionaryWord, dictionaryURL(String) }
    private var replaySource: ReplaySource?

    /// Captured request context for the non-cached replay paths (system re-synth,
    /// dictionary word re-fetch, native URL replay). Set at each speak() start.
    private var lastAccent: SpeakAccent = .usEnglish
    private var lastSettings: SpeakSettings = .default

    // MARK: - Init

    /// - Parameters:
    ///   - tts: TTS engine; defaults to a freshly-owned instance.
    ///   - dictionary: Dictionary-audio engine; defaults to a freshly-owned instance.
    ///   - cloud: Cloud TTS engine; defaults to a freshly-owned instance.
    ///   - keychain: Keychain manager; defaults to the production instance.
    ///
    /// Default arguments allow production code to call `SpeakCoordinator()` while
    /// tests can inject lightweight substitutes without requiring protocols.
    init(
        tts: any LocalTTSSpeaking = TTSEngine(),
        dictionary: any DictionaryAudioSpeaking = DictionaryAudioEngine(),
        cloud: any CloudSpeaking = CloudTTSEngine(),
        keychain: KeychainManager = KeychainManager()
    ) {
        self.tts = tts
        self.dictionary = dictionary
        self.cloud = cloud
        self.keychain = keychain

        // Wire each engine's speaking-change callback to recompute combined state.
        tts.onSpeakingChange = { [weak self] _ in
            self?.recomputePhase()
        }
        dictionary.onSpeakingChange = { [weak self] _ in
            self?.recomputePhase()
        }
        cloud.onSpeakingChange = { [weak self] _ in
            self?.recomputePhase()
        }
    }

    // MARK: - Public API

    /// Speak `text` using the appropriate audio backend for the given `accent`,
    /// `settings`, and optional per-provider `ttsConfig`.
    ///
    /// - If `text` trims to empty, the call is a no-op.
    /// - If already speaking, the current playback is stopped first.
    /// - Routing: single-word + dictionary-capable accent + enabled →
    ///   dictionary lookup first; on miss → `speakWithSelectedEngine`. Everything
    ///   else → `speakWithSelectedEngine`.
    /// - `ttsConfig`: passed to the cloud engine; the default value keeps all
    ///   existing call sites compiling. Phase 3 callers pass the real per-provider
    ///   config from SettingsStore.
    func speak(_ text: String, accent: SpeakAccent, settings: SpeakSettings, ttsConfig: TTSProviderConfig = .default) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Unconditionally cancel any in-flight dictionary or cloud Task and stop
        // all engines before starting fresh — guards against double-billing when a
        // cloud request is in-flight (cloud.isSpeaking is still false during fetch).
        stop()

        // Give instant UI feedback: reset fallback flag and enter loading phase
        // synchronously, before any await. stop() has already set phase = .idle
        // and isLoading = false, so this order is deliberate.
        didFallBackToSystem = false
        isLoading = true
        phase = .loading

        // Record replay context for this selection. `replaySource`/`canReplay`
        // stay unset until a backend actually engages (set in the paths below).
        lastSpokenText = trimmed
        lastAccent = accent
        lastSettings = settings
        replaySource = nil
        canReplay = false

        if settings.dictionaryAudioEnabled,
           accent.usesDictionary,
           let variant = accent.dictionaryVariant,
           Self.isSingleWord(trimmed) {
            // Async path: dictionary lookup → selected-engine fallback.
            let capturedTrimmed = trimmed
            dictionaryTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let played = await dictionary.speak(word: capturedTrimmed, variant: variant)
                // Cancellation check: if stop() or a newer speak() cancelled this
                // Task before we reached here, don't start a stale fallback.
                guard !Task.isCancelled else { return }
                if played {
                    replaySource = .dictionaryWord
                    canReplay = true
                } else {
                    speakWithSelectedEngine(capturedTrimmed, accent: accent, settings: settings, ttsConfig: ttsConfig)
                }
            }
        } else {
            speakWithSelectedEngine(trimmed, accent: accent, settings: settings, ttsConfig: ttsConfig)
        }
    }

    /// Speak a dictionary headword, preferring a source-native audio URL when
    /// provided, otherwise falling back through the standard `speak(...)` path
    /// (Free Dictionary API audio → selected TTS engine).
    ///
    /// Additive entry point for the Look up action — does not alter
    /// the global Speak action's routing.
    func speakDictionary(
        headword: String,
        nativeAudioURL: String?,
        accent: SpeakAccent,
        settings: SpeakSettings,
        ttsConfig: TTSProviderConfig = .default
    ) {
        let trimmed = headword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()

        didFallBackToSystem = false
        isLoading = true
        phase = .loading
        lastSpokenText = trimmed
        lastAccent = accent
        lastSettings = settings
        replaySource = nil
        canReplay = false

        let capturedTrimmed = trimmed
        dictionaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let urlString = nativeAudioURL,
               dictionary.play(urlString: urlString) {
                guard !Task.isCancelled else { return }
                replaySource = .dictionaryURL(urlString)
                canReplay = true
                return
            }
            guard !Task.isCancelled else { return }
            speak(capturedTrimmed, accent: accent, settings: settings, ttsConfig: ttsConfig)
        }
    }

    /// Stop all audio (all three backends) and cancel any in-flight tasks.
    /// Deliberately does NOT clear the replay cache: the toolbar keeps the
    /// "Listen again" affordance after the user taps Stop. Use `clearReplay()`
    /// to drop the cache (on toolbar close / new selection).
    func stop() {
        isLoading = false
        dictionaryTask?.cancel()
        dictionaryTask = nil
        cloudTask?.cancel()
        cloudTask = nil
        tts.stop()
        dictionary.stop()
        cloud.stop()
        // Explicitly reset phase and isSpeaking regardless of engine callbacks.
        phase = .idle
        isSpeaking = false
    }

    /// Re-play the last spoken text. Cloud playback re-uses the cached audio (no
    /// new request); the system path re-synthesises locally; native dictionary
    /// audio reuses the original URL; Free Dictionary audio re-fetches by word.
    /// A cloud fallback is recorded as `.system`, so re-listening never re-bills
    /// the cloud provider.
    func replay() {
        guard let source = replaySource, let text = lastSpokenText, !text.isEmpty else { return }
        // Tear down any current playback (caches survive stop()).
        stop()
        switch source {
        case .cloudCache:
            didFallBackToSystem = false
            if !cloud.replayCached() {
                // Cached audio vanished — degrade to a local re-synth.
                replaySource = .system
                isLoading = true
                phase = .loading
                speakWithTTS(text, accent: lastAccent, settings: lastSettings)
            }
        case .system:
            isLoading = true
            phase = .loading
            speakWithTTS(text, accent: lastAccent, settings: lastSettings)
        case .dictionaryURL(let urlString):
            isLoading = true
            phase = .loading
            if dictionary.play(urlString: urlString) {
                replaySource = .dictionaryURL(urlString)
                canReplay = true
            } else {
                replaySource = .system
                speakWithTTS(text, accent: lastAccent, settings: lastSettings)
            }
        case .dictionaryWord:
            guard let variant = lastAccent.dictionaryVariant else {
                replaySource = .system
                isLoading = true
                phase = .loading
                speakWithTTS(text, accent: lastAccent, settings: lastSettings)
                return
            }
            isLoading = true
            phase = .loading
            let capturedAccent = lastAccent
            let capturedSettings = lastSettings
            dictionaryTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let played = await dictionary.speak(word: text, variant: variant)
                guard !Task.isCancelled else { return }
                if !played {
                    replaySource = .system
                    speakWithTTS(text, accent: capturedAccent, settings: capturedSettings)
                }
            }
        }
    }

    /// Drop the replay cache and clear the toolbar's spoken-text body.
    /// Called when the toolbar closes or a new selection arrives.
    func clearReplay() {
        stop()
        replaySource = nil
        canReplay = false
        lastSpokenText = nil
        cloud.clearCache()
    }

    // MARK: - Private helpers

    /// Recomputes `phase` and derived `isSpeaking` from all three engines' current
    /// states and the `isLoading` flag.
    /// Called whenever any engine fires its `onSpeakingChange` callback.
    private func recomputePhase() {
        if tts.isSpeaking || dictionary.isSpeaking || cloud.isSpeaking {
            isLoading = false
            phase = .playing
        } else {
            phase = isLoading ? .loading : .idle
        }
        isSpeaking = (phase == .playing)
    }

    /// Route `text` to either the cloud engine or the local TTS engine depending
    /// on `settings.selectedEngine`.
    ///
    /// Cloud fallback triggers when:
    ///   - `kind` is not in `TTSProviderKind.implemented`
    ///   - `text.count > settings.cloudCharLimit`
    ///   - no API key is stored for `kind`
    ///   - the provider type lookup returns nil
    ///   - `cloud.speak(...)` returns `false`
    private func speakWithSelectedEngine(
        _ text: String,
        accent: SpeakAccent,
        settings: SpeakSettings,
        ttsConfig: TTSProviderConfig
    ) {
        switch settings.selectedEngine {
        case .system:
            speakWithTTS(text, accent: accent, settings: settings)

        case .cloud(let kind):
            // Guard 1: provider must be fully implemented.
            guard TTSProviderKind.implemented.contains(kind) else {
                didFallBackToSystem = true
                speakWithTTS(text, accent: accent, settings: settings)
                return
            }
            // Guard 2: text within the cloud character limit.
            guard text.count <= settings.cloudCharLimit else {
                didFallBackToSystem = true
                speakWithTTS(text, accent: accent, settings: settings)
                return
            }
            // Guard 3: API key must be present and non-empty.
            guard let apiKey = keychain.key(account: kind.keychainAccount),
                  !apiKey.isEmpty else {
                didFallBackToSystem = true
                speakWithTTS(text, accent: accent, settings: settings)
                return
            }
            // Guard 4: a provider type must exist for this kind.
            guard let providerType = Self.providerType(for: kind) else {
                didFallBackToSystem = true
                speakWithTTS(text, accent: accent, settings: settings)
                return
            }

            // All guards passed — launch the cloud Task.
            let capturedText    = text
            let capturedAccent  = accent
            let capturedConfig  = ttsConfig
            let capturedProvider = providerType
            let capturedKey     = apiKey
            let capturedSettings = settings
            cloudTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let ok = await cloud.speak(
                    text: capturedText,
                    languageCode: capturedAccent.bcp47,
                    provider: capturedProvider,
                    config: capturedConfig,
                    apiKey: capturedKey
                )
                guard !Task.isCancelled else { return }
                if ok {
                    // Cloud cached its audio in speak(); enable cache-backed replay.
                    replaySource = .cloudCache
                    canReplay = true
                } else {
                    didFallBackToSystem = true
                    speakWithTTS(capturedText, accent: capturedAccent, settings: capturedSettings)
                }
            }
        }
    }

    /// Dispatch `text` to the local TTS engine, selecting the appropriate voice.
    ///
    /// Voice selection:
    ///   - If `settings.defaultVoiceID` is set AND the requested `accent` is the
    ///     default accent → use the stored voice identifier (may be nil if not
    ///     installed, which AVFoundation handles gracefully by using its default).
    ///   - Otherwise → `VoiceCatalog.bestVoice(for: accent)`.
    private func speakWithTTS(_ text: String, accent: SpeakAccent, settings: SpeakSettings) {
        let voice: AVSpeechSynthesisVoice?
        if let voiceID = settings.defaultVoiceID, accent == settings.defaultAccent {
            voice = VoiceCatalog.voice(forIdentifier: voiceID)
        } else {
            voice = VoiceCatalog.bestVoice(for: accent)
        }
        // System voice is the actual backend (direct selection OR cloud fallback):
        // replay re-synthesises locally, never re-routing through the cloud.
        replaySource = .system
        canReplay = true
        tts.speak(text, voice: voice, rate: settings.rate, pitch: settings.pitch)
    }

    /// Returns `true` if `text` qualifies as a single spoken word:
    ///   - Non-empty
    ///   - No internal whitespace
    ///   - Length ≤ 45 characters
    ///   - Every character is a Unicode letter, `-`, or `'`
    nonisolated static func isSingleWord(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard text.count <= 45 else { return false }
        // Reject if any whitespace exists internally (already trimmed externally).
        guard !text.unicodeScalars.contains(where: { CharacterSet.whitespaces.contains($0) }) else {
            return false
        }
        // All scalars must be letters, hyphen (-), or apostrophe (').
        let allowed: CharacterSet = CharacterSet.letters
            .union(CharacterSet(charactersIn: "-'"))
        return text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Maps a `TTSProviderKind` to the corresponding `TTSProvider` type.
    ///
    /// Returns a non-nil type for every implemented provider (openAITTS,
    /// googleCloudTTS, and azureTTS). `nonisolated static` so it can be
    /// called from test code and from `nonisolated` contexts without a main-actor hop.
    nonisolated static func providerType(for kind: TTSProviderKind) -> (any TTSProvider.Type)? {
        switch kind {
        case .openAITTS:      return OpenAITTSProvider.self
        case .googleCloudTTS: return GoogleCloudTTSProvider.self
        case .azureTTS:       return AzureTTSProvider.self
        }
    }
}
