using System.Text;

namespace PopGuy.Core.Markdown;

public enum MarkdownBlockKind { Paragraph, Bullet, Numbered }

[Flags]
public enum MarkdownStyle { None = 0, Bold = 1, Italic = 2, Strikethrough = 4, Code = 8 }

/// <summary>
/// A line of a result: <see cref="Marker"/> is a numbered item's own number with its <c>.</c>, empty otherwise. A blank
/// line is a paragraph with no inlines (macOS keeps it as vertical space).
/// </summary>
public sealed record MarkdownBlock(MarkdownBlockKind Kind, string Marker, IReadOnlyList<MarkdownInline> Inlines);

/// <summary>A run of text in one style; <see cref="Link"/> is set only for an allowed link.</summary>
public sealed record MarkdownInline(string Text, MarkdownStyle Style, Uri? Link = null);

/// <summary>
/// A result's Markdown parsed into lines of styled text, for a view that builds its text from objects only (macOS
/// <c>MarkdownResultView.swift</c>): <c>-</c>/<c>*</c>/<c>+</c> bullets and <c>1.</c> items (one or two digits, so a
/// sentence starting with a year stays a paragraph), paragraphs, <c>**bold**</c>, <c>*italic*</c>,
/// <c>~~strikethrough~~</c>, <c>`code`</c> and links. Model output is untrusted: there is no HTML (tags stay literal
/// text), images show their alt text and are never fetched, and a link is kept only when it is an absolute http(s) URL
/// without user info or a mailto address; every other link (javascript:, file:, data:, relative…) shows its text only.
/// Linear in the input. Started from EchoDiar's parser (its citation links and headings dropped: macOS shows neither).
/// </summary>
public static class MarkdownParser
{
    /// <summary>Nesting deeper than this is shown as plain text.</summary>
    private const int MaxDepth = 8;

    /// <summary>The lines of <paramref name="markdown"/>, blank ones included.</summary>
    public static IReadOnlyList<MarkdownBlock> Parse(string markdown)
    {
        var blocks = new List<MarkdownBlock>();
        foreach (var raw in markdown.ReplaceLineEndings("\n").Split('\n'))
        {
            // Up to any indentation before a marker (macOS: one flat level).
            var line = raw.TrimStart(' ', '\t');
            if (line.Length > 2 && line[0] is '-' or '*' or '+' && line[1] == ' ')
                blocks.Add(Block(MarkdownBlockKind.Bullet, "", line[2..]));
            else if (NumberMarker(line) is { } marker)
                blocks.Add(Block(MarkdownBlockKind.Numbered, marker, line[(marker.Length + 1)..]));
            else
                blocks.Add(Block(MarkdownBlockKind.Paragraph, "", raw));
        }
        return blocks;

        static MarkdownBlock Block(MarkdownBlockKind kind, string marker, string text) =>
            new(kind, marker, new InlineParser(text).Parse());
    }

