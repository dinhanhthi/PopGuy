// ComposerTextView.swift
// PopGuy
//
// The composer's plain-text editor: an AppKit text view in a scroll view, wrapped
// for SwiftUI. Soft wrap to the width, undo, find bar, plain text only (paste drops
// formatting), no smart quotes/dashes or autocorrect (prompt and code text).
//
// Keys: Cmd+Return → onDone, Cmd+Shift+Return → onDoneAndSubmit, Esc → onCancel.
// Return and Backspace continue and end Markdown lists (ListContinuation).
// Standard edit shortcuts (cut/copy/paste/undo/redo/select all/find) are handled
// in the view itself, so they work whether or not the app's main menu has an Edit menu.
//
// Sizing: the caller gives it an explicit frame, e.g.
// `.frame(minWidth:, maxWidth: .infinity, minHeight:, maxHeight: .infinity)`.

import AppKit
import SwiftUI

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var onDone: () -> Void = {}
    var onDoneAndSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    static let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize + 1)

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = Self.makeScrollView(text: text, coordinator: context.coordinator)
        if let textView = scrollView.documentView as? ComposerNSTextView {
            apply(callbacksTo: textView)
        }
        return scrollView
    }

    /// The scroll view and its text view, wired to `coordinator` (text storage and text view delegate).
    static func makeScrollView(text: String, coordinator: Coordinator) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // TextKit 1: reliable find-bar highlighting and attribute-based styling.
        let textView = ComposerNSTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.font = Self.baseFont
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 8, height: 10)

        // Soft wrap: the text container follows the view's width; no horizontal growth.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // Markdown highlighting runs on every character edit, including this first text.
        textView.textStorage?.delegate = coordinator
        textView.string = text
        textView.moveCaretToEnd()
        textView.delegate = coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        apply(callbacksTo: textView)
        // Push only real external changes, so selection and undo survive normal updates.
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            textView.moveCaretToEnd()
        }
    }

    private func apply(callbacksTo textView: ComposerNSTextView) {
        textView.onDone = onDone
        textView.onDoneAndSubmit = onDoneAndSubmit
        textView.onCancel = onCancel
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: ComposerTextView

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        /// Attribute changes made here are not registered with the undo manager.
        /// Runs inside the storage's edit pass, while the text view's selection still has
        /// its pre-edit range: change storage attributes only, never text view state (setting
        /// typing attributes here read out of range and left the storage stuck mid-edit).
        /// Typed text needs no typing attributes: this pass restyles it before it is drawn.
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MarkdownStyler.highlight(textStorage, editedRange: editedRange, baseFont: ComposerTextView.baseFont)
        }
    }
}

/// Text view subclass with the composer's key handling.
final class ComposerNSTextView: NSTextView {
    var onDone: () -> Void = {}
    var onDoneAndSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    /// Esc (NSTextView would otherwise start completion).
    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    /// The caret after the last character, scrolled into view, to go on writing.
    func moveCaretToEnd() {
        let end = NSRange(location: (string as NSString).length, length: 0)
        setSelectedRange(end)
        scrollRangeToVisible(end)
    }

    /// Return continues or ends a Markdown list (ListContinuation).
    override func insertNewline(_ sender: Any?) {
        if !applyListEdit(ListContinuation.returnEdit) { super.insertNewline(sender) }
    }

    /// Backspace right after a list marker deletes the marker.
    override func deleteBackward(_ sender: Any?) {
        if !applyListEdit(ListContinuation.backspaceEdit) { super.deleteBackward(sender) }
    }

    /// Applies the list edit for a single caret (no selection, no IME composition) as one undoable edit.
    private func applyListEdit(_ makeEdit: (String, Int) -> ListContinuation.Edit?) -> Bool {
        let selection = selectedRange()
        guard !hasMarkedText(), selectedRanges.count == 1, selection.length == 0,
              let edit = makeEdit(string, selection.location) else { return false }
        insertText(edit.replacement, replacementRange: edit.range)
        return true
    }

    /// Called for every view in the key window, not only the focused one: when the
    /// find bar is open its search field is the first responder, so clipboard and
    /// select-all actions go to the first responder, and undo/find only act here
    /// when this view has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isReturn = event.keyCode == 36 || event.keyCode == 76 // Return, keypad Enter
        if isReturn, modifiers == [.command] {
            onDone()
            return true
        }
        if isReturn, modifiers == [.command, .shift] {
            onDoneAndSubmit()
            return true
        }

        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let isFocused = window?.firstResponder === self
        switch (key, modifiers) {
        case ("x", [.command]):
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        case ("c", [.command]):
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        case ("v", [.command]):
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case ("a", [.command]):
            return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case ("z", [.command]) where isFocused:
            if undoManager?.canUndo == true { undoManager?.undo() }
            return true
        case ("z", [.command, .shift]) where isFocused:
            if undoManager?.canRedo == true { undoManager?.redo() }
            return true
        case ("f", [.command]) where isFocused:
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            performTextFinderAction(item)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
