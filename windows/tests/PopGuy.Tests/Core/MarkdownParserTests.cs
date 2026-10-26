using PopGuy.Core.Markdown;

namespace PopGuy.Tests.Core;

// Contract: a result's Markdown keeps a link only for an absolute http(s) URL without user info or a mailto address
// (model output is untrusted), and the lists and inline styles macOS MarkdownResultView renders are parsed.
public sealed class MarkdownParserTests
{
    // The link target, then the link the parser keeps ("" when the text stays plain).
    public static TheoryData<string, string> Links => new()
    {
        { "javascript:alert%281%29", "" },
        { "file:///etc/passwd", "" },
        { "http://user@evil.example/", "" },
        { "data:text/html,hi", "" },
        { "/relative/path", "" },
        { "https://example.com/", "https://example.com/" },
        { "mailto:a@example.com", "mailto:a@example.com" },
    };

    [Theory]
    [MemberData(nameof(Links))]
    public void KeepsOnlyAllowedLinks(string target, string expected)
    {
        var inline = Assert.Single(Assert.Single(MarkdownParser.Parse($"[click]({target})")).Inlines);

        Assert.Equal("click", inline.Text);
        Assert.Equal(expected, inline.Link?.AbsoluteUri ?? "");
    }

    [Fact]
    public void ParsesTheInlineStyles()
    {
        var inlines = Assert.Single(MarkdownParser.Parse("**b** *i* ~~s~~ `c` ![alt](https://tracker.example/x.png)")).Inlines;

        Assert.Equal(
            ["b:Bold", " :None", "i:Italic", " :None", "s:Strikethrough", " :None", "c:Code", " alt:None"],
            inlines.Select(i => $"{i.Text}:{i.Style}"));
    }

    [Fact]
    public void ParsesListsAndParagraphs()
    {
        var blocks = MarkdownParser.Parse("- a\r\n3. b\n\n2026. c\n<b>d</b>");

        Assert.Equal(
            ["Bullet::a", "Numbered:3.:b", "Paragraph::", "Paragraph::2026. c", "Paragraph::<b>d</b>"],
            blocks.Select(b => $"{b.Kind}:{b.Marker}:{string.Concat(b.Inlines.Select(i => i.Text))}"));
    }
}
