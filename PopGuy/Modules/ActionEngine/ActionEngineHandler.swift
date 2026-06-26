// ActionEngineHandler.swift
// PopGuy — ActionEngine
//
// Implements ToolbarActionHandling by dispatching through ActionEngine.
//
// Isolation: @MainActor — ToolbarActionHandling is @MainActor.
// All @MainActor state (SettingsStore, KeychainManager) is read synchronously
// on the MainActor before the async dispatch; the resulting Sendable snapshot
// (ActionConfig + String key) is handed to the nonisolated ActionEngine.
// Each streaming Task resumes appendProgress / finishWith / failWith on the
// MainActor so the view model stays consistent.

import Foundation
import AppKit

// MARK: - ActionEngineHandler

/// Bridges the @MainActor toolbar to the nonisolated ActionEngine.
@MainActor
final class ActionEngineHandler: ToolbarActionHandling {

    // MARK: - Dependencies

    private let engine: ActionEngine
    private let settings: SettingsStore
    private let keychain: KeychainManager
    private let history: HistoryStore

    // Track the current streaming task so it can be cancelled on new triggers.
    private var streamTask: Task<Void, Never>?

    // Generation token for I1 fix: each new improve/translate run increments this.
    // Tasks guard every viewModel mutation — if a newer run has bumped generation,
    // a stale (cancelled or racing) task returns without touching the view model.
    private var generation = 0

    // MARK: - Init

    init(settings: SettingsStore, keychain: KeychainManager, history: HistoryStore) {
        self.engine   = ActionEngine(providerFactory: ActionEngine.makeDefaultFactory())
        self.settings = settings
        self.keychain = keychain
        self.history  = history
    }

    // MARK: - History recording

