// MarkdownHighlighter.swift
// PopGuy
//
// Simple, line-based Markdown highlighting for the Terminal Composer's plain-text
// editor. `MarkdownHighlighter` is pure (text → runs); `MarkdownStyler` turns the
// runs into text-storage attributes. Characters are never changed, only attributes.
//
// Rules (conservative, nothing spans lines except fenced code):
//   - ``` / ~~~ fences: fence lines are .codeFence, lines between them .codeBlock;
//     an unclosed fence runs to the end. No other rule applies inside fenced code.
//   - `#`–`######` + space: .heading(level) over the whole line.
//   - `-`, `*` or `1.` + space at line start (after indentation): .listMarker.
//   - `code` (any backtick run closed by a run of the same length): .inlineCode;
//     no bold/italic inside it.
//   - **bold**, *italic*, _italic_ (`_` only at word boundaries, so snake_case
//     words are not italic).
// Ranges are UTF-16 NSRanges into the original string (the line scan works on
// UTF-16 code units; every delimiter is ASCII, so no surrogate is ever split).

import AppKit

nonisolated struct HighlightRun: Equatable, Sendable {
    nonisolated enum Style: Equatable, Sendable {
        case heading(level: Int)
        case bold
        case italic
        case listMarker
        case inlineCode
        case codeFence
        case codeBlock
    }

    let range: NSRange
    let style: Style
}

nonisolated enum MarkdownHighlighter {
    /// Documents up to this UTF-16 length are highlighted whole on every edit.
    static let fullDocumentLimit = 200_000

    static func runs(in text: String) -> [HighlightRun] {
        let ns = text as NSString
        return runs(in: ns, range: NSRange(location: 0, length: ns.length))
    }

    /// Runs for the lines that `range` touches. The fence state starts closed at the
    /// first of those lines.
    static func runs(in text: NSString, range: NSRange) -> [HighlightRun] {
        var runs: [HighlightRun] = []
        var openFence: unichar?
        var position = text.lineRange(for: NSRange(location: range.location, length: 0)).location
        let end = NSMaxRange(range)

        while position < end {
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                              for: NSRange(location: position, length: 0))
            let lineStart = position
            position = lineEnd

            var chars = [unichar](repeating: 0, count: contentsEnd - lineStart)
            text.getCharacters(&chars, range: NSRange(location: lineStart, length: chars.count))
            let line = LineScanner(chars: chars, offset: lineStart)

            if let fence = openFence {
                if line.fenceCharacter() == fence {
                    openFence = nil
                    runs.append(line.run(0..<chars.count, .codeFence))
                } else if !chars.isEmpty {
                    runs.append(line.run(0..<chars.count, .codeBlock))
                }
                continue
            }
            if let fence = line.fenceCharacter() {
                openFence = fence
                runs.append(line.run(0..<chars.count, .codeFence))
                continue
            }
            runs += line.blockRuns()
            runs += line.inlineRuns()
        }
        return runs
    }
}

