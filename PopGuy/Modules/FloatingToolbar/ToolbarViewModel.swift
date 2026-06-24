// ToolbarViewModel.swift
// PopGuy
//
// ObservableObject view model for the floating toolbar.
//
// ObservableObject (not @Observable) is used because @Observable requires
// macOS 14.0+; PopGuy targets macOS 13.0+.
//
// The protocol seam `ToolbarActionHandling` lets Phase 3 inject an ActionEngine
// without touching this file or ToolbarView. Until Phase 3 is wired, the
// view model holds a nil handler and buttons show a placeholder state.
//
// Strict concurrency: @MainActor — all state mutation and UI updates happen
// on the main actor.

import Combine
import CoreGraphics
import Foundation

// MARK: - Action state

/// Distinct states for an in-progress or completed toolbar action.
enum ToolbarActionState: Equatable {
    /// No action running, no result to show.
    case idle
    /// Action dispatched and running; `progress` holds streamed text so far.
    case running(progress: String)
    /// Action finished successfully; `result` is the final output.
    case result(String)
    /// Action failed; `message` is a human-readable description.
    case error(String)
}

// MARK: - Target language

/// Languages available in the per-call Translate dropdown.
///
/// Must stay in sync with the language list in SettingsView.TranslateTab.
/// Every bcp47 code offered in the picker must map to a non-.english case
/// (except "en" itself) — enforced by TargetLanguageTests.
enum TargetLanguage: String, CaseIterable, Identifiable {
    case english    = "English"
    case vietnamese = "Vietnamese"
    case french     = "French"
    case spanish    = "Spanish"
    case german     = "German"
    case japanese   = "Japanese"
    case chinese    = "Chinese (Simplified)"
    case korean     = "Korean"
    case portuguese = "Portuguese"
    case italian    = "Italian"

    nonisolated var id: String { rawValue }

    /// BCP-47 language tag passed to translation providers.
    nonisolated var bcp47: String {
        switch self {
        case .english:    return "en"
        case .vietnamese: return "vi"
        case .french:     return "fr"
        case .spanish:    return "es"
        case .german:     return "de"
        case .japanese:   return "ja"
        case .chinese:    return "zh"
        case .korean:     return "ko"
        case .portuguese: return "pt"
        case .italian:    return "it"
        }
    }

    /// Initialize from a BCP-47 string. Falls back to `.english` for unknown codes.
    nonisolated init(bcp47: String) {
        self = Self.allCases.first { $0.bcp47 == bcp47 } ?? .english
    }
}

// MARK: - Action handling protocol

/// Protocol seam so Phase 3 can inject ActionEngine without modifying this file.
///
/// Marked `@MainActor` because all callers and implementors live on the main actor.
@MainActor
protocol ToolbarActionHandling: AnyObject {
    /// Begin the Improve action for the given text.
    /// Implementors should call back via `ToolbarViewModel.appendProgress` /
    /// `ToolbarViewModel.finishWith(result:)` / `ToolbarViewModel.failWith(message:)`.
    func improve(text: String, viewModel: ToolbarViewModel)

    /// Begin the Shorten action for the given text.
    func shorten(text: String, viewModel: ToolbarViewModel)

    /// Begin the Proofread action for the given text.
    func proofread(text: String, viewModel: ToolbarViewModel)

    /// Begin the Translate action for the given text and target language.
    func translate(text: String, targetLanguage: TargetLanguage, viewModel: ToolbarViewModel)

    /// Begin a user-defined custom action (Phase 5).
    func custom(action: CustomAction, text: String, viewModel: ToolbarViewModel)

    /// Begin the Look up action for the given text, using the provided target language.
    func dictionary(text: String, targetLanguage: TargetLanguage, viewModel: ToolbarViewModel)

    /// Begin a custom Dictionary action for the given text, using that action's config.
    func dictionary(text: String, config: DictionaryConfig, actionName: String, viewModel: ToolbarViewModel)

    /// Log a Speak run to history. Speak playback itself is handled by
    /// SpeakCoordinator; this only records the run so it appears in the History tab.
    func recordSpeak(text: String, engineLabel: String, accent: String, sourceBundleID: String?)

    /// Log a completed scriptable custom action run to history (.openURL,
    /// .runShortcut, .appleScript, .shellScript). These bypass ActionEngine, so
    /// the view model records them here. `typeLabel` is shown where the provider
    /// name normally appears.
    func recordScriptAction(actionName: String, typeLabel: String, input: String, output: String, success: Bool, errorMessage: String?, startedAt: Date, sourceBundleID: String?)

    /// Begin a one-off Prompt action: run the user-typed prompt against the selected text.
    func prompt(promptText: String, text: String, viewModel: ToolbarViewModel)