    /// <summary>
    /// <paramref name="target"/> as a link: an absolute http or https URL with a host and no user info, or a mailto
    /// address (its user part is the address, not user info); null for anything else.
    /// </summary>
    public static Uri? LinkUri(string target)
    {
        if (target.StartsWith("mailto:", StringComparison.OrdinalIgnoreCase))
        {
            return target.Length > "mailto:".Length && Uri.TryCreate(target, UriKind.Absolute, out var mail)
                   && mail.Scheme == Uri.UriSchemeMailto
                ? mail
                : null;
        }
        if (!target.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
            && !target.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            return null;
        if (!Uri.TryCreate(target, UriKind.Absolute, out var url)) return null;
        if (url.Scheme != Uri.UriSchemeHttp && url.Scheme != Uri.UriSchemeHttps) return null;
        return url.Host.Length > 0 && url.UserInfo.Length == 0 ? url : null;
    }

    /// <summary>"12." when <paramref name="line"/> starts with a one- or two-digit list number, a period, a space and text.</summary>
    private static string? NumberMarker(string line)
    {
        var digits = line.TakeWhile(char.IsAsciiDigit).Count();
        if (digits is < 1 or > 2 || line.Length < digits + 3 || line[digits] != '.' || line[digits + 1] != ' ')
            return null;
        return line[..(digits + 1)];
    }

    /// <summary>
    /// One line's inline Markdown. Each search for a closing delimiter only moves forward, and a failed search is
    /// remembered (no closer after that point), so a line is read a bounded number of times per nesting level.
    /// </summary>
    private sealed class InlineParser(string text)
    {
        private readonly List<(StringBuilder Text, MarkdownStyle Style, Uri? Link)> _runs = [];

        /// <summary>The last search for <c>]</c>: from, up to (excluded), and where it was found (-1: not found).</summary>
        private int _bracketFrom = -1, _bracketEnd = -1, _bracketAt = -1;

        /// <summary>The last link target tried: its start, its limit, and its <c>)</c> (-1: not a target).</summary>
        private int _targetFrom = -1, _targetLimit = -1, _targetEnd = -1;

        public List<MarkdownInline> Parse()
        {
            Run(0, text.Length, MarkdownStyle.None, null, allowLinks: true, depth: 0);
            return _runs.Select(r => new MarkdownInline(r.Text.ToString(), r.Style, r.Link)).ToList();
        }

        /// <summary>Parses text[start..end) in <paramref name="style"/>, inside <paramref name="link"/> when set.</summary>
        private void Run(int start, int end, MarkdownStyle style, Uri? link, bool allowLinks, int depth)
        {
            if (depth >= MaxDepth)
            {
                Add(text.AsSpan(start, end - start), style, link);
                return;
            }
            // Per emphasis delimiter (*, **, _, __, ~~; and per backtick count): no closer at or after this index.
            Span<int> noCloser = [int.MaxValue, int.MaxValue, int.MaxValue, int.MaxValue, int.MaxValue];
            Dictionary<int, int>? noCode = null;
            var i = start;
            while (i < end)
            {
                var c = text[i];
                if (c == '\\' && i + 1 < end && char.IsAscii(text[i + 1])
                    && (char.IsPunctuation(text[i + 1]) || char.IsSymbol(text[i + 1])))
                {
                    Add(text.AsSpan(i + 1, 1), style, link);
                    i += 2;
                    continue;
                }
                if (c == '`')
                {
                    var ticks = Count(i, end, '`');
                    var close = noCode is not null && noCode.TryGetValue(ticks, out var none) && i >= none
                        ? -1
                        : text.IndexOf(new string('`', ticks), i + ticks, end - i - ticks, StringComparison.Ordinal);
                    if (close < 0)
                    {
                        noCode ??= [];
                        noCode.TryAdd(ticks, i);
                        Add(text.AsSpan(i, ticks), style, link);
                        i += ticks;
                        continue;
                    }
                    Add(text.AsSpan(i + ticks, close - i - ticks), style | MarkdownStyle.Code, link);
                    i = close + ticks;
                    continue;
                }
                if (c is '*' or '_' || (c == '~' && i + 1 < end && text[i + 1] == '~'))
                {
                    var twice = i + 1 < end && text[i + 1] == c;
                    var size = twice ? 2 : 1;
                    var kind = c switch { '*' => 0, '_' => 2, _ => 3 } + (twice ? 1 : 0);
                    var close = -1;
                    if (i < noCloser[kind] && Opens(i, size, end, c))
                    {
                        close = Closer(i + size, end, c, size);
                        if (close < 0) noCloser[kind] = i;
                    }
                    if (close < 0)
                    {
                        Add(text.AsSpan(i, size), style, link);
                        i += size;
                        continue;
                    }
                    var added = c == '~' ? MarkdownStyle.Strikethrough : twice ? MarkdownStyle.Bold : MarkdownStyle.Italic;
                    Run(i + size, close, style | added, link, allowLinks, depth + 1);
                    i = close + size;
                    continue;
                }
                if (c == '[' || (c == '!' && i + 1 < end && text[i + 1] == '['))
                {
                    var image = c == '!';
                    var open = image ? i + 1 : i;
                    if (Bracket(open + 1, end) is var close and >= 0
                        && close + 1 < end && text[close + 1] == '(' && Target(close + 2, end) is var targetEnd and >= 0)
                    {
                        if (image)
                        {
                            // The alt text only, as plain text; the image is never fetched.
                            Add(text.AsSpan(open + 1, close - open - 1), style, link);
                        }
                        else
                        {
                            var target = allowLinks ? LinkUri(text[(close + 2)..targetEnd]) : null;
                            Run(open + 1, close, style, target ?? link, allowLinks: false, depth + 1);
                        }
                        i = targetEnd + 1;
                        continue;
                    }
                    Add(text.AsSpan(i, 1), style, link);
                    i++;
                    continue;
                }
                var next = i + 1;
                while (next < end && text[next] is not ('\\' or '`' or '*' or '_' or '~' or '[' or '!')) next++;
                Add(text.AsSpan(i, next - i), style, link);
                i = next;
            }
        }

        /// <summary>
        /// Whether a <paramref name="size"/>-long run of <paramref name="mark"/> at <paramref name="at"/> can open
        /// emphasis: followed by a non-space, and for <c>_</c> not inside a word.
        /// </summary>
        private bool Opens(int at, int size, int end, char mark)
        {
            if (at + size >= end || char.IsWhiteSpace(text[at + size])) return false;
            return mark != '_' || at == 0 || !char.IsLetterOrDigit(text[at - 1]);
        }

        /// <summary>
        /// The next run of <paramref name="mark"/> in (from, end) that closes emphasis of <paramref name="size"/>:
        /// preceded by a non-space, for <c>_</c> not followed by a letter or digit; a single mark skips longer runs, and
        /// a longer run closes with its last <paramref name="size"/> marks (<c>***a***</c>). -1 when there is none.
        /// </summary>
        private int Closer(int from, int end, char mark, int size)
        {
            var at = from;
            while (at < end)
            {
                var found = text.IndexOf(mark, at, end - at);
                if (found < 0) return -1;
                var run = Count(found, end, mark);
                var last = found + run - size;
                if (found > from && !char.IsWhiteSpace(text[found - 1]) && (size == 2 ? run >= 2 : run == 1)
                    && (mark != '_' || last + size >= end || !char.IsLetterOrDigit(text[last + size])))
                    return last;
                at = found + run;
            }
            return -1;
        }

        /// <summary>The first <c>]</c> in [from, end), or -1; reuses the last search when it covers this one.</summary>
        private int Bracket(int from, int end)
        {
            if (_bracketFrom >= 0 && _bracketFrom <= from)
            {
                if (_bracketAt >= from) return _bracketAt < end ? _bracketAt : -1;
                if (_bracketAt < 0 && end <= _bracketEnd) return -1;
            }
            _bracketFrom = from;
            _bracketEnd = end;
            _bracketAt = text.IndexOf(']', from, end - from);
            return _bracketAt;
        }

        /// <summary>
        /// The <c>)</c> ending a link target that starts at <paramref name="from"/>, or -1: a target has no spaces,
        /// brackets or quotes, so scans from different starts never overlap.
        /// </summary>
        private int Target(int from, int end)
        {
            if (_targetFrom == from && _targetLimit == end) return _targetEnd;
            _targetFrom = from;
            _targetLimit = end;
            _targetEnd = -1;
            for (var at = from; at < end; at++)
            {
                var c = text[at];
                if (c == ')')
                {
                    _targetEnd = at;
                    break;
                }
                if (char.IsWhiteSpace(c) || char.IsControl(c) || c is '(' or '[' or ']' or '<' or '>' or '"' or '`') break;
            }
            return _targetEnd;
        }

        private int Count(int from, int end, char mark)
        {
            var at = from;
            while (at < end && text[at] == mark) at++;
            return at - from;
        }

        /// <summary>Appends text, to the previous inline when it has the same style and link.</summary>
        private void Add(ReadOnlySpan<char> value, MarkdownStyle style, Uri? link)
        {
            if (value.IsEmpty) return;
            if (_runs.Count > 0 && _runs[^1].Style == style && ReferenceEquals(_runs[^1].Link, link))
                _runs[^1].Text.Append(value);
            else
                _runs.Add((new StringBuilder().Append(value), style, link));
        }
    }
}