/// Scans one line (without its terminator) as UTF-16 code units.
private nonisolated struct LineScanner {
    let chars: [unichar]
    /// UTF-16 location of the line in the whole text.
    let offset: Int

    private static let backtick = unichar(UInt8(ascii: "`"))
    private static let tilde = unichar(UInt8(ascii: "~"))
    private static let star = unichar(UInt8(ascii: "*"))
    private static let underscore = unichar(UInt8(ascii: "_"))
    private static let hash = unichar(UInt8(ascii: "#"))
    private static let dash = unichar(UInt8(ascii: "-"))
    private static let dot = unichar(UInt8(ascii: "."))
    private static let space = unichar(UInt8(ascii: " "))
    private static let tab = unichar(UInt8(ascii: "\t"))

    func run(_ range: Range<Int>, _ style: HighlightRun.Style) -> HighlightRun {
        HighlightRun(range: NSRange(location: offset + range.lowerBound, length: range.count), style: style)
    }

    // MARK: Block rules

    /// "`" or "~" when the line opens or closes a fence (up to 3 spaces of indentation).
    func fenceCharacter() -> unichar? {
        let start = indentation()
        guard start <= 3, start + 3 <= chars.count else { return nil }
        let fence = chars[start]
        guard fence == Self.backtick || fence == Self.tilde,
              chars[start + 1] == fence, chars[start + 2] == fence else { return nil }
        // A backtick fence's info string has no backticks ("```x```" is inline code).
        if fence == Self.backtick,
           chars[(start + backtickRunLength(at: start))...].contains(Self.backtick) {
            return nil
        }
        return fence
    }

    /// A heading over the whole line, or a list marker.
    func blockRuns() -> [HighlightRun] {
        let start = indentation()
        var index = start
        while index < chars.count, chars[index] == Self.hash { index += 1 }
        let level = index - start
        if start <= 3, (1...6).contains(level), index == chars.count || chars[index] == Self.space {
            return [run(0..<chars.count, .heading(level: level))]
        }
        if let end = listMarkerEnd(from: start) {
            return [run(start..<end, .listMarker)]
        }
        return []
    }

    /// End of a `-`, `*` or `<digits>.` marker at `start` that is followed by a space.
    private func listMarkerEnd(from start: Int) -> Int? {
        guard start < chars.count else { return nil }
        var end = start
        if chars[start] == Self.dash || chars[start] == Self.star {
            end = start + 1
        } else {
            while end < chars.count, end - start < 9, isDigit(chars[end]) { end += 1 }
            guard end > start, end < chars.count, chars[end] == Self.dot else { return nil }
            end += 1
        }
        return end < chars.count && chars[end] == Self.space ? end : nil
    }

    // MARK: Inline rules

    /// Inline code first, then bold/italic in the text between code spans.
    func inlineRuns() -> [HighlightRun] {
        var runs: [HighlightRun] = []
        var segmentStart = inlineStart()
        var index = segmentStart
        while index < chars.count {
            guard chars[index] == Self.backtick else {
                index += 1
                continue
            }
            let length = backtickRunLength(at: index)
            guard let close = closingBacktickRun(length: length, from: index + length) else {
                index += length
                continue
            }
            runs += emphasisRuns(in: segmentStart..<index)
            runs.append(run(index..<(close + length), .inlineCode))
            index = close + length
            segmentStart = index
        }
        runs += emphasisRuns(in: segmentStart..<chars.count)
        return runs
    }

    /// Where inline rules start: after a list marker (so "* " is not italic).
    private func inlineStart() -> Int {
        let start = indentation()
        return listMarkerEnd(from: start) ?? 0
    }

    private func backtickRunLength(at index: Int) -> Int {
        var end = index
        while end < chars.count, chars[end] == Self.backtick { end += 1 }
        return end - index
    }

    /// Start of the next backtick run of exactly `length` after non-empty content.
    private func closingBacktickRun(length: Int, from start: Int) -> Int? {
        var index = start
        while index < chars.count {
            guard chars[index] == Self.backtick else {
                index += 1
                continue
            }
            let runLength = backtickRunLength(at: index)
            if runLength == length, index > start { return index }
            index += runLength
        }
        return nil
    }

    private func emphasisRuns(in segment: Range<Int>) -> [HighlightRun] {
        var runs: [HighlightRun] = []
        var index = segment.lowerBound
        while index < segment.upperBound {
            let char = chars[index]
            if char == Self.star, index + 1 < segment.upperBound, chars[index + 1] == Self.star {
                if let close = closingBold(from: index + 2, in: segment) {
                    runs.append(run(index..<(close + 2), .bold))
                    index = close + 2
                } else {
                    index += 2
                }
                continue
            }
            let opensUnderscore = char == Self.underscore && (index == 0 || !isWordCharacter(chars[index - 1]))
            if char == Self.star || opensUnderscore,
               let close = closingItalic(char, from: index + 1, in: segment) {
                runs.append(run(index..<(close + 1), .italic))
                index = close + 1
                continue
            }
            index += 1
        }
        return runs
    }

    /// "**" closing a bold span whose content starts at `start`; content is
    /// non-empty and does not start or end with whitespace.
    private func closingBold(from start: Int, in segment: Range<Int>) -> Int? {
        guard start < segment.upperBound, !isWhitespace(chars[start]) else { return nil }
        var index = start + 1
        while index + 1 < segment.upperBound {
            if chars[index] == Self.star, chars[index + 1] == Self.star, !isWhitespace(chars[index - 1]) {
                return index
            }
            index += 1
        }
        return nil
    }

    /// The single `delimiter` closing an italic span whose content starts at `start`.
    private func closingItalic(_ delimiter: unichar, from start: Int, in segment: Range<Int>) -> Int? {
        guard start < segment.upperBound, !isWhitespace(chars[start]), chars[start] != delimiter else { return nil }
        var index = start + 1
        while index < segment.upperBound {
            if chars[index] == delimiter, !isWhitespace(chars[index - 1]) {
                let next: unichar? = index + 1 < chars.count ? chars[index + 1] : nil
                if delimiter == Self.star, next != Self.star { return index }
                if delimiter == Self.underscore, next.map({ !isWordCharacter($0) }) ?? true { return index }
            }
            index += 1
        }
        return nil
    }

    // MARK: Characters

    private func indentation() -> Int {
        var index = 0
        while index < chars.count, chars[index] == Self.space || chars[index] == Self.tab { index += 1 }
        return index
    }

    private func isWhitespace(_ char: unichar) -> Bool {
        char == Self.space || char == Self.tab
    }

    private func isDigit(_ char: unichar) -> Bool {
        (48...57).contains(char)
    }

    /// Letters, digits and `_`; any non-ASCII unit counts as a word character.
    private func isWordCharacter(_ char: unichar) -> Bool {
        isDigit(char) || (65...90).contains(char) || (97...122).contains(char)
            || char == Self.underscore || char > 127
    }
}

