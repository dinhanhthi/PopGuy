// DiffView.swift
// PopGuy — DiffRenderer
//
// AppKit-backed view (NSTextView hosted through SwiftUI's NSViewRepresentable)
// that renders a [DiffSegment] array as a styled inline diff with clickable
// hunks:
//   .equal    → label colour, not clickable
//   .inserted → green foreground
//   .deleted  → red foreground + strikethrough
// Every changed segment carries a link to its hunk (see DiffHunks); clicking it
// reports the hunk index through `onToggleHunk`. Rejected hunks keep their
// colours but are dimmed.
//
// Security: all segment text is treated as untrusted plain text. The attributed
// string is built from plain String segments with explicit attributes only —
// never through a markdown or markup parser.
//
// Sizing: the text view has no scroll view of its own (the surrounding result
// area scrolls). It wraps to the width it is given and reports its laid-out
// height as intrinsic size. Inside the toolbar the caller must give it an
// explicit width.

import AppKit
import SwiftUI

// MARK: - DiffView

/// Renders a word-level diff as styled inline text with clickable hunks.
@MainActor
struct DiffView: NSViewRepresentable {

    /// URL scheme used to tag each changed run with its hunk index.
    static let hunkURLScheme = "popguy-hunk"

    /// Opacity applied to the colours of a rejected hunk.
    static let rejectedAlpha: CGFloat = 0.35

    /// The diff segments to render.
    let segments: [DiffSegment]

    /// Indices of hunks the user rejected (rendered dimmed).
    let rejected: Set<Int>

    /// Font applied to the diff text.
    let font: NSFont

    /// Called with the hunk index when a changed run is clicked.
    let onToggleHunk: ((Int) -> Void)?

    init(
        segments: [DiffSegment],
        rejected: Set<Int> = [],
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        onToggleHunk: ((Int) -> Void)? = nil
    ) {
        self.segments = segments
        self.rejected = rejected
        self.font = font
        self.onToggleHunk = onToggleHunk
    }

    // MARK: NSViewRepresentable

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DiffTextView {
        let textView = DiffTextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        // Links keep their own diff colours; only the cursor changes.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        if let container = textView.textContainer {
            // Width is driven manually in DiffTextView.layout().
            container.widthTracksTextView = false
            container.lineFragmentPadding = 0
        }
        return textView
    }

    func updateNSView(_ textView: DiffTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onToggleHunk = onToggleHunk
        let inputs = Coordinator.Inputs(segments: segments, rejected: rejected, font: font)
        guard coordinator.lastInputs != inputs else { return }
        coordinator.lastInputs = inputs
        textView.textStorage?.setAttributedString(
            Self.makeAttributedString(segments: segments, rejected: rejected, font: font)
        )
        textView.invalidateIntrinsicContentSize()
    }

    // MARK: Attributed string

    /// Builds the styled diff from plain segment strings. Changed runs link to
    /// `popguy-hunk://<hunkIndex>`; runs of rejected hunks are dimmed.
    static func makeAttributedString(
        segments: [DiffSegment],
        rejected: Set<Int>,
        font: NSFont
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (segment, hunk) in zip(segments, DiffHunks.hunkIndices(segments)) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            let alpha: CGFloat = hunk.map(rejected.contains) == true ? rejectedAlpha : 1
            switch segment.kind {
            case .equal:
                attributes[.foregroundColor] = NSColor.labelColor
            case .inserted:
                attributes[.foregroundColor] = dimmed(.systemGreen, alpha: alpha)
            case .deleted:
                attributes[.foregroundColor] = dimmed(.systemRed, alpha: alpha)
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let hunk, let url = URL(string: "\(hunkURLScheme)://\(hunk)") {
                attributes[.link] = url
            }
            result.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return result
    }

    private static func dimmed(_ color: NSColor, alpha: CGFloat) -> NSColor {
        alpha < 1 ? color.withAlphaComponent(alpha) : color
    }

    /// Hunk index encoded in a `popguy-hunk://<i>` link, or nil.
    static func hunkIndex(fromLink link: Any) -> Int? {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, url.scheme == hunkURLScheme, let host = url.host else { return nil }
        return Int(host)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        struct Inputs: Equatable {
            let segments: [DiffSegment]
            let rejected: Set<Int>
            let font: NSFont
        }

        var lastInputs: Inputs?
        var onToggleHunk: ((Int) -> Void)?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let hunk = DiffView.hunkIndex(fromLink: link) else { return false }
            onToggleHunk?(hunk)
            return true
        }
    }
}

// MARK: - DiffTextView

/// Read-only NSTextView that wraps to its own width and reports its laid-out
/// height as intrinsic size, so SwiftUI sizes it vertically.
final class DiffTextView: NSTextView {
    override func layout() {
        super.layout()
        // Drive the container width from the width SwiftUI set; AppKit width
        // tracking does not fire under a hosting view.
        if let container = textContainer {
            let usableWidth = max(0, bounds.width - textContainerInset.width * 2)
            if container.size.width != usableWidth {
                container.size = NSSize(width: usableWidth, height: .greatestFiniteMagnitude)
                invalidateIntrinsicContentSize()
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let layoutManager = layoutManager, let textContainer = textContainer else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let height = layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
    }
}
