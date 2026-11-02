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

    // Menu style: the menu attaches beside the pointer, down-right by default.
    private static readonly Size Menu = new(220, 300);

    [Fact]
    public void MenuOpensDownRightOfThePointer()
    {
        var pointer = new Point(650, 400);

        var origin = PanelPositioning.MenuOrigin(Menu, PanelPositioning.PointerAnchor(pointer, 16), preferUp: false, WorkArea);

        Assert.Equal(new Point(650, 416), origin);
    }

    [Fact]
    public void MenuOpensUpForAnUpDragOrWhenThereIsNoRoomBelow()
    {
        var upDrag = PanelPositioning.MenuOrigin(Menu, PanelPositioning.PointerAnchor(new Point(650, 400), 16), preferUp: true, WorkArea);
        Assert.Equal(new Point(650, 400 - 16 - Menu.Height), upDrag);

        var nearBottom = PanelPositioning.MenuOrigin(Menu, PanelPositioning.PointerAnchor(new Point(650, 800), 16), preferUp: false, WorkArea);
        Assert.Equal(800 - 16 - Menu.Height, nearBottom.Y);
    }

    [Fact]
    public void MenuOpensLeftOfThePointerNearTheRightEdge()
    {
        var origin = PanelPositioning.MenuOrigin(Menu, PanelPositioning.PointerAnchor(new Point(1400, 400), 16), preferUp: false, WorkArea);

        Assert.Equal(new Point(1400 - Menu.Width, 416), origin);
    }

    // Logo-only mode: a 40 px logo card near the pointer, then the bar or menu opening from it.
    private static readonly Size Logo = new(40, 40);

    [Fact]
    public void CollapsedLogoSitsCentredBelowThePointerOrAboveForAnUpDrag()
    {
        var pointer = new Point(700, 500);

        var below = PanelPositioning.CollapsedOrigin(Logo, pointer, grewDownward: true, WorkArea);
        Assert.Equal(new Point(pointer.X - Logo.Width / 2, pointer.Y + 16), below);

        var above = PanelPositioning.CollapsedOrigin(Logo, pointer, grewDownward: false, WorkArea);
        Assert.Equal(new Point(pointer.X - Logo.Width / 2, pointer.Y - 16 - Logo.Height), above);
    }

    [Fact]
    public void CollapsedLogoFlipsAboveAtTheBottomEdgeAndClampsAtASideEdge()
    {
        var nearBottom = PanelPositioning.CollapsedOrigin(Logo, new Point(700, 880), grewDownward: true, WorkArea);
        Assert.Equal(880 - 16 - Logo.Height, nearBottom.Y);

        var nearLeft = PanelPositioning.CollapsedOrigin(Logo, new Point(2, 500), grewDownward: true, WorkArea);
        Assert.Equal(WorkArea.Left + 4, nearLeft.X);
    }

    [Fact]
    public void LogoExpandsRightWhenTheBarFitsElseLeftElseTowardTheRoomierSide()
    {
        Assert.False(PanelPositioning.LogoExpandsLeading(new Rectangle(new Point(600, 400), Logo), 320, WorkArea));
        Assert.True(PanelPositioning.LogoExpandsLeading(new Rectangle(new Point(1380, 400), Logo), 320, WorkArea));

        // Too wide for either side: the side with more room wins.
        Assert.True(PanelPositioning.LogoExpandsLeading(new Rectangle(new Point(1000, 400), Logo), 1500, WorkArea));
        Assert.False(PanelPositioning.LogoExpandsLeading(new Rectangle(new Point(300, 400), Logo), 1500, WorkArea));
    }

    [Fact]
    public void MenuFromLogoCoversTheLogoAndAlignsToItsFarEdgesNearTheWorkAreaEdges()
    {
        var onLogo = PanelPositioning.MenuFromLogoOrigin(Menu, new Rectangle(new Point(600, 400), Logo), WorkArea);
        Assert.Equal(new Point(600, 400), onLogo);

        var rightEdge = new Rectangle(new Point(1380, 400), Logo);
        Assert.Equal(new Point(rightEdge.Right - Menu.Width, 400),
            PanelPositioning.MenuFromLogoOrigin(Menu, rightEdge, WorkArea));

        var bottomEdge = new Rectangle(new Point(600, 800), Logo);
        Assert.Equal(new Point(600, bottomEdge.Bottom - Menu.Height),
            PanelPositioning.MenuFromLogoOrigin(Menu, bottomEdge, WorkArea));
    }
}
