// TriggersView.swift
// PopGuy — UI/SettingsWindow
//
// Settings tab for popup trigger configuration.
//
// Sections:
//   • On text selection: toggle that shows the toolbar on text selection.
//   • Keyboard shortcut: Cmd+C+C chord toggle + optional replacement shortcut.
//
// The chord replacement shortcut is stored directly on SettingsStore as
// `chordReplacementShortcut` (not in shortcutBindings). ShortcutRecorderRow is
// keyed by ActionIdentifier and cannot be used here. Instead, the internal
// ShortcutRecorder view from ShortcutRecorderRow.swift is reused directly with
// custom onCapture / onCancel closures.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - TriggersView

struct TriggersView: View {

    @ObservedObject var settings: SettingsStore
    @ObservedObject var licenseGate: LicenseGate
    @ObservedObject var screenRecordingPermission: ScreenRecordingPermission
    @ObservedObject var navigator: SettingsNavigator

    /// Navigates to the License tab when the user taps an upgrade prompt.
    let onUpgrade: () -> Void

    /// Whether the chord-replacement recorder is active.
    @State private var isRecordingChord = false

    /// Whether the OCR shortcut recorder is active.
    @State private var isRecordingOCRShortcut = false

    /// ScrollViewReader anchor for the OCR section (see `navigator.focusOCRSection`).
    private static let ocrSectionAnchor = "ocrSection"

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            // MARK: On text selection
            Section(header: Text("On Text Selection")) {
                // A setting and its description/warning live in one cell so no
                // divider splits them; the grouped Form still draws a divider
                // between cells (i.e. between settings).
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show toolbar when text is selected", isOn: $settings.triggerOnSelectEnabled)
                    Text("When on, selecting text in any app shows the toolbar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("This feature may not work well with some editors (e.g., Cursor, VS Code, Notion), especially when you select a large amount of text. Use the Cmd+C+C shortcut in those apps instead.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show toolbar on double-click (single word)", isOn: $settings.triggerDoubleClickEnabled)
                    Text("When on, double-clicking a word shows the toolbar — handy for quickly checking a word's meaning or hearing it. Use it on its own, or alongside the option above: a double-click shows the toolbar once, while selecting a range of text still uses the option above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if ProConfig.doubleClickActionFeatureEnabled, settings.triggerDoubleClickEnabled {
                        doubleClickActionPicker()
                    }
                }
            }

            // MARK: Keyboard shortcut
            Section(header: Text("Keyboard Shortcut")) {
                Toggle("Show toolbar with Cmd+C+C", isOn: $settings.triggerChordEnabled)

                VStack(alignment: .leading, spacing: 8) {
                    // Chord replacement row — disabled when chord trigger is off.
                    HStack {
                        Text("Use a different shortcut")
                            .foregroundStyle(settings.triggerChordEnabled ? .primary : .secondary)

                        Spacer()

                        if isRecordingChord {
                            ShortcutRecorder(
                                onCapture: { shortcut in
                                    settings.chordReplacementShortcut = shortcut
                                    isRecordingChord = false
                                },
                                onCancel: {
                                    isRecordingChord = false
                                }
                            )
                        } else {
                            // Show current shortcut badge or nothing.
                            if let shortcut = settings.chordReplacementShortcut {
                                ShortcutBadge(text: shortcut.displayString)

                                // Clear button — reverts to Cmd+C+C.
                                Button {
                                    settings.chordReplacementShortcut = nil
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.borderless)
                                .hoverTooltip("Clear — revert to Cmd+C+C")
                                .disabled(!settings.triggerChordEnabled)
                            }

                            // Record button.
                            Button {
                                isRecordingChord = true
                            } label: {
                                Image(systemName: "record.circle")
                            }
                            .buttonStyle(.borderless)
                            .hoverTooltip("Record a replacement shortcut (e.g. ⌘⇧Space)")
                            .disabled(!settings.triggerChordEnabled)
                        }
                    }
                    .disabled(!settings.triggerChordEnabled)

                    Text("Replaces Cmd+C+C with a single key combo (e.g. ⌘⇧Space). A repeated-key chord like Cmd+C+C cannot be recorded — use one modifier + a key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: Screen Text Capture (OCR)
            Section(header: ocrSectionHeader()) {
                ocrSectionContent()
            }
            .id(Self.ocrSectionAnchor)

        }
        .formStyle(.grouped)
        .onAppear { scrollToOCRSectionIfRequested(proxy) }
        .onChange(of: navigator.focusOCRSection) { _ in
            scrollToOCRSectionIfRequested(proxy)
        }
        .onDisappear {
            // Cancel any in-progress recording when the view disappears.
            isRecordingChord = false
            isRecordingOCRShortcut = false
        }
        }
    }

