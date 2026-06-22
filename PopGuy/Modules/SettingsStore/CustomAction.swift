// CustomAction.swift
// PopGuy — SettingsStore
//
// User-defined action model.
//
// Isolation: nonisolated / Sendable value type — pure data that crosses actor
// boundaries between SettingsStore (@MainActor) and ActionEngine (nonisolated).
//
// NOTE: API keys are NOT stored here. The providerKind key is fetched from
// KeychainManager at dispatch time in ActionEngineHandler.

import Foundation

// MARK: - CustomActionType

/// Discriminator for user-defined actions.
///
/// - ai:          Free-form system prompt sent to an AI model.
/// - translation: Structured translation request (DeepL / Google / AI providers).
/// - speech:      Text-to-speech synthesis (no AI provider; uses SpeakEngine).
/// - dictionary:  Dictionary lookup (no AI provider; uses DictionaryEngine).
/// - openURL:     Opens a URL (with optional text interpolation) in the default browser.
/// - runShortcut: Runs a named Apple Shortcut with the selected text as input.
/// - appleScript: Executes an AppleScript snippet with the selected text available.
/// - shellScript: Runs a shell command/script with the selected text piped as stdin.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum CustomActionType: String, Sendable, Codable, CaseIterable, Identifiable {
    case ai
    case translation
    case speech
    case dictionary
    case openURL
    case runShortcut
    case appleScript
    case shellScript

    nonisolated var id: String { rawValue }

    /// User-visible label for the type picker.
    nonisolated var displayName: String {
        switch self {
        case .ai:          return "AI"
        case .translation: return "Translation"
        case .speech:      return "Speech"
        case .dictionary:  return "Dictionary"
        case .openURL:     return "Open URL"
        case .runShortcut: return "Run Shortcut"
        case .appleScript: return "AppleScript"
        case .shellScript: return "Shell Script"
        }
    }
}

// MARK: - AfterRunBehavior

/// What to do with the output produced by a scriptable action.
///
/// - closeToolbar: Discard any output and dismiss the toolbar (the default).
/// - none:         Discard any output and keep the toolbar open.
/// - copyResult:   Place the output on the clipboard; keep the toolbar open.
/// - pasteResult:  Paste the output back into the source application; keep the toolbar open.
/// - showResult:   Display the output in the toolbar result area.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum AfterRunBehavior: String, Sendable, Codable, CaseIterable, Identifiable {
    case closeToolbar
    case none
    case copyResult
    case pasteResult
    case showResult

    nonisolated var id: String { rawValue }

    /// User-visible label for the picker.
    nonisolated var displayName: String {
        switch self {
        case .closeToolbar: return "Close toolbar"
        case .none:         return "Do nothing"
        case .copyResult:   return "Copy result"
        case .pasteResult:  return "Paste result"
        case .showResult:   return "Show result"
        }
    }
}

// MARK: - CustomAction

