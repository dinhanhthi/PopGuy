// ListContinuation.swift
// PopGuy
//
// Markdown list editing for the Terminal Composer (pure text → edit):
//   - Return on a list item (`-`, `*` or `1.` + space, after indentation) starts the
//     next item with the same indentation and marker; a number goes up by one.
//   - Return on an empty item clears its marker, ending the list.
//   - Backspace right after a marker deletes the whole marker.
// Markers are the ones MarkdownHighlighter colors. Ranges are UTF-16 offsets.

import Foundation

nonisolated enum ListContinuation {
    struct Edit: Equatable, Sendable {
        let range: NSRange
        let replacement: String
    }

    /// The edit for Return with the caret at `caret`; nil: a plain newline.
    static func returnEdit(in text: String, caret: Int) -> Edit? {
        guard let item = ListItem(text as NSString, caret: caret), caret >= item.markerEnd else { return nil }
        if item.isEmpty {
            return Edit(range: NSRange(location: item.lineStart, length: item.lineEnd - item.lineStart), replacement: "")
        }
        return Edit(range: NSRange(location: caret, length: 0), replacement: "\n" + item.indentation + item.nextMarker + " ")
    }

    /// The edit for Backspace with the caret at `caret`; nil: a plain backspace.
    static func backspaceEdit(in text: String, caret: Int) -> Edit? {
        guard let item = ListItem(text as NSString, caret: caret), caret == item.markerEnd else { return nil }
        return Edit(range: NSRange(location: item.markerStart, length: item.markerEnd - item.markerStart), replacement: "")
    }
}

/// The list item on the line with the caret.
private nonisolated struct ListItem {
    let lineStart: Int
    let lineEnd: Int
    let markerStart: Int
    /// After the marker's space.
    let markerEnd: Int
    let indentation: String
    let nextMarker: String
    /// Nothing but spaces after the marker.
    let isEmpty: Bool

    init?(_ text: NSString, caret: Int) {
        guard caret >= 0, caret <= text.length else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: lineRange)
        let line = text.substring(with: NSRange(location: lineRange.location, length: contentsEnd - lineRange.location)) as NSString

        var index = 0
        while index < line.length, line.character(at: index) == 0x20 || line.character(at: index) == 0x09 { index += 1 }
        let markerStart = index
        guard index < line.length else { return nil }
        let first = line.character(at: index)
        let marker: String
        if first == 0x2D || first == 0x2A { // "-", "*"
            index += 1
            marker = line.substring(with: NSRange(location: markerStart, length: 1))
        } else {
            while index < line.length, index - markerStart < 9, (0x30...0x39).contains(line.character(at: index)) { index += 1 }
            guard index > markerStart, index < line.length, line.character(at: index) == 0x2E else { return nil } // "."
            guard let number = Int(line.substring(with: NSRange(location: markerStart, length: index - markerStart))) else { return nil }
            index += 1
            marker = "\(number + 1)."
        }
        guard index < line.length, line.character(at: index) == 0x20 else { return nil }
        index += 1

        lineStart = lineRange.location
        lineEnd = contentsEnd
        self.markerStart = lineStart + markerStart
        markerEnd = lineStart + index
        indentation = line.substring(to: markerStart)
        nextMarker = marker
        isEmpty = line.substring(from: index).allSatisfy { $0 == " " || $0 == "\t" }
    }
}
