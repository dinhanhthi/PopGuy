// TextCaptureEngine.swift
// PopGuy
//
// Primary text-capture path: reads selected text from the focused AXUIElement.
//
// Strict-concurrency design:
//   All public methods are @MainActor-isolated. AXUIElement is not Sendable;
//   the CapturedSelection value type stores it as an opaque wrapper so the
//   struct can be declared Sendable via @MainActor confinement. The payload
//   is consumed entirely on the MainActor (FloatingToolbar — Phase 2 —
//   is also MainActor), so @MainActor confinement is the right isolation.

import AppKit
import ApplicationServices

// MARK: - Result types

/// A reference to the AXUIElement that was the source of the selection.
/// Used in Phase 2 for paste-back into the originating element.
///
/// Isolation: @MainActor — AXUIElement crosses no actor boundaries.
@MainActor
struct SourceElementRef {
    let element: AXUIElement

    /// True when `element` is an editable text input (text field/area). Drives
    /// whether the toolbar shows "Paste back" — paste-back only lands in editable
    /// targets, so it is hidden for read-only sources (web articles, PDFs,
    /// readers). Defaults to false (read-only) when editability is unknown.
    var isEditable: Bool = false
}

/// Contextual data returned by the cheap O(1) probe when a selection is
/// confirmed present. Carries just enough to anchor the toolbar without
/// reading the selected text.
///
/// Isolation: @MainActor — AXUIElement (inside SourceElementRef) is non-Sendable.
@MainActor
struct SelectionProbe {
    /// The focused element where the selection was detected.
    let sourceElement: SourceElementRef
    /// Bounding rect of the selection in screen coordinates, if available.
    /// May be nil (e.g. virtual-scrolled Monaco). Toolbar falls back to
    /// mouse-pointer anchoring when nil.
    let screenRect: CGRect?
}

/// Three-way result from the cheap O(1) probe — decided without reading
/// the selected text (`kAXSelectedTextAttribute`/`AXStringForTextMarkerRange`).
///
/// Isolation: @MainActor — SelectionProbe holds a non-Sendable AXUIElement.
@MainActor
enum ProbeResult {
    /// Selection confirmed present (length > 0 or non-empty bounds).
    case present(SelectionProbe)
    /// Selection confirmed absent (length == 0, read succeeded).
    case absent
    /// Attribute unavailable or read failed — fall back to existing eager
    /// captureSelection so apps that can't be probed still work.
    case inconclusive
}

/// The payload returned by TextCaptureEngine for a successful selection read.
///
/// Isolation: @MainActor — this type is produced and consumed entirely on the
/// main actor. Its non-Sendable AXUIElement wrapper is never sent across actors.
@MainActor
struct CapturedSelection {
    /// Plain text of the selection. Never empty when capture succeeds.
    let text: String

    /// Best-effort rich-text payload from the whole element value attribute.
    /// This is a placeholder for Phase 4 (DiffRenderer); plain text is the
    /// contract. The selected-range's attributed representation is not directly
    /// exposed by most AX elements today — this reads the full element value
    /// and may not correspond to the selection only. May be nil.
    let richPayload: NSAttributedString?

    /// Reference to the AXUIElement for paste-back in Phase 2.
    let sourceElement: SourceElementRef

    /// Bounding rect of the selection in screen coordinates, if available.
    /// Used by FloatingToolbar (Phase 2) to position the panel near the text.
    let screenRect: CGRect?
}

// MARK: - Capture result

/// Three-way result distinguishing "captured text" from "AX succeeded but
/// empty" from "AX attribute unavailable". The distinction is important
/// because only the "unavailable" case should trigger clipboard fallback.
@MainActor
enum CaptureResult {
    /// AX read succeeded and returned non-empty text.
    case captured(CapturedSelection)
    /// AX read succeeded but the selection is absent or empty — no fallback.
    case emptySelection
    /// AX attribute was unavailable (err != .success) — try clipboard fallback.
    case unavailable
}

// MARK: - Engine

