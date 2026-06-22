// DiffView.swift
// PopGuy — DiffRenderer
//
// SwiftUI view that renders a [DiffSegment] array as a styled inline diff:
//   .equal    → default foreground colour
//   .inserted → green foreground
//   .deleted  → red foreground + strikethrough
//
// Security: all segment text is treated as untrusted plain text. AttributedString
// is constructed from plain String segments with explicit attributes only — never
// from AttributedString(markdown:) or any markup parser.
//
// Isolation: @MainActor — SwiftUI view; the pure segment→AttributedString
// mapping is also performed on the main actor (it's cheap for typical diff
// sizes and avoids actor-crossing for a non-Sendable type).
//
// For very large diffs the content is wrapped in a ScrollView capped at
// maxHeight so the toolbar remains usable.

import SwiftUI

// MARK: - DiffView

/// Renders a word-level diff as styled inline text.
@MainActor
struct DiffView: View {

    /// The diff segments to render.
    let segments: [DiffSegment]

    /// Maximum height before the result becomes scrollable.
    var maxHeight: CGFloat = 200

    /// Font applied to the diff text. Defaults to `.callout` to match the
    /// plain-text result renderer.
    var font: Font = .callout

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(attributedString)
                .font(font)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                // Wrap to the available width and grow vertically; without this,
                // the ancestor `.fixedSize()` forces one overflowing line that
                // the panel clips.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
    }

    // MARK: - AttributedString builder

    /// Converts `segments` into a single `AttributedString` with colour and
    /// strikethrough styling.  Plain String initialisation is used for each
    /// segment — never markdown — to avoid executing embedded markup in
    /// untrusted AI-returned text.
    private var attributedString: AttributedString {
        var result = AttributedString()
        for segment in segments {
            var run = AttributedString(segment.text)
            switch segment.kind {
            case .equal:
                break   // Use default container attributes.
            case .inserted:
                run.foregroundColor = .green
            case .deleted:
                run.foregroundColor = .red
                // strikethroughStyle is available in SwiftUI's AttributedString
                // scope on macOS 12.0+, which is below our macOS 13.0 floor.
                run.strikethroughStyle = .single
            }
            result += run
        }
        return result
    }
}
