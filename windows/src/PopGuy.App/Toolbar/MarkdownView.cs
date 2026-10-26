using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using PopGuy.Core.Markdown;
using Windows.UI.Text;

namespace PopGuy.Toolbar;

/// <summary>
/// Renders a result's Markdown into a RichTextBlock (macOS <c>MarkdownResultView.swift</c>), when "Preserve &amp; render
/// formatting" is on: one paragraph per line, bullets and numbered items (the marker in the line: WinUI documents no
/// negative text indent for a hanging one), bold, italic, strikethrough, inline code in a monospace font. An allowed link (http, https,
/// mailto) is a hyperlink the default browser or mail app opens; it takes no focus (focus would activate the toolbar).
/// UNTRUSTED DATA: the text goes into plain runs built from <see cref="MarkdownParser"/>'s objects, never through a
/// markup parser, and the parser decides which links survive. UI thread only.
/// </summary>
internal sealed class MarkdownView(RichTextBlock block)
{
    /// <summary>The space between two lines' paragraphs (macOS: the stack's spacing).</summary>
    private const double LineSpacing = 4;

    /// <summary>A list item's indent before its marker (macOS: 4 pt leading padding).</summary>
    private const double ListLeading = 4;

    private readonly FontFamily _codeFont = new("Cascadia Mono, Consolas");
    private string? _markdown;

    /// <summary>Shows <paramref name="markdown"/>; the same text does nothing, so it is rebuilt only when it changes.</summary>
    public void Show(string markdown)
    {
        if (markdown == _markdown) return;
        _markdown = markdown;

        block.Blocks.Clear();
        var first = true;
        foreach (var line in MarkdownParser.Parse(markdown))
        {
            var paragraph = new Paragraph { Margin = new Thickness(0, first ? 0 : LineSpacing, 0, 0) };
            first = false;
            if (line.Kind != MarkdownBlockKind.Paragraph)
            {
                var marker = (line.Kind == MarkdownBlockKind.Bullet ? "•" : line.Marker) + " ";
                paragraph.Margin = new Thickness(ListLeading, paragraph.Margin.Top, 0, 0);
                paragraph.Inlines.Add(new Run { Text = marker });
            }
            AddInlines(paragraph, line.Inlines);
            block.Blocks.Add(paragraph);
        }
    }

    /// <summary>The runs of a line; consecutive runs of one link share a hyperlink.</summary>
    private void AddInlines(Paragraph paragraph, IReadOnlyList<MarkdownInline> inlines)
    {
        Hyperlink? link = null;
        Uri? linkUri = null;
        foreach (var inline in inlines)
        {
            var run = Styled(inline);
            if (inline.Link is not { } uri)
            {
                link = null;
                paragraph.Inlines.Add(run);
                continue;
            }
            if (link is null || !ReferenceEquals(uri, linkUri))
            {
                link = new Hyperlink { NavigateUri = uri, AllowFocusOnInteraction = false, IsTabStop = false };
                linkUri = uri;
                paragraph.Inlines.Add(link);
            }
            link.Inlines.Add(run);
        }
    }

    private Inline Styled(MarkdownInline inline)
    {
        var run = new Run { Text = inline.Text };
        if (inline.Style.HasFlag(MarkdownStyle.Strikethrough)) run.TextDecorations = TextDecorations.Strikethrough;
        if (inline.Style.HasFlag(MarkdownStyle.Code)) run.FontFamily = _codeFont;
        // Bold and Italic spans, never the run's own weight or style: a bold run ended the app on a Light/Dark switch
        // (VM QA, ArgumentException "target" inside the XAML framework).
        Inline styled = run;
        if (inline.Style.HasFlag(MarkdownStyle.Italic)) styled = Wrap(new Italic(), styled);
        if (inline.Style.HasFlag(MarkdownStyle.Bold)) styled = Wrap(new Bold(), styled);
        return styled;
    }

    private static Span Wrap(Span span, Inline inline)
    {
        span.Inlines.Add(inline);
        return span;
    }
}
