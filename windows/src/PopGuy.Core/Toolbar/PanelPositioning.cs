using System.Drawing;

namespace PopGuy.Core.Toolbar;

/// <summary>
/// The floating toolbar's on-screen origin (spec-1 §3.2; macOS <c>PanelPositioning.swift</c>). Everything is in
/// physical screen pixels with a top-left origin and y down, so no coordinate flip is needed; only the above/below
/// choice flips when the panel does not fit.
/// </summary>
public static class PanelPositioning
{
    /// <summary>Gap between the selection and the panel when there is no pointer (keyboard, chord, hotkey).</summary>
    public const int PanelVerticalGap = 8;

    /// <summary>Gap between the release pointer and the panel: the pointer sits mid-line, so the panel must clear that line.</summary>
    public const int PointerVerticalGap = 16;

    /// <summary>Minimum distance from every work-area edge.</summary>
    public const int PanelEdgeInset = 4;

    /// <summary>
    /// The panel's top-left, clamped into <paramref name="workArea"/>.
    /// With a <paramref name="pointer"/> (a drag or double-click release) the panel is centred on it and goes past it
    /// in the drag direction (below when unknown); the selection rect only matters for the rare edge-of-screen flip,
    /// because UI Automation can report a partial rect for multi-line selections. Without a pointer the panel is
    /// centred on the selection and goes below it, flipping above when there is no room.
    /// </summary>
    /// <param name="selection">The selection rect, or a zero-size rect at the mouse when none is usable.</param>
    /// <param name="workArea">The work area of the monitor that holds the selection.</param>
    /// <param name="grewDownward">The drag direction (<see cref="GestureAnchor.GrewDownward"/>); ignored without a pointer.</param>
    public static Point PanelOrigin(Size panelSize, Rectangle selection, Rectangle workArea, Point? pointer, bool? grewDownward)
    {
        // Min/Max rather than Math.Clamp, which throws when the panel is larger than the work area.
        var anchorX = pointer?.X ?? selection.Left + selection.Width / 2;
        var x = Math.Min(Math.Max(anchorX - panelSize.Width / 2, workArea.Left + PanelEdgeInset),
            workArea.Right - panelSize.Width - PanelEdgeInset);

        var minTop = workArea.Top + PanelEdgeInset;
        var maxTop = workArea.Bottom - PanelEdgeInset - panelSize.Height;
        int y;
        if (pointer is { } p)
        {
            if (grewDownward ?? true)
            {
                var below = p.Y + PointerVerticalGap;
                y = below <= maxTop ? below : Math.Max(Math.Min(p.Y, selection.Top) - PointerVerticalGap - panelSize.Height, minTop);
            }
            else
            {
                var above = p.Y - PointerVerticalGap - panelSize.Height;
                y = above >= minTop ? above : Math.Min(Math.Max(p.Y, selection.Bottom) + PointerVerticalGap, maxTop);
            }
        }
        else
        {
            var below = selection.Bottom + PanelVerticalGap;
            y = below <= maxTop ? below : Math.Max(selection.Top - PanelVerticalGap - panelSize.Height, minTop);
        }

        return new Point(x, y);
    }
}