/// Reads selected text from the focused AXUIElement via the Accessibility API.
///
/// This is the primary capture path. When it returns `.unavailable`, the
/// caller should fall back to `ClipboardFallback`. When it returns
/// `.emptySelection`, no fallback should be attempted — the user has no
/// active selection and clipboard fallback would be misleading.
@MainActor
struct TextCaptureEngine {

    // MARK: - Public interface

    /// Attempt to read the current selection from the focused element.
    ///
    /// Returns:
    ///   - `.captured` when AX succeeds and returns non-empty text.
    ///   - `.emptySelection` when AX succeeds but selection is empty/whitespace.
    ///   - `.unavailable` when AX fails (no focus, attribute absent, not trusted).
    func captureSelection(from pid: pid_t) -> CaptureResult {
        let appElement = AXUIElementCreateApplication(pid)

        // Electron/Chromium apps (VSCode, Chrome, Slack…) keep their
        // accessibility tree dormant and expose web-content selection via the
        // private text-marker API, not AXSelectedText. Gate on a curated
        // bundle-ID allowlist so native apps are never woken (the wake flags are
        // a persistent side-effect — see usesEnhancedCapture).
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let usesEnhanced = bundleID.map(Self.usesEnhancedCapture(bundleID:)) ?? false

        // Primary path: native AXSelectedText on the focused element. Covers
        // NSTextView-backed apps (TextEdit, Notes, native fields).
        if let focused = focusedElement(in: appElement) {
            // A messaging timeout set on one AXUIElement does NOT propagate to
            // other (even equal) elements, so bound the focused element's own
            // reads here — otherwise a hung app beachballs the main thread.
            AXUIElementSetMessagingTimeout(focused, Self.axMessagingTimeout)
            var rawValue: AnyObject?
            let nativeReadOK = AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &rawValue) == .success
            if nativeReadOK {
                let text = rawValue as? String ?? ""
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .captured(makeCapturedSelection(text: text, focused: focused))
                }
            }

            // Native read empty or unavailable. Before giving up, try the WebKit
            // text-marker API on the focused element / enclosing AXWebArea WITHOUT
            // waking the AX tree. Native WebKit apps (Safari, Mail, Preview, Help,
            // and other WKWebView hosts) render page text whose selection lives in
            // AXSelectedTextMarkerRange — NOT kAXSelectedTextAttribute, which is
            // empty/unsupported for rendered content. This is a harmless,
            // side-effect-free read, so — unlike the wake flags — it is NOT gated
            // on the Electron allowlist. It is the fix for "toolbar never appears
            // on normal Safari/Mail page text" and mirrors how PopClip and similar
            // tools read web selections (A11y first, no clipboard).
            if !usesEnhanced, let result = markerCapture(focused: focused) {
                return result
            }

            // Focused element exposes no selection. Some native apps (Apple Books
            // and other readers) keep focus on a container (AXGroup) while the
            // actual selection lives on AXStaticText leaves deeper in the tree,
            // exposed via kAXSelectedTextAttribute (NOT the text-marker API and NOT
            // on an ancestor of the focused element). Descend the tree to collect
            // it — pure AX, no clipboard, mirroring how PopClip reads such apps.
            if !usesEnhanced, let result = descendingSelectionCapture(appElement: appElement) {
                return result
            }

