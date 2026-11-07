// ComposerView.swift
// PopGuy
//
// SwiftUI content of the composer window: the text editor and a footer with the
// source hint, "Restore draft", Cancel, Done and Done & Submit. When the terminal
// session has ended, Done becomes "Copy & Close" and Done & Submit is hidden.
// The owner (the composer controller) holds the `ComposerModel` and its callbacks.

import AppKit
import Combine
import SwiftUI

/// State and callbacks of one composer window. The buttons and the editor's
/// keyboard shortcuts call the same callbacks.
@MainActor
final class ComposerModel: ObservableObject {
    @Published var text: String
    /// Name of the app the text is edited for; nil for the Compose mode.
    @Published var sourceAppName: String?
    /// The CLI went away: the text can only be copied.
    @Published var sessionEnded = false
    /// An older draft exists; shows "Restore draft".
    @Published var draftAvailable = false

    var onDone: () -> Void = {}
    var onDoneAndSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Called after the text was copied to the general pasteboard.
    var onCopyAndClose: () -> Void = {}
    var onRestoreDraft: () -> Void = {}

    init(text: String = "", sourceAppName: String? = nil) {
        self.text = text
        self.sourceAppName = sourceAppName
    }

    /// The text cannot be sent back: it exceeds the protocol's size cap.
    var isTooLarge: Bool {
        text.utf8.count > ComposerMessage.maxTextBytes
    }
}

struct ComposerView: View {
    @ObservedObject var model: ComposerModel

    var body: some View {
        VStack(spacing: 0) {
            ComposerTextView(
                text: $model.text,
                onDone: done,
                onDoneAndSubmit: doneAndSubmit,
                onCancel: { model.onCancel() }
            )
            .frame(minWidth: 320, maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
            Divider()
            footer
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.sessionEnded {
                notice("The terminal session ended. Copy the text to keep it.")
            }
            if model.isTooLarge {
                notice("Text is too large (max 1 MB).")
            }
            // One row when it fits; in a narrow window the actions move to a second row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    leadingItems
                    Spacer(minLength: 0)
                    actionButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { leadingItems }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        actionButtons
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var leadingItems: some View {
        Text(sourceHint)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        if model.draftAvailable {
            footerButton("Restore draft", tooltip: "Restore the last saved draft") {
                model.onRestoreDraft()
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        footerButton("Cancel", tooltip: "Cancel (Esc)") { model.onCancel() }
        if model.sessionEnded {
            footerButton("Copy & Close", tooltip: "Copy & Close (\u{2318}\u{21A9})", prominent: true, action: done)
                .disabled(model.text.isEmpty)
        } else {
            footerButton("Done", tooltip: "Done (\u{2318}\u{21A9})", prominent: true, action: done)
                .disabled(model.isTooLarge)
            footerButton("Done & Submit", tooltip: "Done & Submit (\u{2318}\u{21E7}\u{21A9})", action: doneAndSubmit)
                .disabled(model.isTooLarge)
        }
    }

    private var sourceHint: String {
        if let name = model.sourceAppName, !name.isEmpty {
            return "Editing for \(name)"
        }
        return "Compose"
    }

    private func notice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func footerButton(_ title: String, tooltip: String, prominent: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(BottomBarButtonStyle(height: 28, prominent: prominent, horizontalPadding: 12))
            .fixedSize()
            .hoverTooltip(tooltip)
    }

    // MARK: Actions (buttons and keyboard)

    /// Done, or Copy & Close once the session ended. Ignored while the text is too large.
    private func done() {
        if model.sessionEnded {
            guard !model.text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(model.text, forType: .string)
            model.onCopyAndClose()
            return
        }
        guard !model.isTooLarge else {
            NSSound.beep()
            return
        }
        model.onDone()
    }

    private func doneAndSubmit() {
        guard !model.sessionEnded, !model.isTooLarge else {
            NSSound.beep()
            return
        }
        model.onDoneAndSubmit()
    }
}
