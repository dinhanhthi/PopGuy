// Simple, line-based Markdown highlighting for the Terminal Composer's plain-text editor: pure text -> runs; the
// composer window turns them into character formats. Same rules and run kinds as
// macos/PopGuy/Modules/TerminalComposer/MarkdownHighlighter.swift.
//
// Rules (conservative, nothing spans lines except fenced code):
//   - ``` / ~~~ fences: fence lines are CodeFence, lines between them CodeBlock; an unclosed fence runs to the end.
//     No other rule applies inside fenced code.
//   - "#" to "######" + space: Heading over the whole line, "#"s included.
//   - "-", "*" or "1." + space at line start (after indentation): ListMarker.
//   - `code` (any backtick run closed by a run of the same length): InlineCode; no bold/italic inside it.
//   - **bold**, *italic*, _italic_ ("_" only at word boundaries, so snake_case words are not italic).
// Ranges are (Start, Length) in UTF-16 code units, the C# string index; every delimiter is ASCII, so no surrogate
// pair is ever split. Lines end at "\n", "\r\n" or a bare "\r" (RichEditBox text uses "\r").

namespace PopGuy.Core.Composer;

public enum HighlightKind
{
    Heading,
    Bold,
    Italic,
    ListMarker,
    InlineCode,
    CodeFence,
    CodeBlock,
}

/// <summary>A styled range of the text. <c>HeadingLevel</c> is 1 to 6 for a heading, 0 otherwise.</summary>
public readonly record struct HighlightRun(int Start, int Length, HighlightKind Kind, int HeadingLevel = 0);

public static class MarkdownHighlighter
{
    /// <summary>Documents up to this length are highlighted whole on every edit.</summary>
    public const int FullDocumentLimit = 200_000;

    public static List<HighlightRun> Runs(string text) => Runs(text, 0, text.Length);

    /// <summary>Runs for the lines that the range touches. The fence state starts closed at the first of those lines.</summary>
    public static List<HighlightRun> Runs(string text, int start, int length)
    {
        var runs = new List<HighlightRun>();
        char? openFence = null;
        var position = start;
        while (position > 0 && !IsLineBreak(text[position - 1]))
            position--;
        var end = start + length;

        while (position < end)
        {
            var contentsEnd = position;
            while (contentsEnd < text.Length && !IsLineBreak(text[contentsEnd]))
                contentsEnd++;
            var line = new LineScanner(text.AsSpan(position, contentsEnd - position), position, runs);
            position = contentsEnd;
            if (position < text.Length)
                position += text[position] == '\r' && position + 1 < text.Length && text[position + 1] == '\n' ? 2 : 1;

            if (openFence is { } fence)
            {
                if (line.FenceCharacter() == fence)
                {
                    openFence = null;
                    line.Add(0, line.Length, HighlightKind.CodeFence);
                }
                else if (line.Length > 0)
                {
                    line.Add(0, line.Length, HighlightKind.CodeBlock);
                }
                continue;
            }
            if (line.FenceCharacter() is { } opening)
            {
                openFence = opening;
                line.Add(0, line.Length, HighlightKind.CodeFence);
                continue;
            }
            line.AddBlockRuns();
            line.AddInlineRuns();
        }
        return runs;
    }

    private static bool IsLineBreak(char c) => c is '\n' or '\r';

