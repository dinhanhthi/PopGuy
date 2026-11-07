using PopGuy.Core.Actions;
using PopGuy.Core.Settings;

namespace PopGuy.Tests.Core;

// Contract: the toolbar layout editor's rules (macOS ToolbarLayoutEditorView.swift ToolbarLayoutEditMath,
// SettingsStore.swift setPrincipal and setLabeled).
public sealed class ToolbarLayoutEditTests
{
    private static readonly ActionIdentifier Improve = ActionIdentifier.Builtin(ActionKind.Improve);
    private static readonly ActionIdentifier Shorten = ActionIdentifier.Builtin(ActionKind.Shorten);
    private static readonly ActionIdentifier Translate = ActionIdentifier.Builtin(ActionKind.Translate);
    private static readonly IReadOnlyList<ActionIdentifier> Row = [Improve, Shorten, Translate];

    [Fact]
    public void InsertionStepsOnlyPastANeighboursCentre()
    {
        var centers = new Dictionary<ActionIdentifier, double> { [Improve] = 10, [Shorten] = 50, [Translate] = 90 };

        // Improve dragged right: not past Shorten's centre yet, then past it, then past Translate's.
        Assert.Equal(0, ToolbarLayoutEditMath.InsertionIndex(45, 0, Row, centers, Improve));
        Assert.Equal(1, ToolbarLayoutEditMath.InsertionIndex(55, 0, Row, centers, Improve));
        Assert.Equal(2, ToolbarLayoutEditMath.InsertionIndex(95, 0, Row, centers, Improve));
        // Translate dragged left from the end steps back past each centre.
        Assert.Equal(0, ToolbarLayoutEditMath.InsertionIndex(5, 2, Row, centers, Translate));
    }

    [Fact]
    public void ZoneIndexSkipsActionsTheToolbarDoesNotShow()
    {
        // Speak is enabled but has no button: Improve dropped after Shorten lands after Shorten in the zone too.
        IReadOnlyList<ActionIdentifier> zone = [Improve, ActionIdentifier.Speak, Shorten, Translate];

        Assert.Equal(2, ToolbarLayoutEditMath.ZoneIndex(zone, Row, Improve, 1));
        Assert.Equal(3, ToolbarLayoutEditMath.ZoneIndex(zone, Row, Improve, 2));
        // No shown neighbour (an emptied row): the end of the zone.
        Assert.Equal(1, ToolbarLayoutEditMath.ZoneIndex([ActionIdentifier.Speak], [], Improve, 0));
    }

    [Fact]
    public void ReorderPastAHiddenActionMovesTheButton()
    {
        IReadOnlyList<ActionIdentifier> order = [Improve, ActionIdentifier.Speak, Shorten, Translate];
        var s = new AppSettings { ActionOrder = order, PrincipalActionIds = order };
        var index = ToolbarLayoutEditMath.ZoneIndex(ToolbarLayout.PrincipalOrdered(s), Row, Improve, 1);

        var moved = ToolbarLayout.MoveAction(s, Improve, toPrincipal: true, index);

        Assert.Equal([Shorten, Improve, Translate], ToolbarLayout.PrincipalOrdered(moved).Where(Row.Contains));
    }

    [Fact]
    public void LabelAndZoneToggleKeepTheOrder()
    {
        var s = new AppSettings { PrincipalActionIds = [.. AppSettings.DefaultBuiltinOrder] };

        var labeled = ToolbarLayout.WithLabeled(s, Shorten, true);
        var inMore = ToolbarLayout.WithPrincipal(labeled, Shorten, false);

        Assert.True(ToolbarLayout.IsLabeled(inMore, Shorten));
        Assert.False(ToolbarLayout.IsLabeled(ToolbarLayout.WithLabeled(inMore, Shorten, false), Shorten));
        Assert.Equal([Shorten], ToolbarLayout.OverflowOrdered(inMore));
        Assert.Equal(s.ActionOrder, inMore.ActionOrder);
    }

    [Fact]
    public void MoreFitsBesideTheToolbarOnlyWhenBothFitTheWidth()
    {
        // 100 + 8 + 50 = 158.
        Assert.True(ToolbarLayoutEditMath.MoreFitsBesideToolbar(100, 50, 8, 200));
        Assert.True(ToolbarLayoutEditMath.MoreFitsBesideToolbar(100, 50, 8, 158));
        Assert.False(ToolbarLayoutEditMath.MoreFitsBesideToolbar(100, 50, 8, 157));
    }

    [Fact]
    public void MoreZoneFollowsTheLayout()
    {
        // The More card's left edge is at 300, its top at 10.
        // Side by side: a point over the toolbar row is not in the zone, even level with the card.
        Assert.False(ToolbarLayoutEditMath.IsInMoreZone(291, 20, 300, 10, sideBySide: true, slack: 8));
        Assert.True(ToolbarLayoutEditMath.IsInMoreZone(292, 20, 300, 10, sideBySide: true, slack: 8));
        Assert.True(ToolbarLayoutEditMath.IsInMoreZone(340, 0, 300, 10, sideBySide: true, slack: 8));
        // Wrapped: the whole band at or below the card's top (less slack), at any x.
        Assert.True(ToolbarLayoutEditMath.IsInMoreZone(0, 2, 300, 10, sideBySide: false, slack: 8));
        Assert.False(ToolbarLayoutEditMath.IsInMoreZone(340, 1, 300, 10, sideBySide: false, slack: 8));
    }
}