/// A user-defined action.
///
/// - AI:          Sends a custom system prompt to an AI model.
/// - Translation: Dispatches a structured translation request (targetLanguage + tone).
/// - Speech:      Synthesises text via SpeakEngine (no ProviderKind).
/// - Dictionary:  Looks up definitions via DictionaryEngine (no ProviderKind).
/// - Open URL:    Opens a URL (with optional text interpolation) in the default browser.
/// - Run Shortcut: Runs a named Apple Shortcut with the selected text as input.
/// - AppleScript: Executes an AppleScript snippet with the selected text available.
/// - Shell Script: Runs a shell command/script with the selected text piped as stdin.
///
/// Backward-compat: blobs stored by older builds have no `type` key and decode
/// as `.ai` with all existing fields intact.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct CustomAction: Codable, Sendable, Identifiable, Equatable {

    /// Stable unique identifier — used as the action identity in shortcut bindings.
    let id: UUID

    /// User-visible name shown in the toolbar button label.
    var title: String

    /// Optional short description shown under the action title in Settings.
    /// Purely informational — not sent to the AI provider.
    var actionDescription: String

    /// Icon displayed on the toolbar button.
    var icon: ActionIcon

    /// Action type — determines which fields are active and which provider is used.
    var type: CustomActionType

    /// The system prompt (AI) or additional instructions (Translation).
    /// Required and non-empty for AI actions; optional for Translation; unused for Speech.
    /// Treated as untrusted UI-authored text at dispatch — never executed as code.
    var systemPrompt: String

    /// The AI or translation provider that executes this action.
    var providerKind: ProviderKind

    /// The model identifier (e.g. "gpt-4o", "claude-sonnet-4-6").
    var model: String

    /// Whether this action is shown in the floating toolbar.
    var isEnabled: Bool

    // MARK: Translation fields

    /// BCP-47 target language code for Translation actions (e.g. "en", "fr").
    var targetLanguage: String

    /// Tone applied when translating text.
    var tone: TranslateTone

    // MARK: Speech fields

    /// Speech synthesis settings (engine, voice, speed, pitch) for Speech actions.
    var speakSettings: SpeakSettings

    /// Cloud TTS provider configuration for Speech actions.
    var ttsConfig: TTSProviderConfig

    // MARK: Dictionary fields

    /// Dictionary lookup configuration for Dictionary actions.
    var dictionaryConfig: DictionaryConfig

    // MARK: Scriptable action fields

    /// The URL template, shortcut name, AppleScript source, or shell command for
    /// scriptable action types (.openURL, .runShortcut, .appleScript, .shellScript).
    /// Semantics depend on `type`; unused for AI/Translation/Speech/Dictionary actions.
    var scriptSource: String

    /// What to do with any output produced by a scriptable action.
    var afterRun: AfterRunBehavior

    /// When non-empty, the action is visible in the toolbar only when the selected
    /// text matches this regular expression. Empty string means always visible.
    /// Applied in a later phase — stored here for forward-compat.
    var appliesWhenRegex: String

    /// True when this action was added by importing a plugin/extension (native JSON
    /// or a PopClip extension). Drives the "From plugin" badge in Settings.
    /// Backward-compat: absent in older blobs → decoded as `false`.
    var isFromPlugin: Bool

    init(
        id: UUID = UUID(),
        title: String,
        actionDescription: String = "",
        icon: ActionIcon = .default,
        type: CustomActionType = .ai,
        systemPrompt: String,
        providerKind: ProviderKind = .anthropic,
        model: String = "claude-sonnet-4-6",
        isEnabled: Bool = true,
        targetLanguage: String = "en",
        tone: TranslateTone = .neutral,
        speakSettings: SpeakSettings = .default,
        ttsConfig: TTSProviderConfig = .default,
        dictionaryConfig: DictionaryConfig = .default,
        scriptSource: String = "",
        afterRun: AfterRunBehavior = .closeToolbar,
        appliesWhenRegex: String = "",
        isFromPlugin: Bool = false
    ) {
        self.id = id
        self.title = title
        self.actionDescription = actionDescription
        self.icon = icon
        self.type = type
        self.systemPrompt = systemPrompt
        self.providerKind = providerKind
        self.model = model
        self.isEnabled = isEnabled
        self.targetLanguage = targetLanguage
        self.tone = tone
        self.speakSettings = speakSettings
        self.ttsConfig = ttsConfig
        self.dictionaryConfig = dictionaryConfig
        self.scriptSource = scriptSource
        self.afterRun = afterRun
        self.appliesWhenRegex = appliesWhenRegex
        self.isFromPlugin = isFromPlugin
    }

    // MARK: - Codable (with backward-compat migration)

    private enum CodingKeys: String, CodingKey {
        case id, title, actionDescription, icon, systemPrompt, providerKind, model, isEnabled
        // Discriminator — absent in blobs written by older builds (decode as .ai).
        case type
        // Translation fields.
        case targetLanguage, tone
        // Speech fields.
        case speakSettings, ttsConfig
        // Dictionary fields.
        case dictionaryConfig
        // Scriptable action fields — absent in blobs written by older builds.
        case scriptSource, afterRun, appliesWhenRegex
        // Plugin-import marker — absent in blobs written by older builds (decode as false).
        case isFromPlugin
        // Legacy key written by older builds.
        case iconSystemName
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id           = try container.decode(UUID.self,        forKey: .id)
        title        = try container.decode(String.self,      forKey: .title)
        // Optional + added later: absent in actions saved by older builds.
        actionDescription = try container.decodeIfPresent(String.self, forKey: .actionDescription) ?? ""
        systemPrompt = try container.decode(String.self,      forKey: .systemPrompt)
        providerKind = try container.decode(ProviderKind.self, forKey: .providerKind)
        model        = try container.decode(String.self,      forKey: .model)
        isEnabled    = try container.decode(Bool.self,        forKey: .isEnabled)

        // Prefer the new `icon` key; fall back to the legacy `iconSystemName` string.
        if let newIcon = try container.decodeIfPresent(ActionIcon.self, forKey: .icon) {
            icon = newIcon
        } else if let legacyName = try container.decodeIfPresent(String.self, forKey: .iconSystemName) {
            icon = .sfSymbol(legacyName)
        } else {
            icon = .default
        }

        // Discriminator — old blobs have no key; treat as .ai.
        type = try container.decodeIfPresent(CustomActionType.self, forKey: .type) ?? .ai

        // Translation fields — absent in old blobs and in AI/Speech actions.
        targetLanguage = try container.decodeIfPresent(String.self,       forKey: .targetLanguage) ?? "en"
        tone           = try container.decodeIfPresent(TranslateTone.self, forKey: .tone)           ?? .neutral

        // Speech fields — absent in old blobs and in AI/Translation actions.
        speakSettings = try container.decodeIfPresent(SpeakSettings.self,     forKey: .speakSettings) ?? .default
        ttsConfig     = try container.decodeIfPresent(TTSProviderConfig.self,  forKey: .ttsConfig)     ?? .default

        // Dictionary fields — absent in old blobs and in non-Dictionary actions.
        dictionaryConfig = try container.decodeIfPresent(DictionaryConfig.self, forKey: .dictionaryConfig) ?? .default

        // Scriptable action fields — absent in blobs written by older builds.
        scriptSource       = try container.decodeIfPresent(String.self,           forKey: .scriptSource)       ?? ""
        afterRun           = try container.decodeIfPresent(AfterRunBehavior.self,  forKey: .afterRun)           ?? .none
        appliesWhenRegex   = try container.decodeIfPresent(String.self,           forKey: .appliesWhenRegex)   ?? ""
        isFromPlugin       = try container.decodeIfPresent(Bool.self,             forKey: .isFromPlugin)       ?? false
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id,                forKey: .id)
        try container.encode(title,             forKey: .title)
        try container.encode(actionDescription, forKey: .actionDescription)
        try container.encode(icon,              forKey: .icon)
        try container.encode(systemPrompt,      forKey: .systemPrompt)
        try container.encode(providerKind,      forKey: .providerKind)
        try container.encode(model,             forKey: .model)
        try container.encode(isEnabled,         forKey: .isEnabled)
        try container.encode(type,              forKey: .type)
        try container.encode(targetLanguage,    forKey: .targetLanguage)
        try container.encode(tone,              forKey: .tone)
        try container.encode(speakSettings,     forKey: .speakSettings)
        try container.encode(ttsConfig,         forKey: .ttsConfig)
        try container.encode(dictionaryConfig,  forKey: .dictionaryConfig)
        try container.encode(scriptSource,      forKey: .scriptSource)
        try container.encode(afterRun,          forKey: .afterRun)
        try container.encode(appliesWhenRegex,  forKey: .appliesWhenRegex)
        try container.encode(isFromPlugin,      forKey: .isFromPlugin)
    }
}