    /// <summary>Scans one line (without its terminator) and appends its runs.</summary>
    private readonly ref struct LineScanner(ReadOnlySpan<char> chars, int offset, List<HighlightRun> runs)
    {
        private readonly ReadOnlySpan<char> _chars = chars;

        public int Length => _chars.Length;

        /// <summary>Adds a run for the line-relative range [from, to).</summary>
        public void Add(int from, int to, HighlightKind kind, int headingLevel = 0) =>
            runs.Add(new HighlightRun(offset + from, to - from, kind, headingLevel));

        // Block rules

        /// <summary>'`' or '~' when the line opens or closes a fence (up to 3 spaces of indentation).</summary>
        public char? FenceCharacter()
        {
            var start = Indentation();
            if (start > 3 || start + 3 > _chars.Length)
                return null;
            var fence = _chars[start];
            if (fence is not ('`' or '~') || _chars[start + 1] != fence || _chars[start + 2] != fence)
                return null;
            // A backtick fence's info string has no backticks ("```x```" is inline code).
            if (fence == '`' && _chars[(start + BacktickRunLength(start))..].Contains('`'))
                return null;
            return fence;
        }

        /// <summary>A heading over the whole line, or a list marker.</summary>
        public void AddBlockRuns()
        {
            var start = Indentation();
            var index = start;
            while (index < _chars.Length && _chars[index] == '#')
                index++;
            var level = index - start;
            if (start <= 3 && level is >= 1 and <= 6 && (index == _chars.Length || _chars[index] == ' '))
            {
                Add(0, _chars.Length, HighlightKind.Heading, level);
                return;
            }
            if (ListMarkerEnd(start) is { } end)
                Add(start, end, HighlightKind.ListMarker);
        }

        /// <summary>End of a "-", "*" or "&lt;digits&gt;." marker at <paramref name="start"/> that is followed by a space.</summary>
        private int? ListMarkerEnd(int start)
        {
            if (start >= _chars.Length)
                return null;
            var end = start;
            if (_chars[start] is '-' or '*')
            {
                end = start + 1;
            }
            else
            {
                while (end < _chars.Length && end - start < 9 && char.IsAsciiDigit(_chars[end]))
                    end++;
                if (end == start || end >= _chars.Length || _chars[end] != '.')
                    return null;
                end++;
            }
            return end < _chars.Length && _chars[end] == ' ' ? end : null;
        }

        // Inline rules

        /// <summary>Inline code first, then bold/italic in the text between code spans.</summary>
        public void AddInlineRuns()
        {
            // Inline rules start after a list marker (so "* " is not italic).
            var segmentStart = ListMarkerEnd(Indentation()) ?? 0;
            var index = segmentStart;
            while (index < _chars.Length)
            {
                if (_chars[index] != '`')
                {
                    index++;
                    continue;
                }
                var length = BacktickRunLength(index);
                if (ClosingBacktickRun(length, index + length) is not { } close)
                {
                    index += length;
                    continue;
                }
                AddEmphasisRuns(segmentStart, index);
                Add(index, close + length, HighlightKind.InlineCode);
                index = close + length;
                segmentStart = index;
            }
            AddEmphasisRuns(segmentStart, _chars.Length);
        }

        private int BacktickRunLength(int index)
        {
            var end = index;
            while (end < _chars.Length && _chars[end] == '`')
                end++;
            return end - index;
        }

        /// <summary>Start of the next backtick run of exactly <paramref name="length"/> after non-empty content.</summary>
        private int? ClosingBacktickRun(int length, int start)
        {
            var index = start;
            while (index < _chars.Length)
            {
                if (_chars[index] != '`')
                {
                    index++;
                    continue;
                }
                var runLength = BacktickRunLength(index);
                if (runLength == length && index > start)
                    return index;
                index += runLength;
            }
            return null;
        }

        private void AddEmphasisRuns(int from, int to)
        {
            var index = from;
            while (index < to)
            {
                var c = _chars[index];
                if (c == '*' && index + 1 < to && _chars[index + 1] == '*')
                {
                    if (ClosingBold(index + 2, to) is { } boldClose)
                    {
                        Add(index, boldClose + 2, HighlightKind.Bold);
                        index = boldClose + 2;
                    }
                    else
                    {
                        index += 2;
                    }
                    continue;
                }
                var opensUnderscore = c == '_' && (index == 0 || !IsWordCharacter(_chars[index - 1]));
                if ((c == '*' || opensUnderscore) && ClosingItalic(c, index + 1, to) is { } italicClose)
                {
                    Add(index, italicClose + 1, HighlightKind.Italic);
                    index = italicClose + 1;
                    continue;
                }
                index++;
            }
        }

        /// <summary>"**" closing a bold span whose content starts at <paramref name="start"/>; content is non-empty
        /// and does not start or end with whitespace.</summary>
        private int? ClosingBold(int start, int to)
        {
            if (start >= to || IsWhitespace(_chars[start]))
                return null;
            for (var index = start + 1; index + 1 < to; index++)
            {
                if (_chars[index] == '*' && _chars[index + 1] == '*' && !IsWhitespace(_chars[index - 1]))
                    return index;
            }
            return null;
        }

        /// <summary>The single <paramref name="delimiter"/> closing an italic span whose content starts at
        /// <paramref name="start"/>.</summary>
        private int? ClosingItalic(char delimiter, int start, int to)
        {
            if (start >= to || IsWhitespace(_chars[start]) || _chars[start] == delimiter)
                return null;
            for (var index = start + 1; index < to; index++)
            {
                if (_chars[index] != delimiter || IsWhitespace(_chars[index - 1]))
                    continue;
                char? next = index + 1 < _chars.Length ? _chars[index + 1] : null;
                if (delimiter == '*' && next != '*')
                    return index;
                if (delimiter == '_' && (next is not { } n || !IsWordCharacter(n)))
                    return index;
            }
            return null;
        }

        // Characters

        private int Indentation()
        {
            var index = 0;
            while (index < _chars.Length && IsWhitespace(_chars[index]))
                index++;
            return index;
        }

        private static bool IsWhitespace(char c) => c is ' ' or '\t';

        /// <summary>Letters, digits and "_"; any non-ASCII unit counts as a word character.</summary>
        private static bool IsWordCharacter(char c) => char.IsAsciiLetterOrDigit(c) || c == '_' || c > 127;
    }
}