    /// Cancel any in-flight stream. Called when the toolbar is dismissed.
    func cancel()
}

// MARK: - View model

/// State container for the floating toolbar.
///
/// Isolation: @MainActor throughout — every property read and write happens
/// on the main actor because the view layer (SwiftUI + AppKit) is main-only.
@MainActor
final class ToolbarViewModel: ObservableObject {

    // MARK: Current selection context

    /// The captured text to act on.
    @Published private(set) var capturedText: String = ""

    /// Screen rect of the selection — retained for re-positioning if needed.
    @Published private(set) var selectionScreenRect: CGRect?

    /// The source element — used by OutputHandler for paste-back.
    private(set) var sourceElement: SourceElementRef?

    /// Bundle ID of the app that owned the selection. Captured at handleEvent time
    /// (before the panel is shown) so it is always the source app, not PopGuy.
    @Published private(set) var sourceBundleID: String?

    /// The browser domain (host) active when this selection was made, if the source
    /// app is a supported browser. Nil for non-browser apps or when the URL could
    /// not be read.
    @Published private(set) var sourceDomain: String? = nil

    // MARK: Action state

    @Published private(set) var actionState: ToolbarActionState = .idle

    /// Tracks which action produced the current state.
    /// Nil when state is .idle or the action kind is unknown.
    /// Used by ToolbarView to select the appropriate result renderer (e.g.
    /// DiffView for Improve, plain text for Translate).
    @Published private(set) var activeActionKind: ActionKind? = nil

    /// ID of the custom action that produced the current state.
    /// Nil unless a custom action is the active one. Lets ToolbarView show the
    /// running spinner only on the custom button that was clicked.
    @Published private(set) var activeCustomActionID: UUID? = nil

    /// True when the Look up action produced the current result.
    @Published private(set) var isDictionaryAction: Bool = false

    /// Structured dictionary results from every provider that found a definition.
    @Published private(set) var dictionaryEntries: [DictionaryProviderResult] = []

    /// Provider selected in the dictionary result tabs. Nil until a result exists.
    @Published private(set) var selectedDictionaryProvider: DictionaryProviderKind? = nil

    /// True when a dictionary lookup completed with no definition found.
    @Published private(set) var isDictionaryNotFound: Bool = false

    /// Editable copy of the current result. Seeded by `finishWith(result:)` and
    /// cleared by `reset()`. The view operates on this buffer; the raw result
    /// inside `actionState` is the permanent source of truth.
    @Published var editedResult: String = ""

    /// Whether the result area is currently in edit mode.
    /// Only meaningful when `actionState` is `.result` and the action is non-diff
    /// (Translate, Shorten, custom). Toggled via `beginEditing()` / `endEditing()`.
    @Published var isEditing: Bool = false

    /// Drives the "close without using the result?" confirmation dialog. Set by
    /// ToolbarController when an outside-click / Escape arrives after a result is
    /// ready and the confirm-on-close setting is on.
    @Published var isShowingCloseConfirmation: Bool = false

    // MARK: Translate settings

    @Published var targetLanguage: TargetLanguage = .english

    // MARK: Enabled flags (read from SettingsStore each presentation)

    /// Whether the Improve button should be shown.
    @Published var improveEnabled: Bool = true

    /// Whether the Shorten button should be shown.
    @Published var shortenEnabled: Bool = true

    /// Whether the Proofread button should be shown.
    @Published var proofreadEnabled: Bool = true

    /// Whether the Translate button (and picker) should be shown.
    @Published var translateEnabled: Bool = true

    /// Whether the Speak button should be shown.
    @Published var speakEnabled: Bool = true

    /// Whether the Prompt button should be shown.
    @Published var promptEnabled: Bool = false

    /// Whether the Look up button should be shown.
    /// Mirrors `SettingsStore.dictionaryConfig.isEnabled` per presentation.
    @Published var dictionaryEnabled: Bool = false

    /// Target language for the Dictionary action (independent of Translate's targetLanguage).
    @Published var dictionaryTargetLanguage: TargetLanguage = .english

    /// True while the inline prompt input area is open. Drives the prevent-close
    /// guard in ToolbarController and the input UI in ToolbarView.
    @Published var isPromptInputActive: Bool = false

    /// The user's in-progress prompt text. Non-empty while typing keeps the
    /// toolbar open (prevent-close).
    @Published var promptDraft: String = ""

    /// Speak settings (accent, voice, rate, pitch, dictionary toggle).
    /// Set by ToolbarController on each presentation from SettingsStore.
    @Published var speakSettings: SpeakSettings = .default

