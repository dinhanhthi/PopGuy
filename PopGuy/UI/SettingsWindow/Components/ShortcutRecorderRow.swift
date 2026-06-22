// ShortcutRecorderRow.swift
// PopGuy — UI/SettingsWindow/Components
//
// Reusable shortcut-recording control row used inside action cards.
//
// Usage: embed inside a card; the card header supplies the action label/icon.
// This component shows only the current shortcut and the record/clear buttons.
//
// The NSEvent local-monitor recorder is the same MANUAL-QA-verified
// implementation from ShortcutsView. A local monitor only fires when the
// PopGuy settings window is key — acceptable for shortcut recording.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import AppKit
import SwiftUI

// MARK: - ShortcutRecorderRow

/// A reusable row control that displays and records a keyboard shortcut for the given action.
///
/// The parent view owns the shared `recordingID` state so only one row records at a time.
struct ShortcutRecorderRow: View {

    let actionID: ActionIdentifier
    @ObservedObject var settings: SettingsStore
    @Binding var recordingID: ActionIdentifier?

    private var isRecording: Bool { recordingID == actionID }
    private var currentShortcut: KeyboardShortcut? { settings.shortcut(for: actionID) }

    var body: some View {
        HStack {
            Text("Keyboard shortcut")
                .foregroundStyle(.secondary)
                .font(.callout)

            Spacer()

            if isRecording {
                ShortcutRecorder(
                    onCapture: { shortcut in
                        settings.setShortcut(shortcut, for: actionID)
                        recordingID = nil
                    },
                    onCancel: {
                        recordingID = nil
                    }
                )
            } else {
                // Show current shortcut or "None".
                if let shortcut = currentShortcut {
                    ShortcutBadge(text: shortcut.displayString) {
                        recordingID = actionID
                    }
                } else {
                    Text("None")
                        .foregroundStyle(.secondary)
                        .onTapGesture { recordingID = actionID }
                }

                // Record button
                Button {
                    recordingID = actionID
                } label: {
                    Image(systemName: "record.circle")
                }
                .buttonStyle(.borderless)
                .help("Record shortcut")

                // Clear button — only shown when a shortcut is set
                if currentShortcut != nil {
                    Button {
                        settings.removeShortcut(for: actionID)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove shortcut")
                }
            }
        }
    }
}

// MARK: - ShortcutBadge

/// Monospaced badge showing a shortcut's display string.
/// With `onTap`, the badge is clickable (starts recording) and shows a hover
/// highlight as the affordance; without it, the badge is display-only.
struct ShortcutBadge: View {

    let text: String
    var onTap: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .tracking(4)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Color.primary.opacity(onTap != nil && isHovered ? 0.12 : 0.06),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { hovering in
                guard onTap != nil else { return }
                isHovered = hovering
            }
            .onTapGesture { onTap?() }
    }
}

// MARK: - ShortcutRecorder

/// Captures the next key-down event (with modifiers) via a local NSEvent monitor.
///
/// MANUAL QA only — recording behavior verified by interacting with the UI.
/// Implementation is identical to ShortcutsView.ShortcutRecorder.
/// Internal (not private) so TriggersView can reuse it with custom onCapture/onCancel closures.
struct ShortcutRecorder: View {

    let onCapture: (KeyboardShortcut) -> Void
    let onCancel: () -> Void

    @State private var monitorToken: Any? = nil

    var body: some View {
        Text("Press shortcut…")
            .italic()
            .foregroundColor(.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .onAppear { startRecording() }
            .onDisappear { stopRecording() }
    }

    private func startRecording() {
        // Install a local event monitor that captures the very next keyDown.
        // A local monitor only fires when the PopGuy settings window is key —
        // this is acceptable for shortcut recording (the user must focus the
        // settings window to interact with it).
        monitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape (keyCode 53) cancels recording.
            if event.keyCode == 53 {
                Task { @MainActor in onCancel() }
                stopRecording()
                return nil // consume the Escape
            }

            // Require at least one modifier to avoid accidentally recording plain letters.
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty else {
                // No modifier — ignore and keep recording.
                return event
            }

            let shortcut = KeyboardShortcut(
                keyCode: UInt32(event.keyCode),
                modifierFlags: flags.rawValue
            )
            Task { @MainActor in onCapture(shortcut) }
            stopRecording()
            return nil // consume the key event
        }
    }

    private func stopRecording() {
        if let token = monitorToken {
            NSEvent.removeMonitor(token)
            monitorToken = nil
        }
    }
}
