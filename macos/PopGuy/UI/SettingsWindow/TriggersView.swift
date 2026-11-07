// TriggersView.swift
// PopGuy — UI/SettingsWindow
//
// Settings tab for popup trigger configuration.
//
// Sections:
//   • On text selection: toggle that shows the toolbar on text selection, plus
//     an "only in editable text" sub-option.
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
    @ObservedObject var screenRecordingPermission: ScreenRecordingPermission
    @ObservedObject var navigator: SettingsNavigator

    /// Whether the chord-replacement recorder is active.
    @State private var isRecordingChord = false

    /// Whether the OCR shortcut recorder is active.
    @State private var isRecordingOCRShortcut = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// ScrollViewReader anchor for the OCR section (see `navigator.focusOCRSection`).
    private static let ocrSectionAnchor = "ocrSection"

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                // MARK: On text selection
                SettingsGroup("On Text Selection") {
                    // A setting and its description/warning live in one row so
                    // no divider splits them; dividers go between settings.
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent {
                            Toggle("Show toolbar when text is selected", isOn: $settings.triggerOnSelectEnabled)
                                .toggleStyle(CompactSwitch())
                                .labelsHidden()
                        } label: {
                            Text("Show toolbar when text is selected")
                            Text("When on, selecting text shows the toolbar — in editable fields only, or in any app when the option below is off.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("This feature may not work well with some editors (e.g., Cursor, VS Code, Notion), especially when you select a large amount of text. Use the Cmd+C+C shortcut in those apps instead.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption)
                    }

                    SettingsDivider()

                    // The row style dims the label while the row is disabled.
                    LabeledContent {
                        Toggle("Only in editable text", isOn: $settings.triggerOnSelectEditableOnly)
                            .toggleStyle(CompactSwitch())
                            .labelsHidden()
                    } label: {
                        Text("Only in editable text")
                        Text("When on, the toolbar appears only for text selected inside a field you can type in (text boxes, editors, compose areas). Selecting read-only text — web page content, chat messages — does nothing, so other apps' own selection features are not interrupted. Cmd+C+C and hotkeys still work on any text.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!settings.triggerOnSelectEnabled)

                    SettingsDivider()

                    LabeledContent {
                        Toggle("Show toolbar on double-click (single word)", isOn: $settings.triggerDoubleClickEnabled)
                            .toggleStyle(CompactSwitch())
                            .labelsHidden()
                    } label: {
                        Text("Show toolbar on double-click (single word)")
                        Text("When on, double-clicking a word shows the toolbar — handy for quickly checking a word's meaning or hearing it. Use it on its own, or alongside \"Show toolbar when text is selected\": a double-click shows the toolbar once (even on read-only text), while selecting a range of text still follows the options above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if ToolbarLimits.doubleClickActionFeatureEnabled, settings.triggerDoubleClickEnabled {
                        SettingsDivider()
                        doubleClickActionPicker()
                    }
                }

                // MARK: Keyboard shortcut
                SettingsGroup("Keyboard Shortcut") {
                    LabeledContent {
                        Toggle("Show toolbar with Cmd+C+C", isOn: $settings.triggerChordEnabled)
                            .toggleStyle(CompactSwitch())
                            .labelsHidden()
                    } label: {
                        Text("Show toolbar with Cmd+C+C")
                    }

                    SettingsDivider()

                    VStack(alignment: .leading, spacing: 8) {
                        // Chord replacement row — disabled when chord trigger is off.
                        // 10 pt apart: the icon buttons' hover highlights reach 5 pt past each icon.
                        HStack(spacing: 10) {
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
                                    .buttonStyle(RowIconButtonStyle())
                                    .hoverTooltip("Clear — revert to Cmd+C+C")
                                    .disabled(!settings.triggerChordEnabled)
                                }

                                // Record button.
                                Button {
                                    isRecordingChord = true
                                } label: {
                                    Image(systemName: "record.circle")
                                }
                                .buttonStyle(RowIconButtonStyle())
                                .hoverTooltip("Record a replacement shortcut (e.g. ⌘⇧Space)")
                                .disabled(!settings.triggerChordEnabled)
                            }
                        }
                        .disabled(!settings.triggerChordEnabled)

                        Text("Replaces Cmd+C+C with a single key combo (e.g. ⌘⇧Space). A repeated-key chord like Cmd+C+C cannot be recorded — use one modifier + a key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // MARK: Screen Text Capture (OCR)
                SettingsGroup("Screen Text Capture (OCR)") {
                    ocrSectionContent()
                }
                .id(Self.ocrSectionAnchor)
                TerminalComposerSettingsSection(settings: settings)
            }
            .padding(SettingsMetrics.pagePadding)
        }
        .labeledContentStyle(.settingsRow)
        .onAppear {
            #if DEBUG
            // DEBUG-only QA hook: `--triggers-ocr` scrolls to the OCR section, for screenshots from a shell.
            if ProcessInfo.processInfo.arguments.contains("--triggers-ocr") { navigator.focusOCRSection = true }
            #endif
            scrollToOCRSectionIfRequested(proxy)
        }
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
    /// scroll is deferred to the next runloop tick so the page has laid out.
    private func scrollToOCRSectionIfRequested(_ proxy: ScrollViewProxy) {
        guard navigator.focusOCRSection else { return }
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : Motion.standard) {
                proxy.scrollTo(Self.ocrSectionAnchor, anchor: .top)
            }
            navigator.focusOCRSection = false
        }
    }

    // MARK: - Screen Text Capture (OCR)

    @ViewBuilder
    private func ocrSectionContent() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Toggle("Enable Screen Text Capture", isOn: $settings.ocrEnabled)
                    .toggleStyle(CompactSwitch())
                    .labelsHidden()
            } label: {
                Text("Enable Screen Text Capture")
                Text("Select any region of the screen and PopGuy recognizes the text in it, then hands it to the toolbar to copy. Useful for text you can't select normally — images, PDFs, video captions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        SettingsDivider()

        VStack(alignment: .leading, spacing: 8) {
            // 10 pt apart: the icon buttons' hover highlights reach 5 pt past each icon.
            HStack(spacing: 10) {
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
                        .buttonStyle(RowIconButtonStyle())
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
                    .buttonStyle(RowIconButtonStyle())
                    .hoverTooltip("Record shortcut")
                    .disabled(!settings.ocrEnabled)
                }
            }

            Text("Assign a shortcut to start a capture from anywhere (e.g. ⌘⇧2). Also available from the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        SettingsDivider()

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
                    .buttonStyle(RowTextButtonStyle(formRow: true))

                    Button("Open System Settings") {
                        screenRecordingPermission.openSystemSettings()
                    }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                }
            }

            Text("macOS requires Screen Recording permission to capture the screen region for OCR. PopGuy only captures the region you select.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Picker to assign a default action to the double-click trigger.
    private func doubleClickActionPicker() -> some View {
        LabeledContent {
            Picker(selection: $settings.doubleClickAssignedAction) {
                Text("Unassign (show toolbar)").tag(ActionIdentifier?.none)
                ForEach(settings.actionOrder, id: \.self) { id in
                    Text(actionLabel(for: id)).tag(ActionIdentifier?.some(id))
                }
            } label: {
                Text("Default action")
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            Text("Default action")
            Text("When assigned, double-clicking a word runs this action directly instead of showing the toolbar.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
