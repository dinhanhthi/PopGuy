// DiffHunks.swift
// PopGuy — DiffRenderer
//
// Pure helpers that group diff segments into hunks and rebuild text from a
// per-hunk accept/reject choice.
//
// Public surface:
//   DiffHunks.hunkRanges(_:)            -> [Range<Int>]
//   DiffHunks.hunkIndices(_:)           -> [Int?]
//   DiffHunks.merged(segments:rejected:) -> String
//
// A hunk is a maximal run of consecutive non-.equal segments.
//
// Isolation:
//   `nonisolated` opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor so the
//   helpers can be called from any actor.

import Foundation

nonisolated enum DiffHunks {

    /// Segment index ranges of each hunk (maximal run of non-.equal segments).
    static func hunkRanges(_ segments: [DiffSegment]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        for (index, segment) in segments.enumerated() {
            if segment.kind == .equal {
                if let s = start { ranges.append(s..<index); start = nil }
            } else if start == nil {
                start = index
            }
        }
        if let s = start { ranges.append(s..<segments.count) }
        return ranges
    }

    /// Per segment: the index of the hunk it belongs to, or nil for .equal.
    static func hunkIndices(_ segments: [DiffSegment]) -> [Int?] {
        var indices = [Int?](repeating: nil, count: segments.count)
        for (hunk, range) in hunkRanges(segments).enumerated() {
            for index in range { indices[index] = hunk }
        }
        return indices
    }

    /// Rebuilds text: accepted hunks keep their inserted text, rejected hunks
    /// keep their deleted text. Out-of-range indices in `rejected` are ignored.
    static func merged(segments: [DiffSegment], rejected: Set<Int>) -> String {
        zip(segments, hunkIndices(segments)).map { segment, hunk in
            let isRejected = hunk.map(rejected.contains) ?? false
            switch segment.kind {
            case .equal:    return segment.text
            case .inserted: return isRejected ? "" : segment.text
            case .deleted:  return isRejected ? segment.text : ""
            }
        }.joined()
    }
}
