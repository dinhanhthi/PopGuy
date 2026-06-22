// DictionaryEntryView.swift
// PopGuy — DictionaryEngine
//
// Read-only dictionary result card for the floating toolbar.

import SwiftUI

// MARK: - DictionaryEntryView

@MainActor
struct DictionaryEntryView: View {
    let entry: DictionaryEntry
    var onListen: () -> Void = {}
    var isSpeaking: Bool = false
    var onCopy: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    /// Muted red for source-language examples. A softer shade than system `.red`,
    /// tuned to stay legible on both the light and dark toolbar materials.
    private var exampleColor: Color {
        colorScheme == .dark
            ? Color(red: 0.93, green: 0.56, blue: 0.52)
            : Color(red: 0.70, green: 0.22, blue: 0.18)
    }

    /// Soft sky blue for part-of-speech labels, adapting to the toolbar material.
    private var partOfSpeechColor: Color {
        colorScheme == .dark
            ? Color(red: 0.55, green: 0.78, blue: 0.96)
            : Color(red: 0.20, green: 0.52, blue: 0.80)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headwordSection

            if entry.isPlainTextOnly, let raw = entry.rawText {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(raw)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 220)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(entry.lexicalEntries.enumerated()), id: \.offset) { _, lexical in
                            lexicalSection(lexical)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }

        }
    }

    // MARK: - Sections

    private var headwordSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.headword)
                .font(.title3.weight(.semibold))

            let pronunciations = entry.lexicalEntries.flatMap(\.pronunciations)
            if !pronunciations.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(pronunciations.enumerated()), id: \.offset) { _, pronunciation in
                        pronunciationChip(pronunciation)
                    }
                }
            }

            Text(entry.sourceName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func lexicalSection(_ lexical: LexicalEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pos = lexical.partOfSpeech, !pos.isEmpty {
                Text(pos)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(partOfSpeechColor)
            }

            ForEach(Array(lexical.senses.enumerated()), id: \.offset) { _, sense in
                VStack(alignment: .leading, spacing: 4) {
                    if !sense.definition.isEmpty {
                        Text(sense.definition)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(Array(sense.examples.enumerated()), id: \.offset) { _, example in
                        exampleBlock(example)
                    }

                    if !sense.synonyms.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(sense.synonyms, id: \.self) { synonym in
                                Text(synonym)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    private func pronunciationChip(_ pronunciation: Pronunciation) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(pronunciation.ipa)
                .font(.caption.monospaced())
                .foregroundStyle(.blue)
            if let region = pronunciation.tags.first, !region.isEmpty {
                Text(region)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func exampleBlock(_ example: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(Self.exampleLines(for: example).enumerated()), id: \.offset) { index, line in
                exampleLine(line, index: index)
            }
        }
        .padding(.leading, 10)
    }

    @ViewBuilder
    private func exampleLine(_ line: String, index: Int) -> some View {
        if index == 0 {
            // Source-language example — coloured to stand apart from the meaning
            // (mirrors the red example text in reference dictionaries like GoldenDict).
            Text(line)
                .font(.callout)
                .foregroundStyle(exampleColor)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // Translation — muted, like the meaning's supporting text.
            Text(line)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Copy text

    static func readableText(for entry: DictionaryEntry) -> String {
        if entry.isPlainTextOnly, let raw = entry.rawText {
            return "\(entry.headword)\n\n\(raw)"
        }

        var lines: [String] = [entry.headword]
        for lexical in entry.lexicalEntries {
            if let pos = lexical.partOfSpeech, !pos.isEmpty {
                lines.append("")
                lines.append(pos)
            }
            for sense in lexical.senses {
                if !sense.definition.isEmpty {
                    lines.append(sense.definition)
                }
                for example in sense.examples {
                    lines.append("   Example:")
                    for line in Self.exampleLines(for: example) {
                        lines.append("      \(line)")
                    }
                }
                if !sense.synonyms.isEmpty {
                    lines.append("   Synonyms: \(sense.synonyms.joined(separator: ", "))")
                }
            }
        }
        lines.append("")
        lines.append("— \(entry.sourceName)")
        return lines.joined(separator: "\n")
    }

    private static func exampleLines(for example: String) -> [String] {
        example
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - FlowLayout

/// Simple wrapping horizontal layout for chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
