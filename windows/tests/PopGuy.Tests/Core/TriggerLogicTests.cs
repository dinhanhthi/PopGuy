using System.Drawing;
using PopGuy.Core.Settings;
using PopGuy.Core.Toolbar;

namespace PopGuy.Tests.Core;

// Contract: the Ctrl+C+C chord detector (DoubleTapDetectorTests), the selection-gesture helpers of
// SelectionEvent.swift (GestureAnchorTests, ClipboardFallbackGateTests) and the text-select editable-only gate
// (TextSelectEditableGateTests), plus the Windows keyboard-selection keys.
public sealed class TriggerLogicTests
{
    private static bool[] Feed(params (uint TimestampMs, bool IsChordKey)[] keys)
    {
        var detector = new DoubleTapDetector();
        return keys.Select(k => detector.Handle(k.TimestampMs, k.IsChordKey)).ToArray();
    }

    [Fact]
    public void ChordFiresOnAPairWithinTheWindowAndAThirdTapReArms()
    {
        Assert.Equal([false, true], Feed((1000, true), (1299, true)));
        Assert.Equal([false, true, false, true], Feed((0, true), (100, true), (200, true), (250, true)));
    }

    [Fact]
    public void ChordDoesNotFireAfterAGapOrAnInterleavedKey()
    {
        Assert.Equal([false, false], Feed((1000, true), (1300, true)));
        Assert.Equal([false, false, false], Feed((1000, true), (1050, false), (1100, true)));
    }

    // Windows screen coordinates: y grows downward.
    private static readonly Point Down = new(500, 400);
    private const uint Now = 10_000;

    private static GestureAnchor Anchor(Point up, int clickCount = 1, uint? upTime = Now - 100, double scale = 1) =>
        SelectionGesture.Anchor(Down, up, upTime, clickCount, Now, scale);

    [Theory]
    [InlineData(450, true)] // released lower on screen
    [InlineData(400, true)] // horizontal drag: below, as on macOS
    [InlineData(350, false)] // released higher on screen
    public void AnchorGrewDownwardFollowsTheDragDirection(int upY, bool grewDownward)
    {
        var up = new Point(520, upY);
        var anchor = Anchor(up);

        Assert.Equal(grewDownward, anchor.GrewDownward);
        Assert.Equal(up, anchor.MouseReleasePoint);
        Assert.False(anchor.IsDoubleClick);
    }

    [Fact]
    public void MergeCarriesThePendingDoubleClickForward()
    {
        var doubleClick = Anchor(new Point(501, 400), clickCount: 2);
        // The word's trailing selection event reschedules after the mouse-up state was consumed.
        var consumed = Anchor(new Point(501, 400), clickCount: 0, upTime: null);

        var merged = SelectionGesture.Schedule(consumed, pending: doubleClick, fromMouseUp: false);

        Assert.True(merged.IsDoubleClick);
        Assert.Equal(new Point(501, 400), merged.MouseReleasePoint);
        Assert.Null(merged.GrewDownward);
    }

    [Fact]
    public void TripleClickNeverInheritsTheDoubleClickTag()
    {
        var doubleClick = Anchor(new Point(501, 400), clickCount: 2);
        var tripleClick = Anchor(new Point(501, 400), clickCount: 3);

        var scheduled = SelectionGesture.Schedule(tripleClick, pending: doubleClick, fromMouseUp: true);

        Assert.False(scheduled.IsDoubleClick);
        // Still mouse-driven: the release point lets the VS Code copy fallback read the line.
        Assert.Equal(new Point(501, 400), tripleClick.MouseReleasePoint);
    }

    [Fact]
    public void FourthClickOfASeriesIsABareClick()
    {
        // In a Monaco editor an empty selection copies the current line: a quick click series must not copy it.
        Assert.Null(Anchor(new Point(501, 400), clickCount: 4).MouseReleasePoint);
    }

