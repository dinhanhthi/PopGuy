// Markdown list editing for the Terminal Composer (pure text -> edit), as in
// macos/PopGuy/Modules/TerminalComposer/ListContinuation.swift:
//   - Enter on a list item ("-", "*" or "1." + space, after indentation) starts the next item with the same
//     indentation and marker; a number goes up by one.
//   - Enter on an empty item clears its marker, ending the list.
//   - Backspace right after a marker deletes the whole marker.
// Markers are the ones MarkdownHighlighter colors. Lines end at "\n", "\r" or "\v" (RichEdit's paragraph mark and soft
// break); an inserted line break is "\n". Positions are C# string indices.

using System.Globalization;

namespace PopGuy.Core.Composer;

/// <summary>Replace <c>Length</c> characters at <c>Start</c> with <c>Replacement</c>.</summary>
public readonly record struct ListEdit(int Start, int Length, string Replacement);

public static class ListContinuation
{
    /// <summary>The edit for Enter with the caret at <paramref name="caret"/>; null: a plain line break.</summary>
    public static ListEdit? ReturnEdit(string text, int caret)
    {
        if (Item(text, caret) is not { } item || caret < item.MarkerEnd) return null;
        if (item.IsEmpty) return new ListEdit(item.LineStart, item.LineEnd - item.LineStart, "");
        return new ListEdit(caret, 0, "\n" + item.Indentation + item.NextMarker + " ");
    }

    /// <summary>The edit for Backspace with the caret at <paramref name="caret"/>; null: a plain backspace.</summary>
    public static ListEdit? BackspaceEdit(string text, int caret)
    {
        if (Item(text, caret) is not { } item || caret != item.MarkerEnd) return null;
        return new ListEdit(item.MarkerStart, item.MarkerEnd - item.MarkerStart, "");
    }

    /// <summary>The list item on the line with the caret. <c>MarkerEnd</c> is after the marker's space.</summary>
    private readonly record struct ListItem(
        int LineStart, int LineEnd, int MarkerStart, int MarkerEnd, string Indentation, string NextMarker, bool IsEmpty);

    private static bool IsLineBreak(char c) => c is '\n' or '\r' or '\v';

    private static ListItem? Item(string text, int caret)
    {
        if (caret < 0 || caret > text.Length) return null;
        var lineStart = caret;
        while (lineStart > 0 && !IsLineBreak(text[lineStart - 1])) lineStart--;
        var lineEnd = caret;
        while (lineEnd < text.Length && !IsLineBreak(text[lineEnd])) lineEnd++;

        var index = lineStart;
        while (index < lineEnd && text[index] is ' ' or '\t') index++;
        var markerStart = index;
        if (index >= lineEnd) return null;
        string marker;
        if (text[index] is '-' or '*')
        {
            marker = text[index..(index + 1)];
            index++;
        }
        else
        {
            while (index < lineEnd && index - markerStart < 9 && char.IsAsciiDigit(text[index])) index++;
            if (index == markerStart || index >= lineEnd || text[index] != '.') return null;
            var number = int.Parse(text.AsSpan(markerStart, index - markerStart), CultureInfo.InvariantCulture);
            marker = (number + 1).ToString(CultureInfo.InvariantCulture) + ".";
            index++;
        }
        if (index >= lineEnd || text[index] != ' ') return null;
        index++;

        var isEmpty = text.AsSpan(index, lineEnd - index).Trim(" \t").IsEmpty;
        return new ListItem(lineStart, lineEnd, markerStart, index, text[lineStart..markerStart], marker, isEmpty);
    }
}