// MARK: - Save validation

extension CustomAction {

    /// Whether the action has enough data to be saved.
    ///
    /// - AI:          Title and system prompt must both be non-empty (after trimming).
    /// - Translation: Title must be non-empty.
    /// - Speech:      Title must be non-empty.
    /// - Dictionary:  Title must be non-empty.
    /// - Open URL:    Title and scriptSource must both be non-empty (after trimming).
    /// - Run Shortcut: Title and scriptSource must both be non-empty (after trimming).
    /// - AppleScript: Title and scriptSource must both be non-empty (after trimming).
    /// - Shell Script: Title and scriptSource must both be non-empty (after trimming).
    ///
    /// Pure, nonisolated — safe to call from any actor or in tests without UI.
    nonisolated var isSaveable: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch type {
        case .ai:
            return !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .translation, .speech, .dictionary:
            return true
        case .openURL, .runShortcut, .appleScript, .shellScript:
            return !scriptSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

// MARK: - Visibility filter

// MARK: Regex cache

/// Process-wide cache mapping a regex pattern string → compiled NSRegularExpression?
/// (nil is cached for invalid patterns so they still fail open without recompiling).
///
/// Thread-safety: all accesses are serialised through `lock`.
/// @unchecked Sendable: the stored dictionary is guarded by NSLock — same pattern as RunState.
/// Cap: 64 entries; evict-all on overflow to bound memory growth.
private final class RegexCache: @unchecked Sendable {

    // nonisolated(unsafe): SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor would otherwise
    // infer MainActor isolation. The NSLock serialises all accesses.
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var store: [String: NSRegularExpression?] = [:]

    // nonisolated: static constant on a Sendable class — safe to read from any context.
    nonisolated private static let maxEntries = 64

    /// Returns the compiled regex for `pattern`, compiling and caching on first access.
    /// Returns `nil` if `pattern` is invalid (nil is cached so the next call is fast).
    ///
    /// Store type is `[String: NSRegularExpression?]` (optional value). Subscript
    /// returns `NSRegularExpression??` — a double-optional:
    ///   - `nil`          → key absent (not yet compiled)
    ///   - `.some(nil)`   → key present, cached nil (invalid pattern)
    ///   - `.some(regex)` → key present, valid compiled regex
    nonisolated func regex(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }

        // Check whether the key is already in the cache (including cached-nil entries).
        // store[pattern] returns NSRegularExpression?? (double-optional):
        //   .some(let inner) → key present; inner is the cached value (may be nil).
        //   nil              → key absent.
        if let cachedEntry = store[pattern] {
            // Key present — return the inner value directly (may be nil for invalid patterns).
            return cachedEntry
        }

        // Not yet in cache — compile and cache.
        if store.count >= RegexCache.maxEntries { store.removeAll() }
        let compiled = try? NSRegularExpression(pattern: pattern)
        store[pattern] = compiled   // stores NSRegularExpression? (nil or valid)
        return compiled
    }
}

extension CustomAction {

