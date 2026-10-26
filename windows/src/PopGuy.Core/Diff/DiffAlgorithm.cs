using System.Text;

namespace PopGuy.Core.Diff;

// The word-level diff of Improve and Proofread results (macOS DiffAlgorithm.swift; same tokens, same segments).
// UNTRUSTED DATA: both strings are plain text; the diff never interprets them.

/// <summary>The role of one segment of a diff.</summary>
public enum DiffKind
{
    /// <summary>Text present in both the original and the improved string.</summary>
    Equal,

    /// <summary>Text present only in the improved string (an addition).</summary>
    Inserted,

    /// <summary>Text present only in the original string (a deletion).</summary>
    Deleted,
}

/// <summary>One run of text with one diff role.</summary>
public sealed record DiffSegment(DiffKind Kind, string Text);

/// <summary>
/// A standard O(m·n) LCS diff over word and whitespace tokens, adjacent segments of one kind merged. The output keeps
/// the round-trip invariant: the equal and deleted segments rebuild the original, the equal and inserted ones the
/// improved string.
/// </summary>
public static class DiffAlgorithm
{
    /// <summary>The diff between <paramref name="original"/> and <paramref name="improved"/>.</summary>
    public static IReadOnlyList<DiffSegment> Diff(string original, string improved)
    {
        var oldTokens = Tokenize(original);
        var newTokens = Tokenize(improved);

        // Fast paths.
        if (oldTokens.Count == 0 && newTokens.Count == 0) return [];
        if (oldTokens.Count == 0) return Merge(newTokens.Select(t => new DiffSegment(DiffKind.Inserted, t)));
        if (newTokens.Count == 0) return Merge(oldTokens.Select(t => new DiffSegment(DiffKind.Deleted, t)));
        if (oldTokens.SequenceEqual(newTokens)) return Merge(oldTokens.Select(t => new DiffSegment(DiffKind.Equal, t)));

        return Merge(LcsDiff(oldTokens, newTokens));
    }

    /// <summary>
    /// Alternating whitespace and word runs, so the LCS matches words by identity alone and the tokens join back to
    /// <paramref name="s"/>. "  hello  world " → ["  ", "hello", "  ", "world", " "]. Runs split between user-perceived
    /// characters (grapheme clusters, as Swift's characters), a cluster being whitespace when its first char is.
    /// </summary>
    public static IReadOnlyList<string> Tokenize(string s)
    {
        if (s.Length == 0) return [];
        var tokens = new List<string>();
        var current = new StringBuilder();
        var buildingWhitespace = char.IsWhiteSpace(s[0]);
        var elements = System.Globalization.StringInfo.GetTextElementEnumerator(s);
        while (elements.MoveNext())
        {
            var element = elements.GetTextElement();
            var isSpace = char.IsWhiteSpace(element[0]);
            if (isSpace != buildingWhitespace)
            {
                // The kind changed: emit the run so far and start a new one.
                if (current.Length > 0) tokens.Add(current.ToString());
                current.Clear();
                buildingWhitespace = isSpace;
            }
            current.Append(element);
        }
        if (current.Length > 0) tokens.Add(current.ToString());
        return tokens;
    }

    /// <summary>The classic LCS table and walk-back; the segments are not merged yet.</summary>
    private static List<DiffSegment> LcsDiff(IReadOnlyList<string> old, IReadOnlyList<string> @new)
    {
        var m = old.Count;
        var n = @new.Count;

        // dp[i * (n + 1) + j] = the LCS length of old[0..<i] and new[0..<j] (a flat array for cache locality).
        var dp = new int[(m + 1) * (n + 1)];
        int Idx(int i, int j) => i * (n + 1) + j;

        for (var i = 1; i <= m; i++)
        {
            for (var j = 1; j <= n; j++)
            {
                dp[Idx(i, j)] = old[i - 1] == @new[j - 1]
                    ? dp[Idx(i - 1, j - 1)] + 1
                    : Math.Max(dp[Idx(i - 1, j)], dp[Idx(i, j - 1)]);
            }
        }

        // Walk back from the end; on a tie an insertion goes first (so it lands after the deletion once reversed).
        var segments = new List<DiffSegment>();
        var x = m;
        var y = n;
        while (x > 0 || y > 0)
        {
            if (x > 0 && y > 0 && old[x - 1] == @new[y - 1])
            {
                segments.Add(new DiffSegment(DiffKind.Equal, old[x - 1]));
                x--;
                y--;
            }
            else if (y > 0 && (x == 0 || dp[Idx(x, y - 1)] >= dp[Idx(x - 1, y)]))
            {
                segments.Add(new DiffSegment(DiffKind.Inserted, @new[y - 1]));
                y--;
            }
            else
            {
                segments.Add(new DiffSegment(DiffKind.Deleted, old[x - 1]));
                x--;
            }
        }

        segments.Reverse();
        return segments;
    }

    /// <summary>Adjacent segments of one kind become one.</summary>
    private static List<DiffSegment> Merge(IEnumerable<DiffSegment> segments)
    {
        var result = new List<DiffSegment>();
        DiffKind? kind = null;
        var text = new StringBuilder();
        foreach (var segment in segments)
        {
            if (segment.Kind != kind)
            {
                if (kind is { } done) result.Add(new DiffSegment(done, text.ToString()));
                kind = segment.Kind;
                text.Clear();
            }
            text.Append(segment.Text);
        }
        if (kind is { } last) result.Add(new DiffSegment(last, text.ToString()));
        return result;
    }
}
