// RichTextBridge.swift
// PopGuy — TextCaptureEngine
//
// Best-effort helper for round-tripping rich text through an AI provider.
//
// LIMITATION (by design):
//   AI providers (OpenAI, Anthropic, etc.) operate on plain text.  Any rich
//   formatting (bold, italic, font, paragraph style) in the original selection
//   is inherently lost when the text is sent to the provider.
//
//   This helper implements the simplest honest heuristic for V1:
//     • Extract the "dominant" (most-commonly-applied) base attributes from the
//       original NSAttributedString.
//     • Apply those base attributes uniformly to the entire improved plain-text
//       string.
//
//   This is explicitly LOSSY.  Inline spans (bold words, code runs) are not
//   preserved — only the base font, colour, and paragraph style that covered
//   the majority of the original text survive.  Plain text is always the
//   reliable fallback; this helper must NEVER block or break the Improve path.
//
// Wiring note:
//   This helper is intentionally NOT wired into the live Improve pipeline for
//   V1.  The ActionEngine/ActionEngineHandler operate on String throughout.
//   This module is a standalone tested helper that Phase-later work can adopt
//   by passing richPayload from CapturedSelection into applyDominantAttributes.
//
// Isolation:
//   All functions are nonisolated static members.  They accept and return
//   NSAttributedString synchronously — no actor crossing occurs, so no
//   Sendable conformance is needed.  NSAttributedString is documented as
//   thread-safe for concurrent reads.

import AppKit
import Foundation

// MARK: - RichTextBridge

/// Best-effort bridge between the original rich text and an AI-improved plain string.
nonisolated enum RichTextBridge {

    // MARK: - Public API

    /// Apply the dominant attributes of `original` uniformly to the plain
    /// `improved` string, producing a best-effort rich `NSAttributedString`.
    ///
    /// - Parameters:
    ///   - original: The NSAttributedString captured from the source element.
    ///   - improved: The plain-text result from the AI provider.
    /// - Returns: An NSAttributedString with the improved text styled using the
    ///   dominant base attributes of the original, or a plain NSAttributedString
    ///   if dominant-attribute extraction fails.
    ///
    /// LIMITATION: Inline spans (bold words, code runs, links) are not preserved.
    /// Only the base font, foreground colour, and paragraph style are applied.
    static func applyDominantAttributes(
        original: NSAttributedString,
        improved: String
    ) -> NSAttributedString {
        guard !improved.isEmpty else {
            return NSAttributedString(string: improved)
        }
        let dominant = dominantAttributes(in: original)
        return NSAttributedString(string: improved, attributes: dominant)
    }

    // MARK: - Internal helpers

    /// Extract the attributes that cover the most characters in `attributed`.
    ///
    /// Strategy: walk all attribute runs; tally total character-length for each
    /// distinct attribute dictionary; return the one with the highest total.
    /// Ties are broken by first occurrence (earliest in the string).
    ///
    /// Only the three most stable attributes are carried forward:
    ///   NSFont, NSForegroundColor, NSParagraphStyle.
    /// Other attributes (links, attachments, custom keys) are deliberately
    /// dropped to avoid reapplying context-specific metadata to the new text.
    static func dominantAttributes(in attributed: NSAttributedString) -> [NSAttributedString.Key: Any] {
        let length = attributed.length
        guard length > 0 else { return [:] }

        // Tally: map a "normalised attribute fingerprint" → (attrs, coverage).
        // We key on the description of the three stable attributes for grouping.
        var coverage: [(attrs: [NSAttributedString.Key: Any], chars: Int)] = []

        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: length),
            options: []
        ) { rawAttrs, range, _ in
            let filtered = filtered(rawAttrs)
            let key = attributeFingerprint(filtered)
            if let idx = coverage.firstIndex(where: { attributeFingerprint($0.attrs) == key }) {
                coverage[idx].chars += range.length
            } else {
                coverage.append((attrs: filtered, chars: range.length))
            }
        }

        return coverage.max(by: { $0.chars < $1.chars })?.attrs ?? [:]
    }

    /// Keep only the three stable text attributes; discard the rest.
    private static func filtered(
        _ attrs: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        let allowed: Set<NSAttributedString.Key> = [
            .font, .foregroundColor, .paragraphStyle
        ]
        return attrs.filter { allowed.contains($0.key) }
    }

    /// A stable string fingerprint for a filtered attribute dictionary so we
    /// can group identical sets without requiring dictionary equality on `Any`.
    private static func attributeFingerprint(
        _ attrs: [NSAttributedString.Key: Any]
    ) -> String {
        let font = attrs[.font].map { "\($0)" } ?? "nil"
        let color = attrs[.foregroundColor].map { "\($0)" } ?? "nil"
        let para = attrs[.paragraphStyle].map { "\($0)" } ?? "nil"
        return "\(font)|\(color)|\(para)"
    }
}