    // nonisolated: SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor infers MainActor on static
    // stored properties; mark nonisolated so isVisible (nonisolated func) can access them.
    nonisolated private static let regexCache = RegexCache()

    /// Maximum number of characters of the selection that the visibility regex tests.
    /// Visibility patterns (paths, URLs, emails) match near the start; bounding the
    /// input prevents catastrophic backtracking on large selections.
    nonisolated static let maxRegexInputLength = 4096

    /// True when this action is one of the four scriptable types that support
    /// the `appliesWhenRegex` visibility filter.
    nonisolated var isScriptable: Bool {
        type == .openURL || type == .runShortcut || type == .appleScript || type == .shellScript
    }

    /// True when the action should appear in the toolbar for the given selection text.
    ///
    /// Rules:
    /// - Non-scriptable types (ai, translation, speech, dictionary) are always visible —
    ///   `appliesWhenRegex` has no effect on them.
    /// - Scriptable types with an empty `appliesWhenRegex` are always visible.
    /// - Scriptable types with a non-empty `appliesWhenRegex` are visible only when
    ///   the (truncated) selection text has at least one match for that regex.
    ///
    /// Malformed regex: fails **open** (returns true, action is shown). A user-typed bad
    /// pattern should not silently hide the action — they will see the button and can
    /// return to Settings to fix the regex.
    ///
    /// Performance notes:
    /// - Compiled regexes are cached process-wide (keyed by pattern) to avoid repeated
    ///   compilation on every selection event.
    /// - The tested input is capped to `maxRegexInputLength` characters (via
    ///   `String.prefix`) to bound the cost of catastrophic-backtracking patterns on
    ///   large selections. Visibility patterns (paths, URLs) match near the start, so
    ///   this is lossless for all well-behaved patterns.
    ///
    /// Security note — cosmetic filter only:
    /// - This is a COSMETIC toolbar filter, NOT an execution gate. A regex-hidden action
    ///   whose hotkey is invoked directly still runs — `dispatchAction` resolves by
    ///   uuid + isEnabled and does not consult `isVisible`.
    /// - A deliberately catastrophic LOCAL pattern (e.g. `(a+)+$`) can still hang the
    ///   event loop when matched against long input. This is self-inflicted (like an
    ///   infinite loop in a user shell action) and accepted for V1.
    nonisolated func isVisible(forSelection text: String) -> Bool {
        guard isScriptable, !appliesWhenRegex.isEmpty else { return true }
        // Look up (or compile) the regex in the process-wide cache.
        // Fail open when the pattern is invalid — nil from cache means invalid.
        guard let regex = Self.regexCache.regex(for: appliesWhenRegex) else { return true }
        // Truncate the tested input to bound backtracking cost on large selections.
        let searched = String(text.prefix(CustomAction.maxRegexInputLength))
        let range = NSRange(searched.startIndex..., in: searched)
        return regex.firstMatch(in: searched, range: range) != nil
    }

