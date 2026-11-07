using PopGuy.Core.Composer;

namespace PopGuy.Tests.Core;

// Core behavior of the Terminal Composer's Markdown highlighter (pure text -> runs), as in
// macos/PopGuyTests/Unit/MarkdownHighlighterTests.swift: fenced code is code with no inline rules inside, and runs
// are UTF-16 ranges (C# string indices) that stay right after non-ASCII text.
public sealed class MarkdownHighlighterTests
{
    [Fact]
    public void FencedCodeClosedAndUnclosedIsCodeWithNoInlineRulesInside()
    {
        const string text = "Intro **bold**\n```swift\nlet a = `b` **c** _d_\n```\nAfter\n~~~\n**open**";
        var runs = MarkdownHighlighter.Runs(text);

        Assert.Contains(Run(text, "**bold**", HighlightKind.Bold), runs);
        Assert.Contains(Run(text, "```swift", HighlightKind.CodeFence), runs);
        Assert.Contains(Run(text, "let a = `b` **c** _d_", HighlightKind.CodeBlock), runs);
        Assert.Contains(new HighlightRun(text.IndexOf("```\n", StringComparison.Ordinal), 3, HighlightKind.CodeFence), runs);
        // The unclosed "~~~" fence runs to the end of the text.
        Assert.Contains(Run(text, "~~~", HighlightKind.CodeFence), runs);
        Assert.Contains(Run(text, "**open**", HighlightKind.CodeBlock), runs);

        // Only the prose "**bold**" gets an inline style; nothing inside the fences.
        HighlightKind[] inlineKinds = [HighlightKind.Bold, HighlightKind.Italic, HighlightKind.InlineCode];
        Assert.Equal([Run(text, "**bold**", HighlightKind.Bold)], runs.Where(r => inlineKinds.Contains(r.Kind)));
    }

    [Fact]
    public void InlineCodeAndAHeadingGetUtf16RangesAfterNonAsciiText()
    {
        const string text = "Café 🎉 uses `x_y *z*` here\n## Title 😀 `k`\nsnake_case_words and *it* _em_";
        var runs = MarkdownHighlighter.Runs(text);

        var code = Run(text, "`x_y *z*`", HighlightKind.InlineCode);
        Assert.Contains(code, runs);
        Assert.Contains(Run(text, "## Title 😀 `k`", HighlightKind.Heading) with { HeadingLevel = 2 }, runs);
        Assert.Contains(Run(text, "`k`", HighlightKind.InlineCode), runs);

        // No italic inside inline code, and snake_case is not italic.
        Assert.Equal(
            [Run(text, "*it*", HighlightKind.Italic), Run(text, "_em_", HighlightKind.Italic)],
            runs.Where(r => r.Kind == HighlightKind.Italic));
        Assert.DoesNotContain(runs, r => r.Kind == HighlightKind.Italic && r.Start < code.Start + code.Length && code.Start < r.Start + r.Length);
    }

    private static HighlightRun Run(string text, string part, HighlightKind kind) =>
        new(text.IndexOf(part, StringComparison.Ordinal), part.Length, kind);
}