    /// The accent currently active in the toolbar's accent picker. In-session
    /// only (mirrors `targetLanguage`): reset to `speakSettings.defaultAccent`
    /// by ToolbarController on each presentation. Drives the picker label, the
    /// checkmark, and the main Speak button's accent.
    @Published var selectedSpeakAccent: SpeakAccent = .usEnglish

    /// Per-provider TTS config for the currently-selected cloud engine.
    /// Set by ToolbarController on each presentation; defaults to `.default`
    /// (no overrides) so existing call sites and tests compile unchanged.
    @Published var ttsConfig: TTSProviderConfig = .default

    /// Dedicated speech settings for the Look up action (independent of Speak).
    @Published var dictionarySpeakSettings: SpeakSettings = .default
    @Published var dictionaryAccent: SpeakAccent = .usEnglish
    @Published var dictionaryTTSConfig: TTSProviderConfig = .default

    /// Mirrors SpeakCoordinator.phase — the current speak lifecycle phase.
    @Published private(set) var speakPhase: SpeakPhase = .idle

    /// Mirrors SpeakCoordinator.didFallBackToSystem — true when the selected
    /// cloud engine fell back to the system voice for the last speak() call.
    @Published private(set) var speakFellBack: Bool = false

    /// Mirrors SpeakCoordinator.lastSpokenText — the text most recently spoken in
    /// this session. Drives the persistent spoken-text body in the toolbar.
    @Published private(set) var lastSpokenText: String?

    /// Mirrors SpeakCoordinator.canReplay — true once a backend engaged, so the
    /// toolbar can show "Listen again" (replays cached audio, no new request).
    @Published private(set) var canReplaySpeak: Bool = false

    /// Ordered enabled action identifiers to render in the action bar.
    /// Set by ToolbarController (and ToolbarPreviewView) on each presentation
    /// from SettingsStore.enabledOrderedIdentifiers. The action bar iterates
    /// this list; per-action data still comes from the individual flags and
    /// customActions array below.
    @Published var orderedActions: [ActionIdentifier] = []

    /// Enabled overflow actions shown in the burger menu.
    @Published var overflowActions: [ActionIdentifier] = []

    /// True when at least one action is assigned to the burger overflow menu.
    var hasOverflow: Bool { !overflowActions.isEmpty }

    /// Enabled custom actions to show alongside the built-in buttons.
    /// Set by ToolbarController on each presentation from SettingsStore.
    @Published var customActions: [CustomAction] = []

    /// Whether the cloud TTS engine is allowed for this session.
    /// Set by ToolbarController from `licenseGate.entitlements.cloudTTSPremiumAllowed`
    /// on each presentation, co-located with the `customActions` push.
    /// Defaults to `false` (safe direction: non-Pro) so any unforeseen path that
    /// pushes customActions without updating this flag still falls back to system
    /// voice for speech custom actions.
    var cloudTTSAllowed: Bool = false

    // MARK: Appearance

    /// Font size for the result body. Set by ToolbarController on each
    /// presentation from SettingsStore; applies to the next toolbar show.
    @Published var resultFontSize: ResultFontSize = .normal

    /// Toolbar zoom level. Set by ToolbarController on each presentation from
    /// SettingsStore; applies to the next toolbar show.
    @Published var toolbarZoom: ToolbarZoom = .x1

    /// Whether the zoom level also scales the result body font. Set by
    /// ToolbarController on each presentation from SettingsStore.
    @Published var includeFontInZoom: Bool = true

    /// When on, non-diff results render Markdown formatting (and the prompt asks
    /// the provider to preserve the input's formatting). Set by ToolbarController
    /// on each presentation from SettingsStore.
    @Published var preserveFormatting: Bool = false

    // MARK: Panel suppression for scriptable actions

    /// True when the result panel should be hidden during a running scriptable action
    /// whose `afterRun` is not `.showResult`.
    ///
    /// Only suppresses during `.running` — `.error`, `.result`, and `.idle` are never
    /// suppressed here. Keyed on `activeCustomActionID` so it resets as soon as the
    /// task clears that ID (to `.idle` or `.error`).
    var suppressRunningPanel: Bool {
        guard case .running = actionState else { return false }
        guard let id = activeCustomActionID,
              let action = customActions.first(where: { $0.id == id }) else { return false }
        return action.isScriptable && action.afterRun != .showResult
    }

    // MARK: Compact mode

    /// True when 4 or more inline controls are visible (principal actions plus the
    /// burger button when present). Utility buttons are excluded.
    /// When compact, action buttons render icon-only with a hover tooltip.
    var compactActions: Bool {
        let inlineCount = orderedActions.count + (hasOverflow ? 1 : 0)
        return inlineCount >= 4
    }

    // MARK: Edit-buffer computed helpers

