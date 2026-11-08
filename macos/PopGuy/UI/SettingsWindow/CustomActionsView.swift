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
    /// The Name field takes the keyboard focus when the modal opens.
    @FocusState private var nameFocused: Bool
    @ObservedObject var settings: SettingsStore
    let keychain: KeychainManager
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
        onSave: @escaping (CustomAction) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: action)
        self.settings = settings
        self.keychain = keychain
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
        // The draft no longer is the Library preset it was installed from.
        draft.libraryPresetID = nil
        // Intentionally not copying: id (preserves identity), isEnabled (user preference),
        // systemPrompt (unused by scriptable presets), and provider/model/speech/etc.
    }

    /// The header's capsule buttons, shorter than a bottom bar's so the header
    /// keeps its height.
    private static var headerButtonHeight: CGFloat { 28 }

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
                Menu {
                    ForEach(ScriptActionPresets.all()) { preset in
                        Button(preset.title) {
                            applyPreset(preset)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Examples")
                        MenuChevron()
                    }
                }
                // A button-style menu draws the label through the button style;
                // a borderless one drops the capsule.
                .menuStyle(.button)
                .buttonStyle(BottomBarButtonStyle(
                    height: Self.headerButtonHeight, horizontalPadding: 12, menu: true))
                .menuIndicator(.hidden)
                .fixedSize()
                Button("Cancel", action: onCancel)
                    .buttonStyle(BottomBarButtonStyle(height: Self.headerButtonHeight, horizontalPadding: 12))
                Button("Save") {
                    var saved = draft
                    saved.speakSettings = saved.speakSettings.resolvingCloudGate(
                        cloudAllowed: true
                    )
                    saved.dictionaryConfig.speakSettings = saved.dictionaryConfig.speakSettings.resolvingCloudGate(
                        cloudAllowed: true
                    )
                    onSave(saved)
                }
                    .buttonStyle(BottomBarButtonStyle(
                        height: Self.headerButtonHeight, prominent: true, horizontalPadding: 12))
                    .disabled(saveDisabled)
            }
            // At the top of the modal card, symmetric vertical padding.
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
                        // A dropdown (not a segmented control): 8 action types overflow
                        // a segmented control at the settings width.
                        SettingsMenuPicker(
                            "Type",
                            selection: $draft.type,
                            options: CustomActionType.allCases.map { ($0, $0.displayName) }
                        )
                    }
                    .padding(.horizontal, SettingsMetrics.cardPadding)
                    .padding(.vertical, 6)
                    .frame(minHeight: 36)
                    .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
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
                        // Locked while this is the only active action: the
                        // toolbar needs at least one. The tooltip sits on an
                        // enabled wrapper so it still shows while locked.
                        let isLastEnabled = settings.isLastEnabledAction(.custom(draft.id))
                        HStack {
                            // CompactSwitch dims itself while disabled.
                            Toggle("Enabled", isOn: $draft.isEnabled)
                                .labelsHidden()
                                .toggleStyle(CompactSwitch())
                                .disabled(isLastEnabled)
                        }
                        .contentShape(Rectangle())
                        .hoverTooltip(isLastEnabled
                            ? "Disabled because this is the only active action. The toolbar needs at least one. Turn on another action first."
                            : "Turn this action on or off")
                    } content: {
                        HStack(spacing: 8) {
                            Text("Name")
                            TextField("e.g. Summarise", text: $draft.title)
                                .textFieldStyle(.settings)
                                .frame(maxWidth: .infinity)
                                .focused($nameFocused)
                        }

                        HStack(spacing: 8) {
                            Text("Description")
                            TextField("Optional — short description", text: $draft.actionDescription)
                                .textFieldStyle(.settings)
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
                            .buttonStyle(RowTextButtonStyle())
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
        // No minimum height: the modal card sets the height, the form scrolls.
        .frame(minWidth: 480)
        // Focus the Name field on the next run-loop turn, once the modal is in
        // the view tree.
        .onAppear { DispatchQueue.main.async { nameFocused = true } }
    }

    // MARK: - AI fields

    @ViewBuilder
    private var aiFields: some View {
        SettingsCard(title: "System Prompt") {
            TextEditor(text: $draft.systemPrompt)
                .font(.body)
                .frame(minHeight: 100)
                .settingsTextEditor()
            Text("Use {{text}} for the selected text. Also available: {{app}}, {{date}}, {{language}}, {{domain}} (only when Ignored Domains is on).")
                .font(.settingsCaption)
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
                keychain: keychain,
                libraryPresetID: draft.libraryPresetID
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
                SettingsMenuPicker(
                    "Default Target Language",
                    selection: $draft.targetLanguage,
                    options: languages.map { ($0.bcp47, $0.name) }
                )
            }

            // Tone picker — for AI providers and DeepL (formality parameter).
            if draft.providerKind.usesModel || draft.providerKind == .deepL {
                LabeledContent("Tone") {
                    SettingsMenuPicker(
                        "Tone",
                        selection: $draft.tone,
                        options: TranslateTone.allCases.map { ($0, $0.displayName) }
                    )
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
                    .textFieldStyle(.settings)
                    .lineLimit(3...6)
                    Text("Added on top of the default translation prompt.")
                        .font(.settingsCaption)
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
                keychain: keychain
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
                .textFieldStyle(.settings)
                .font(.system(.body, design: .monospaced))

                HStack(spacing: 8) {
                    Button("Insert \(PlaceholderExpander.textToken)") {
                        draft.scriptSource += PlaceholderExpander.textToken
                    }
                    .buttonStyle(RowTextButtonStyle())
                    .hoverTooltip("Append the {text} placeholder at the end of the URL")

                    Spacer()
                }

                afterRunPicker

                Text("{text} is replaced with the selected text, URL-encoded. Place it in the path or query, not the hostname.")
                    .font(.settingsCaption)
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
                        .textFieldStyle(.settings)
                        .frame(maxWidth: .infinity)
                }

                afterRunPicker

                Text("The selected text is passed to the Shortcut on standard input.")
                    .font(.settingsCaption)
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
                .font(.settingsCaption)

                TextEditor(text: $draft.scriptSource)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .settingsTextEditor()

                HStack(spacing: 8) {
                    Button("Insert \(PlaceholderExpander.textToken)") {
                        draft.scriptSource += PlaceholderExpander.textToken
                    }
                    .buttonStyle(RowTextButtonStyle())
                    .hoverTooltip("Append the {text} placeholder — becomes a quoted AppleScript string at runtime")

                    Spacer()
                }

                afterRunPicker

                Text("{text} is replaced with the selected text as a quoted AppleScript string literal.")
                    .font(.settingsCaption)
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
                .font(.settingsCaption)

                TextEditor(text: $draft.scriptSource)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .settingsTextEditor()

                afterRunPicker

                Text("The selection is available as $POPGUY_TEXT (and $POPGUY_FULL_TEXT). Runs via /bin/zsh.")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Shared "After run" picker (all scriptable types)

    @ViewBuilder
    private var afterRunPicker: some View {
        LabeledContent("After run") {
            SettingsMenuPicker(
                "After run",
                selection: $draft.afterRun,
                options: AfterRunBehavior.allCases.map { ($0, $0.displayName) }
            )
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
                .textFieldStyle(.settings)
                // Cap to match the import sanitizer's 500-char bound.
                .onChange(of: draft.appliesWhenRegex) { _ in
                    if draft.appliesWhenRegex.count > 500 {
                        draft.appliesWhenRegex = String(draft.appliesWhenRegex.prefix(500))
                    }
                }
                Text("Leave empty to always show. Example for file paths: ^(/|~|file:).+")
                    .font(.settingsCaption)
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
                SettingsMenuPicker(
                    "Provider",
                    selection: $draft.dictionaryConfig.provider,
                    options: DictionaryProviderKind.allCases.map { ($0, $0.displayName) }
                )
            }

            Divider()

            DictionaryConfigFields(
                config: $draft.dictionaryConfig
            )
        }
    }
}
