// MarkdownResultView.swift
// PopGuy
//
// SwiftUI view that renders a Markdown source string with inline decorations
// (bold, italic, strikethrough, inline code via AttributedString) and
// block-level bullet / ordered lists via a custom line classifier.
//
// Scope: inline syntax only — bold, italic, strikethrough, inline code.
// Block scope: bullet lists (- / * / +) and ordered lists (<n>. ).
// Underline and HTML are intentionally excluded.
// On any parse failure the raw text is shown as-is (plain text fallback).
//
// This view must satisfy the same layout contract as ToolbarView.resultText:
//   .font / .textSelection / .fixedSize / .multilineTextAlignment / .frame

import SwiftUI

// MARK: - Line classification

/// A classified line from the markdown source.
enum MarkdownLine {
    /// An unordered list item with its inline content.
    case bullet(content: String)
    /// An ordered list item with the original number and its inline content.
    case ordered(number: Int, content: String)
    /// A paragraph line (may be empty — rendered as blank space).
    case paragraph(content: String)
}

/// Classify each line of `source` into one of the three line kinds.
///
/// Detection is intentionally strict: the leading marker must be `- `, `* `,
/// or `+ ` (bullet) or `<digits>. ` (ordered) with at least one trailing
/// character. This avoids mis-classifying sentences that happen to start with
/// a dash (a known acceptable heuristic — no over-engineering intended).
func classifyLines(_ source: String) -> [MarkdownLine] {
    source.components(separatedBy: "\n").map { raw in
        // Strip leading whitespace before the marker (allows up to one level
        // of indentation without breaking the basic classifier).
        let trimmed = raw.drop(while: { $0 == " " || $0 == "\t" })
        let line = String(trimmed)

        // Bullet: starts with "- ", "* ", or "+ " followed by content.
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            let content = String(line.dropFirst(2))
            if !content.isEmpty {
                return .bullet(content: content)
            }
        }

        // Ordered: starts with one or two digits, a period, a space, then content.
        // Limiting to 1–2 digits prevents year-initial sentences (e.g. "2026. Something")
        // from being mis-classified as list items (4-digit years fail the bound).
        if let match = line.firstMatch(of: /^(\d{1,2})\. (.+)/) {
            let number = Int(match.1) ?? 1
            let content = String(match.2)
            return .ordered(number: number, content: content)
        }

        return .paragraph(content: raw)
    }
}

// MARK: - MarkdownResultView

/// Renders a Markdown source string with inline decorations and block lists.
///
/// Uses SwiftUI `Text` backed by `AttributedString` (Foundation Markdown) for
/// inline rendering (bold, italic, strikethrough, inline code). Block-level
/// bullets and ordered lists are built with `HStack` / `VStack` so that list
/// structure is preserved even when `AttributedString` does not handle block
/// syntax.
struct MarkdownResultView: View {

    let source: String
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(classifyLines(source).enumerated()), id: \.offset) { _, line in
                switch line {
                case .bullet(let content):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        inlineText(content)
                    }
                    .padding(.leading, 4)

                case .ordered(let number, let content):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(number).")
                        inlineText(content)
                    }
                    .padding(.leading, 4)

                case .paragraph(let content):
                    if content.isEmpty {
                        // Blank lines provide visual separation between blocks.
                        Text("")
                    } else {
                        inlineText(content)
                    }
                }
            }
        }
        .font(font)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Inline rendering

    /// Renders a single inline string via AttributedString (Foundation Markdown)
    /// to produce bold, italic, strikethrough, and inline-code decorations.
    /// Link and image attributes are stripped so untrusted AI/translation output
    /// cannot render tappable phishing links — this view is decorations-only.
    /// Falls back to plain `Text` if parsing fails.
    private func inlineText(_ s: String) -> Text {
        Text(strippedAttributedString(s))
    }
}

// MARK: - Inline attribute stripping

/// Parses `s` as inline Markdown and returns an `AttributedString` with all
/// link and image URL attributes removed.
///
/// The strip is performed via a single whole-range mutation, which is safe
/// because a single attribute-only, length-preserving whole-range mutation
/// cannot invalidate any index or coalesce runs mid-iteration — the range
/// itself never changes, so no runs are skipped.
///
/// On parse failure the input is wrapped in a plain `AttributedString`.
func strippedAttributedString(_ s: String) -> AttributedString {
    guard var attributed = try? AttributedString(
        markdown: s,
        options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
    ) else {
        return AttributedString(s)
    }
    let whole = attributed.startIndex..<attributed.endIndex
    attributed[whole].link = nil
    attributed[whole].imageURL = nil
    return attributed
}

// MARK: - Preview

#Preview {
    let sample = """
    **Bold** and *italic* and ~~strikethrough~~ and `inline code`.

    Bullet list:
    - Alpha item
    - Beta item
    + Gamma item

    Ordered list:
    1. First step
    2. Second step

    A plain paragraph that is long enough to demonstrate line wrapping behaviour inside the floating toolbar result area.
    """

    return MarkdownResultView(source: sample, font: .headline.weight(.regular))
        .padding()
        .frame(width: 320)
}