    /// True when the current result is editable (non-diff actions). Improve and
    /// Proofread render a diff and are not editable.
    var isResultEditable: Bool {
        !isDictionaryAction && activeActionKind != .improve && activeActionKind != .proofread
    }

    /// The text the result area should display and that Copy / Paste-back use.
    /// For editable results this is the edit buffer; for diff results it is the
    /// finalized result. Empty when there is no result.
    var displayedResult: String {
        guard case .result(let text) = actionState else { return "" }
        return isResultEditable ? editedResult : text
    }

    /// Currently selected dictionary result for rendering and Listen playback.
    var selectedDictionaryResult: DictionaryProviderResult? {
        guard !dictionaryEntries.isEmpty else { return nil }
        if let selectedDictionaryProvider,
           let selected = dictionaryEntries.first(where: { $0.providerKind == selectedDictionaryProvider }) {
            return selected
        }
        return dictionaryEntries.first
    }

    /// Backward-compatible accessor for code/tests that only care about the
    /// currently selected entry.
    var dictionaryEntry: DictionaryEntry? {
        selectedDictionaryResult?.entry
    }

    // MARK: Diff memoization (I-A)

    /// Precomputed diff segments — set once when the Improve action finalizes.
    /// Empty for non-Improve actions.
    @Published private(set) var diffSegments: [DiffSegment] = []

    // MARK: Phase 3 seam

    /// Inject an ActionEngine here in Phase 3. Nil = placeholder mode.
    weak var actionHandler: (any ToolbarActionHandling)?

    // MARK: Act counter seam

    /// Called by each trigger method immediately before dispatching an action.
    /// Set by `ToolbarController` to record a free-tier act and surface the nag
    /// when due. The view model fires the closure but never checks Pro status —
    /// that guard lives in the controller.
    var onActPerformed: (() -> Void)?

    /// Asks the controller to dismiss (hide) the toolbar. Used by scriptable actions
    /// whose `afterRun` is `.closeToolbar` — the action runs for its side-effect and
    /// then closes the toolbar like a built-in side-effect action.
    /// Set by `ToolbarController`; nil-safe when unset (e.g. in tests).
    var onRequestDismiss: (() -> Void)?

    // MARK: Speak seam

    /// Coordinator that routes speak requests to the appropriate audio backend.
    /// Assigned once by ToolbarController at setup (T2.3).
    weak var speakCoordinator: SpeakCoordinator?

    // MARK: Script action seam

    /// Executor for the four scriptable action types (.openURL, .appleScript,
    /// .shellScript, .runShortcut). Assigned once by ToolbarController at setup,
    /// mirroring the speakCoordinator pattern.
    /// Protocol type allows tests to inject a fake executor without touching this file.
    weak var scriptActionEngine: (any ScriptActionRunning)?

    /// Delivers copy/paste-back output for scriptable actions.
    /// Assigned once by ToolbarController (it owns OutputHandler). Weak to avoid
    /// a retain cycle — ToolbarController holds the strong reference.
    weak var outputHandler: OutputHandler?

    /// Tracks the in-flight scriptable-action task so it can be cancelled on
    /// dismiss (reset()) or when a new selection displaces the current one (update()).
    /// Internal (not private) so tests can `await vm.scriptActionTask?.value` to
    /// drain the task before asserting state transitions.
    var scriptActionTask: Task<Void, Never>?

    /// Cancellables that mirror SpeakCoordinator state into this view model.
    private var speakPhaseCancellable: AnyCancellable?
    private var speakFellBackCancellable: AnyCancellable?
    private var lastSpokenTextCancellable: AnyCancellable?
    private var canReplayCancellable: AnyCancellable?

    /// Bind to a SpeakCoordinator so this view model mirrors its playing state.
    ///
    /// Replaces any existing binding. Called once by ToolbarController at setup.
    func bindSpeakCoordinator(_ coordinator: SpeakCoordinator) {
        speakCoordinator = coordinator
        speakPhaseCancellable = coordinator.$phase
            .sink { [weak self] phase in
                self?.speakPhase = phase
            }
        speakFellBackCancellable = coordinator.$didFallBackToSystem
            .sink { [weak self] fellBack in
                self?.speakFellBack = fellBack
            }
        lastSpokenTextCancellable = coordinator.$lastSpokenText
            .sink { [weak self] text in
                self?.lastSpokenText = text
            }
        canReplayCancellable = coordinator.$canReplay
            .sink { [weak self] canReplay in
                self?.canReplaySpeak = canReplay
            }
    }

    // MARK: - Update from selection event

