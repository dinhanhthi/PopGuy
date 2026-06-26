// CustomActionsView.swift
// PopGuy — UI/SettingsWindow
//
// Modal sheet for creating or editing a custom action.
// CustomActionsView (the old "Custom" tab) was removed in T8.1 — its
// functionality is now surfaced through the card-based ActionsView tab.
//
// Isolation: @MainActor — all views are implicitly @MainActor under
// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - CustomActionEditSheet

/// Modal sheet for creating or editing a custom action.
/// Internal so ActionsView can present this sheet.
struct CustomActionEditSheet: View {

    @State private var draft: CustomAction
    @State private var showIconPicker = false
    /// Suppresses the per-type `afterRun` default that `.onChange(of: draft.type)`
    /// would otherwise apply when a preset changes the action type. The preset's
    /// own `afterRun` is assigned in the same pass; without this flag, the onChange
    /// fires in the next SwiftUI update pass and overwrites it.
    @State private var suppressAfterRunReset = false
    @ObservedObject var settings: SettingsStore
    let keychain: KeychainManager
    @ObservedObject var licenseGate: LicenseGate
    var onUpgrade: () -> Void = {}
    let onSave: (CustomAction) -> Void
    let onCancel: () -> Void

    // Language list — mirrors the list in ActionsView for the Translation branch.
    private let languages: [(name: String, bcp47: String)] = [
        ("English",              "en"),
        ("Vietnamese",           "vi"),
        ("French",               "fr"),
        ("Spanish",              "es"),
        ("German",               "de"),
        ("Japanese",             "ja"),
        ("Chinese (Simplified)", "zh"),
        ("Korean",               "ko"),
        ("Portuguese",           "pt"),
        ("Italian",              "it"),
    ]

