using System.Globalization;
using System.Text;

namespace PopGuy.Core.Emojis;

/// <summary>Search score constants (macOS <c>EmojiSearch.swift</c>; keep identical).</summary>
internal static class SearchScore
{
    public const double Base = 10.0;
    public const double ExactAlias = 100.0;
    public const double Prefix = 30.0;
    public const double WordBoundary = 15.0;
    public const double Consecutive = 5.0;
    public const double Gap = 1.0;
    public const double AliasWeight = 2.0;
    public const double DescriptionWeight = 1.0;
    public const double TagWeight = 0.0;

    /// <summary>
    /// Taken off symbol scores, so emoji lead unless the match is much better; an exact alias (<c>cmd</c> → ⌘) still
    /// beats an emoji prefix match.
    /// </summary>
    public const double NonEmojiPenalty = 25.0;

    /// <summary>Max frecency bonus = 10 * 0.25 = 2.5, below one consecutive-char bonus.</summary>
    public const double FrecencyCap = 10.0;
    public const double FrecencyFactor = 0.25;
}

/// <summary>Read-only search data built once from the decoded rows and shared by every picker (macOS <c>CatalogIndex</c>).</summary>
public sealed class CatalogIndex
{
    internal sealed record Field(int[] Scalars, bool IsAlias, bool IsTag, double Weight);

    /// <summary>
    /// The catalog with <see cref="Emoji.Keywords"/> dropped (they only live folded in the fields, to save memory). The
    /// single source of <see cref="Emoji"/> values, so results compare equal to everything built from it.
    /// </summary>
    public IReadOnlyList<Emoji> Emojis { get; }

    /// <summary>Folded, deduped searchable texts per emoji, same order as <see cref="Emojis"/>.</summary>
    internal IReadOnlyList<IReadOnlyList<Field>> Fields { get; }

    public CatalogIndex(IReadOnlyList<Emoji> catalog)
    {
        Fields = [.. catalog.Select(BuildFields)];
        Emojis = [.. catalog.Select(e => e with { Keywords = null })];
    }

    private static IReadOnlyList<Field> BuildFields(Emoji emoji)
    {
        // Highest weight first, so dedup keeps the best weight and its flags.
        var texts = emoji.Aliases.Select(a => (Text: a, IsAlias: true, IsTag: false, Weight: SearchScore.AliasWeight))
            .Append((emoji.Description, false, false, SearchScore.DescriptionWeight))
            .Concat(emoji.Tags.Concat(emoji.Keywords ?? []).Select(t => (t, false, true, SearchScore.TagWeight)));
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var fields = new List<Field>();
        foreach (var (text, isAlias, isTag, weight) in texts)
        {
            var folded = Fold(text);
            if (seen.Add(folded))
                fields.Add(new Field(Scalars(folded), isAlias, isTag, weight));
        }
        return fields;
    }

    internal static int[] Scalars(string text) => [.. text.EnumerateRunes().Select(r => r.Value)];

    /// <summary>
    /// Case- and accent-insensitive form used for both fields and queries ("Cười" → "cuoi"). Folding keeps the
    /// Vietnamese "đ" (a letter, not d + accent) and the French "œ" (a ligature), so they are mapped by hand: "cœur" is
    /// found by typing <c>coeur</c>. Lowercasing already turns "Đ" into "đ" and "Œ" into "œ".
    /// </summary>
    public static string Fold(string text)
    {
        // Most texts are plain ASCII, where folding is just lowercasing (and much faster).
        if (Ascii.IsValid(text))
            return text.ToLowerInvariant();
        var decomposed = text.Normalize(NormalizationForm.FormD);
        var stripped = new StringBuilder(decomposed.Length);
        foreach (var c in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark)
                stripped.Append(c);
        }
        return stripped.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant()
            .Replace("đ", "d", StringComparison.Ordinal)
            .Replace("œ", "oe", StringComparison.Ordinal);
    }
}

/// <summary>Fuzzy subsequence search over the catalog, ranked by text score then frecency (macOS <c>EmojiSearch</c>).</summary>
public sealed class EmojiSearch(CatalogIndex index)
{
    public CatalogIndex Index { get; } = index;