            // Native read succeeded but empty AND no marker selection: a genuine
            // "no selection" for a non-allowlisted app. Return .emptySelection so
            // explicit-trigger paths (chord/hotkey) do not fire a needless
            // synthetic ⌘C. When the native read itself FAILED (nativeReadOK ==
            // false, e.g. a web area that doesn't support kAXSelectedTextAttribute),
            // fall through to .unavailable so the ⌘C fallback can still run.
            if nativeReadOK, !usesEnhanced {
                return .emptySelection
            }
        }

        // Enhanced path: woken AX + text-marker read for allowlisted apps.
        if usesEnhanced, let result = enhancedCapture(in: appElement) {
            return result
        }

        return .unavailable
    }

    /// Maximum AX nodes visited while descending to collect a selection — caps the
    /// main-thread cost of walking a large tree (Books needs ~400).
    private static let descendNodeBudget = 2000

    /// Maximum descent depth (Books exposes the selection around depth 9).
    private static let descendMaxDepth = 30

    /// Collect a selection by descending the app's AX tree when the focused element
    /// exposes none. Some native apps (Apple Books and other readers) keep focus on
    /// a container (AXGroup) while the actual selection lives on AXStaticText leaves
    /// deeper in the tree, exposed via `kAXSelectedTextAttribute` — not the
    /// text-marker API, and not on an ancestor of the focused element. Returns
    /// `.captured` with the joined selection, or `nil` when no element reports one.
    ///
    /// Pure AX, no clipboard. Bounded by `descendNodeBudget` + `descendMaxDepth`
    /// and a per-element messaging timeout so a large/hung tree cannot stall the
    /// main thread. Anchors to the mouse pointer (`screenRect: nil`) — these apps
    /// expose no usable selection rect.
    private func descendingSelectionCapture(appElement: AXUIElement) -> CaptureResult? {
        var pieces: [String] = []
        var budget = Self.descendNodeBudget
        collectSelectedText(from: appElement, depth: 0, budget: &budget, into: &pieces)
        let text = Self.assembleSelectedText(pieces)
        guard !text.isEmpty else { return nil }
        return .captured(CapturedSelection(
            text: text,
            richPayload: nil,
            sourceElement: SourceElementRef(element: appElement),
            screenRect: nil
        ))
    }

    /// DFS pre-order (document order) collection of `kAXSelectedTextAttribute`.
    /// When an element reports a non-empty selection its subtree is PRUNED — so a
    /// container that exposes the whole selection wins in one read, and a parent +
    /// its descendants are never double-counted. Otherwise descend into children.
    private func collectSelectedText(from element: AXUIElement, depth: Int, budget: inout Int, into pieces: inout [String]) {
        guard depth < Self.descendMaxDepth, budget > 0 else { return }
        budget -= 1
        AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeout)

        var selRaw: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selRaw) == .success,
           let sel = selRaw as? String,
           !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pieces.append(sel)
            return  // prune — this element's selection already covers its subtree
        }

        var childrenRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRaw) == .success,
              let children = childrenRaw as? [AXUIElement] else { return }
        for child in children {
            guard budget > 0 else { return }
            collectSelectedText(from: child, depth: depth + 1, budget: &budget, into: &pieces)
        }
    }

    /// Join per-element selected-text fragments into one string: trim each, drop
    /// empties, join with a single space. Pure/testable — nonisolated so unit tests
    /// need no main-actor hop.
    nonisolated static func assembleSelectedText(_ pieces: [String]) -> String {
        pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Cheap O(1) probe

    /// Checks for a selection without reading the selected text — safe to call
    /// on every left mouse-up.
    ///
    /// Primary path (native + Cursor/VSCode): `kAXSelectedTextRangeAttribute` on
    /// the focused element returns a CFRange. Length > 0 → `.present`; length ==
    /// 0 → `.absent`. Bounded by `axMessagingTimeout` — no string read.
    ///
    /// Electron fallback (allowlisted bundle ID only, when the primary read
    /// fails): sets wake flags (fire-and-forget, NO touchDescendants), reads
    /// `AXSelectedTextMarkerRange` on the focused element / enclosing AXWebArea,
    /// and uses `AXBoundsForTextMarkerRange` rect-width as the presence proxy.
    ///
    /// Returns `.inconclusive` when the attributes are unavailable — callers
    /// fall back to the existing eager `captureSelection` so no app regresses.
    ///
    /// NEVER reads `kAXSelectedTextAttribute` or `AXStringForTextMarkerRange` —
    /// those are O(size) and defeat the purpose of this probe.
    func probeSelection(from pid: pid_t) -> ProbeResult {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.axMessagingTimeout)

        // Resolve the focused element — no selection without one.
        guard let focused = focusedElement(in: appElement) else {
            return .inconclusive
        }
        AXUIElementSetMessagingTimeout(focused, Self.axMessagingTimeout)

        // --- Primary probe: kAXSelectedTextRangeAttribute (CFRange) ---
        // Works for native NSTextView apps AND Cursor/VSCode (returns a non-zero
        // length for real selections without needing to wake the AX tree).
        var rangeRaw: AnyObject?
        let rangeErr = AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRaw
        )

        if rangeErr == .success, let rangeRaw {
            // Guard CF type before casting — mirror selectionScreenRect pattern.
            if CFGetTypeID(rangeRaw as CFTypeRef) == AXValueGetTypeID() {
                let axVal = (rangeRaw as CFTypeRef) as! AXValue
                var cfRange = CFRange()
                if AXValueGetValue(axVal, .cfRange, &cfRange) {
                    if Self.isNonEmptyRange(cfRange) {
                        // Reuse the already-obtained range AXValue for the
                        // bounds call (avoids a second round-trip).
                        let rect = boundsForRange(rangeRaw: rangeRaw, on: focused)
                        return .present(SelectionProbe(
                            sourceElement: SourceElementRef(element: focused),
                            screenRect: rect
                        ))
                    } else {
                        // Attribute read succeeded and length == 0: no selection.
                        return .absent
                    }
                }
            }
            // AXValue type-check failed — treat as inconclusive.
            return .inconclusive
        }

        // Primary read failed (attribute absent or err). For non-allowlisted
        // apps this is truly inconclusive; for Electron apps try the marker path.
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        guard bundleID.map(Self.usesEnhancedCapture(bundleID:)) ?? false else {
            return .inconclusive
        }

        // --- Electron fallback: AXSelectedTextMarkerRange rect-width probe ---
        // Set wake flags (fire-and-forget). Explicitly do NOT run touchDescendants
        // here — that O(≤1 s) walk is what makes the probe expensive. The probe
        // must stay cheap; any probe cost is paid on every click.
        AXUIElementSetAttributeValue(appElement, AXAttr.manualAccessibility as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, AXAttr.enhancedUserInterface as CFString, kCFBooleanTrue)

        // Try focused element first, then the enclosing AXWebArea.
        var markerSources = [focused]
        if let webArea = enclosingWebArea(of: focused), webArea != focused {
            AXUIElementSetMessagingTimeout(webArea, Self.axMessagingTimeout)
            markerSources.append(webArea)
        }
        for source in markerSources {
            if let rect = markerSelectionBounds(of: source) {
                // Non-nil, non-zero rect ≡ non-empty selection.
                if Self.isNonEmptyRect(rect) {
                    return .present(SelectionProbe(
                        sourceElement: SourceElementRef(element: focused),
                        screenRect: rect
                    ))
                } else {
                    // Marker range returned but bounds are empty → absent.
                    return .absent
                }
            }
        }
        // Marker read failed or returned nil on all sources → inconclusive.
        return .inconclusive
    }

    // MARK: - Probe helpers (internal static — unit-testable without a live AX tree)

    /// Returns true when the CFRange has a positive length (non-empty selection).
    /// Pure value computation — nonisolated so unit tests can call it without
    /// hopping to the main actor.
    nonisolated static func isNonEmptyRange(_ range: CFRange) -> Bool {
        range.length > 0
    }

    /// Returns true when the rect has a positive width (used as the O(1) marker
    /// presence proxy — avoids decoding AXTextMarker endpoints).
    /// Pure value computation — nonisolated so unit tests can call it without
    /// hopping to the main actor.
    nonisolated static func isNonEmptyRect(_ rect: CGRect) -> Bool {
        rect.width > 0
    }

    /// Reads `AXBoundsForTextMarkerRange` for the given element's marker range.
    /// Returns nil on any error or type-check failure. Never reads the text string.
    private func markerSelectionBounds(of element: AXUIElement) -> CGRect? {
        var markerRangeRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            AXAttr.selectedTextMarkerRange as CFString,
            &markerRangeRaw
        ) == .success, let markerRangeRaw else { return nil }

        var boundsRaw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            AXAttr.boundsForTextMarkerRange as CFString,
            markerRangeRaw as CFTypeRef,
            &boundsRaw
        ) == .success, let boundsRaw else { return nil }

        guard CFGetTypeID(boundsRaw as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let axVal = (boundsRaw as CFTypeRef) as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(axVal, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Reads `kAXBoundsForRangeParameterizedAttribute` for the given range AXValue.
    /// Mirrors `selectionScreenRect` but accepts an already-obtained rangeRaw so
    /// the probe doesn't need a second round-trip to re-read the range.
    private func boundsForRange(rangeRaw: AnyObject, on element: AXUIElement) -> CGRect? {
        var boundsRaw: AnyObject?
        let boundsErr = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeRaw as CFTypeRef,
            &boundsRaw
        )
        guard boundsErr == .success, let boundsRaw else { return nil }
        guard CFGetTypeID(boundsRaw as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let axVal = (boundsRaw as CFTypeRef) as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(axVal, .cgRect, &rect) else { return nil }
        return rect
    }

    // MARK: - Capture paths

    /// Woken-AX + text-marker read for Electron/Chromium apps. Sets the wake
    /// flags (fire-and-forget), forces the AX tree to materialize, re-fetches
    /// the focused element, reads native AXSelectedText, then the WebKit
    /// text-marker API (on the focused element and its enclosing AXWebArea).
    ///
    /// Returns `.captured` on a non-empty read, or `nil` when nothing readable
    /// — including a readable-but-empty marker. Returning `nil` (not
    /// `.emptySelection`) lets the caller fall through to the clipboard
    /// fallback: web-based editors (Monaco in VSCode/Cursor, Notion) render a
    /// *virtual* selection the AX text-marker API does not surface, so AX reads
    /// empty even when text is selected — only the clipboard path captures it.
    /// When there is genuinely no selection the fallback copies nothing and
    /// shows no toolbar, so over-reaching to `.unavailable` is harmless.
    private func enhancedCapture(in appElement: AXUIElement) -> CaptureResult? {
        // Bound the app element's AX IPC round-trips (touchDescendants reads
        // children off it). A timeout on one element does NOT propagate to
        // others, so the focused element below is bounded separately.
        AXUIElementSetMessagingTimeout(appElement, Self.axMessagingTimeout)

        // Wake Chromium's accessibility tree. AXManualAccessibility is the
        // Electron flag; AXEnhancedUserInterface is required for Chrome. Both
        // are private and may be unsupported on some versions — fire-and-forget.
        AXUIElementSetAttributeValue(appElement, AXAttr.manualAccessibility as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, AXAttr.enhancedUserInterface as CFString, kCFBooleanTrue)

        // Tree construction is asynchronous; touching descendants forces it to
        // materialize before we re-fetch the focused element and read. Bounded
        // by depth, a total-node budget, AND a wall-clock deadline so a huge or
        // slow tree can't stall the main thread.
        var budget = Self.touchNodeBudget
        touchDescendants(
            of: appElement,
            depth: 4,
            budget: &budget,
            deadline: CFAbsoluteTimeGetCurrent() + Self.touchDeadlineSeconds
        )

        guard let focused = focusedElement(in: appElement) else { return nil }
        AXUIElementSetMessagingTimeout(focused, Self.axMessagingTimeout)

        // Native field inside the woken app (e.g. the Chrome omnibox). An empty
        // read here does NOT conclude — a web-area selection lives in the
        // text-marker range, tried next.
        var rawValue: AnyObject?
        if AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &rawValue) == .success {
            let text = rawValue as? String ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .captured(makeCapturedSelection(text: text, focused: focused))
            }
        }

        // Web content: text-marker API on the focused element / enclosing AXWebArea.
        return markerCapture(focused: focused)
    }

    /// Read a web-content selection via the WebKit text-marker API on the focused
    /// element and its enclosing AXWebArea. Returns `.captured` on a non-empty
    /// read, or `nil` when no marker selection is exposed.
    ///
    /// Sets NO wake flags and runs NO `touchDescendants` walk — a plain marker
    /// read is harmless and side-effect-free, so it is safe to call directly on
    /// native WebKit apps (Safari, Mail, …) as well as from the woken Electron
    /// path. The selection lives on the AXWebArea — which is `focused` for a
    /// plain web page, or an ancestor of a focused hidden textarea in editor apps
    /// — so try the focused element first, then the enclosing area.
    private func markerCapture(focused: AXUIElement) -> CaptureResult? {
        // `enclosingWebArea` bounds the IPC of every ancestor it walks (including
        // the returned web area), so the marker reads below are already timeout-safe
        // even on the ungated native path.
        var markerSources = [focused]
        if let webArea = enclosingWebArea(of: focused), webArea != focused {
            markerSources.append(webArea)
        }
        for source in markerSources {
            if let markerText = selectedTextViaMarker(of: source),
               !markerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .captured(makeCapturedSelection(text: markerText, focused: focused))
            }
        }
        return nil
    }

    /// Walk up the AX parent chain to the enclosing AXWebArea (or return the
    /// element itself when it is already one). The web-content selection lives
    /// on the AXWebArea, even when a descendant textarea holds focus.
    private func enclosingWebArea(of element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0 ..< 12 {
            // Bound EACH node's AX IPC before reading it. A messaging timeout is
            // per-element and does NOT propagate, so the up-to-12 ancestors walked
            // here are otherwise read at the multi-second system default. This walk
            // now runs ungated for native apps (Safari/Mail/…), so an unbounded
            // ancestor read could beachball the main thread on a hung WebKit host.
            AXUIElementSetMessagingTimeout(current, Self.axMessagingTimeout)
            var roleValue: AnyObject?
            if AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleValue) == .success,
               (roleValue as? String) == "AXWebArea" {
                return current
            }
            var parentValue: AnyObject?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue,
                  CFGetTypeID(parentValue as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
            current = unsafeDowncast(parentValue as CFTypeRef, to: AXUIElement.self)
        }
        return nil
    }

    /// Assemble a CapturedSelection from a focused element and its selected
    /// text. Rich payload and screen rect are best-effort — both are commonly
    /// nil for web content, and the toolbar positions at the mouse when the
    /// rect is nil.
    private func makeCapturedSelection(text: String, focused: AXUIElement) -> CapturedSelection {
        CapturedSelection(
            text: text,
            richPayload: attributedStringAttribute(kAXValueAttribute, of: focused),
            sourceElement: SourceElementRef(element: focused, isEditable: isElementEditable(focused)),
            screenRect: selectionScreenRect(of: focused)
        )
    }

    /// AX roles that identify an editable text input.
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    /// Whether `element` is an editable text input. Editable web pages focus the
    /// AXWebArea (read-only here) while editor apps focus a hidden AXTextArea, so
    /// checking the focused element discriminates "inside an input" correctly.
    /// `focused` already has a messaging timeout set by the caller.
    private func isElementEditable(_ element: AXUIElement) -> Bool {
        // Primary: can the value be written? Editable fields report
        // kAXValueAttribute as settable; read-only content does not.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        // Fallback: role-based for inputs that don't report settable.
        var roleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return false }
        return Self.editableRoles.contains(role)
    }

    // MARK: - AX helpers

    private func focusedElement(in appElement: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard err == .success, let value else { return nil }
        // Guard the CF type before casting to avoid a trap on untrusted AX data.
        guard CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value as CFTypeRef, to: AXUIElement.self)
    }

    private func attributedStringAttribute(_ attribute: String, of element: AXUIElement) -> NSAttributedString? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? NSAttributedString
    }

    /// Returns the bounding rect of the selected text range in screen coordinates.
    /// Uses kAXBoundsForRangeParameterizedAttribute with the selected range.
    private func selectionScreenRect(of element: AXUIElement) -> CGRect? {
        // Read the selected text range.
        var rangeValue: AnyObject?
        let rangeErr = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )
        guard rangeErr == .success, let rangeValue else { return nil }

        // Ask for the bounding rect of that range.
        var boundsValue: AnyObject?
        let boundsErr = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        )
        guard boundsErr == .success, let boundsValue else { return nil }

        var rect = CGRect.zero
        // Guard the CF type before casting to avoid a trap on untrusted AX data.
        guard CFGetTypeID(boundsValue as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let axValue = (boundsValue as CFTypeRef) as! AXValue
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    // MARK: - Enhanced (Electron/Chromium) helpers

    /// Private/undocumented AX attribute names used to wake and read web content.
    private enum AXAttr {
        static let manualAccessibility = "AXManualAccessibility"
        static let enhancedUserInterface = "AXEnhancedUserInterface"
        static let selectedTextMarkerRange = "AXSelectedTextMarkerRange"
        static let stringForTextMarkerRange = "AXStringForTextMarkerRange"
        static let boundsForTextMarkerRange = "AXBoundsForTextMarkerRange"
    }

    /// Bundle IDs of Electron/Chromium apps whose web content needs the AX tree
    /// woken and read via the text-marker API. Hardcoded (not user-facing);
    /// extend in code as new apps are confirmed. Non-private so a unit test can
    /// assert set-equality against the expected list (catches additive drift).
    static let enhancedCaptureBundleIDs: Set<String> = [
        // VSCode + forks
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",       // VSCodium
        "com.todesktop.230313mzl4w4u92",   // Cursor
        // Chromium browsers
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",           // Edge
        "com.brave.Browser",
        "company.thebrowser.Browser",      // Arc
        // Electron apps
        "com.tinyspeck.slackmacgap",       // Slack
        "com.hnc.Discord",
        "com.hnc.DiscordCanary",
        "com.hnc.DiscordPTB",
        "md.obsidian",
        "notion.id",
        "com.figma.Desktop",
    ]

    /// Whether the app with this bundle ID uses the enhanced (woken-AX +
    /// text-marker) capture path instead of the plain AXSelectedText path.
    /// Non-private so the matcher contract can be unit-tested directly.
    static func usesEnhancedCapture(bundleID: String) -> Bool {
        enhancedCaptureBundleIDs.contains(bundleID)
    }

    /// Whether the app with this PID uses the enhanced capture path.
    /// Resolves the bundle ID via NSRunningApplication and delegates to
    /// `usesEnhancedCapture(bundleID:)`. Returns false when the PID is unknown.
    /// Non-private so SelectionPipeline can call it without duplicating the lookup.
    static func usesEnhancedCapture(pid: pid_t) -> Bool {
        guard let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
            return false
        }
        return usesEnhancedCapture(bundleID: bundleID)
    }

    /// Upper bound on AXChildren reads during `touchDescendants` — caps the
    /// main-thread cost of waking a large (e.g. VSCode) accessibility tree.
    private static let touchNodeBudget = 200

    /// Wall-clock ceiling (seconds) for the whole `touchDescendants` walk, so a
    /// slow tree can't stall the main thread even within the node budget.
    private static let touchDeadlineSeconds: CFAbsoluteTime = 1.0

    /// Per-element AX messaging timeout (seconds). Bounds each synchronous AX
    /// IPC so a hung app can't beachball the main thread.
    private static let axMessagingTimeout: Float = 0.5

    /// Read web-content selection via the WebKit text-marker API:
    /// AXSelectedTextMarkerRange → AXStringForTextMarkerRange. Returns nil when
    /// the element does not expose a text-marker selection.
    private func selectedTextViaMarker(of element: AXUIElement) -> String? {
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            AXAttr.selectedTextMarkerRange as CFString,
            &rangeValue
        ) == .success, let rangeValue else { return nil }

        var stringValue: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            AXAttr.stringForTextMarkerRange as CFString,
            rangeValue as CFTypeRef,
            &stringValue
        ) == .success else { return nil }

        return stringValue as? String
    }

    /// Recursively read AXChildren to a bounded depth, forcing a dormant
    /// Chromium accessibility tree to materialize after the wake flags are set.
    /// Bounded three ways so a large/slow tree cannot stall the main thread:
    /// `depth`, a total-node `budget` (breadth is otherwise unbounded), and a
    /// wall-clock `deadline`.
    private func touchDescendants(of element: AXUIElement, depth: Int, budget: inout Int, deadline: CFAbsoluteTime) {
        guard depth > 0, budget > 0, CFAbsoluteTimeGetCurrent() < deadline else { return }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success, let children = value as? [AXUIElement] else { return }
        for child in children {
            guard budget > 0, CFAbsoluteTimeGetCurrent() < deadline else { return }
            budget -= 1
            touchDescendants(of: child, depth: depth - 1, budget: &budget, deadline: deadline)
        }
    }

}