    // The low-level hook reports no click count: this counter alone decides double- and triple-clicks.
    [Fact]
    public void ClickCounterFollowsTheSystemDoubleClickTimeAndRectangle()
    {
        const uint Time = 500;
        var size = new Size(4, 4);
        var counter = new ClickCounter();

        Assert.Equal(1, counter.Press(new Point(100, 100), 1000, Time, size));
        Assert.Equal(2, counter.Press(new Point(102, 98), 1400, Time, size));
        // The rectangle is centred on the previous press, not the first: (103, 97) is 3 px from (100, 100).
        Assert.Equal(3, counter.Press(new Point(103, 97), 1800, Time, size));
        // Too late, then too far: each starts a new series.
        Assert.Equal(1, counter.Press(new Point(103, 97), 2301, Time, size));
        Assert.Equal(1, counter.Press(new Point(106, 97), 2400, Time, size));
        // Another button's press ends the series.
        counter.Reset();
        Assert.Equal(1, counter.Press(new Point(106, 97), 2500, Time, size));
        // The tick count wraps after 49.7 days.
        Assert.Equal(1, counter.Press(new Point(10, 10), uint.MaxValue - 100, Time, size));
        Assert.Equal(2, counter.Press(new Point(10, 10), 200, Time, size));
    }

    [Fact]
    public void BareClickNeverFallsBackToCtrlC()
    {
        // 4 px of travel stays under the 3 DIP threshold at 150 % scale (4.5 px).
        var bareClick = Anchor(new Point(504, 400), scale: 1.5);
        var drag = Anchor(new Point(505, 400), scale: 1.5);
        var vsCode = SelectionGesture.UsesClipboardFallback("Code.exe");

        Assert.Null(bareClick.MouseReleasePoint);
        Assert.False(SelectionGesture.ShouldAttemptClipboardFallback(true, bareClick.MouseReleasePoint, vsCode));
        Assert.True(SelectionGesture.ShouldSkipInconclusiveFallback(true, bareClick.MouseReleasePoint, bareClick.IsDoubleClick));
        Assert.True(SelectionGesture.ShouldAttemptClipboardFallback(true, drag.MouseReleasePoint, vsCode));
        Assert.False(SelectionGesture.ShouldAttemptClipboardFallback(false, drag.MouseReleasePoint, vsCode));
        Assert.False(SelectionGesture.ShouldAttemptClipboardFallback(
            true, drag.MouseReleasePoint, SelectionGesture.UsesClipboardFallback("chrome.exe")));
    }

    [Theory]
    [InlineData(0x27, ShortcutModifiers.Shift, true)] // Shift+Right
    [InlineData(0x27, ShortcutModifiers.Control | ShortcutModifiers.Shift, true)] // Ctrl+Shift+Right
    [InlineData(0x24, ShortcutModifiers.Shift, true)] // Shift+Home
    [InlineData(0x22, ShortcutModifiers.Control | ShortcutModifiers.Shift, true)] // Ctrl+Shift+Page Down
    [InlineData(0x41, ShortcutModifiers.Control, true)] // Ctrl+A
    [InlineData(0x27, ShortcutModifiers.None, false)] // Right: caret move
    [InlineData(0x41, ShortcutModifiers.None, false)] // A: typing
    [InlineData(0x43, ShortcutModifiers.Control, false)] // Ctrl+C
    [InlineData(0x41, ShortcutModifiers.Control | ShortcutModifiers.Shift, false)] // Ctrl+Shift+A
    [InlineData(0x27, ShortcutModifiers.Alt | ShortcutModifiers.Shift, false)] // Alt+Shift+Right
    [InlineData(0x27, ShortcutModifiers.Win | ShortcutModifiers.Shift, false)] // Win+Shift+Right: moves the window
    public void KeyboardSelectionKeys(uint virtualKey, ShortcutModifiers modifiers, bool selects) =>
        Assert.Equal(selects, SelectionGesture.IsKeyboardSelection(virtualKey, modifiers));

    [Theory]
    [InlineData(true, true, true)] // editable-only on, editable source: show
    [InlineData(false, true, false)] // editable-only on, read-only source (web page text): no toolbar
    [InlineData(true, false, true)] // editable-only off: show
    [InlineData(false, false, true)]
    public void TextSelectEditableOnlyGate(bool isEditable, bool editableOnly, bool shows) =>
        Assert.Equal(shows, SelectionGesture.ShouldShowOnTextSelect(isEditable, editableOnly));
}