/// Applies highlight runs to the composer's text storage, attributes only.
enum MarkdownStyler {
    static let codeBackground = NSColor.quaternaryLabelColor

    /// Re-highlights after an edit. Up to `MarkdownHighlighter.fullDocumentLimit`
    /// the whole document is styled; above it only the paragraphs the edit touched.
    /// Limitation of that large-document mode: a fence's open/closed state is not
    /// known outside those paragraphs, so lines inside a fenced block that is opened
    /// earlier in the document are styled as prose until the fence line is edited.
    static func highlight(_ storage: NSTextStorage, editedRange: NSRange, baseFont: NSFont) {
        let text = storage.string as NSString
        let whole = NSRange(location: 0, length: text.length)
        let target = text.length <= MarkdownHighlighter.fullDocumentLimit
            ? whole
            : text.paragraphRange(for: NSIntersectionRange(editedRange, whole))
        guard target.length > 0 else { return }

        // Reset only the keys this styler sets, so other attributes (e.g. the
        // input method's marked-text underline) survive.
        storage.addAttributes(baseAttributes(baseFont), range: target)
        storage.removeAttribute(.backgroundColor, range: target)
        for run in MarkdownHighlighter.runs(in: text, range: target) {
            apply(run, to: storage, baseFont: baseFont)
        }
    }

    static func baseAttributes(_ baseFont: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.textColor]
    }

    private static func apply(_ run: HighlightRun, to storage: NSTextStorage, baseFont: NSFont) {
        let code = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        switch run.style {
        case .inlineCode, .codeBlock:
            storage.addAttributes([.font: code, .backgroundColor: codeBackground], range: run.range)
        case .codeFence:
            storage.addAttributes([.font: code, .backgroundColor: codeBackground,
                                   .foregroundColor: NSColor.secondaryLabelColor], range: run.range)
        case .heading:
            // Simple Markdown: the whole heading line, `#`s included, is bold at the base size.
            storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: baseFont.pointSize), range: run.range)
        case .bold:
            addTrait(.boldFontMask, to: run.range, in: storage, baseFont: baseFont)
        case .italic:
            addTrait(.italicFontMask, to: run.range, in: storage, baseFont: baseFont)
        case .listMarker:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: run.range)
        }
    }

    /// Adds a trait to the font already there (bold inside a heading keeps its size).
    private static func addTrait(_ trait: NSFontTraitMask, to range: NSRange,
                                 in storage: NSTextStorage, baseFont: NSFont) {
        let current = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? baseFont
        storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: trait), range: range)
    }
}
