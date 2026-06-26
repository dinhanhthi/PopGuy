// SettingsStore.swift
// PopGuy — SettingsStore
//
// Persists non-secret configuration via UserDefaults.
//
// HARD CONSTRAINT: API keys are NEVER stored here. They go through KeychainManager.
//
// Stored items:
//   - Per-action provider+model mapping (ActionConfig per ActionKind)
//   - Default translate target language (BCP-47 string, e.g. "en")
//   - User-loaded Babylon .bgl dictionary metadata
//   - Ollama base URL string
//   - Enabled state for built-in actions
//   - Ordered list of user-defined custom actions ([CustomAction])
//   - Shortcut bindings ([ShortcutBinding]) — action id → keyboard shortcut
//   - Ignored app bundle IDs ([String]) — apps where the popup is suppressed
//   - Trigger flags: text-select on/off, Cmd+C+C chord on/off
//   - Optional chord-replacement shortcut (KeyboardShortcut?)
//
// Isolation: @MainActor — SettingsStore is app-wide state consumed by SwiftUI views
// and ToolbarViewModel. Marking it @MainActor matches SWIFT_DEFAULT_ACTOR_ISOLATION
// = MainActor and makes @Published properties safe to observe.
//
// ActionEngine reads a Sendable snapshot (ActionConfig + String) synchronously
// on the MainActor via the wiring in ActionEngineHandler, so no actor hop is
// needed at dispatch time.
//
// Local (MLX) model state:
//   - completedLocalModelIDs: Set<String>  — PERSISTED set of successfully-downloaded model ids
//                                            (source of truth for installation status)
//   - installedLocalModels: Set<String>  — PUBLISHED cache: completedLocalModelIDs reconciled
//                                          with disk (ids whose model dir no longer exists are dropped)
//   - localModelDownloadProgress: [String: Double]  — transient, cleared on completion
//   - activeLocalModelDownloadID: String?  — which model is being downloaded
//   - localModelDownloadError: String?  — last download error message

import Foundation
import Combine

// MARK: - ResultFontSize

/// Font size for the result body rendered in the floating toolbar.
///
/// nonisolated: this is model-layer data persisted by SettingsStore; the
/// SwiftUI `Font` mapping lives in the view layer (ToolbarView).
nonisolated enum ResultFontSize: String, CaseIterable, Identifiable, Codable {
    case small
    case normal
    case big

    var id: String { rawValue }

    /// User-facing label for the Appearance picker.
    var displayName: String {
        switch self {
        case .small:  return "Small"
        case .normal: return "Normal"
        case .big:    return "Big"
        }
    }
}

// MARK: - ToolbarZoom

/// Zoom level applied to the entire floating toolbar (chrome + optionally the
/// result font). The view layer (ToolbarView) consumes `scale`.
nonisolated enum ToolbarZoom: String, CaseIterable, Identifiable, Codable {
    case x1
    case x1_2
    case x1_3

    var id: String { rawValue }

    /// Multiplier applied to toolbar dimensions and fonts.
    var scale: CGFloat {
        switch self {
        case .x1:   return 1.0
        case .x1_2: return 1.2
        case .x1_3: return 1.3
        }
    }

    /// User-facing label for the Appearance picker.
    var displayName: String {
        switch self {
        case .x1:   return "1×"
        case .x1_2: return "1.2×"
        case .x1_3: return "1.3×"
        }
    }
}

// MARK: - LocalModelAvailability

/// Decision returned by `SettingsStore.availability(for:isPro:)`.
///
/// Checked in this priority order:
///  1. Capability (MLX supported on this Mac?)
///  2. Licensing (Pro model but user is not Pro?)
///  3. Available (all clear)
///
/// `nonisolated` so views can pattern-match on it without an actor hop.
nonisolated enum LocalModelAvailability: Sendable {
    /// MLX is not supported on this Mac (e.g. Intel or macOS < 14).
    case unsupported(reason: String)
    /// The model requires Pro and the user is on the free plan.
    case proLocked
    /// The model can be downloaded or used.
    case available
}

// MARK: - SettingsStore

/// Observable store for non-secret PopGuy configuration.
///
/// Backed by an injectable `UserDefaults` instance so tests can use a unique
/// ephemeral suite without touching real app preferences.
@MainActor
final class SettingsStore: ObservableObject {

    // MARK: - Keys

    private enum Keys {
        static let improveConfig              = "settings.improveConfig"
        static let shortenConfig              = "settings.shortenConfig"
        static let proofreadConfig            = "settings.proofreadConfig"
        static let translateConfig            = "settings.translateConfig"
        static let targetLanguage             = "settings.targetLanguage"
        static let ollamaBaseURL              = "settings.ollamaBaseURL"
        static let customBaseURL              = "settings.customBaseURL"
        static let improveEnabled             = "settings.improveEnabled"
        static let shortenEnabled             = "settings.shortenEnabled"
        static let proofreadEnabled           = "settings.proofreadEnabled"
        static let translateEnabled           = "settings.translateEnabled"
        static let speakEnabled               = "settings.speakEnabled"
        static let promptEnabled              = "settings.promptEnabled"
        static let promptConfig               = "settings.promptConfig"
        static let speakSettings              = "settings.speakSettings"
        static let dictionaryConfig           = "settings.dictionaryConfig"
        static let babylonDictionaries        = "settings.babylonDictionaries"
        static let customActions              = "settings.customActions"
        static let shortcutBindings           = "settings.shortcutBindings"
        static let hasOnboarded               = "settings.hasOnboarded"
        static let ignoredAppBundleIDs        = "settings.ignoredAppBundleIDs"
        static let ignoredDomains             = "settings.ignoredDomains"
        static let ignoredDomainsEnabled      = "settings.ignoredDomainsEnabled"
        static let popGuyEnabled              = "settings.popGuyEnabled"
        static let triggerOnSelect            = "settings.triggerOnSelect"
        static let triggerDoubleClick         = "settings.triggerDoubleClick"
        static let doubleClickAssignedAction  = "settings.doubleClickAssignedAction"
        static let triggerChord               = "settings.triggerChord"
        static let chordReplacementShortcut   = "settings.chordReplacementShortcut"
        static let confirmCloseAfterResult    = "settings.confirmCloseAfterResult"
        static let showDockIconWithSettings   = "settings.showDockIconWithSettings"
        static let resultFontSize             = "settings.resultFontSize"
        static let preserveFormatting         = "settings.preserveFormatting"
        static let toolbarZoom                = "settings.toolbarZoom"
        static let zoomIncludesFontSize       = "settings.zoomIncludesFontSize"
        static let claudeCLIPath              = "settings.claudeCLIPath"
        static let codexCLIPath               = "settings.codexCLIPath"
        static let geminiCLIPath              = "settings.geminiCLIPath"
        static let ttsProviderConfigs         = "settings.ttsProviderConfigs"
        static let historyEnabled             = "settings.historyEnabled"
        static let historyStoreFullText       = "settings.historyStoreFullText"
        static let actionOrder                = "settings.actionOrder"
        static let principalActionIDs         = "settings.principalActionIDs"
        static let actCount                   = "settings.actCount"
        static let completedLocalModelIDs     = "settings.completedLocalModelIDs"
        static let localModelIdleSeconds      = "settings.localModelIdleSeconds"
    }