    /// Called by ToolbarController when a new SelectionEvent arrives.
    func update(text: String, sourceElement: SourceElementRef, screenRect: CGRect?, sourceBundleID: String?, sourceDomain: String? = nil) {
        // Cancel any in-flight script action: a new selection displaces the current one.
        scriptActionTask?.cancel()
        scriptActionTask = nil
        capturedText = text
        self.sourceElement = sourceElement
        selectionScreenRect = screenRect
        self.sourceBundleID = sourceBundleID
        self.sourceDomain = sourceDomain
        // Reset action state when a new selection arrives.
        actionState = .idle
        editedResult = ""
        isEditing = false
        isPromptInputActive = false
        promptDraft = ""
        clearDictionaryState()
        // Stop any audio from the previous selection and drop its replay cache.
        speakCoordinator?.clearReplay()
    }

    // MARK: - Action triggers (called from ToolbarView buttons)

    func triggerImprove() {
        guard !capturedText.isEmpty else { return }
        onActPerformed?()
        cancelScriptAction()
        activeActionKind = .improve
        activeCustomActionID = nil
        isEditing = false
        guard let handler = actionHandler else {
            // Phase 3 not yet wired — show placeholder.
            let placeholder = "[Phase 3] Improve: \(capturedText)"
            actionState = .result(placeholder)
            editedResult = placeholder
            return
        }
        actionState = .running(progress: "")
        handler.improve(text: capturedText, viewModel: self)
    }

    func triggerShorten() {
        guard !capturedText.isEmpty else { return }
        onActPerformed?()
        cancelScriptAction()
        activeActionKind = .shorten
        activeCustomActionID = nil
        isEditing = false
        guard let handler = actionHandler else {
            let placeholder = "[Phase 3] Shorten: \(capturedText)"
            actionState = .result(placeholder)
            editedResult = placeholder
            return
        }
        actionState = .running(progress: "")
        handler.shorten(text: capturedText, viewModel: self)
    }

    func triggerProofread() {
        guard !capturedText.isEmpty else { return }
        onActPerformed?()
        cancelScriptAction()
        activeActionKind = .proofread
        activeCustomActionID = nil
        isEditing = false
        guard let handler = actionHandler else {
            let placeholder = "[Phase 3] Proofread: \(capturedText)"
            actionState = .result(placeholder)
            editedResult = placeholder
            return
        }
        actionState = .running(progress: "")
        handler.proofread(text: capturedText, viewModel: self)
    }

    func triggerDictionaryListen() {
        guard let entry = selectedDictionaryResult?.entry else { return }
        if speakPhase != .idle {
            stopSpeaking()
            return
        }
        speakCoordinator?.speakDictionary(
            headword: entry.headword,
            nativeAudioURL: entry.primaryAudioURL,
            accent: dictionaryAccent,
            settings: dictionarySpeakSettings,
            ttsConfig: dictionaryTTSConfig
        )
    }

    func triggerDictionary() {
        guard !capturedText.isEmpty else { return }
        onActPerformed?()
        cancelScriptAction()
        activeActionKind = nil
        activeCustomActionID = nil
        isDictionaryAction = true
        isDictionaryNotFound = false
        dictionaryEntries = []
        selectedDictionaryProvider = nil
        isEditing = false
        guard let handler = actionHandler else {
            actionState = .error("Dictionary action is not wired")
            return
        }
        actionState = .running(progress: "")
        handler.dictionary(text: capturedText, targetLanguage: dictionaryTargetLanguage, viewModel: self)
    }

    func triggerTranslate() {
        guard !capturedText.isEmpty else { return }
        onActPerformed?()
        cancelScriptAction()
        activeActionKind = .translate
        activeCustomActionID = nil
        isEditing = false
        guard let handler = actionHandler else {
            // Phase 3 not yet wired — show placeholder.
            let placeholder = "[Phase 3] Translate (\(targetLanguage.rawValue)): \(capturedText)"
            actionState = .result(placeholder)
            editedResult = placeholder
            return
        }
        actionState = .running(progress: "")
        handler.translate(text: capturedText, targetLanguage: targetLanguage, viewModel: self)
    }