    /// Filters `actions` to those visible for the given selection text.
    ///
    /// Pure helper — use from every visibility-filter site so the two call sites in
    /// ToolbarController (customActions and orderedActions) can't diverge.
    nonisolated static func visible(_ actions: [CustomAction], forSelection text: String) -> [CustomAction] {
        actions.filter { $0.isVisible(forSelection: text) }
    }
}

// MARK: - Type-aware provider validation

extension CustomAction {
    /// Provider kinds valid for a given action type.
    ///
    /// - ai:          Delegates to ActionKind.improve.allowedProviders — same set as
    ///                built-in AI actions (Improve, Shorten, Proofread, Prompt).
    /// - translation: Delegates to ActionKind.translate.allowedProviders — all providers
    ///                including dedicated translation services.
    /// - speech:      No ProviderKind; speech uses SpeakEngineSelection.
    /// - dictionary:  No ProviderKind; dictionary uses DictionaryProviderKind.
    nonisolated static func allowedProviders(for type: CustomActionType) -> [ProviderKind] {
        switch type {
        case .ai:
            return ActionKind.improve.allowedProviders
        case .translation:
            return ActionKind.translate.allowedProviders
        case .speech, .dictionary, .openURL, .runShortcut, .appleScript, .shellScript:
            return []
        }
    }

    /// Convenience accessor — resolves allowed providers for this action's type.
    nonisolated var allowedProviders: [ProviderKind] {
        Self.allowedProviders(for: type)
    }
}

// MARK: - Import sanitization

extension CustomAction {

    /// Validates and sanitises an action decoded from an untrusted import file.
    ///
    /// This is the sole security gate for the import path. It:
    /// - Rejects `.ai` / `.translation` actions whose `providerKind` is not in the
    ///   allowed set for their type (returns `nil`).
    /// - Accepts `.speech` / `.dictionary` actions unconditionally — they have no
    ///   ProviderKind constraint — but clamps cloud speech engines to `.system`
    ///   when the importing user is not Pro.
    /// - Regenerates the `id` so an imported action never collides with an existing one.
    /// - Bounds all unbounded string fields to prevent UserDefaults bloat.
    ///   String fields are bounded regardless of type — a tampered file can attach
    ///   oversized `ttsConfig`/`speakSettings` to any action type.
    ///
    /// - Parameters:
    ///   - action:       The decoded (untrusted) action.
    ///   - cloudAllowed: Whether the importing user's entitlements permit cloud TTS.
    ///                   Pass `licenseGate.entitlements.cloudTTSPremiumAllowed`.
    /// - Returns: A sanitised copy with a fresh UUID, or `nil` when the action
    ///            has a provider that is disallowed for its type.
    nonisolated static func sanitizeImported(
        _ action: CustomAction,
        cloudAllowed: Bool
    ) -> CustomAction? {

        // --- Provider validation (type-aware) ---

        switch action.type {
        case .ai, .translation:
            // For AI and Translation actions the provider must be in the allowed list.
            guard Self.allowedProviders(for: action.type).contains(action.providerKind) else {
                return nil
            }
        case .speech, .dictionary, .openURL, .runShortcut, .appleScript, .shellScript:
            // These types have no ProviderKind constraint; never reject on provider.
            break
        }

        // --- Icon bounding ---

        let safeIcon: ActionIcon = {
            switch action.icon {
            case .sfSymbol(let name): return .sfSymbol(String(name.prefix(100)))
            case .emoji(let char):    return .emoji(String(char.prefix(8)))
            }
        }()

        // --- ttsConfig bounding (applied regardless of type — any typed blob can
        //     carry this field and a tampered value must not bloat UserDefaults) ---

        var safeTTSConfig = action.ttsConfig
        if let model = safeTTSConfig.model {
            safeTTSConfig.model = String(model.prefix(200))
        }
        if let voice = safeTTSConfig.defaultVoice {
            safeTTSConfig.defaultVoice = String(voice.prefix(100))
        }
        if let region = safeTTSConfig.region {
            safeTTSConfig.region = String(region.prefix(50))
        }
        // Cap voice-override entry count and bound both key and value strings.
        // Two distinct long keys can collapse after prefixing, so use
        // uniquingKeysWith to keep the last entry when that happens.
        // prefix(20) is a no-op for ≤20 entries, so one unconditional pass covers all cases.
        safeTTSConfig.voiceOverrides = Dictionary(
            safeTTSConfig.voiceOverrides.prefix(20).map { (String($0.key.prefix(20)), String($0.value.prefix(100))) },
            uniquingKeysWith: { _, last in last }
        )

        // --- speakSettings bounding + cloud-gate clamp ---
        // All unbounded string fields are capped regardless of action type —
        // a tampered file can attach oversized speakSettings to any action.

        let safeSpeakSettings = sanitizedSpeakSettings(action.speakSettings, cloudAllowed: cloudAllowed)

        // --- dictionaryConfig bounding + cloud-gate clamp ---

        var safeDictionaryConfig = action.dictionaryConfig
        safeDictionaryConfig.definitionLanguage = String(safeDictionaryConfig.definitionLanguage.prefix(20))
        safeDictionaryConfig.speakSettings = sanitizedSpeakSettings(
            safeDictionaryConfig.speakSettings,
            cloudAllowed: cloudAllowed
        )

        // --- Construct the sanitised action with a fresh UUID ---

        return CustomAction(
            id: UUID(),
            title: String(action.title.prefix(100)),
            actionDescription: String(action.actionDescription.prefix(500)),
            icon: safeIcon,
            type: action.type,
            systemPrompt: String(action.systemPrompt.prefix(10000)),
            providerKind: action.providerKind,
            model: String(action.model.prefix(200)),
            isEnabled: action.isEnabled,
            targetLanguage: String(action.targetLanguage.prefix(20)),
            tone: action.tone,
            speakSettings: safeSpeakSettings,
            ttsConfig: safeTTSConfig,
            dictionaryConfig: safeDictionaryConfig,
            scriptSource: String(action.scriptSource.prefix(20000)),
            afterRun: action.afterRun,
            appliesWhenRegex: String(action.appliesWhenRegex.prefix(500))
        )
    }

