using System.Text;

namespace PopGuy.Core.Diff;

/// <summary>
/// Groups diff segments into hunks and rebuilds the text from a per-hunk accept or reject (macOS DiffHunks.swift). A
/// hunk is a maximal run of consecutive segments that are not <see cref="DiffKind.Equal"/>.
/// </summary>
public static class DiffHunks
{
    /// <summary>The segment index range of each hunk, in order (<c>End</c> exclusive).</summary>
    public static IReadOnlyList<(int Start, int End)> HunkRanges(IReadOnlyList<DiffSegment> segments)
    {
        var ranges = new List<(int Start, int End)>();
        int? start = null;
        for (var index = 0; index < segments.Count; index++)
        {
            if (segments[index].Kind == DiffKind.Equal)
            {
                if (start is { } s)
                {
                    ranges.Add((s, index));
                    start = null;
                }
            }
            else
            {
                start ??= index;
            }
        }
        if (start is { } last) ranges.Add((last, segments.Count));
        return ranges;
    }

    /// <summary>Per segment: the index of its hunk, or null for an equal segment.</summary>
    public static int?[] HunkIndices(IReadOnlyList<DiffSegment> segments)
    {
        var indices = new int?[segments.Count];
        var ranges = HunkRanges(segments);
        for (var hunk = 0; hunk < ranges.Count; hunk++)
        {
            for (var index = ranges[hunk].Start; index < ranges[hunk].End; index++) indices[index] = hunk;
        }
        return indices;
    }

    /// <summary>
    /// The text with accepted hunks keeping their inserted text and rejected hunks their deleted text. Indices in
    /// <paramref name="rejected"/> that name no hunk are ignored.
    /// </summary>
    public static string Merged(IReadOnlyList<DiffSegment> segments, IReadOnlySet<int> rejected)
    {
        var hunks = HunkIndices(segments);
        var text = new StringBuilder();
        for (var index = 0; index < segments.Count; index++)
        {
            var segment = segments[index];
            var isRejected = hunks[index] is { } hunk && rejected.Contains(hunk);
            var keep = segment.Kind switch
            {
                DiffKind.Inserted => !isRejected,
                DiffKind.Deleted => isRejected,
                _ => true,
            };
            if (keep) text.Append(segment.Text);
        }
        return text.ToString();
    }
}