    // MARK: - Storage

    private let defaults: UserDefaults

    // MARK: - Local model dependencies (injectable for tests)

    /// MLXHelperManager used for install-detection, download, and delete.
    /// Defaults to the shared singleton; tests inject a stub.
    private let mlxHelper: MLXHelperManager

    /// Capability flag injected at init so tests can exercise all branches without
    /// depending on actual hardware. Production passes `MLXCapability.isSupported`.
    private let isMLXSupported: Bool

    // MARK: - Local model state

    /// Persisted set of catalog model ids that have completed a successful download.
    ///
    /// This is the SOURCE OF TRUTH for which models are installed. A model is
    /// added here only when its download stream completes without error and without
    /// cancellation. `refreshInstalledLocalModels()` reconciles this set with disk
    /// (drops ids whose directory no longer exists) to detect external deletions.
    ///
    /// Persisted to UserDefaults so the installed status survives app restarts
    /// without rescanning disk every launch.
    private var completedLocalModelIDs: Set<String> {
        didSet {
            save(completedLocalModelIDs, key: Keys.completedLocalModelIDs)
        }
    }

    /// Catalog model ids confirmed as installed: the persisted completed set
    /// reconciled against disk. Published so the UI can observe changes.
    @Published private(set) var installedLocalModels: Set<String> = []

    /// Per-model download progress (0.0 … 1.0). Cleared on completion or error.
    @Published private(set) var localModelDownloadProgress: [String: Double] = [:]

    /// The model id currently being downloaded, or `nil` when idle.
    @Published private(set) var activeLocalModelDownloadID: String?

    /// Last download error message, or `nil` when the last download succeeded.
    @Published private(set) var localModelDownloadError: String?

    /// Idle timeout in seconds for the local MLX helper process. 0 = never unload.
    /// The UI should offer Never / 1 / 2 / 5 / 10 / 30 min options.
    @Published var localModelIdleSeconds: Int {
        didSet {
            defaults.set(localModelIdleSeconds, forKey: Keys.localModelIdleSeconds)
            let helper = mlxHelper
            let seconds = localModelIdleSeconds
            Task { await helper.applyIdleTimeoutChange(seconds) }
        }
    }

    /// The catalog model id currently loaded in the helper process, or nil when idle or not running.
    /// Updated by calling `refreshLoadedLocalModel()`.
    @Published private(set) var loadedLocalModelID: String?

    /// The running download Task. Retained so `cancelLocalModelDownload()` can cancel it.
    private var activeDownloadTask: Task<Void, Never>?

    /// Monotonically-incrementing token that identifies the current download.
    /// Each call to `downloadLocalModel` bumps this counter and captures a copy
    /// into the Task. Any cleanup/state write inside the Task is guarded on
    /// `myToken == downloadToken` so a cancelled/superseded download cannot
    /// null out a replacement download's `activeLocalModelDownloadID`, progress,
    /// or error.
    private var downloadToken: Int = 0

    // MARK: - Published properties

    /// Configuration for the Improve action.
    @Published var improveConfig: ActionConfig {
        didSet { save(improveConfig, key: Keys.improveConfig) }
    }

    /// Configuration for the Shorten action.
    @Published var shortenConfig: ActionConfig {
        didSet { save(shortenConfig, key: Keys.shortenConfig) }
    }

    /// Configuration for the Proofread action.
    @Published var proofreadConfig: ActionConfig {
        didSet { save(proofreadConfig, key: Keys.proofreadConfig) }
    }

    /// Configuration for the Translate action.
    @Published var translateConfig: ActionConfig {
        didSet { save(translateConfig, key: Keys.translateConfig) }
    }

    /// Default translate target language (BCP-47, e.g. "en", "fr", "vi").
    @Published var defaultTargetLanguage: String {
        didSet { defaults.set(defaultTargetLanguage, forKey: Keys.targetLanguage) }
    }

    /// Ollama base URL string (e.g. "http://localhost:11434/v1").
    @Published var ollamaBaseURL: String {
        didSet { defaults.set(ollamaBaseURL, forKey: Keys.ollamaBaseURL) }
    }

    /// Base URL for the Custom (OpenAI-compatible) provider (e.g. "http://myserver:8080/v1").
    /// Empty string means no endpoint has been configured yet.
    @Published var customBaseURL: String {
        didSet { defaults.set(customBaseURL, forKey: Keys.customBaseURL) }
    }

    /// Absolute path to the `claude` CLI binary (e.g. "~/.local/bin/claude").
    /// Empty string means the path is not configured; auto-detected on first launch.
    @Published var claudeCLIPath: String {
        didSet { defaults.set(claudeCLIPath, forKey: Keys.claudeCLIPath) }
    }

    /// Absolute path to the `codex` CLI binary (e.g. "~/.nvm/versions/node/v22.21.1/bin/codex").
    /// Empty string means the path is not configured; auto-detected on first launch.
    @Published var codexCLIPath: String {
        didSet { defaults.set(codexCLIPath, forKey: Keys.codexCLIPath) }
    }

    /// Absolute path to the `gemini` CLI binary (e.g. "~/.nvm/versions/node/v22.21.1/bin/gemini").
    /// Empty string means the path is not configured; auto-detected on first launch.
    @Published var geminiCLIPath: String {
        didSet { defaults.set(geminiCLIPath, forKey: Keys.geminiCLIPath) }
    }

    /// Whether the built-in Improve action is enabled in the toolbar.
    @Published var improveEnabled: Bool {
        didSet { defaults.set(improveEnabled, forKey: Keys.improveEnabled) }
    }

    /// Whether the built-in Shorten action is enabled in the toolbar.
    @Published var shortenEnabled: Bool {
        didSet { defaults.set(shortenEnabled, forKey: Keys.shortenEnabled) }
    }

    /// Whether the built-in Proofread action is enabled in the toolbar.
    @Published var proofreadEnabled: Bool {
        didSet { defaults.set(proofreadEnabled, forKey: Keys.proofreadEnabled) }
    }

    /// Whether the built-in Translate action is enabled in the toolbar.
    @Published var translateEnabled: Bool {
        didSet { defaults.set(translateEnabled, forKey: Keys.translateEnabled) }
    }

    /// Whether the built-in Speak action is enabled in the toolbar.
    @Published var speakEnabled: Bool {
        didSet { defaults.set(speakEnabled, forKey: Keys.speakEnabled) }
    }

    /// Whether the built-in Prompt action is enabled in the toolbar.
    @Published var promptEnabled: Bool {
        didSet { defaults.set(promptEnabled, forKey: Keys.promptEnabled) }
    }

    /// Configuration for the Prompt action.
    @Published var promptConfig: ActionConfig {
        didSet { save(promptConfig, key: Keys.promptConfig) }
    }

    /// Configuration for the Speak action (voice, rate, pitch, accent).
    @Published var speakSettings: SpeakSettings {
        didSet { save(speakSettings, key: Keys.speakSettings) }
    }

    /// Configuration for the Look up action (language, speech, legacy provider).
    @Published var dictionaryConfig: DictionaryConfig {
        didSet { save(dictionaryConfig, key: Keys.dictionaryConfig) }
    }

