using System.Drawing;
using PopGuy.Core.Toolbar;

namespace PopGuy.Tests.Core;

// Contract: toolbar placement (spec-1 §3.2, macOS PanelPositioningTests) in physical px, top-left origin, y down. The
// pointer side follows the drag direction, never the selection rect; keyboard selections go below; the panel stays
// inside the monitor's work area, including a secondary monitor with negative coordinates.
public sealed class PanelPositioningTests
{
    private static readonly Rectangle WorkArea = new(0, 0, 1440, 900);
    private static readonly Size Panel = new(280, 50);
    private static readonly Rectangle Selection = new(600, 400, 200, 120);

    [Fact]
    public void DownDragPlacesThePanelBelowThePointer()
    {
        var pointer = new Point(650, Selection.Bottom - 4);

        var origin = PanelPositioning.PanelOrigin(Panel, Selection, WorkArea, pointer, grewDownward: true);

        Assert.Equal(new Point(pointer.X - Panel.Width / 2, pointer.Y + 16), origin);
    }

    [Fact]
    public void UpDragPlacesThePanelAboveThePointerEvenWithAPartialSelectionRect()
    {
        // UI Automation may report only the caret line of a multi-line selection: the rect must not decide the side.
        var fullSelection = new Rectangle(600, 400, 200, 200);
        var caretLine = new Rectangle(600, 400, 200, 20);
        var pointer = new Point(650, 410);

        var origin = PanelPositioning.PanelOrigin(Panel, caretLine, WorkArea, pointer, grewDownward: false);

        Assert.Equal(new Point(pointer.X - Panel.Width / 2, pointer.Y - 16 - Panel.Height), origin);
        Assert.False(new Rectangle(origin, Panel).IntersectsWith(fullSelection));
    }

    [Fact]
    public void KeyboardSelectionGoesBelowAndFlipsAboveWhenItDoesNotFit()
    {
        var below = PanelPositioning.PanelOrigin(Panel, Selection, WorkArea, pointer: null, grewDownward: null);
        Assert.Equal(new Point(Selection.Left + Selection.Width / 2 - Panel.Width / 2, Selection.Bottom + 8), below);

        var nearBottom = new Rectangle(600, 860, 200, 20);
        var flipped = PanelPositioning.PanelOrigin(Panel, nearBottom, WorkArea, pointer: null, grewDownward: null);
        Assert.Equal(nearBottom.Top - 8 - Panel.Height, flipped.Y);
    }

    [Fact]
    public void ClampsIntoASecondaryMonitorWithNegativeCoordinates()
    {
        // A monitor left of and above the primary one; the pointer sits at its top-left corner after an up-drag.
        var secondary = new Rectangle(-1920, -200, 1920, 1040);
        var pointer = new Point(-1915, -190);
        var selection = new Rectangle(-1915, -195, 100, 20);

        var origin = PanelPositioning.PanelOrigin(Panel, selection, secondary, pointer, grewDownward: false);

        var inset = Rectangle.Inflate(secondary, -4, -4);
        Assert.True(inset.Contains(new Rectangle(origin, Panel)), $"panel at {origin} leaves {inset}");
        Assert.Equal(secondary.Left + 4, origin.X);
    }
}
