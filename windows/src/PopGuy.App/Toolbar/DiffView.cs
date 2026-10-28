using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using PopGuy.Core.Diff;
using Windows.UI.Text;

namespace PopGuy.Toolbar;

/// <summary>
/// Renders an Improve/Proofread diff into a RichTextBlock (macOS <c>DiffView.swift</c>): equal text in the block's
/// colour, additions in the theme's success colour, deletions in its critical colour with strikethrough. Each changed
/// run is a hyperlink to its hunk: a click reports the hunk index (accept/reject toggle). A rejected hunk keeps its
/// colours, dimmed. The links take no focus (focus would activate the toolbar) and have no underline or tooltip.
/// UNTRUSTED DATA: segment text goes into plain runs, never through a markup parser. UI thread only.
/// </summary>
internal sealed class DiffView(RichTextBlock block, Action<int> onToggleHunk)
{
    /// <summary>The opacity of a rejected hunk's colours (macOS: 0.35).</summary>
    private const double RejectedOpacity = 0.35;

    private IReadOnlyList<DiffSegment>? _segments;
    private IReadOnlySet<int>? _rejected;

    /// <summary>
    /// Shows <paramref name="segments"/> with <paramref name="rejected"/> dimmed. The inputs are snapshots the session
    /// replaces on change, so the same pair (by reference) does nothing: the diff is rebuilt only when it changes.
    /// </summary>
    public void Show(IReadOnlyList<DiffSegment> segments, IReadOnlySet<int> rejected)
    {
        if (ReferenceEquals(segments, _segments) && ReferenceEquals(rejected, _rejected)) return;
        _segments = segments;
        _rejected = rejected;

        var hunks = DiffHunks.HunkIndices(segments);
        var paragraph = new Paragraph();
        for (var index = 0; index < segments.Count; index++)
        {
            var segment = segments[index];
            var run = new Run { Text = segment.Text };
            if (hunks[index] is not { } hunk)
            {
                paragraph.Inlines.Add(run);
                continue;
            }

            // The colour is set on the run, so the link's own hover and pressed colours never replace it.
            var dimmed = rejected.Contains(hunk);
            if (segment.Kind == DiffKind.Deleted)
            {
                run.Foreground = Brush("SystemFillColorCriticalBrush", dimmed);
                run.TextDecorations = TextDecorations.Strikethrough;
            }
            else
            {
                run.Foreground = Brush("SystemFillColorSuccessBrush", dimmed);
            }
            var link = new Hyperlink
            {
                UnderlineStyle = UnderlineStyle.None,
                AllowFocusOnInteraction = false,
                IsTabStop = false,
            };
            link.Inlines.Add(run);
            link.Click += (_, _) => onToggleHunk(hunk);
            paragraph.Inlines.Add(link);
        }
        block.Blocks.Clear();
        block.Blocks.Add(paragraph);
    }

    /// <summary>The theme brush <paramref name="key"/>; a dimmed copy for a rejected hunk.</summary>
    private static Brush Brush(string key, bool dimmed)
    {
        var brush = (Brush)Application.Current.Resources[key];
        return dimmed && brush is SolidColorBrush solid
            ? new SolidColorBrush(solid.Color) { Opacity = RejectedOpacity }
            : brush;
    }
}