    /// User-loaded Babylon .bgl dictionaries. API keys are not involved; only
    /// metadata and language mappings are persisted.
    @Published var babylonDictionaries: [BabylonDictionary] {
        didSet { save(babylonDictionaries, key: Keys.babylonDictionaries) }
    }

    /// Per-provider cloud TTS configuration keyed by `TTSProviderKind.rawValue`.
    /// Missing entries fall back to `TTSProviderConfig.default` via `ttsConfig(for:)`.
    @Published var ttsProviderConfigs: [String: TTSProviderConfig] {
        didSet { save(ttsProviderConfigs, key: Keys.ttsProviderConfigs) }
    }

    /// Ordered list of user-defined custom actions.
    @Published var customActions: [CustomAction] {
        didSet { save(customActions, key: Keys.customActions) }
    }

    /// Shortcut bindings: each entry maps an action identifier to a shortcut.
    @Published var shortcutBindings: [ShortcutBinding] {
        didSet { save(shortcutBindings, key: Keys.shortcutBindings) }
    }

    /// Unified display order for all actions (built-ins and custom actions interleaved).
    /// Mutations are persisted via `didSet`. On load the value is computed by
    /// `reconcileOrder` — `didSet` does NOT fire on init assignment, so only
    /// subsequent mutations (addCustomAction, moveAction, deleteCustomAction) persist.
    /// `reconcileOrder` is deterministic and idempotent, so it recomputes to the
    /// same result on every fresh load.
    @Published private(set) var actionOrder: [ActionIdentifier] {
        didSet { save(actionOrder, key: Keys.actionOrder) }
    }