    /// Scroll to the OCR section when AppDelegate requested focus (menu-bar item
    /// picked while OCR is disabled/locked), then clear the one-shot flag. The
    /// scroll is deferred to the next runloop tick so the Form has laid out.
    private func scrollToOCRSectionIfRequested(_ proxy: ScrollViewProxy) {
        guard navigator.focusOCRSection else { return }
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(Self.ocrSectionAnchor, anchor: .top)
            }
            navigator.focusOCRSection = false
        }
    }

    // MARK: - Screen Text Capture (OCR)

    @ViewBuilder
    private func ocrSectionHeader() -> some View {
        HStack(spacing: 6) {
            Text("Screen Text Capture (OCR)")
            if !licenseGate.entitlements.ocrAllowed { ProBadge() }
        }
    }

    @ViewBuilder
    private func ocrSectionContent() -> some View {
        let ocrAllowed = licenseGate.entitlements.ocrAllowed

        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Enable Screen Text Capture",
                isOn: Binding(
                    get: { ocrAllowed && settings.ocrEnabled },
                    set: { newValue in
                        guard ocrAllowed else { return }
                        settings.ocrEnabled = newValue
                    }
                )
            )
            .disabled(!ocrAllowed)

            Text("Select any region of the screen and PopGuy recognizes the text in it, then hands it to the toolbar to copy. Useful for text you can't select normally — images, PDFs, video captions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if ocrAllowed {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Keyboard shortcut")
                        .foregroundStyle(settings.ocrEnabled ? .primary : .secondary)

                    Spacer()

                    if isRecordingOCRShortcut {
                        ShortcutRecorder(
                            onCapture: { shortcut in
                                settings.ocrShortcut = shortcut
                                isRecordingOCRShortcut = false
                            },
                            onCancel: {
                                isRecordingOCRShortcut = false
                            }
                        )
                    } else {
                        if let shortcut = settings.ocrShortcut {
                            ShortcutBadge(text: shortcut.displayString)

                            Button {
                                settings.ocrShortcut = nil
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .hoverTooltip("Remove shortcut")
                            .disabled(!settings.ocrEnabled)
                        } else {
                            Text("None")
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            isRecordingOCRShortcut = true
                        } label: {
                            Image(systemName: "record.circle")
                        }
                        .buttonStyle(.borderless)
                        .hoverTooltip("Record shortcut")
                        .disabled(!settings.ocrEnabled)
                    }
                }

                Text("Assign a shortcut to start a capture from anywhere (e.g. ⌘⇧2). Also available from the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: screenRecordingPermission.isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(screenRecordingPermission.isGranted ? .green : .orange)

                    Text(screenRecordingPermission.isGranted ? "Screen Recording permission granted" : "Screen Recording permission required")

                    Spacer(minLength: 0)

                    if !screenRecordingPermission.isGranted {
                        Button("Grant\u{2026}") {
                            screenRecordingPermission.request()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Open System Settings") {
                            screenRecordingPermission.openSystemSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Text("macOS requires Screen Recording permission to capture the screen region for OCR. PopGuy only captures the region you select.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            UpgradePromptView(
                message: "Screen Text Capture (OCR) requires a Pro plan.",
                onUpgrade: onUpgrade
            )
        }
    }

    /// Picker to assign a default action to the double-click trigger.
    /// Pro-gated: free users see a disabled control plus an upgrade prompt; the
    /// stored assignment is hidden (shows "Unassign") and cannot be changed.
    @ViewBuilder
    private func doubleClickActionPicker() -> some View {
        let actionAllowed = licenseGate.entitlements.doubleClickActionAllowed
        let assignedBinding = Binding<ActionIdentifier?>(
            get: { actionAllowed ? settings.doubleClickAssignedAction : nil },
            set: { newValue in
                guard actionAllowed else { return }
                settings.doubleClickAssignedAction = newValue
            }
        )

        Picker(selection: assignedBinding) {
            Text("Unassign (show toolbar)").tag(ActionIdentifier?.none)
            ForEach(settings.actionOrder, id: \.self) { id in
                Text(actionLabel(for: id)).tag(ActionIdentifier?.some(id))
            }
        } label: {
            HStack(spacing: 6) {
                Text("Default action")
                if !actionAllowed { ProBadge() }
            }
        }
        .disabled(!actionAllowed)

        if actionAllowed {
            Text("When assigned, double-clicking a word runs this action directly instead of showing the toolbar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            UpgradePromptView(
                message: "Assigning a default action to the double-click trigger requires a Pro plan. Free users see the toolbar on double-click.",
                onUpgrade: onUpgrade
            )
        }
    }

    /// User-visible label for an action in the double-click assignment picker.
    private func actionLabel(for id: ActionIdentifier) -> String {
        switch id {
        case .builtin(.improve):   return "Improve"
        case .builtin(.shorten):   return "Shorten"
        case .builtin(.proofread): return "Proofread"
        case .builtin(.translate): return "Translate"
        case .builtin(.prompt):    return "Prompt"
        case .speak:               return "Speak"
        case .dictionary:          return "Look up"
        case .custom(let uuid):
            return settings.customActions.first(where: { $0.id == uuid })?.title ?? "Custom"
        }
    }
}
