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

    /// <summary>
    /// The Menu style's menu top-left (macOS <c>menuCardOrigin</c>), clamped into <paramref name="workArea"/>.
    /// <paramref name="anchor"/> is the rect the menu attaches to: vertically the menu sits outside it (dropping down
    /// puts its top at <c>anchor.Bottom</c>, dropping up puts its bottom at <c>anchor.Top</c>); horizontally it aligns
    /// inside it (going right puts its left at <c>anchor.Left</c>, going left puts its right at <c>anchor.Right</c>).
    /// Prefers down (up when <paramref name="preferUp"/>); flips when the preferred side lacks room and the other side
    /// has it, else takes the side with more room. Prefers right; flips left when there is no room on the right. When
    /// the menu is larger than the work area it keeps the top/left edge.
    /// </summary>
    /// <param name="anchor">
    /// A pointer: <see cref="PointerAnchor"/>. A keyboard selection: the selection padded vertically by
    /// <see cref="PanelVerticalGap"/>, zero width at the bar's anchor x.
    /// </param>
    public static Point MenuOrigin(Size menu, Rectangle anchor, bool preferUp, Rectangle workArea)
    {
        var minX = workArea.Left + PanelEdgeInset;
        var maxX = workArea.Right - PanelEdgeInset - menu.Width;
        var minTop = workArea.Top + PanelEdgeInset;
        var maxTop = workArea.Bottom - PanelEdgeInset - menu.Height;

        var roomBelow = workArea.Bottom - PanelEdgeInset - anchor.Bottom;
        var roomAbove = anchor.Top - minTop;
        var goUp = preferUp
            ? roomAbove >= menu.Height || (roomBelow < menu.Height && roomAbove >= roomBelow)
            : roomBelow < menu.Height && (roomAbove >= menu.Height || roomAbove > roomBelow);
        var y = goUp ? anchor.Top - menu.Height : anchor.Bottom;
        var x = anchor.Left <= maxX ? anchor.Left : anchor.Right - menu.Width;

        // Min then Max, so a menu larger than the work area keeps its top/left edge.
        return new Point(Math.Max(Math.Min(x, maxX), minX), Math.Max(Math.Min(y, maxTop), minTop));
    }

    /// <summary>
    /// The logo-only card's top-left (macOS <c>collapsedPanelOrigin</c>), clamped into <paramref name="workArea"/>:
    /// centred on the pointer and <see cref="PointerVerticalGap"/> below it, or above it for an up-drag or when below
    /// would leave the work area. When the card is larger than the work area it keeps the top/left edge.
    /// </summary>
    /// <param name="grewDownward">The drag direction (<see cref="GestureAnchor.GrewDownward"/>); below when unknown.</param>
    public static Point CollapsedOrigin(Size card, Point pointer, bool? grewDownward, Rectangle workArea)
    {
        var below = pointer.Y + PointerVerticalGap;
        var goAbove = grewDownward == false || below + card.Height > workArea.Bottom - PanelEdgeInset;
        var y = goAbove ? pointer.Y - PointerVerticalGap - card.Height : below;
        var x = pointer.X - card.Width / 2;
        return ClampTopLeft(new Point(x, y), card, workArea);
    }

    /// <summary>
    /// Whether the bar opened from the logo grows leftward, its right edge on the logo's (macOS
    /// <c>logoExpandsLeading</c>). Grows right when it fits there, else left when it fits there, else toward the side
    /// with more room.
    /// </summary>
    /// <param name="logo">The logo card's rect on screen.</param>
    /// <param name="expandedWidth">The full bar's width.</param>
    public static bool LogoExpandsLeading(Rectangle logo, int expandedWidth, Rectangle workArea)
    {
        if (logo.Left + expandedWidth <= workArea.Right - PanelEdgeInset)
            return false;
        if (logo.Right - expandedWidth >= workArea.Left + PanelEdgeInset)
            return true;
        return logo.Right - workArea.Left > workArea.Right - logo.Left;
    }

    /// <summary>
    /// The Menu style's menu top-left when opened from the logo (macOS <c>openMenuFromLogo</c>): the menu covers the
    /// logo from its top-left, aligning its right or bottom edge to the logo's instead when it would cross that
    /// work-area edge, then is clamped into <paramref name="workArea"/> (top/left wins when it is too large).
    /// </summary>
    /// <param name="logo">The logo card's rect on screen.</param>
    public static Point MenuFromLogoOrigin(Size menu, Rectangle logo, Rectangle workArea)
    {
        var x = logo.Left + menu.Width > workArea.Right - PanelEdgeInset ? logo.Right - menu.Width : logo.Left;
        var y = logo.Top + menu.Height > workArea.Bottom - PanelEdgeInset ? logo.Bottom - menu.Height : logo.Top;
        return ClampTopLeft(new Point(x, y), menu, workArea);
    }

    // Min then Max, so a card larger than the work area keeps its top/left edge.
    private static Point ClampTopLeft(Point origin, Size size, Rectangle workArea) => new(
        Math.Max(Math.Min(origin.X, workArea.Right - PanelEdgeInset - size.Width), workArea.Left + PanelEdgeInset),
        Math.Max(Math.Min(origin.Y, workArea.Bottom - PanelEdgeInset - size.Height), workArea.Top + PanelEdgeInset));

    /// <summary>The menu anchor for a pointer: the point padded vertically by <paramref name="gap"/>, zero width.</summary>
    public static Rectangle PointerAnchor(Point pointer, int gap) => new(pointer.X, pointer.Y - gap, 0, 2 * gap);
}