    /// Whether the user has completed the first-launch onboarding flow.
    /// Defaults to `false` on a fresh install; set to `true` when the onboarding
    /// window is closed so it is never shown again.
    @Published var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Keys.hasOnboarded) }
    }

    /// Bundle IDs of apps in which the floating popup is suppressed.
    @Published var ignoredAppBundleIDs: [String] {
        didSet { save(ignoredAppBundleIDs, key: Keys.ignoredAppBundleIDs) }
    }

    /// Domains for which the floating popup is suppressed when the frontmost browser is on that domain.
    @Published var ignoredDomains: [String] = [] {
        didSet { save(ignoredDomains, key: Keys.ignoredDomains) }
    }

    /// Master switch for the ignored-domains feature (default: false). While off,
    /// PopGuy never reads the browser tab URL, so macOS never prompts for the
    /// Automation permission. Must be opted in before any domain matching runs.
    @Published var ignoredDomainsEnabled: Bool {
        didSet { defaults.set(ignoredDomainsEnabled, forKey: Keys.ignoredDomainsEnabled) }
    }

    /// Master kill switch (default: true). When false, every trigger — text
    /// selection, double-click, the Cmd+C+C chord (and its replacement shortcut),
    /// and custom-action hotkeys — is suppressed and PopGuy stays idle until
    /// re-enabled.
    @Published var popGuyEnabled: Bool {
        didSet { defaults.set(popGuyEnabled, forKey: Keys.popGuyEnabled) }
    }

    /// Whether to trigger the popup on text selection (default: false).
    @Published var triggerOnSelectEnabled: Bool {
        didSet { defaults.set(triggerOnSelectEnabled, forKey: Keys.triggerOnSelect) }
    }

    /// Whether to trigger the popup on double-clicking a single word (default: false).
    /// Works alongside `triggerOnSelectEnabled`: a double-click fires when either
    /// trigger is on, while range selections use `triggerOnSelectEnabled`.
    @Published var triggerDoubleClickEnabled: Bool {
        didSet { defaults.set(triggerDoubleClickEnabled, forKey: Keys.triggerDoubleClick) }
    }

    /// Optional default action run when the double-click trigger fires. When set,
    /// a double-click runs this action directly instead of showing the toolbar.
    /// `nil` (default) shows the toolbar as usual.
    @Published var doubleClickAssignedAction: ActionIdentifier? {
        didSet { saveOptional(doubleClickAssignedAction, key: Keys.doubleClickAssignedAction) }
    }

    /// Whether to trigger the popup via the Cmd+C+C chord (default: true).
    @Published var triggerChordEnabled: Bool {
        didSet { defaults.set(triggerChordEnabled, forKey: Keys.triggerChord) }
    }

    /// Global on/off for the action History log (default: true). When off,
    /// nothing is recorded.
    @Published var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Keys.historyEnabled) }
    }

    /// When true, the full input/output text of each run is stored; when false,
    /// only a truncated preview is kept (default: true).
    @Published var historyStoreFullText: Bool {
        didSet { defaults.set(historyStoreFullText, forKey: Keys.historyStoreFullText) }
    }

    /// Optional replacement shortcut for the Cmd+C+C chord (default: nil).
    @Published var chordReplacementShortcut: KeyboardShortcut? {
        didSet { saveOptional(chordReplacementShortcut, key: Keys.chordReplacementShortcut) }
    }

    /// When true, clicking outside (or pressing Escape) after a result has
    /// finished generating asks for confirmation instead of closing the toolbar,
    /// so a ready result isn't dismissed by accident (default: true).
    @Published var confirmCloseAfterResult: Bool {
        didSet { defaults.set(confirmCloseAfterResult, forKey: Keys.confirmCloseAfterResult) }
    }

    /// When true, a Dock icon is shown while the Settings window is open in addition
    /// to the normal menu-bar presence (default: false).
    @Published var showDockIconWithSettings: Bool {
        didSet { defaults.set(showDockIconWithSettings, forKey: Keys.showDockIconWithSettings) }
    }

    /// Font size for the result body shown in the floating toolbar (default: .normal).
    @Published var resultFontSize: ResultFontSize {
        didSet { defaults.set(resultFontSize.rawValue, forKey: Keys.resultFontSize) }
    }

    /// When on, the toolbar renders Markdown formatting in the result and the
    /// AI is asked to preserve the input's formatting. Default off.
    @Published var preserveFormatting: Bool {
        didSet { defaults.set(preserveFormatting, forKey: Keys.preserveFormatting) }
    }

    /// Zoom level applied to the floating toolbar (default: .x1).
    @Published var toolbarZoom: ToolbarZoom {
        didSet { defaults.set(toolbarZoom.rawValue, forKey: Keys.toolbarZoom) }
    }

    /// When true, the result body font size also scales with `toolbarZoom` (default: true).
    @Published var zoomIncludesFontSize: Bool {
        didSet { defaults.set(zoomIncludesFontSize, forKey: Keys.zoomIncludesFontSize) }
    }

    /// Running count of toolbar actions performed by free-tier users.
    /// Persisted across launches. Pro users are never counted (the closure in
    /// ToolbarController guards on `!licenseGate.entitlements.isPro`).
    @Published private(set) var actCount: Int {
        didSet { defaults.set(actCount, forKey: Keys.actCount) }
    }

    /// Action identifiers assigned to the principal (inline) toolbar row.
    /// Overflow actions are enabled identifiers not in this set. Persisted via
    /// `didSet` on mutation; `didSet` does NOT fire on init assignment.
    @Published private(set) var principalActionIDs: Set<ActionIdentifier> {
        didSet { save(principalActionIDs, key: Keys.principalActionIDs) }
    }

    // MARK: - Init

    /// Create a SettingsStore backed by the given UserDefaults instance.
    ///
    /// - Parameters:
    ///   - defaults: The `UserDefaults` suite to use. Defaults to `.standard`.
    ///     Pass `UserDefaults(suiteName: "<unique>")` in tests.
    ///   - mlxHelper: The `MLXHelperManager` to use for local model operations.
    ///     Defaults to `.shared`. Pass a stub in tests.
    ///   - isMLXSupported: Whether MLX is supported on this Mac.
    ///     Defaults to `MLXCapability.isSupported`. Pass a fixed value in tests.
    init(
        defaults: UserDefaults = .standard,
        mlxHelper: MLXHelperManager = .shared,
        isMLXSupported: Bool = MLXCapability.isSupported
    ) {
        self.defaults = defaults
        self.mlxHelper = mlxHelper
        self.isMLXSupported = isMLXSupported
        completedLocalModelIDs = Self.load(Set<String>.self, key: Keys.completedLocalModelIDs, from: defaults) ?? []
        localModelIdleSeconds = defaults.object(forKey: Keys.localModelIdleSeconds) as? Int ?? 300

        // Load persisted values or fall back to built-in defaults.
        let rawImproveConfig = Self.load(ActionConfig.self, key: Keys.improveConfig, from: defaults) ?? .defaultImprove
        // I-B coercion: if the persisted Improve provider is translation-only,
        // reset to the default AI provider so the app never dispatches Improve to DeepL/Google.
        if ActionKind.improve.allowedProviders.contains(rawImproveConfig.providerKind) {
            improveConfig = rawImproveConfig
        } else {
            improveConfig = ActionConfig(
                id: .improve,
                providerKind: ActionConfig.defaultImprove.providerKind,
                model: ActionConfig.defaultImprove.model
            )
        }
        // Same I-B coercion for Shorten and Proofread (AI-only actions).
        let rawShortenConfig = Self.load(ActionConfig.self, key: Keys.shortenConfig, from: defaults) ?? .defaultShorten
        if ActionKind.shorten.allowedProviders.contains(rawShortenConfig.providerKind) {
            shortenConfig = rawShortenConfig
        } else {
            shortenConfig = ActionConfig(
                id: .shorten,
                providerKind: ActionConfig.defaultShorten.providerKind,
                model: ActionConfig.defaultShorten.model
            )
        }
        let rawProofreadConfig = Self.load(ActionConfig.self, key: Keys.proofreadConfig, from: defaults) ?? .defaultProofread
        if ActionKind.proofread.allowedProviders.contains(rawProofreadConfig.providerKind) {
            proofreadConfig = rawProofreadConfig
        } else {
            proofreadConfig = ActionConfig(
                id: .proofread,
                providerKind: ActionConfig.defaultProofread.providerKind,
                model: ActionConfig.defaultProofread.model
            )
        }
        translateConfig  = Self.load(ActionConfig.self, key: Keys.translateConfig, from: defaults) ?? .defaultTranslate
        defaultTargetLanguage = defaults.string(forKey: Keys.targetLanguage) ?? "en"
        ollamaBaseURL         = defaults.string(forKey: Keys.ollamaBaseURL)  ?? "http://localhost:11434/v1"
        customBaseURL         = defaults.string(forKey: Keys.customBaseURL)  ?? ""
        claudeCLIPath  = defaults.string(forKey: Keys.claudeCLIPath)  ?? SettingsStore.detectCLIPath("claude")
        codexCLIPath   = defaults.string(forKey: Keys.codexCLIPath)   ?? SettingsStore.detectCLIPath("codex")
        geminiCLIPath  = defaults.string(forKey: Keys.geminiCLIPath)  ?? SettingsStore.detectCLIPath("gemini")
        improveEnabled   = defaults.object(forKey: Keys.improveEnabled)   as? Bool ?? true
        shortenEnabled   = defaults.object(forKey: Keys.shortenEnabled)   as? Bool ?? true
        proofreadEnabled = defaults.object(forKey: Keys.proofreadEnabled) as? Bool ?? true
        translateEnabled = defaults.object(forKey: Keys.translateEnabled) as? Bool ?? true
        speakEnabled     = defaults.object(forKey: Keys.speakEnabled)     as? Bool ?? true
        promptEnabled    = defaults.object(forKey: Keys.promptEnabled)    as? Bool ?? false
        // I-B coercion: if the persisted Prompt provider is translation-only,
        // reset to the default AI provider so the app never dispatches Prompt to DeepL/Google.
        let rawPromptConfig = Self.load(ActionConfig.self, key: Keys.promptConfig, from: defaults) ?? .defaultPrompt
        if ActionKind.prompt.allowedProviders.contains(rawPromptConfig.providerKind) {
            promptConfig = rawPromptConfig
        } else {
            promptConfig = ActionConfig(
                id: .prompt,
                providerKind: ActionConfig.defaultPrompt.providerKind,
                model: ActionConfig.defaultPrompt.model
            )
        }
        speakSettings       = Self.load(SpeakSettings.self, key: Keys.speakSettings, from: defaults) ?? .default
        dictionaryConfig    = Self.load(DictionaryConfig.self, key: Keys.dictionaryConfig, from: defaults) ?? .default
        babylonDictionaries = Self.load([BabylonDictionary].self, key: Keys.babylonDictionaries, from: defaults) ?? []
        ttsProviderConfigs  = Self.load([String: TTSProviderConfig].self, key: Keys.ttsProviderConfigs, from: defaults) ?? [:]
        let loadedCustomActions = Self.load([CustomAction].self, key: Keys.customActions, from: defaults) ?? []
        customActions       = loadedCustomActions
        shortcutBindings = Self.load([ShortcutBinding].self, key: Keys.shortcutBindings, from: defaults) ?? ShortcutBinding.defaultBuiltins
        hasOnboarded     = defaults.object(forKey: Keys.hasOnboarded) as? Bool ?? false
        ignoredAppBundleIDs      = Self.load([String].self, key: Keys.ignoredAppBundleIDs, from: defaults) ?? []
        ignoredDomains           = Self.load([String].self, key: Keys.ignoredDomains, from: defaults) ?? []
        ignoredDomainsEnabled    = defaults.object(forKey: Keys.ignoredDomainsEnabled) as? Bool ?? false
        popGuyEnabled            = defaults.object(forKey: Keys.popGuyEnabled) as? Bool ?? true
        triggerOnSelectEnabled   = defaults.object(forKey: Keys.triggerOnSelect) as? Bool ?? false
        triggerDoubleClickEnabled = defaults.object(forKey: Keys.triggerDoubleClick) as? Bool ?? false
        doubleClickAssignedAction = Self.load(ActionIdentifier.self, key: Keys.doubleClickAssignedAction, from: defaults)
        triggerChordEnabled      = defaults.object(forKey: Keys.triggerChord)    as? Bool ?? true
        historyEnabled           = defaults.object(forKey: Keys.historyEnabled)        as? Bool ?? true
        historyStoreFullText     = defaults.object(forKey: Keys.historyStoreFullText)  as? Bool ?? true
        chordReplacementShortcut = Self.load(KeyboardShortcut.self, key: Keys.chordReplacementShortcut, from: defaults)
        confirmCloseAfterResult  = defaults.object(forKey: Keys.confirmCloseAfterResult) as? Bool ?? true
        showDockIconWithSettings = defaults.object(forKey: Keys.showDockIconWithSettings) as? Bool ?? true
        resultFontSize = defaults.string(forKey: Keys.resultFontSize).flatMap(ResultFontSize.init(rawValue:)) ?? .normal
        preserveFormatting = defaults.bool(forKey: Keys.preserveFormatting)
        toolbarZoom = defaults.string(forKey: Keys.toolbarZoom).flatMap(ToolbarZoom.init(rawValue:)) ?? .x1
        zoomIncludesFontSize = defaults.object(forKey: Keys.zoomIncludesFontSize) == nil ? true : defaults.bool(forKey: Keys.zoomIncludesFontSize)
        actCount = defaults.object(forKey: Keys.actCount) as? Int ?? 0
        // Reconcile actionOrder and principal partition using locals only — `self`
        // is not fully initialized until both assignments below complete.
        let rawOrder = Self.load([ActionIdentifier].self, key: Keys.actionOrder, from: defaults)
        let reconciledOrder = Self.reconcileOrder(persisted: rawOrder, customActions: loadedCustomActions)

        let rawPrincipal = Self.load(Set<ActionIdentifier>.self, key: Keys.principalActionIDs, from: defaults)
        let resolvedPrincipal: Set<ActionIdentifier>
        if let rawPrincipal, !rawPrincipal.isEmpty {
            resolvedPrincipal = Self.reconcilePrincipal(persisted: rawPrincipal, actionOrder: reconciledOrder)
        } else {
            let impEnabled = defaults.object(forKey: Keys.improveEnabled) as? Bool ?? true
            let shEnabled = defaults.object(forKey: Keys.shortenEnabled) as? Bool ?? true
            let prEnabled = defaults.object(forKey: Keys.proofreadEnabled) as? Bool ?? true
            let pmEnabled = defaults.object(forKey: Keys.promptEnabled) as? Bool ?? false
            let trEnabled = defaults.object(forKey: Keys.translateEnabled) as? Bool ?? true
            let spEnabled = defaults.object(forKey: Keys.speakEnabled) as? Bool ?? true
            let dictConfig = Self.load(DictionaryConfig.self, key: Keys.dictionaryConfig, from: defaults) ?? .default
            let enabled = Self.enabledIdentifiers(
                in: reconciledOrder,
                improveEnabled: impEnabled,
                shortenEnabled: shEnabled,
                proofreadEnabled: prEnabled,
                promptEnabled: pmEnabled,
                translateEnabled: trEnabled,
                speakEnabled: spEnabled,
                dictionaryEnabled: dictConfig.isEnabled,
                customActions: loadedCustomActions
            )
            let migrated = Set(enabled.prefix(ProConfig.maxPrincipalActions))
            resolvedPrincipal = Self.reconcilePrincipal(persisted: migrated, actionOrder: reconciledOrder)
        }

        actionOrder = reconciledOrder
        principalActionIDs = resolvedPrincipal
        // Persist first-launch / upgrade migration (`didSet` does not run on init).
        if rawPrincipal == nil || rawPrincipal?.isEmpty == true {
            save(principalActionIDs, key: Keys.principalActionIDs)
        }

        // Push the persisted idle value to the manager (didSet does not fire on init assignment).
        // The manager defaults to 300; push only when the persisted value differs.
        let persistedIdleSeconds = localModelIdleSeconds
        if persistedIdleSeconds != 300 {
            let helper = mlxHelper
            Task { await helper.applyIdleTimeoutChange(persistedIdleSeconds) }
        }
    }

    // MARK: - Toolbar action cap

    /// Maximum number of enabled actions that may be active on the toolbar at once
    /// (principal row + burger menu combined).
    static let maxToolbarActions = ProConfig.maxPrincipalActions + ProConfig.maxBurgerActions

    /// Canonical default order for the six built-in actions.
    /// Custom actions are appended after these in `customActions` array order.
    static let defaultBuiltinOrder: [ActionIdentifier] = [
        .builtin(.improve),
        .builtin(.shorten),
        .builtin(.proofread),
        .builtin(.prompt),
        .builtin(.translate),
        .dictionary,
        .speak,
    ]

    /// Total count of enabled toolbar actions: built-in flags + enabled custom actions.
    var enabledToolbarActionCount: Int {
        let builtins = [improveEnabled, shortenEnabled, proofreadEnabled, translateEnabled, speakEnabled, promptEnabled, dictionaryConfig.isEnabled]
            .filter { $0 }.count
        let customs = customActions.filter(\.isEnabled).count
        return builtins + customs
    }

    /// Total count of all toolbar actions (enabled or not): built-ins + custom.
    var totalToolbarActionCount: Int {
        Self.defaultBuiltinOrder.count + customActions.count
    }

    // MARK: - Config accessors

    /// Return the ActionConfig for the given ActionKind.
    func config(for action: ActionKind) -> ActionConfig {
        switch action {
        case .improve:   return improveConfig
        case .shorten:   return shortenConfig
        case .proofread: return proofreadConfig
        case .translate: return translateConfig
        case .prompt:    return promptConfig
        }
    }

    /// Update the ActionConfig for the given ActionKind.
    func setConfig(_ config: ActionConfig, for action: ActionKind) {
        switch action {
        case .improve:   improveConfig   = config
        case .shorten:   shortenConfig   = config
        case .proofread: proofreadConfig = config
        case .translate: translateConfig = config
        case .prompt:    promptConfig    = config
        }
    }

    /// Return the persisted `TTSProviderConfig` for the given cloud TTS provider,
    /// or `.default` if no config has been stored yet.
    func ttsConfig(for kind: TTSProviderKind) -> TTSProviderConfig {
        ttsProviderConfigs[kind.rawValue] ?? .default
    }

    /// Persist a `TTSProviderConfig` for the given cloud TTS provider.
    func setTTSConfig(_ config: TTSProviderConfig, for kind: TTSProviderKind) {
        ttsProviderConfigs[kind.rawValue] = config
    }

    // MARK: - Custom action CRUD

    /// Append a new custom action at the end of the list.
    ///
    /// If the incoming action is enabled and committing it would push
    /// `enabledToolbarActionCount` beyond `maxToolbarActions`, the action is
    /// persisted with `isEnabled = false` instead.
    ///
    /// - Returns: `true` if the enable flag was clamped to `false`; `false` otherwise.
    @discardableResult
    func addCustomAction(_ action: CustomAction) -> Bool {
        let wouldExceed = action.isEnabled && (enabledToolbarActionCount + 1 > Self.maxToolbarActions)
        if wouldExceed {
            var clamped = action
            clamped.isEnabled = false
            customActions.append(clamped)
            actionOrder.append(.custom(action.id))
            return true
        }
        customActions.append(action)
        actionOrder.append(.custom(action.id))
        return false
    }

    /// Replace an existing custom action identified by its `id`.
    /// No-op if the id is not found.
    ///
    /// If the incoming action is enabled and committing it would push the
    /// enabled count beyond `maxToolbarActions` (excluding the old version
    /// of this action from the count), the action is persisted with
    /// `isEnabled = false` instead.
    ///
    /// - Returns: `true` if the enable flag was clamped to `false`; `false` otherwise.
    @discardableResult
    func updateCustomAction(_ action: CustomAction) -> Bool {
        guard let index = customActions.firstIndex(where: { $0.id == action.id }) else { return false }
        if action.isEnabled {
            // Count excluding the old version of this action.
            let oldWasEnabled = customActions[index].isEnabled
            let countWithoutOld = enabledToolbarActionCount - (oldWasEnabled ? 1 : 0)
            if countWithoutOld + 1 > Self.maxToolbarActions {
                var clamped = action
                clamped.isEnabled = false
                customActions[index] = clamped
                return true
            }
        }
        customActions[index] = action
        return false
    }

    /// Remove the custom action with the given id.
    func deleteCustomAction(id: UUID) {
        customActions.removeAll { $0.id == id }
        // Also remove any shortcut binding for this action.
        shortcutBindings.removeAll { $0.actionID == .custom(id) }
        // Remove from the unified action order and principal partition.
        actionOrder.removeAll { $0 == .custom(id) }
        principalActionIDs.remove(.custom(id))
    }

    /// Move custom actions at the given source offsets to the destination offset.
    /// Mirrors SwiftUI's `List.onMove` semantics.
    /// Implemented inline to avoid importing SwiftUI into the model layer.
    func moveCustomActions(fromOffsets source: IndexSet, toOffset destination: Int) {
        // Collect items being moved.
        let items = source.map { customActions[$0] }
        // Adjust destination for items that will be removed before it.
        let adjustedDest = destination - source.filter { $0 < destination }.count
        // Remove source indices in reverse order to keep indices stable.
        for index in source.sorted().reversed() {
            customActions.remove(at: index)
        }
        customActions.insert(contentsOf: items, at: adjustedDest)
    }

    // MARK: - Shortcut binding CRUD

    /// Set (add or replace) the shortcut for the given action identifier.
    ///
    /// Last-write-wins deduplication: if another action already owns the same
    /// {keyCode, modifierFlags} combo, that binding is removed first so the
    /// combo maps to at most one action at all times.
    func setShortcut(_ shortcut: KeyboardShortcut, for actionID: ActionIdentifier) {
        // Remove any existing binding that uses the same combo for a DIFFERENT action.
        shortcutBindings.removeAll { $0.actionID != actionID && $0.shortcut == shortcut }

        if let index = shortcutBindings.firstIndex(where: { $0.actionID == actionID }) {
            shortcutBindings[index] = ShortcutBinding(actionID: actionID, shortcut: shortcut)
        } else {
            shortcutBindings.append(ShortcutBinding(actionID: actionID, shortcut: shortcut))
        }
    }

    /// Remove the shortcut binding for the given action identifier.
    func removeShortcut(for actionID: ActionIdentifier) {
        shortcutBindings.removeAll { $0.actionID == actionID }
    }

    /// Return the shortcut bound to the given action identifier, or nil.
    func shortcut(for actionID: ActionIdentifier) -> KeyboardShortcut? {
        shortcutBindings.first { $0.actionID == actionID }?.shortcut
    }

    // MARK: - Ignored-app CRUD

    /// Append `bundleID` to the ignore list if not already present.
    func addIgnoredApp(bundleID: String) {
        guard !ignoredAppBundleIDs.contains(bundleID) else { return }
        ignoredAppBundleIDs.append(bundleID)
    }

    /// Remove all entries matching `bundleID` from the ignore list.
    func removeIgnoredApp(bundleID: String) {
        ignoredAppBundleIDs.removeAll { $0 == bundleID }
    }

    /// Returns `true` if `bundleID` is in the ignore list.
    func isIgnored(bundleID: String) -> Bool {
        ignoredAppBundleIDs.contains(bundleID)
    }

    // MARK: - Ignored-domain CRUD

    /// Append `raw` (normalized) to the ignored-domains list if not already present.
    func addIgnoredDomain(_ raw: String) {
        guard let domain = BrowserURLReader.normalizeDomain(raw),
              !ignoredDomains.contains(domain) else { return }
        ignoredDomains.append(domain)
    }

    /// Remove all entries matching `domain` from the ignored-domains list.
    ///
    /// The input is normalized before matching so callers may pass any common
    /// format (e.g. `"www.notion.so"` removes the stored entry `"notion.so"`).
    func removeIgnoredDomain(_ domain: String) {
        let normalized = BrowserURLReader.normalizeDomain(domain) ?? domain
        ignoredDomains.removeAll { $0 == normalized }
    }

    /// Returns `true` if `host` matches any entry in the ignored-domains list.
    func isIgnoredDomain(host: String) -> Bool {
        ignoredDomains.contains { BrowserURLReader.hostMatches(host: host, domain: $0) }
    }

    // MARK: - Act counter

    /// Increment the free-tier act counter and return whether a nag is due.
    ///
    /// Called by `ToolbarController` after confirming the user is not Pro.
    /// The `@discardableResult` allows callers that only want the side effect.
    ///
    /// - Returns: `true` when the new `actCount` satisfies `UsagePolicy.isNagDue`,
    ///   i.e. exactly at counts 101, 111, 121, …
    @discardableResult
    func recordAct() -> Bool {
        actCount += 1
        return UsagePolicy.isNagDue(actCount: actCount)
    }

    // MARK: - Action order

    /// Compute the reconciled actionOrder from a persisted snapshot and the current custom actions.
    ///
    /// - Canonical set: defaultBuiltinOrder + .custom(uuid) for each custom action in order.
    /// - Valid persisted entries (those in canonical) are kept in their persisted relative order,
    ///   de-duplicated (first occurrence wins).
    /// - Any canonical entry not present in the persisted set is appended in canonical order.
    /// - Stale entries (removed custom actions, unknown identifiers) are dropped.
    private static func reconcileOrder(
        persisted: [ActionIdentifier]?,
        customActions: [CustomAction]
    ) -> [ActionIdentifier] {
        let canonical = defaultBuiltinOrder + customActions.map { .custom($0.id) }
        let canonicalSet = Set(canonical)
        var seen = Set<ActionIdentifier>()
        var result: [ActionIdentifier] = []
        // Keep valid persisted entries in order, deduplicated.
        for entry in persisted ?? [] {
            guard canonicalSet.contains(entry), seen.insert(entry).inserted else { continue }
            result.append(entry)
        }
        // Append any canonical entry not already present.
        for entry in canonical where !seen.contains(entry) {
            result.append(entry)
        }
        return result
    }

    /// Move actions at the given source offsets to the destination offset in `actionOrder`.
    /// Mirrors SwiftUI's `List.onMove` semantics and the existing `moveCustomActions` implementation.
    func moveAction(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard source.allSatisfy({ $0 >= 0 && $0 < actionOrder.count }),
              destination >= 0, destination <= actionOrder.count else { return }
        let items = source.map { actionOrder[$0] }
        let adjustedDest = destination - source.filter { $0 < destination }.count
        for index in source.sorted().reversed() {
            actionOrder.remove(at: index)
        }
        actionOrder.insert(contentsOf: items, at: adjustedDest)
    }

    /// Returns whether the action identified by `id` is currently enabled.
    func isEnabled(_ id: ActionIdentifier) -> Bool {
        switch id {
        case .builtin(.improve):   return improveEnabled
        case .builtin(.shorten):   return shortenEnabled
        case .builtin(.proofread): return proofreadEnabled
        case .builtin(.prompt):    return promptEnabled
        case .builtin(.translate): return translateEnabled
        case .speak:               return speakEnabled
        case .dictionary:          return dictionaryConfig.isEnabled
        case .custom(let uuid):    return customActions.first { $0.id == uuid }?.isEnabled ?? false
        }
    }

    /// The ordered identifiers of all enabled actions.
    var enabledOrderedIdentifiers: [ActionIdentifier] {
        actionOrder.filter { isEnabled($0) }
    }

    /// Returns whether `id` is assigned to the principal (inline) toolbar row.
    func isPrincipal(_ id: ActionIdentifier) -> Bool {
        principalActionIDs.contains(id)
    }

    /// Enabled actions shown inline on the toolbar, in `actionOrder`.
    var principalOrderedIdentifiers: [ActionIdentifier] {
        enabledOrderedIdentifiers.filter { isPrincipal($0) }
    }

    /// Enabled actions assigned to the burger overflow menu, in `actionOrder`.
    var overflowOrderedIdentifiers: [ActionIdentifier] {
        enabledOrderedIdentifiers.filter { !isPrincipal($0) }
    }

    /// Count of enabled principal-row actions.
    var principalActionCount: Int {
        principalOrderedIdentifiers.count
    }

    /// Count of enabled burger-menu actions.
    var overflowActionCount: Int {
        overflowOrderedIdentifiers.count
    }

    /// Assign or remove `id` from the principal toolbar row.
    ///
    /// Caps apply only when the action is enabled: moving an enabled action into
    /// a zone that is already at its cap is rejected. Disabled actions may
    /// switch zones freely.
    ///
    /// - Returns: `true` when the membership changed or was already in the requested state;
    ///   `false` when rejected by a zone cap.
    @discardableResult
    func setPrincipal(_ id: ActionIdentifier, _ value: Bool) -> Bool {
        let currentlyPrincipal = principalActionIDs.contains(id)
        guard value != currentlyPrincipal else { return true }

        if value {
            // Enabled actions count toward the principal cap; disabled actions may
            // be assigned freely and only block once enabled.
            if isEnabled(id), principalActionCount >= ProConfig.maxPrincipalActions {
                return false
            }
            principalActionIDs.insert(id)
        } else {
            if isEnabled(id), overflowActionCount >= ProConfig.maxBurgerActions {
                return false
            }
            principalActionIDs.remove(id)
        }
        return true
    }

    /// Atomically move an action to a toolbar zone at a position among that zone's
    /// enabled members (principal row or burger menu).
    ///
    /// Enforces the same zone caps as `setPrincipal`. Reorders `actionOrder` so
    /// enabled members of the target zone appear at `atIndex` relative to each other.
    ///
    /// - Returns: `false` when the zone cap would be exceeded; `true` on success.
    @discardableResult
    func moveAction(_ id: ActionIdentifier, toZone principal: Bool, atIndex: Int) -> Bool {
        if isPrincipal(id) != principal {
            guard setPrincipal(id, principal) else { return false }
        }

        guard actionOrder.contains(id) else { return false }
        guard isEnabled(id) else { return true }

        let zoneMembers = actionOrder.filter {
            principalActionIDs.contains($0) == principal && isEnabled($0)
        }

        var reordered = zoneMembers.filter { $0 != id }
        let clamped = min(max(0, atIndex), reordered.count)
        reordered.insert(id, at: clamped)

        var reorderedIter = reordered.makeIterator()
        var newOrder: [ActionIdentifier] = []
        for item in actionOrder {
            if principalActionIDs.contains(item) == principal && isEnabled(item) {
                if let next = reorderedIter.next() {
                    newOrder.append(next)
                }
            } else {
                newOrder.append(item)
            }
        }
        actionOrder = newOrder
        return true
    }

    /// Reconcile a persisted principal set against the current `actionOrder`.
    ///
    /// Drops stale identifiers, trims to `ProConfig.maxPrincipalActions` by
    /// `actionOrder`, and leaves actions not in the set in the burger zone.
    private static func reconcilePrincipal(
        persisted: Set<ActionIdentifier>,
        actionOrder: [ActionIdentifier]
    ) -> Set<ActionIdentifier> {
        var ordered = actionOrder.filter { persisted.contains($0) }
        if ordered.count > ProConfig.maxPrincipalActions {
            ordered = Array(ordered.prefix(ProConfig.maxPrincipalActions))
        }
        var principalSet = Set(ordered)
        var burger = actionOrder.filter { !principalSet.contains($0) }
        while burger.count > ProConfig.maxBurgerActions,
              principalSet.count < ProConfig.maxPrincipalActions {
            let promote = burger.removeFirst()
            principalSet.insert(promote)
        }
        return principalSet
    }

    /// Enabled identifiers in `actionOrder` order — static for init migration.
    private static func enabledIdentifiers(
        in actionOrder: [ActionIdentifier],
        improveEnabled: Bool,
        shortenEnabled: Bool,
        proofreadEnabled: Bool,
        promptEnabled: Bool,
        translateEnabled: Bool,
        speakEnabled: Bool,
        dictionaryEnabled: Bool,
        customActions: [CustomAction]
    ) -> [ActionIdentifier] {
        actionOrder.filter { id in
            switch id {
            case .builtin(.improve):   return improveEnabled
            case .builtin(.shorten):   return shortenEnabled
            case .builtin(.proofread): return proofreadEnabled
            case .builtin(.prompt):    return promptEnabled
            case .builtin(.translate): return translateEnabled
            case .speak:               return speakEnabled
            case .dictionary:          return dictionaryEnabled
            case .custom(let uuid):    return customActions.first { $0.id == uuid }?.isEnabled ?? false
            }
        }
    }

    // MARK: - Local model availability

    /// Returns the availability status for `model` given whether the user is Pro.
    ///
    /// Checks in priority order: capability → licensing → available.
    /// Callers (UI + download enforcement) should call this before any download or use.
    nonisolated func availability(for model: LocalModel, isPro: Bool) -> LocalModelAvailability {
        guard isMLXSupported else {
            return .unsupported(reason: MLXCapability.unsupportedReason)
        }
        if !model.isFreeTier && !isPro {
            return .proLocked
        }
        return .available
    }

    // MARK: - Loaded model status

    /// Refresh the published `loadedLocalModelID` by querying the helper.
    ///
    /// Returns nil without launching the helper when it is not running.
    /// The UI calls this on a timer and after generate/unload to keep the indicator current.
    ///
    /// The helper reports the loaded model by its HuggingFace **repo id** (what
    /// `generate` loads); the UI keys off the catalog **id**, so map repo id → catalog id.
    func refreshLoadedLocalModel() async {
        let reportedRepoID = await mlxHelper.loadedModelID()
        loadedLocalModelID = reportedRepoID.flatMap { repo in
            LocalModelCatalog.all.first { $0.repoID == repo }?.id
        }
    }

    /// Unload the currently loaded model from the helper, then refresh `loadedLocalModelID`.
    func unloadLoadedLocalModel() async {
        await mlxHelper.unloadModel()
        await refreshLoadedLocalModel()
    }

    // MARK: - Local model installed-models cache

    /// Refresh the `installedLocalModels` cache.
    ///
    /// Reconciles the persisted `completedLocalModelIDs` set against disk:
    /// - Keeps an id only if its model directory still exists on disk.
    /// - NEVER adds an id just because disk files exist — only successful
    ///   downloads (tracked in completedLocalModelIDs) count as installed.
    /// - Writes back any pruned ids to keep the persisted set consistent with disk.
    ///
    /// Call on Settings view appear and after any download or delete completes.
    func refreshInstalledLocalModels() async {
        let helper = mlxHelper
        var reconciled = Set<String>()
        for id in completedLocalModelIDs {
            if await helper.modelDirExists(modelID: id) {
                reconciled.insert(id)
            }
        }
        // Write back pruned set if anything was removed (external deletion).
        if reconciled != completedLocalModelIDs {
            completedLocalModelIDs = reconciled
        }
        installedLocalModels = reconciled
    }

    // MARK: - Local model download

    /// Download the model with the given catalog id.
    ///
    /// - Checks capability and Pro gate via `availability(for:isPro:)`; refuses and
    ///   sets `localModelDownloadError` when not `.available`.
    /// - Streams progress updates to `localModelDownloadProgress[id]`.
    /// - On completion clears progress, clears `activeLocalModelDownloadID`, and
    ///   calls `refreshInstalledLocalModels()`.
    /// - On error clears progress, clears `activeLocalModelDownloadID`, and sets
    ///   `localModelDownloadError`.
    /// - The work runs in a stored `Task` that `cancelLocalModelDownload()` cancels.
    func downloadLocalModel(_ id: String, isPro: Bool) {
        guard let model = LocalModelCatalog.model(for: id) else {
            localModelDownloadError = "Unknown model id: \(id)"
            return
        }

        switch availability(for: model, isPro: isPro) {
        case .unsupported(let reason):
            localModelDownloadError = reason
            return
        case .proLocked:
            localModelDownloadError = "This model requires a Pro license."
            return
        case .available:
            break
        }

        // Cancel any in-flight download before starting a new one.
        // Eagerly clear all stale progress so a prior download's progress key
        // (which may differ from the new id) is not left in the dict.
        activeDownloadTask?.cancel()
        localModelDownloadProgress = [:]

        localModelDownloadError = nil
        activeLocalModelDownloadID = id

        // Bump the monotonic token. The Task captures `myToken` and guards every
        // state write so a cancelled/superseded Task A's teardown cannot clobber
        // the replacement Task B's activeID, progress, or error.
        downloadToken &+= 1
        let myToken = downloadToken

        let repoID = model.repoID
        let helper = mlxHelper

        activeDownloadTask = Task {
            var completedSuccessfully = false
            do {
                let stream = try await helper.download(modelID: repoID)
                for try await progress in stream {
                    if Task.isCancelled { break }
                    guard myToken == downloadToken else { return }
                    localModelDownloadProgress[id] = progress.fraction
                }
                // Mark success only when the loop finished without cancellation
                // and this token is still the current download.
                if !Task.isCancelled {
                    completedSuccessfully = true
                }
            } catch {
                guard myToken == downloadToken else { return }
                if !Task.isCancelled {
                    if let mlxErr = error as? MLXHelperError {
                        switch mlxErr {
                        case .helperNotFound:  localModelDownloadError = "MLX helper not found. Try reinstalling PopGuy."
                        case .launchFailed:    localModelDownloadError = "Failed to start the on-device engine."
                        case .startupTimeout:  localModelDownloadError = "On-device engine timed out. Try again."
                        case .ipcError:        localModelDownloadError = "On-device engine communication error."
                        case .processExited:   localModelDownloadError = "On-device engine exited unexpectedly."
                        case .unsupported:     localModelDownloadError = error.localizedDescription
                        }
                    } else {
                        localModelDownloadError = "Download failed. Check your internet connection and try again."
                    }
                }
            }
            guard myToken == downloadToken else { return }
            // Record the model as installed only on a verified successful completion.
            if completedSuccessfully {
                completedLocalModelIDs.insert(id)
            }
            localModelDownloadProgress.removeValue(forKey: id)
            activeLocalModelDownloadID = nil
            await refreshInstalledLocalModels()
        }
    }

    /// Cancel the currently active model download, if any.
    ///
    /// Cancelling terminates the stream on the helper side (via `onTermination`).
    /// Progress and active-id are cleared by the task's completion block.
    func cancelLocalModelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
    }

    // MARK: - Local model delete

    /// Delete the on-disk files for the given catalog model id, then refresh the cache.
    ///
    /// If a download of the same model is in flight, it is cancelled first to
    /// prevent the download racing against the delete and writing files after
    /// the delete completes. The model id is removed from the persisted completed
    /// set so it no longer shows as installed.
    func deleteLocalModel(_ id: String) async {
        if activeLocalModelDownloadID == id {
            cancelLocalModelDownload()
        }
        completedLocalModelIDs.remove(id)
        await mlxHelper.delete(modelID: id)
        await refreshInstalledLocalModels()
    }

    // MARK: - Private helpers

    private func save<T: Codable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    /// Persist an optional Codable value: encodes and stores when non-nil,
    /// removes the key when nil.
    private func saveOptional<T: Codable>(_ value: T?, key: String) {
        if let value {
            guard let data = try? JSONEncoder().encode(value) else { return }
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func load<T: Codable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - CLI binary auto-detect

    /// Probes well-known candidate paths for a CLI binary named `name` and returns
    /// the first path where the binary exists, or `""` if none is found.
    ///
    /// Candidates checked in order:
    ///   1. `~/.local/bin/<name>`
    ///   2. `/opt/homebrew/bin/<name>`
    ///   3. `/usr/local/bin/<name>`
    ///   4. Newest nvm node version: `~/.nvm/versions/node/<newest>/bin/<name>`
    ///
    /// This is a best-effort helper for initial default population; the user can
    /// override the path in Settings at any time.
    nonisolated static func detectCLIPath(_ name: String) -> String {
        detectCLIPath(name,
                      home: NSHomeDirectory(),
                      fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Testable core of `detectCLIPath(_:)`. Accepts injected `home` and
    /// `fileExists` so unit tests can exercise every branch without touching
    /// the real filesystem for fixed-path checks.
    ///
    /// The nvm branch enumerates `<home>/.nvm/versions/node/` via `FileManager`
    /// directly (real or temp directory) and then probes each candidate through
    /// the injected `fileExists` closure.
    nonisolated static func detectCLIPath(
        _ name: String,
        home: String,
        fileExists: (String) -> Bool
    ) -> String {
        // Fixed candidates (tilde already expanded via the injected `home`).
        let fixed = [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        for path in fixed where fileExists(path) {
            return path
        }

        // nvm candidate: enumerate <home>/.nvm/versions/node/ and pick the newest version.
        let nvmNodeDir = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmNodeDir) {
            // Sort using localizedStandardCompare (Finder-style numeric) to rank
            // "v22.x" correctly above "v9.x" without relying on lexicographic order.
            let sorted = entries.sorted { a, b in
                a.localizedStandardCompare(b) == .orderedDescending
            }
            for version in sorted {
                let candidate = "\(nvmNodeDir)/\(version)/bin/\(name)"
                if fileExists(candidate) {
                    return candidate
                }
            }
        }

        return ""
    }
}