    init(
        action: CustomAction,
        settings: SettingsStore,
        keychain: KeychainManager,
        licenseGate: LicenseGate,
        onUpgrade: @escaping () -> Void = {},
        onSave: @escaping (CustomAction) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: action)
        self.settings = settings
        self.keychain = keychain
        self.licenseGate = licenseGate
        self.onUpgrade = onUpgrade
        self.onSave = onSave
        self.onCancel = onCancel
    }

    // MARK: - Preset application

    /// Copies the content fields from a preset into the draft, preserving the
    /// draft's existing `id` and `isEnabled`. The suppression flag tells
    /// `.onChange(of: draft.type)` not to override `afterRun` with the per-type
    /// default — the preset's own value is already written and must win.
    private func applyPreset(_ preset: CustomAction) {
        let typeWillChange = draft.type != preset.type
        if typeWillChange {
            suppressAfterRunReset = true
        }
        draft.title = preset.title
        draft.icon = preset.icon
        draft.type = preset.type
        draft.scriptSource = preset.scriptSource
        draft.afterRun = preset.afterRun
        draft.appliesWhenRegex = preset.appliesWhenRegex
        // Intentionally not copying: id (preserves identity), isEnabled (user preference),
        // systemPrompt (unused by scriptable presets), and provider/model/speech/etc.
    }

    // MARK: - Save validation

    private var saveDisabled: Bool { !draft.isSaveable }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — live icon + title preview of the action being edited.
            HStack(spacing: 5) {
                ActionIconView(icon: draft.icon, font: .system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(draft.title.isEmpty ? "New Action" : draft.title)
                    .font(.headline)
                Spacer()
                Menu("Examples") {
                    ForEach(ScriptActionPresets.all()) { preset in
                        Button(preset.title) {
                            applyPreset(preset)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Save") {
                    var saved = draft
                    saved.speakSettings = saved.speakSettings.resolvingCloudGate(
                        cloudAllowed: licenseGate.entitlements.cloudTTSPremiumAllowed
                    )
                    saved.dictionaryConfig.speakSettings = saved.dictionaryConfig.speakSettings.resolvingCloudGate(
                        cloudAllowed: licenseGate.entitlements.cloudTTSPremiumAllowed
                    )
                    onSave(saved)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(saveDisabled)
            }
            // Symmetric vertical padding, matching the ActionLibraryView baseline
            // so the header sits the same distance from the panel's top and bottom edges.
            .padding(.horizontal, SettingsMetrics.cardPadding)
            .padding(.vertical, SettingsMetrics.cardPadding + 6)

            Divider()

            // Same card system as the Providers / Actions tabs.
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {

                    // MARK: Type picker — label and dropdown share one row.
                    // Single-row card mirroring SettingsCard's header layout so the
                    // "Type" label sits beside the dropdown with space between.
                    HStack {
                        Text("Type")
                            .font(.headline)
                        Spacer()
                        Picker("", selection: $draft.type) {
                            ForEach(CustomActionType.allCases) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        // .menu (not .segmented): 8 action types overflow a segmented
                        // control at the settings width — a dropdown stays readable.
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                    .padding(.horizontal, SettingsMetrics.cardPadding)
                    .padding(.vertical, 6)
                    .frame(minHeight: 36)
                    .background(
                        RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                    )
                    .onChange(of: draft.type) { _ in
                        // Reset provider to the first allowed provider for the new type
                        // if the current one is not valid (e.g. switching AI→Translation
                        // may carry over an AI-only provider like Anthropic, which is
                        // actually fine for Translation too — but switching to Speech
                        // needs no provider at all, and switching back resets).
                        if !draft.allowedProviders.isEmpty,
                           !draft.allowedProviders.contains(draft.providerKind) {
                            draft.providerKind = draft.allowedProviders[0]
                        }
                        // Sensible per-type output default on an explicit type change.
                        // Skipped when a preset is being applied — the preset's own
                        // afterRun was already written and must not be overridden here.
                        if suppressAfterRunReset {
                            suppressAfterRunReset = false
                            return
                        }
                        // Default scriptable actions to closing the toolbar after they
                        // run; the user can still override per action.
                        switch draft.type {
                        case .openURL, .runShortcut, .appleScript, .shellScript:
                            draft.afterRun = .closeToolbar
                        case .ai, .translation, .speech, .dictionary:
                            break   // afterRun is unused for these types
                        }
                    }

                    // MARK: Identity (shared across all types)
                    SettingsCard(title: "Identity") {
                        Toggle("", isOn: $draft.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    } content: {
                        HStack(spacing: 8) {
                            Text("Name")
                            TextField("e.g. Summarise", text: $draft.title)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                        }

                        HStack(spacing: 8) {
                            Text("Description")
                            TextField("Optional — short description", text: $draft.actionDescription)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                        }

                        HStack(spacing: 8) {
                            Text("Icon")
                            // Collapsed by default — show the current icon and an
                            // "Add" button that reveals the full picker in a popover.
                            Button {
                                showIconPicker = true
                            } label: {
                                HStack(spacing: 6) {
                                    ActionIconView(icon: draft.icon)
                                    Text("Add")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
                                IconPickerView(selection: $draft.icon)
                                    .frame(width: 320)
                                    .padding(12)
                            }
                            Spacer()
                        }
                    }

                    // MARK: Per-type fields
                    switch draft.type {

                    case .ai:
                        aiFields

                    case .translation:
                        translationFields

                    case .speech:
                        speechFields

                    case .dictionary:
                        dictionaryFields

                    case .openURL:
                        openURLFields
                        scriptableRegexCard

                    case .runShortcut:
                        runShortcutFields
                        scriptableRegexCard

                    case .appleScript:
                        appleScriptFields
                        scriptableRegexCard

                    case .shellScript:
                        shellScriptFields
                        scriptableRegexCard
                    }
                }
                .padding(SettingsMetrics.pagePadding)
            }
            // Bottom breathing room at the panel's edge, matching the body's
            // top inset (pagePadding).
            .padding(.bottom, SettingsMetrics.pagePadding)
        }
        .frame(minWidth: 480, minHeight: 520)
        // Match the ActionLibraryView baseline: extend to the panel's top edge so the
        // header's top gap stays fixed (and equal to its bottom gap) as the window resizes.
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - AI fields

    @ViewBuilder
    private var aiFields: some View {
        SettingsCard(title: "System Prompt") {
            TextEditor(text: $draft.systemPrompt)
                .font(.body)
                .frame(minHeight: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(.separator, lineWidth: 1)
                )
                // Pull the editor closer to the card edges — less margin around the input box.
                .padding(.horizontal, -6)
                .padding(.top, -6)
            Text("Use {{text}} for the selected text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        SettingsCard(title: "Provider") {
            ProviderPicker(
                label: "Provider",
                selection: $draft.providerKind,
                allowed: draft.allowedProviders
            )

            ModelField(
                label: "Model",
                model: $draft.model,
                providerKind: draft.providerKind,
                settings: settings,
                keychain: keychain
            )
        }
    }

    // MARK: - Translation fields

    @ViewBuilder
    private var translationFields: some View {
        SettingsCard(title: "Provider") {
            ProviderPicker(
                label: "Provider",
                selection: $draft.providerKind,
                allowed: draft.allowedProviders
            )

            // Model field — hidden for translation-native providers (DeepL, Google).
            if draft.providerKind.usesModel {
                ModelField(
                    label: "Model",
                    model: $draft.model,
                    providerKind: draft.providerKind,
                    settings: settings,
                    keychain: keychain
                )
            }

            // Default target language picker.
            LabeledContent("Default Target Language") {
                Picker("", selection: $draft.targetLanguage) {
                    ForEach(languages, id: \.bcp47) { lang in
                        Text(lang.name).tag(lang.bcp47)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            // Tone picker — for AI providers and DeepL (formality parameter).
            if draft.providerKind.usesModel || draft.providerKind == .deepL {
                LabeledContent("Tone") {
                    Picker("", selection: $draft.tone) {
                        ForEach(TranslateTone.allCases) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            // Additional prompt — optional, for AI providers only.
            if draft.providerKind.usesModel {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Additional prompt")
                    TextField(
                        "Optional — extra instructions layered on top of translation",
                        text: $draft.systemPrompt,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                    Text("Added on top of the default translation prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Speech fields

    @ViewBuilder
    private var speechFields: some View {
        SettingsCard(title: "Speech") {
            DraftSpeechFields(
                speakSettings: $draft.speakSettings,
                ttsConfig: $draft.ttsConfig,
                settings: settings,
                keychain: keychain,
                licenseGate: licenseGate,
                onUpgrade: onUpgrade
            )
        }
    }

    // MARK: - Open URL fields

    @ViewBuilder
    private var openURLFields: some View {
        SettingsCard(title: "URL Template") {
            VStack(alignment: .leading, spacing: SettingsMetrics.contentSpacing) {
                TextField(
                    "https://www.google.com/search?q={text}",
                    text: $draft.scriptSource
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

                HStack(spacing: 8) {
                    Button("Insert \(PlaceholderExpander.textToken)") {
                        draft.scriptSource += PlaceholderExpander.textToken
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .hoverTooltip("Append the {text} placeholder at the end of the URL")

                    Spacer()
                }

                afterRunPicker

                Text("{text} is replaced with the selected text, URL-encoded. Place it in the path or query, not the hostname.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Run Shortcut fields

    @ViewBuilder
    private var runShortcutFields: some View {
        SettingsCard(title: "Shortcut") {
            VStack(alignment: .leading, spacing: SettingsMetrics.contentSpacing) {
                HStack(spacing: 8) {
                    Text("Shortcut name")
                    TextField("e.g. My Shortcut", text: $draft.scriptSource)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                }

                afterRunPicker

                Text("The selected text is passed to the Shortcut on standard input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - AppleScript fields

    @ViewBuilder
    private var appleScriptFields: some View {
        SettingsCard(title: "AppleScript") {
            VStack(alignment: .leading, spacing: SettingsMetrics.contentSpacing) {

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Runs the AppleScript you write with your full user permissions. Only use scripts you trust.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)

                TextEditor(text: $draft.scriptSource)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.separator, lineWidth: 1)
                    )

                HStack(spacing: 8) {
                    Button("Insert \(PlaceholderExpander.textToken)") {
                        draft.scriptSource += PlaceholderExpander.textToken
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .hoverTooltip("Append the {text} placeholder — becomes a quoted AppleScript string at runtime")

                    Spacer()
                }

                afterRunPicker

                Text("{text} is replaced with the selected text as a quoted AppleScript string literal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Shell Script fields

    @ViewBuilder
    private var shellScriptFields: some View {
        SettingsCard(title: "Shell Script") {
            VStack(alignment: .leading, spacing: SettingsMetrics.contentSpacing) {

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Runs the shell script you write with your full user permissions. Only use scripts you trust.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)

                TextEditor(text: $draft.scriptSource)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.separator, lineWidth: 1)
                    )

                afterRunPicker

                Text("The selection is available as $POPGUY_TEXT (and $POPGUY_FULL_TEXT). Runs via /bin/zsh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Shared "After run" picker (all scriptable types)

    @ViewBuilder
    private var afterRunPicker: some View {
        LabeledContent("After run") {
            Picker("", selection: $draft.afterRun) {
                ForEach(AfterRunBehavior.allCases) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: - Shared regex card (all scriptable types)

    @ViewBuilder
    private var scriptableRegexCard: some View {
        SettingsCard(title: "Visibility") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Show only when selection matches (regex)")
                TextField(
                    "Leave empty to always show",
                    text: $draft.appliesWhenRegex
                )
                .textFieldStyle(.roundedBorder)
                // Cap to match the import sanitizer's 500-char bound.
                .onChange(of: draft.appliesWhenRegex) { _ in
                    if draft.appliesWhenRegex.count > 500 {
                        draft.appliesWhenRegex = String(draft.appliesWhenRegex.prefix(500))
                    }
                }
                Text("Leave empty to always show. Example for file paths: ^(/|~|file:).+")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Dictionary fields

    @ViewBuilder
    private var dictionaryFields: some View {
        SettingsCard(title: "Dictionary") {
            // Provider — a custom Dictionary action looks up in one chosen provider,
            // unlike the built-in Look up which queries every provider.
            LabeledContent("Provider") {
                Picker("", selection: $draft.dictionaryConfig.provider) {
                    ForEach(DictionaryProviderKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            Divider()

            DictionaryConfigFields(
                config: $draft.dictionaryConfig,
                licenseGate: licenseGate,
                onUpgrade: onUpgrade
            )
        }
    }
}