    func triggerCustomAction(_ action: CustomAction) {
        guard !capturedText.isEmpty else { return }

        // Scriptable actions (.openURL, .runShortcut, .appleScript, .shellScript) are
        // dispatched through ScriptActionEngine — they never reach ActionEngine or
        // ProviderLayer.  Mirror the .speech/.dictionary pattern: early-return, own
        // the full lifecycle (running → execute → deliver/clear).
        if action.isScriptable {

            guard let engine = scriptActionEngine else { return }

            onActPerformed?()
            activeActionKind = nil
            activeCustomActionID = action.id
            isEditing = false

            // Cancel any in-flight AI stream before setting .running so that a
            // late-completing AI cancel() call cannot clobber the state we are
            // about to set.  Cancel any previous script task for the same reason.
            cancelAIAction()
            scriptActionTask?.cancel()

            actionState = .running(progress: "")

            // Capture values before entering the Task (all are value types or Sendable).
            let text = capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
            // fullText is the untrimmed selection — safe ONLY for env-var delivery
            // (POPGUY_FULL_TEXT). Never interpolate into a command string.
            let fullText = capturedText
            let afterRun = action.afterRun
            let capturedSource = sourceElement
            let capturedOutputHandler = outputHandler
            // Captured for history recording (scriptable actions bypass ActionEngine,
            // so they are logged here rather than in ActionEngineHandler).
            let actionTitle = action.title
            let typeLabel = action.type.displayName
            let capturedBundleID = sourceBundleID
            let startedAt = Date()
            scriptActionTask = Task { [weak self] in
                guard let self else { return }

                do {
                    let result = try await engine.run(action, text: text, fullText: fullText)

                    // Guard against cancellation (toolbar dismissed or new selection)
                    // before mutating any state.
                    guard !Task.isCancelled else { return }

                    // Record once, before the afterRun branch, so every delivery
                    // mode (none/copy/paste/show) is logged uniformly.
                    self.actionHandler?.recordScriptAction(
                        actionName: actionTitle,
                        typeLabel: typeLabel,
                        input: text,
                        output: result.text ?? "",
                        success: true,
                        errorMessage: nil,
                        startedAt: startedAt,
                        sourceBundleID: capturedBundleID
                    )

                    switch afterRun {
                    case .closeToolbar:
                        self.finishScriptActionSilently()

                    case .none:
                        self.finishScriptActionKeepingToolbar()

                    case .copyResult:
                        if let text = result.text, !text.isEmpty {
                            capturedOutputHandler?.copy(text)
                        }
                        self.finishScriptActionKeepingToolbar()

                    case .pasteResult:
                        if let text = result.text, !text.isEmpty,
                           let source = capturedSource {
                            await capturedOutputHandler?.pasteBack(text, to: source)
                        }
                        guard !Task.isCancelled else { return }
                        self.finishScriptActionKeepingToolbar()

                    case .showResult:
                        if let text = result.text, !text.isEmpty {
                            self.finishWith(result: text)
                        } else {
                            self.finishScriptActionKeepingToolbar()
                        }
                    }
                } catch is CancellationError {
                    // Task was cancelled (panel dismissed or new selection) —
                    // state was already cleared by reset()/update(), so do nothing.
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self.actionHandler?.recordScriptAction(
                        actionName: actionTitle,
                        typeLabel: typeLabel,
                        input: text,
                        output: "",
                        success: false,
                        errorMessage: error.localizedDescription,
                        startedAt: startedAt,
                        sourceBundleID: capturedBundleID
                    )
                    self.failWith(message: error.localizedDescription)
                }

                self.scriptActionTask = nil
            }
            return
        }

        // Dictionary custom actions share the built-in DictionaryEngine/result
        // renderer, but use the action's own DictionaryConfig instead of the
        // global Look up settings.
        if action.type == .dictionary {
            onActPerformed?()
            cancelScriptAction()
            activeActionKind = nil
            activeCustomActionID = action.id
            isDictionaryAction = true
            isDictionaryNotFound = false
            dictionaryEntries = []
            selectedDictionaryProvider = nil
            let gatedSpeakSettings = action.dictionaryConfig.speakSettings
                .resolvingCloudGate(cloudAllowed: cloudTTSAllowed)
            dictionarySpeakSettings = gatedSpeakSettings
            dictionaryAccent = action.dictionaryConfig.accent
            dictionaryTTSConfig = gatedSpeakSettings.selectedEngine == .system ? .default : action.ttsConfig
            isEditing = false
            guard let handler = actionHandler else {
                actionState = .error("Dictionary action is not wired")
                return
            }
            actionState = .running(progress: "")
            handler.dictionary(
                text: capturedText,
                config: action.dictionaryConfig,
                actionName: action.title,
                viewModel: self
            )
            return
        }

        // Speech custom actions are orthogonal to the text-result state machine,
        // just like the built-in Speak button. Route them through SpeakCoordinator
        // instead of ActionEngine.
        if action.type == .speech {
            // Mirror triggerSpeak: a non-empty trimmed text guard, toggle-to-stop
            // before counting the act, and no actionState/activeActionKind mutations.
            guard !capturedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if speakPhase != .idle {
                stopSpeaking()
                return
            }
            // Count the act only when speech actually starts (not on stop).
            onActPerformed?()
            // Apply the cloud gate: if the user is not Pro, resolvingCloudGate
            // forces the engine to .system, preventing non-Pro access to cloud TTS.
            let gatedSettings = action.speakSettings.resolvingCloudGate(cloudAllowed: cloudTTSAllowed)
            speakCoordinator?.speak(
                capturedText,
                accent: action.speakSettings.defaultAccent,
                settings: gatedSettings,
                ttsConfig: action.ttsConfig
            )
            actionHandler?.recordSpeak(
                text: capturedText,
                engineLabel: action.speakSettings.selectedEngine.displayName,
                accent: action.speakSettings.defaultAccent.displayName,
                sourceBundleID: sourceBundleID
            )
            return
        }

        onActPerformed?()
        cancelScriptAction()
        // Custom AI/translation actions are not diffed — leave activeActionKind = nil
        // so ToolbarView uses plain-text rendering (the == .improve gate in
        // finishWith + resultArea).
        activeActionKind = nil
        activeCustomActionID = action.id
        isEditing = false
        guard let handler = actionHandler else {
            let placeholder = "[Phase 5] \(action.title): \(capturedText)"
            actionState = .result(placeholder)
            editedResult = placeholder
            return
        }
        actionState = .running(progress: "")
        handler.custom(action: action, text: capturedText, viewModel: self)
    }