    public EmojiSearch(IReadOnlyList<Emoji> catalog) : this(new CatalogIndex(catalog))
    {
    }

    /// <summary>
    /// Matching emoji and symbols, best first. An empty query returns the catalog order. Ties keep catalog order (emoji,
    /// then symbols), so grouping the result by kind in order of first appearance gives sections ordered by best score,
    /// emoji first on ties. <paramref name="frecency"/> maps a glyph to its usage score.
    /// </summary>
    public IReadOnlyList<Emoji> Search(string query, Func<string, double> frecency)
    {
        var q = CatalogIndex.Scalars(CatalogIndex.Fold(query.Trim()));
        if (q.Length == 0)
            return Index.Emojis;

        var hits = new List<(int Index, double Score)>();
        for (var i = 0; i < Index.Fields.Count; i++)
        {
            double? best = null;
            foreach (var field in Index.Fields[i])
            {
                if (Score(q, field) is { } s)
                    best = Math.Max(best ?? s, s);
            }
            if (best is not { } score)
                continue;
            var emoji = Index.Emojis[i];
            if (emoji.Kind is not null)
                score -= SearchScore.NonEmojiPenalty;
            var bonus = Math.Min(frecency(emoji.Glyph), SearchScore.FrecencyCap) * SearchScore.FrecencyFactor;
            hits.Add((i, score + Math.Max(0, bonus)));
        }
        hits.Sort((a, b) => a.Score != b.Score ? b.Score.CompareTo(a.Score) : a.Index.CompareTo(b.Index));
        return [.. hits.Select(h => Index.Emojis[h.Index])];
    }

    /// <summary>
    /// Best subsequence score of <paramref name="q"/> in <paramref name="field"/>, trying every start position; null if
    /// no match. Minimum match rule: a start inside a word counts only when the whole query follows it contiguously, so
    /// scattered letters don't match (<c>yeet</c> must not find "lady_beetle"). Tags and keywords (many per emoji, often
    /// long phrases) need that at every start, word starts included: a scattered match there only adds unrelated
    /// results to the tail.
    /// </summary>
    private static double? Score(int[] q, CatalogIndex.Field field)
    {
        var f = field.Scalars;
        if (q.Length > f.Length)
            return null;
        if (field.IsAlias && f.AsSpan().SequenceEqual(q))
            return SearchScore.ExactAlias + SearchScore.Base + field.Weight;

        var isPrefix = f.AsSpan().StartsWith(q);
        double? best = null;
        for (var start = 0; start < f.Length; start++)
        {
            if (f[start] != q[0])
                continue;
            var atBoundary = start == 0 || IsSeparator(f[start - 1]);
            if (!atBoundary || field.IsTag)
            {
                // A contiguous match also scores best among in-word starts, so skipping the rest is the same as allowing
                // any match once the query is a substring.
                if (start + q.Length > f.Length || !f.AsSpan(start, q.Length).SequenceEqual(q))
                    continue;
            }
            if (MatchScore(q, f, start) is not { } s)
                break; // later starts cannot match either
            best = Math.Max(best ?? s, s);
        }
        if (best is not { } result)
            return null;
        return result + (isPrefix ? SearchScore.Prefix : 0) + field.Weight;
    }

    /// <summary>Greedy forward match of <paramref name="q"/> in <paramref name="f"/> starting with <c>q[0]</c> at <paramref name="start"/>.</summary>
    private static double? MatchScore(int[] q, int[] f, int start)
    {
        var score = SearchScore.Base;
        if (start == 0 || IsSeparator(f[start - 1]))
            score += SearchScore.WordBoundary;
        var last = start;
        var qi = 1;
        var fi = start + 1;
        while (qi < q.Length && fi < f.Length)
        {
            if (f[fi] == q[qi])
            {
                score += fi == last + 1 ? SearchScore.Consecutive : -SearchScore.Gap * (fi - last - 1);
                last = fi;
                qi++;
            }
            fi++;
        }
        return qi == q.Length ? score : null;
    }

    private static bool IsSeparator(int c) => c is '_' or '-' or ' ';
}
