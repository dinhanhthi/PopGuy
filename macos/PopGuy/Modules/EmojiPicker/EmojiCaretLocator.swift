// EmojiCaretLocator.swift
// PopGuy — EmojiPicker
//
// Finds the text caret of the focused element in a given app via the Accessibility API
// (ported from FastMoji), so the Emoji Picker can open next to it.
//
// Isolation: nonisolated — the AX lookups are synchronous, thread-safe and bounded by
// per-element messaging timeouts, meant to run off the main thread. Only
// `screenRect(fromAX:)` (AppKit screens and mouse location) is MainActor.
// Read-only: nothing here ever sets an AX attribute.

import AppKit
import ApplicationServices

/// Result of `EmojiCaretLocator.axCaretRect(pid:)`, in global top-left-origin coordinates.
nonisolated enum CaretLookup: Sendable {
    /// Plausible caret bounds.
    case caret(CGRect)
    /// No plausible caret, but the focused element is a small (single-line-ish) text field.
    case field(CGRect)
    /// Nothing usable.
    case none
}

nonisolated enum EmojiCaretLocator {
    /// Messaging timeout set on the app element and on its focused element only. Never set on
    /// the system-wide element: that would apply process-wide and cut every other module's
    /// AX reads to this value.
    private static let axMessagingTimeout: Float = 0.2

    /// `lookup` (from `axCaretRect(pid:)`) in AppKit screen coordinates (bottom-left origin).
    /// A `.field` maps to its full frame (zero width), so the panel opens below it, or above it
    /// without covering it when there is no room below. Falls back to the mouse location
    /// (zero size) for `.none` or when the point lies on no screen.
    @MainActor
    static func screenRect(fromAX lookup: CaretLookup) -> NSRect {
        let mouse = NSRect(origin: NSEvent.mouseLocation, size: .zero)
        guard let primary = NSScreen.screens.first else { return mouse }
        let rect: NSRect
        switch lookup {
        case .caret(let caret):
            rect = NSRect(
                x: caret.minX,
                y: primary.frame.maxY - caret.maxY,
                width: caret.width,
                height: caret.height
            )
        case .field(let field):
            rect = NSRect(x: field.minX, y: primary.frame.maxY - field.maxY, width: 0, height: field.height)
        case .none:
            return mouse
        }
        guard NSScreen.screens.contains(where: { NSMouseInRect(rect.origin, $0.frame, false) })
        else { return mouse }
        return rect
    }

    /// Caret bounds (or the focused field's frame) of the app `pid`, in global top-left-origin
    /// coordinates. Up to 7 AX round-trips of up to 0.2 s each: call it off the main thread.
    static func axCaretRect(pid: pid_t) -> CaretLookup {
        guard let element = focusedElement(pid: pid) else { return .none }
        let frame = elementFrame(element)

        if let caret = caretRect(element, in: frame) { return .caret(anchor(caret, in: frame)) }
        // Chromium/Electron often report bogus caret bounds: anchor on a small focused text field instead.
        if let frame, !frame.isEmpty, frame.height >= 1, frame.height <= 120, frame.width >= 1,
           isTextInput(element) {
            return .field(frame)
        }
        return .none
    }

    /// True when the focused element of the app `pid` is a password field (native secure text
    /// field or a web password input). False when it cannot be read (no AX trust, timeout,
    /// nothing focused): an unreadable element must not turn the picker off everywhere.
    /// Second layer of the password guard: `EmojiPickerController` first checks the system's
    /// Secure Input state (Carbon), which covers fields this AX read cannot see, and only then
    /// runs this check. 3 AX round-trips of up to 0.2 s each: call it off the main thread.
    static func focusedIsSecure(pid: pid_t) -> Bool {
        guard let element = focusedElement(pid: pid) else { return false }
        return isSecureTextInput(
            role: attribute(element, kAXRoleAttribute) as? String,
            subrole: attribute(element, kAXSubroleAttribute) as? String
        )
    }

    /// Password fields report `AXSecureTextField` as their subrole (role `AXTextField`);
    /// some hosts report it as the role itself.
    static func isSecureTextInput(role: String?, subrole: String?) -> Bool {
        role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole
    }

    /// In a small field (e.g. Safari's address bar) the caret is shorter than the field, so a panel
    /// placed under the caret would cover the field: stretch it to the field's height, keeping its x.
    /// Large text views keep the caret line.
    static func anchor(_ caret: CGRect, in field: CGRect?) -> CGRect {
        guard let field, !field.isEmpty, field.height <= 120 else { return caret }
        return CGRect(x: caret.minX, y: field.minY, width: caret.width, height: field.height)
    }

    /// False for bounds that cannot be a caret: null/infinite, huge, or (when the focused
    /// element's frame is known) away from that element. Chromium-based apps report success
    /// with such rects (e.g. x≈0 or the wrong coordinate space). Zero height is allowed.
    static func isPlausibleCaret(_ caret: CGRect, in element: CGRect?) -> Bool {
        guard !caret.isNull, !caret.isInfinite,
              caret.height >= 0, caret.height <= 200, caret.width <= 400,
              // Chromium's bogus bounds sit at global x = 0; a maximised window would contain them.
              abs(caret.minX) >= 1
        else { return false }
        if let element, !element.isEmpty {
            return element.insetBy(dx: -24, dy: -24).contains(CGPoint(x: caret.midX, y: caret.midY))
        }
        return true
    }

    // MARK: - AX helpers

    /// Focused element of the app `pid`, read through the app element (never the system-wide
    /// one), with the short messaging timeout set on both elements.
    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axMessagingTimeout)
        guard let focused = attribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
        return element
    }

    private static func isTextInput(_ element: AXUIElement) -> Bool {
        guard let role = attribute(element, kAXRoleAttribute) as? String else { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    }

    /// Plausible caret bounds of the selection in `element`, or nil.
    private static func caretRect(_ element: AXUIElement, in frame: CGRect?) -> CGRect? {
        guard let rangeRef = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }
        let rangeValue = unsafeDowncast(rangeRef, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &range)
        else { return nil }

        // A selection anchors on its first character (its union rect can be wide or multi-line).
        var anchor = range.length > 0 ? CFRange(location: range.location, length: 1) : range
        let anchorValue = range.length > 0 ? AXValueCreate(.cfRange, &anchor) : rangeValue
        let primary = anchorValue.flatMap { bounds(element, $0) }.flatMap {
            isPlausibleCaret($0, in: frame) ? $0 : nil
        }
        if let primary, primary.height > 0 { return primary }
        if range.length == 0, range.location > 0 {
            // Empty selection often reports zero-height bounds: use the previous character's.
            var previous = CFRange(location: range.location - 1, length: 1)
            if let previousValue = AXValueCreate(.cfRange, &previous),
               let rect = bounds(element, previousValue) {
                let caret = CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
                if isPlausibleCaret(caret, in: frame) { return caret }
            }
        }
        // Zero-height but otherwise plausible (e.g. caret at position 0): still better than the mouse.
        return primary
    }

    /// Frame of `element` (position + size attributes), or nil.
    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionRef = attribute(element, kAXPositionAttribute),
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              let sizeRef = attribute(element, kAXSizeAttribute),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        let positionValue = unsafeDowncast(positionRef, to: AXValue.self)
        let sizeValue = unsafeDowncast(sizeRef, to: AXValue.self)
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Bounds-for-range parameterized attribute for `range`; nil on failure or a zero rect at (0,0).
    private static func bounds(_ element: AXUIElement, _ range: AXValue) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect,
              AXValueGetValue(axValue, .cgRect, &rect),
              !rect.isNull, !rect.isInfinite,
              !(rect.origin == .zero && rect.size == .zero)
        else { return nil }
        return rect
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
