// EmojiPickerSettingsView.swift
// PopGuy — UI/SettingsWindow
//
// The Settings → Emoji page (Emoji Picker): a one-line intro, the enable switch, the picker
// shortcut, the default skin tone, and a button that clears the Frequently Used history.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

struct EmojiPickerSettingsView: View {

    @ObservedObject var settings: SettingsStore

    /// Whether the picker shortcut recorder is active.
    @State private var isRecordingShortcut = false
    /// Whether a Frequently Used history is saved (read on appear and after a clear).
    @State private var hasFrequentlyUsed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                Text("Press a shortcut in any text field to pick an emoji or symbol.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsMetrics.cardPadding)
                pickerGroup
            }
            .padding(SettingsMetrics.pagePadding)
        }
        .labeledContentStyle(.settingsRow)
        .onAppear { refreshFrequentlyUsed() }
        .onDisappear { isRecordingShortcut = false }
    }

    // MARK: - Group

    /// No title: the page header already reads "Emoji" (the sidebar title).
    private var pickerGroup: some View {
        SettingsGroup(nil) {
            LabeledContent {
                Toggle("Emoji picker", isOn: $settings.emojiPickerEnabled)
                    .toggleStyle(CompactSwitch())
                    .labelsHidden()
            } label: {
                Text("Emoji picker")
                Text("Off by default. Opens a picker at the text cursor; Enter or a click types the emoji into the app you're in.")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
            }

            SettingsDivider()

            shortcutRow()

            SettingsDivider()

            skinToneRow()

            SettingsDivider()

            frequentlyUsedRow()
        }
    }

    // MARK: - Shortcut

    private func shortcutRow() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 10 pt apart: the icon buttons' hover highlights reach 5 pt past each icon.
            HStack(spacing: 10) {
                Text("Shortcut")
                    .foregroundStyle(settings.emojiPickerEnabled ? .primary : .secondary)

                Spacer()

                if isRecordingShortcut {
                    ShortcutRecorder(
                        onCapture: { shortcut in
                            settings.emojiPickerShortcut = shortcut
                            isRecordingShortcut = false
                        },
                        onCancel: {
                            isRecordingShortcut = false
                        }
                    )
                } else {
                    if let shortcut = settings.emojiPickerShortcut {
                        ShortcutBadge(text: shortcut.displayString)

                        Button {
                            settings.emojiPickerShortcut = nil
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(RowIconButtonStyle())
                        .hoverTooltip("Remove shortcut")
                    } else {
                        Text("None")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        isRecordingShortcut = true
                    } label: {
                        Image(systemName: "record.circle")
                    }
                    .buttonStyle(RowIconButtonStyle())
                    .hoverTooltip("Record shortcut")
                }
            }
            .disabled(!settings.emojiPickerEnabled)

            Text("In Cocoa apps, \u{2318}; replaces Edit \u{2192} Spelling and Grammar \u{2192} Check Document Now.")
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Skin tone

    private func skinToneRow() -> some View {
        LabeledContent("Default skin tone") {
            SettingsMenuPicker(
                "Default skin tone",
                selection: $settings.emojiSkinTone,
                options: SkinTone.allCases.map { ($0, "\(Self.sample($0))  \($0.title)") }
            )
        }
    }

    /// ✋ with the tone's modifier (plain yellow for the default).
    private static func sample(_ tone: SkinTone) -> String {
        "\u{270B}" + (tone.modifier.map { String($0) } ?? "")
    }

    // MARK: - Frequently Used

    private func frequentlyUsedRow() -> some View {
        LabeledContent {
            Button("Clear") {
                UserDefaults.standard.removeObject(forKey: EmojiFrecency.defaultsKey)
                refreshFrequentlyUsed()
            }
            .buttonStyle(RowTextButtonStyle(formRow: true))
            .disabled(!hasFrequentlyUsed)
        } label: {
            Text("Frequently Used")
            Text("The emoji you pick most often show first in the picker.")
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshFrequentlyUsed() {
        hasFrequentlyUsed = UserDefaults.standard.object(forKey: EmojiFrecency.defaultsKey) != nil
    }
}
