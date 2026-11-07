using PopGuy.Core.Composer;

namespace PopGuy.Tests.Core;

// The Terminal Composer's Markdown list editing (pure text -> edit), as in
// macos/PopGuyTests/Unit/ListContinuationTests.swift: Enter continues "-", "*" and numbered items and clears an empty
// one, Backspace right after a marker deletes it. RichEdit's "\r" and "\v" line ends count as lines too.
public sealed class ListContinuationTests
{
    private static string? Apply(ListEdit? edit, string text) =>
        edit is { } e ? text[..e.Start] + e.Replacement + text[(e.Start + e.Length)..] : null;

    private static string? AfterReturn(string text, int? caret = null) =>
        Apply(ListContinuation.ReturnEdit(text, caret ?? text.Length), text);

    private static string? AfterBackspace(string text, int? caret = null) =>
        Apply(ListContinuation.BackspaceEdit(text, caret ?? text.Length), text);

    [Fact]
    public void ReturnContinuesBulletsAndNumbersWithTheSameIndentation()
    {
        Assert.Equal("- one\n- ", AfterReturn("- one"));
        Assert.Equal("intro\r* one\n* ", AfterReturn("intro\r* one"));
        Assert.Equal("1. one\n2. ", AfterReturn("1. one"));
        Assert.Equal("9. nine\n10. ", AfterReturn("9. nine"));
        Assert.Equal("  - nested 😀\n  - ", AfterReturn("  - nested 😀"));
        // The caret mid-item splits it, the rest moving to the new item.
        Assert.Equal("- one\n- two\rnext", AfterReturn("- onetwo\rnext", 5));
    }

    [Fact]
    public void ReturnOnAnEmptyItemClearsItAndOffAListIsPlain()
    {
        Assert.Equal("- one\r", AfterReturn("- one\r- "));
        Assert.Equal("- one\v", AfterReturn("- one\v  2.  "));
        Assert.Null(AfterReturn("plain"));
        Assert.Null(AfterReturn("-not a marker"));
        Assert.Null(AfterReturn("- one\r"));
        Assert.Null(AfterReturn("1.5 kg"));
        // The caret before the marker's end: a plain line break.
        Assert.Null(AfterReturn("- one", 1));
    }

    [Fact]
    public void BackspaceRightAfterAMarkerDeletesTheMarker()
    {
        Assert.Equal("- one\r", AfterBackspace("- one\r- "));
        Assert.Equal("  ", AfterBackspace("  12. "));
        Assert.Equal("item", AfterBackspace("* item", 2));
        Assert.Null(AfterBackspace("- item"));
        Assert.Null(AfterBackspace("- ", 1));
        Assert.Null(AfterBackspace("plain "));
    }
}