    /// Toggle the inline prompt input area. Opening requires a non-empty selection;
    /// a second tap (while open) cancels and clears the draft.
    func triggerPromptInput() {
        guard !capturedText.isEmpty else { return }
        if isPromptInputActive {
            cancelPromptInput()
        } else {
            isPromptInputActive = true
        }
    }

    /// Close the prompt input area and discard the draft.
    func cancelPromptInput() {
        isPromptInputActive = false
        promptDraft = ""
    }

    /// Run the typed prompt against the captured text. No-op when the draft or the
    /// selection is empty. Dispatches through the custom-action path (ActionEngine
    /// applies the {{text}} placeholder — implicitly when omitted, verbatim when present).
    func runPrompt() {
        let trimmed = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !capturedText.isEmpty else { return }
        onActPerformed?()
        cancelScriptAction()
        activeActionKind = .prompt
        activeCustomActionID = nil
        isEditing = false
        isPromptInputActive = false
        guard let handler = actionHandler else {
            let placeholder = "[Phase] Prompt: \(capturedText)"
            actionState = .result(placeholder)
            editedResult = placeholder
            promptDraft = ""
            return
        }
        actionState = .running(progress: "")
        handler.prompt(promptText: trimmed, text: capturedText, viewModel: self)
        promptDraft = ""
    }

    /// Speak the captured text using the given accent, or the currently selected
    /// accent when `accent` is nil. If already speaking, stops playback instead.
    ///
    /// Orthogonal to the text-result state machine — does not touch actionState
    /// or activeActionKind.
    func triggerSpeak(accent: SpeakAccent?) {
        // Match SpeakCoordinator.speak, which trims before deciding to play, so a
        // whitespace-only selection never logs a phantom Speak record.
        guard !capturedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if speakPhase != .idle {
            stopSpeaking()
            return
        }
        // Only count when a speak actually starts (not on the toggle-to-stop path above).
        onActPerformed?()
        let resolvedAccent = accent ?? selectedSpeakAccent
        speakCoordinator?.speak(
            capturedText,
            accent: resolvedAccent,
            settings: speakSettings,
            ttsConfig: ttsConfig
        )
        // Log the run to history (no-op when history is disabled). Recorded at
        // trigger time — the selected engine, not the actual playback backend
        // (dictionary/fallback are resolved later inside SpeakCoordinator).
        actionHandler?.recordSpeak(
            text: capturedText,
            engineLabel: speakSettings.selectedEngine.displayName,
            accent: resolvedAccent.displayName,
            sourceBundleID: sourceBundleID
        )
    }

    /// Stop any in-progress speech playback. Keeps the replay cache so the
    /// toolbar's "Listen again" affordance survives a Stop tap.
    func stopSpeaking() {
        speakCoordinator?.stop()
    }

    /// Re-play the last spoken text using the cached audio (no new request).
    /// Not an "act": never counts toward the free-tier nag or history.
    func replaySpeak() {
        speakCoordinator?.replay()
    }

    // MARK: - Callbacks from ActionEngine (Phase 3 will call these)

    /// Append a streamed token to the running progress text.
    func appendProgress(_ token: String) {
        if case .running(let existing) = actionState {
            actionState = .running(progress: existing + token)
        }
    }

    /// Select which provider's successful dictionary result is shown.
    func selectDictionaryProvider(_ provider: DictionaryProviderKind) {
        guard dictionaryEntries.contains(where: { $0.providerKind == provider }) else { return }
        selectedDictionaryProvider = provider
    }

