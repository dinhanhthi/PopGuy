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

    /// Navigates to the License tab when the user taps an upgrade prompt.
    let onUpgrade: () -> Void

    /// Whether the chord-replacement recorder is active.
    @State private var isRecordingChord = false

    var body: some View {
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
                                .help("Clear — revert to Cmd+C+C")
                                .disabled(!settings.triggerChordEnabled)
                            }

                            // Record button.
                            Button {
                                isRecordingChord = true
                            } label: {
                                Image(systemName: "record.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Record a replacement shortcut (e.g. ⌘⇧Space)")
                            .disabled(!settings.triggerChordEnabled)
                        }
                    }
                    .disabled(!settings.triggerChordEnabled)

                    Text("Replaces Cmd+C+C with a single key combo (e.g. ⌘⇧Space). A repeated-key chord like Cmd+C+C cannot be recorded — use one modifier + a key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .formStyle(.grouped)
        .onDisappear {
            // Cancel any in-progress recording when the view disappears.
            isRecordingChord = false
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