    /// Log a completed run to HistoryStore when history is enabled.
    ///
    /// Takes the source bundle ID captured at *dispatch* time — not read from the
    /// view model here — because `viewModel.sourceBundleID` can be replaced by a
    /// new selection (trigger-on-select) while this run is still streaming, which
    /// would misattribute the record to the wrong app. App-name resolution still
    /// happens at record-time (falling back to the bundle ID when the app quit).
    private func recordHistory(
        actionName: String,
        providerKind: ProviderKind?,
        providerLabel: String? = nil,
        model: String,
        input: String,
        output: String,
        success: Bool,
        errorMessage: String?,
        startedAt: Date,
        sourceBundleID: String?
    ) {
        guard settings.historyEnabled else { return }

        let appName: String?
        if let sourceBundleID {
            appName = NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == sourceBundleID }?.localizedName ?? sourceBundleID
        } else {
            appName = nil
        }

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        history.record(
            actionName: actionName,
            providerKind: providerKind,
            providerLabel: providerLabel,
            model: model,
            sourceBundleID: sourceBundleID,
            sourceAppName: appName,
            durationMs: durationMs,
            success: success,
            errorMessage: errorMessage,
            input: input,
            output: output,
            storeFullText: settings.historyStoreFullText
        )
    }

    // MARK: - Speak

    /// Log a Speak run. Speak produces audio rather than text, so this records the
    /// spoken text as `input` with an empty `output`, the selected TTS engine as the
    /// provider label, and the accent as the model. Recorded at trigger time, so
    /// `success` is always true and duration ≈ 0 — playback outcome is not tracked
    /// (SpeakCoordinator handles routing/fallback independently).
    func recordSpeak(text: String, engineLabel: String, accent: String, sourceBundleID: String?) {
        recordHistory(
            actionName: "Speak",
            providerKind: nil,
            providerLabel: engineLabel,
            model: accent,
            input: text,
            output: "",
            success: true,
            errorMessage: nil,
            startedAt: Date(),
            sourceBundleID: sourceBundleID
        )
    }

    // MARK: - Script actions

    /// Log a scriptable custom action run. Scriptable actions have no provider,
    /// so the action type (e.g. "Shell Script") is recorded as the provider label.
    func recordScriptAction(actionName: String, typeLabel: String, input: String, output: String, success: Bool, errorMessage: String?, startedAt: Date, sourceBundleID: String?) {
        recordHistory(
            actionName: actionName,
            providerKind: nil,
            providerLabel: typeLabel,
            model: "",
            input: input,
            output: output,
            success: success,
            errorMessage: errorMessage,
            startedAt: startedAt,
            sourceBundleID: sourceBundleID
        )
    }

    // MARK: - Base URL resolution

    /// Resolve the correct base URL override string for a provider kind.
    ///
    /// Each provider must hit its own endpoint — never `api.openai.com` unless
    /// the kind is actually `.openAI`. This helper centralises the routing so it
    /// is impossible for a new dispatch site to accidentally omit a case.
    ///
    /// - `.ollama`     → user-configured Ollama/LM Studio URL
    /// - `.glm`        → GLM's fixed OpenAI-compatible base URL
    /// - `.openRouter` → OpenRouter's fixed base URL
    /// - `.custom`     → user-configured custom base URL
    /// - `.gemini`     → nil  (GeminiProvider uses its own native base; MUST NOT be redirected)
    /// - CLI kinds     → nil  (CLI adapters spawn a subprocess, no HTTP base URL)
    /// - all others    → nil  (adapter uses its own hard-coded base URL)
    private func resolveBaseURL(for kind: ProviderKind) -> String? {
        switch kind {
        case .ollama:
            return settings.ollamaBaseURL
        case .glm, .openRouter:
            return kind.defaultBaseURL?.absoluteString
        case .custom:
            return settings.customBaseURL.isEmpty ? nil : settings.customBaseURL
        case .openAI, .anthropic, .gemini, .deepL, .googleTranslate:
            return nil
        case .claudeCLI, .codexCLI, .geminiCLI:
            return nil
        case .mlxLocal:
            // MLX helper path is resolved internally by MLXHelperManager.
            return nil
        }
    }

    /// Resolve the absolute path to the CLI binary for a provider kind.
    ///
    /// Returns the configured path from SettingsStore for CLI providers.
    /// Returns `nil` for HTTP-backed providers (they don't use an executable path).
    /// An empty string from SettingsStore is treated as nil (not configured).
    private func resolveExecutablePath(for kind: ProviderKind) -> String? {
        switch kind {
        case .claudeCLI:
            let p = settings.claudeCLIPath
            return p.isEmpty ? nil : p
        case .codexCLI:
            let p = settings.codexCLIPath
            return p.isEmpty ? nil : p
        case .geminiCLI:
            let p = settings.geminiCLIPath
            return p.isEmpty ? nil : p
        case .openAI, .anthropic, .ollama, .deepL, .googleTranslate, .gemini, .glm, .openRouter, .custom,
             .mlxLocal:
            return nil
        }
    }

    // MARK: - ToolbarActionHandling

    func improve(text: String, viewModel: ToolbarViewModel) {
        cancelCurrentTask()
        generation += 1
        let myGen = generation
        let config = settings.config(for: .improve)
        let apiKey = keychain.key(for: config.providerKind) ?? ""
        let baseURLOverride = resolveBaseURL(for: config.providerKind)
        let executablePath = resolveExecutablePath(for: config.providerKind)
        // Read customPrompt from improveConfig directly (config(for:) returns the
        // full ActionConfig including customPrompt).
        let customPrompt = config.customPrompt
        let preserveFormatting = settings.preserveFormatting
        let globalPrompt = settings.globalPrompt

        let startedAt = Date()
        // Snapshot the source app now; viewModel.sourceBundleID may change mid-stream.
        let sourceBundleID = viewModel.sourceBundleID
        streamTask = Task { @MainActor in
            do {
                let stream = try await engine.dispatch(
                    action: .improve(customPrompt: customPrompt, tone: config.tone ?? .neutral),
                    input: text,
                    config: config,
                    apiKey: apiKey,
                    baseURLOverride: baseURLOverride,
                    executablePathOverride: executablePath,
                    preserveFormatting: preserveFormatting,
                    globalPrompt: globalPrompt
                )
                var accumulated = ""
                for try await token in stream {
                    guard myGen == self.generation else { return }
                    accumulated += token
                    viewModel.appendProgress(token)
                }
                guard myGen == self.generation else { return }
                viewModel.finishWith(result: accumulated)
                recordHistory(actionName: "Improve", providerKind: config.providerKind, model: config.model,
                              input: text, output: accumulated, success: true, errorMessage: nil,
                              startedAt: startedAt, sourceBundleID: sourceBundleID)
            } catch {
                guard myGen == self.generation else { return }
                viewModel.failWith(message: error.localizedDescription)
                recordHistory(actionName: "Improve", providerKind: config.providerKind, model: config.model,
                              input: text, output: "", success: false, errorMessage: error.localizedDescription,
                              startedAt: startedAt, sourceBundleID: sourceBundleID)
            }
        }
    }

    func shorten(text: String, viewModel: ToolbarViewModel) {
        cancelCurrentTask()
        generation += 1
        let myGen = generation
        let config = settings.config(for: .shorten)
        let apiKey = keychain.key(for: config.providerKind) ?? ""
        let baseURLOverride = resolveBaseURL(for: config.providerKind)
        let executablePath = resolveExecutablePath(for: config.providerKind)
        let customPrompt = config.customPrompt
        let preserveFormatting = settings.preserveFormatting
        let globalPrompt = settings.globalPrompt

        let startedAt = Date()
        // Snapshot the source app now; viewModel.sourceBundleID may change mid-stream.
        let sourceBundleID = viewModel.sourceBundleID
        streamTask = Task { @MainActor in
            do {
                let stream = try await engine.dispatch(
                    action: .shorten(customPrompt: customPrompt, tone: config.tone ?? .neutral),
                    input: text,
                    config: config,
                    apiKey: apiKey,
                    baseURLOverride: baseURLOverride,
                    executablePathOverride: executablePath,
                    preserveFormatting: preserveFormatting,
                    globalPrompt: globalPrompt
                )
                var accumulated = ""
                for try await token in stream {
                    guard myGen == self.generation else { return }
                    accumulated += token
                    viewModel.appendProgress(token)
                }
                guard myGen == self.generation else { return }
                viewModel.finishWith(result: accumulated)
                recordHistory(actionName: "Shorten", providerKind: config.providerKind, model: config.model,
                              input: text, output: accumulated, success: true, errorMessage: nil,
                              startedAt: startedAt, sourceBundleID: sourceBundleID)
            } catch {
                guard myGen == self.generation else { return }
                viewModel.failWith(message: error.localizedDescription)
                recordHistory(actionName: "Shorten", providerKind: config.providerKind, model: config.model,
                              input: text, output: "", success: false, errorMessage: error.localizedDescription,
                              startedAt: startedAt, sourceBundleID: sourceBundleID)
            }
        }
    }

    func proofread(text: String, viewModel: ToolbarViewModel) {
        cancelCurrentTask()
        generation += 1
        let myGen = generation
        let config = settings.config(for: .proofread)
        let apiKey = keychain.key(for: config.providerKind) ?? ""
        let baseURLOverride = resolveBaseURL(for: config.providerKind)
        let executablePath = resolveExecutablePath(for: config.providerKind)
        let customPrompt = config.customPrompt
        let preserveFormatting = settings.preserveFormatting
        let globalPrompt = settings.globalPrompt

        let startedAt = Date()
        // Snapshot the source app now; viewModel.sourceBundleID may change mid-stream.
        let sourceBundleID = viewModel.sourceBundleID
        streamTask = Task { @MainActor in
            do {
                let stream = try await engine.dispatch(
                    action: .proofread(customPrompt: customPrompt),
                    input: text,
                    config: config,
                    apiKey: apiKey,
                    baseURLOverride: baseURLOverride,
                    executablePathOverride: executablePath,
                    preserveFormatting: preserveFormatting,
                    globalPrompt: globalPrompt
                )
                var accumulated = ""
                for try await token in stream {
                    guard myGen == self.generation else { return }
                    accumulated += token
                    viewModel.appendProgress(token)
                }
                guard myGen == self.generation else { return }
                viewModel.finishWith(result: accumulated)
                recordHistory(actionName: "Proofread", providerKind: config.providerKind, model: config.model,
                              input: text, output: accumulated, success: true, errorMessage: nil,
                              startedAt: startedAt, sourceBundleID: sourceBundleID)
            } catch {
                guard myGen == self.generation else { return }
                viewModel.failWith(message: error.localizedDescription)
                recordHistory(actionName: "Proofread", providerKind: config.providerKind, model: config.model,
                              input: text, output: "", success: false, errorMessage: error.localizedDescription,
                              startedAt: startedAt, sourceBundleID: sourceBundleID)
            }
        }
    }

    func custom(action: CustomAction, text: String, viewModel: ToolbarViewModel) {
        // Speech, Dictionary, and scriptable actions must never reach here — they are
        // routed through their own coordinators / executors in ToolbarViewModel.
        // Guard up front before any state mutations (cancelCurrentTask /
        // generation) so a stray call cannot cancel an in-flight AI/translation stream.
        guard action.type != .speech,
              action.type != .dictionary,
              action.type != .openURL,
              action.type != .runShortcut,
              action.type != .appleScript,
              action.type != .shellScript
        else { return }

        cancelCurrentTask()
        generation += 1
        let myGen = generation

        // Custom actions use the action's own providerKind and model.
        // ActionConfig.id must be a built-in ActionKind; .improve is used as a
        // neutral placeholder — ActionEngine ignores config.id for Action.custom
        // (it reads only config.providerKind and config.model at dispatch time).
        let config = ActionConfig(
            id: .improve,
            providerKind: action.providerKind,
            model: action.model
        )
        let apiKey = keychain.key(for: action.providerKind) ?? ""
        let baseURLOverride = resolveBaseURL(for: action.providerKind)
        let executablePath = resolveExecutablePath(for: action.providerKind)
        let preserveFormatting = settings.preserveFormatting
        let globalPrompt = settings.globalPrompt

        // Choose the engine action based on the custom action's type.
        // .ai          → .custom(prompt:) — free-form system prompt.
        // .translation → .translate(...)  — structured translation request.
        let engineAction: Action
        switch action.type {
        case .ai:
            engineAction = .custom(prompt: action.systemPrompt)
        case .translation:
            engineAction = .translate(
                targetLanguage: action.targetLanguage,
                customPrompt: action.systemPrompt.isEmpty ? nil : action.systemPrompt,
                tone: action.tone
            )
        case .speech, .dictionary, .openURL, .runShortcut, .appleScript, .shellScript:
            // Already guarded above; these cases are unreachable.
            return
        }

        let startedAt = Date()
        // Snapshot the source app now; viewModel.sourceBundleID may change mid-stream.
        let sourceBundleID = viewModel.sourceBundleID
        streamTask = Task { @MainActor in
            do {
                let stream = try await engine.dispatch(
                    action: engineAction,
                    input: text,
                    config: config,
                    apiKey: apiKey,
                    baseURLOverride: baseURLOverride,
                    executablePathOverride: executablePath,
                    preserveFormatting: preserveFormatting,
                    globalPrompt: globalPrompt
                )
                var accumulated = ""
                for try await token in stream {
                    guard myGen == self.generation else { return }
                    accumulated += token
                    viewModel.appendProgress(token)
                }
                guard myGen == self.generation else { return }
                viewModel.finishWith(result: accumulated)
                recordHistory(actionName: action.title, providerKind: action.providerKind, model: action.model,
                              input: text, output: accumulated, success: true, errorMessage: nil,
                              startedAt: startedAt, sourceBundleID: sourceBundleID)
            } catch {
                guard myGen == self.generation else { return }
                viewModel.failWith(message: error.localizedDescription)
                recordHistory(actionName: action.title, providerKind: action.providerKind, model: action.model,
                              input: text, output: "", success: false, errorMessage: error.localizedDescription,
                              startedAt: startedAt, sourceBundleID: sourceBundleID)
            }
        }
    }

    func prompt(promptText: String, text: String, viewModel: ToolbarViewModel) {
        cancelCurrentTask()
        generation += 1
        let myGen = generation
        let config = settings.config(for: .prompt)
        let apiKey = keychain.key(for: config.providerKind) ?? ""
        let baseURLOverride = resolveBaseURL(for: config.providerKind)
        let executablePath = resolveExecutablePath(for: config.providerKind)
        let preserveFormatting = settings.preserveFormatting
        let globalPrompt = settings.globalPrompt

        let startedAt = Date()
        // Snapshot the source app now; viewModel.sourceBundleID may change mid-stream.
        let sourceBundleID = viewModel.sourceBundleID
        streamTask = Task { @MainActor in
            do {
                let stream = try await engine.dispatch(
                    action: .custom(prompt: promptText),
                    input: text,
                    config: config,
                    apiKey: apiKey,
                    baseURLOverride: baseURLOverride,
                    executablePathOverride: executablePath,
                    preserveFormatting: preserveFormatting,
                    globalPrompt: globalPrompt
                )
                var accumulated = ""
                for try await token in stream {
                    guard myGen == self.generation else { return }
                    accumulated += token
                    viewModel.appendProgress(token)
                }
                guard myGen == self.generation else { return }
                viewModel.finishWith(result: accumulated)
                recordHistory(actionName: "Prompt", providerKind: config.providerKind, model: config.model,
                              input: text, output: accumulated, success: true, errorMessage: nil,
                              startedAt: startedAt, sourceBundleID: sourceBundleID)
            } catch {
                guard myGen == self.generation else { return }
                viewModel.failWith(message: error.localizedDescription)
                recordHistory(actionName: "Prompt", providerKind: config.providerKind, model: config.model,
                              input: text, output: "", success: false, errorMessage: error.localizedDescription,
                              startedAt: startedAt, sourceBundleID: sourceBundleID)
            }
        }
    }

    func translate(text: String, targetLanguage: TargetLanguage, viewModel: ToolbarViewModel) {
        cancelCurrentTask()
        generation += 1
        let myGen = generation
        let config = settings.config(for: .translate)
        let apiKey = keychain.key(for: config.providerKind) ?? ""
        let baseURLOverride = resolveBaseURL(for: config.providerKind)
        let executablePath = resolveExecutablePath(for: config.providerKind)
        let preserveFormatting = settings.preserveFormatting
        let globalPrompt = settings.globalPrompt

        let startedAt = Date()
        // Snapshot the source app now; viewModel.sourceBundleID may change mid-stream.
        let sourceBundleID = viewModel.sourceBundleID
        streamTask = Task { @MainActor in
            do {
                let stream = try await engine.dispatch(
                    action: .translate(
                        targetLanguage: targetLanguage.bcp47,
                        customPrompt: config.customPrompt,
                        tone: config.tone ?? .neutral
                    ),
                    input: text,
                    config: config,
                    apiKey: apiKey,
                    baseURLOverride: baseURLOverride,
                    executablePathOverride: executablePath,
                    preserveFormatting: preserveFormatting,
                    globalPrompt: globalPrompt
                )
                var accumulated = ""
                for try await token in stream {
                    guard myGen == self.generation else { return }
                    accumulated += token
                    viewModel.appendProgress(token)
                }
                guard myGen == self.generation else { return }
                viewModel.finishWith(result: accumulated)
                recordHistory(actionName: "Translate", providerKind: config.providerKind, model: config.model,
                              input: text, output: accumulated, success: true, errorMessage: nil,
                              startedAt: startedAt, sourceBundleID: sourceBundleID)
            } catch {
                guard myGen == self.generation else { return }
                viewModel.failWith(message: error.localizedDescription)
                recordHistory(actionName: "Translate", providerKind: config.providerKind, model: config.model,
                              input: text, output: "", success: false, errorMessage: error.localizedDescription,
                              startedAt: startedAt, sourceBundleID: sourceBundleID)
            }
        }
    }

    // MARK: - Dictionary

    func dictionary(text: String, targetLanguage: TargetLanguage, viewModel: ToolbarViewModel) {
        var config = settings.dictionaryConfig
        // Override with the per-call target language from the toolbar picker.
        config.definitionLanguage = targetLanguage.bcp47
        let babylonDictionaries = settings.babylonDictionaries
        // Built-in Look up queries every provider concurrently.
        runDictionary(
            text: text,
            definitionLanguage: config.definitionLanguage,
            actionName: "Look up",
            missProviderLabel: "All dictionary providers",
            viewModel: viewModel
        ) {
            try await DictionaryEngine().lookupAll(
                term: text,
                config: config,
                babylonDictionaries: babylonDictionaries
            )
        }
    }

    func dictionary(text: String, config: DictionaryConfig, actionName: String, viewModel: ToolbarViewModel) {
        let resolvedActionName = actionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Dictionary"
            : actionName
        let babylonDictionaries = settings.babylonDictionaries
        // A custom Dictionary action targets the single provider chosen in its form,
        // unlike the built-in Look up which aggregates every provider.
        runDictionary(
            text: text,
            definitionLanguage: config.definitionLanguage,
            actionName: resolvedActionName,
            missProviderLabel: config.provider.displayName,
            viewModel: viewModel
        ) {
            let entry = try await DictionaryEngine().lookup(
                term: text,
                config: config,
                babylonDictionaries: babylonDictionaries
            )
            return [DictionaryProviderResult(providerKind: config.provider, entry: entry)]
        }
    }

    /// Shared runner for both dictionary paths. `fetch` returns the provider results
    /// (all providers for built-in Look up, a single provider for custom actions);
    /// success/not-found/error handling and history recording are identical.
    private func runDictionary(
        text: String,
        definitionLanguage: String,
        actionName: String,
        missProviderLabel: String,
        viewModel: ToolbarViewModel,
        fetch: @escaping () async throws -> [DictionaryProviderResult]
    ) {
        cancelCurrentTask()
        generation += 1
        let myGen = generation
        let startedAt = Date()
        let sourceBundleID = viewModel.sourceBundleID

        streamTask = Task { @MainActor in
            do {
                let results = try await fetch()
                guard myGen == self.generation else { return }
                viewModel.finishWithDictionaryResults(results)
                let outputPreview = results
                    .map { Self.dictionaryPreview(for: $0.entry) }
                    .joined(separator: "\n\n")
                let providerLabel = results
                    .map { $0.providerKind.displayName }
                    .joined(separator: ", ")
                recordHistory(
                    actionName: actionName,
                    providerKind: nil,
                    providerLabel: providerLabel,
                    model: definitionLanguage,
                    input: text,
                    output: outputPreview,
                    success: true,
                    errorMessage: nil,
                    startedAt: startedAt,
                    sourceBundleID: sourceBundleID
                )
            } catch DictionaryLookupError.notFound {
                guard myGen == self.generation else { return }
                viewModel.finishWithDictionaryNotFound()
                // A notFound outcome is a definitive miss, not a successful lookup —
                // record it as a failure so history filters/analytics don't conflate
                // "no definition found" with a genuinely successful result.
                recordHistory(
                    actionName: actionName,
                    providerKind: nil,
                    providerLabel: missProviderLabel,
                    model: definitionLanguage,
                    input: text,
                    output: "",
                    success: false,
                    errorMessage: "No definition found",
                    startedAt: startedAt,
                    sourceBundleID: sourceBundleID
                )
            } catch {
                guard myGen == self.generation else { return }
                let message: String
                if let lookupError = error as? DictionaryLookupError {
                    message = Self.dictionaryErrorMessage(lookupError)
                } else {
                    message = error.localizedDescription
                }
                viewModel.failWith(message: message)
                recordHistory(
                    actionName: actionName,
                    providerKind: nil,
                    providerLabel: missProviderLabel,
                    model: definitionLanguage,
                    input: text,
                    output: "",
                    success: false,
                    errorMessage: message,
                    startedAt: startedAt,
                    sourceBundleID: sourceBundleID
                )
            }
        }
    }

    private static func dictionaryErrorMessage(_ error: DictionaryLookupError) -> String {
        switch error {
        case .notFound:
            return "No definition found"
        case .network(let underlying):
            return "Dictionary lookup failed: \(underlying)"
        case .rateLimited:
            return "Dictionary rate limit reached. Try again later."
        case .decoding(let detail):
            return "Could not read dictionary response: \(detail)"
        }
    }

    private static func dictionaryPreview(for entry: DictionaryEntry) -> String {
        entry.lexicalEntries.first?.senses.first?.definition
            ?? entry.rawText
            ?? entry.headword
    }

    // MARK: - Lifecycle

    func cancel() {
        cancelCurrentTask()
    }

    private func cancelCurrentTask() {
        // Bump the generation BEFORE cancelling so the in-flight task's
        // `myGen == generation` guards all fail — its terminal finishWith/failWith
        // then no-op even if the cancelled stream resumes with nil (not a throw).
        // Without this, a cancel() with no subsequent run (e.g. hide()) leaves
        // `generation` unchanged, letting a late completion resurrect a result
        // onto the already-reset/hidden view model.
        generation += 1
        streamTask?.cancel()
        streamTask = nil
    }
}