    nonisolated private static func sanitizedSpeakSettings(
        _ settings: SpeakSettings,
        cloudAllowed: Bool
    ) -> SpeakSettings {
        var safe = settings.resolvingCloudGate(cloudAllowed: cloudAllowed)
        if let voiceID = safe.defaultVoiceID {
            safe.defaultVoiceID = String(voiceID.prefix(100))
        }
        // quickSwitchAccents: enum-validated on decode (unknown rawValues are
        // dropped by compactMap), but duplicates are allowed and the array is
        // unbounded. Cap to a sane count to prevent UserDefaults bloat.
        if safe.quickSwitchAccents.count > 20 {
            safe.quickSwitchAccents = Array(safe.quickSwitchAccents.prefix(20))
        }
        return safe
    }
}

// MARK: - ActionIdentifier

/// A stable identifier for any action — built-in or user-defined.
///
/// Used as the key in shortcut bindings so both `ActionKind` cases and custom
/// action UUIDs can share one Codable dictionary / array.
///
/// JSON encoding: enum key → "improve", "translate", or a UUID string.
/// Stored as an array of `{id, shortcut}` structs (not a dict) because Swift
/// Codable does not round-trip enum keys in dictionaries out of the box.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum ActionIdentifier: Sendable, Hashable, Codable, Equatable {
    case builtin(ActionKind)
    case custom(UUID)
    case speak
    case dictionary

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case type, value }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let kind):
            try container.encode("builtin", forKey: .type)
            try container.encode(kind.rawValue, forKey: .value)
        case .custom(let uuid):
            try container.encode("custom", forKey: .type)
            try container.encode(uuid.uuidString, forKey: .value)
        case .speak:
            try container.encode("speak", forKey: .type)
        case .dictionary:
            try container.encode("dictionary", forKey: .type)
        }
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type_ = try container.decode(String.self, forKey: .type)
        // Note: `value` is decoded inside each branch that requires it.
        // `.speak` has no associated value and writes no `value` key, so
        // decoding it unconditionally before the switch would throw keyNotFound.
        switch type_ {
        case "speak":
            self = .speak
        case "dictionary":
            self = .dictionary
        case "builtin":
            let value = try container.decode(String.self, forKey: .value)
            guard let kind = ActionKind(rawValue: value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Unknown ActionKind: \(value)"
                )
            }
            self = .builtin(kind)
        case "custom":
            let value = try container.decode(String.self, forKey: .value)
            guard let uuid = UUID(uuidString: value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Invalid UUID: \(value)"
                )
            }
            self = .custom(uuid)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown ActionIdentifier type: \(type_)"
            )
        }
    }
}