    /// Mark a dictionary lookup as successfully completed.
    func finishWithDictionary(_ entry: DictionaryEntry) {
        finishWithDictionaryResults([
            DictionaryProviderResult(providerKind: .macOSBuiltin, entry: entry)
        ])
    }

    /// Mark a multi-provider dictionary lookup as successfully completed.
    func finishWithDictionaryResults(_ results: [DictionaryProviderResult]) {
        guard let first = results.first else {
            finishWithDictionaryNotFound()
            return
        }
        isDictionaryAction = true
        isDictionaryNotFound = false
        dictionaryEntries = results
        if let currentProvider = selectedDictionaryProvider,
           results.contains(where: { $0.providerKind == currentProvider }) {
            selectedDictionaryProvider = currentProvider
        } else {
            selectedDictionaryProvider = first.providerKind
        }
        diffSegments = []
        let preview = dictionaryPreview(for: selectedDictionaryResult?.entry ?? first.entry)
        actionState = .result(preview)
        editedResult = preview
        isEditing = false
    }

    /// Mark a dictionary lookup as completed with no definition found.
    func finishWithDictionaryNotFound() {
        isDictionaryAction = true
        isDictionaryNotFound = true
        dictionaryEntries = []
        selectedDictionaryProvider = nil
        diffSegments = []
        actionState = .result("")
        editedResult = ""
        isEditing = false
    }

    /// Mark the action as successfully completed.
    func finishWith(result: String) {
        clearDictionaryState()
        // I-A: compute diff ONCE here, not on every body re-evaluation in the view.
        // Improve and Proofread render a diff (their output closely mirrors the
        // input, so highlighting what changed is the point of the result view).
        if activeActionKind == .improve || activeActionKind == .proofread {
            diffSegments = DiffAlgorithm.diff(original: capturedText, improved: result)
        } else {
            diffSegments = []
        }
        actionState = .result(result)
        editedResult = result
        isEditing = false
    }

    /// Mark the action as failed.
    func failWith(message: String) {
        if isDictionaryAction {
            dictionaryEntries = []
            selectedDictionaryProvider = nil
            isDictionaryNotFound = false
        }
        actionState = .error(message)
    }

    // MARK: - Engine mutual-cancellation helpers

    /// Cancel any in-flight script action and clear its handle.
    /// Call before starting an AI/built-in action to prevent a late-completing
    /// script action from overwriting the new terminal state.
    private func cancelScriptAction() {
        scriptActionTask?.cancel()
        scriptActionTask = nil
    }

    /// Cancel any in-flight AI stream action.
    /// Call before starting a scriptable action to prevent a late-completing
    /// AI stream from overwriting the new terminal state.
    private func cancelAIAction() {
        actionHandler?.cancel()
    }

    // MARK: - Reset

    /// Terminal state for a scriptable action whose `afterRun` is `.closeToolbar`:
    /// clear running state and ask the controller to dismiss the toolbar.
    private func finishScriptActionSilently() {
        actionState = .idle
        activeCustomActionID = nil
        onRequestDismiss?()
    }

    /// Terminal state for a scriptable action that keeps the toolbar open:
    /// clear running state and return to idle so the action buttons reappear.
    /// Used for `afterRun` = none / copyResult / pasteResult (and showResult with
    /// empty output).
    private func finishScriptActionKeepingToolbar() {
        actionState = .idle
        activeCustomActionID = nil
    }

    /// Return to idle state (e.g., when the panel is dismissed).
    func reset() {
        // Cancel any in-flight script action (panel dismissed mid-run).
        scriptActionTask?.cancel()
        scriptActionTask = nil
        actionState = .idle
        activeActionKind = nil
        activeCustomActionID = nil
        clearDictionaryState()
        diffSegments = []
        editedResult = ""
        isEditing = false
        isShowingCloseConfirmation = false
        isPromptInputActive = false
        promptDraft = ""
        sourceDomain = nil
        speakCoordinator?.clearReplay()
    }

    // MARK: - Edit buffer control

    /// Enter edit mode for the current result. The view calls this when the user
    /// taps the Edit button; state mutations go through here, not directly from
    /// the view, to keep write paths centralised.
    func beginEditing() { isEditing = true }

    private func clearDictionaryState() {
        isDictionaryAction = false
        dictionaryEntries = []
        selectedDictionaryProvider = nil
        isDictionaryNotFound = false
    }

    private func dictionaryPreview(for entry: DictionaryEntry) -> String {
        entry.lexicalEntries.first?.senses.first?.definition
            ?? entry.rawText
            ?? entry.headword
    }

    /// Exit edit mode. Does not discard `editedResult` — callers decide whether
    /// to apply or discard the buffer contents before calling this.
    func endEditing() { isEditing = false }
}
