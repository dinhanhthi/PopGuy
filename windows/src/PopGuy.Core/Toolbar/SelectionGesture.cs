using System.Drawing;
using PopGuy.Core.Settings;

namespace PopGuy.Core.Toolbar;

/// <summary>
/// The panel-anchoring inputs derived from the last mouse gesture.
/// </summary>
/// <param name="MouseReleasePoint">The release point (physical px) of a recent drag or double-click; null otherwise.</param>
/// <param name="GrewDownward">
/// The drag went down the screen (panel below the pointer) or up (panel above); null for double-clicks, keyboard
/// selections and bare clicks, which have no direction.
/// </param>
/// <param name="IsDoubleClick">The selection came from a recent double-click (a single word).</param>
public readonly record struct GestureAnchor(Point? MouseReleasePoint, bool? GrewDownward, bool IsDoubleClick);

/// <summary>
/// Pure selection-trigger decisions, ported from SelectionEvent.swift (gestureAnchor, mergeGestureAnchor,
/// shouldSkipInconclusiveFallback, shouldAttemptClipboardFallback) and TextCaptureEngine.swift's clipboard-fallback set,
/// plus the Windows keyboard-selection keys. Points are physical screen pixels with a top-left origin and y down;
/// times are the system tick count in milliseconds (the low-level hooks' timestamps).
/// </summary>
public static class SelectionGesture
{
    /// <summary>Minimum pointer travel, in DIPs, for a deliberate drag rather than a bare click.</summary>
    public const double DragThresholdDip = 3;

    /// <summary>How long after a mouse-up a selection still counts as made by that mouse gesture.</summary>
    public const uint DoubleClickWindowMs = 600;

    // Monaco editors, whose large selections UI Automation cannot read: only they get the drag-end Ctrl+C. Browsers and
    // other apps are excluded on purpose: a speculative Ctrl+C on a non-text drag (a window moved by its tab strip)
    // makes the host beep with nothing to copy.
    private static readonly HashSet<string> ClipboardFallbackExeNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "code.exe",
        "code - insiders.exe",
        "cursor.exe",
        "windsurf.exe",
        "vscodium.exe",
    };

    /// <summary>
    /// Derives the anchor from a snapshot of the last gesture, taken when the capture is scheduled.
    /// </summary>
    /// <param name="down">The last left-button press.</param>
    /// <param name="up">The last left-button release.</param>
    /// <param name="upTimeMs">The release time; null once consumed by a schedule (no recent mouse-up).</param>
    /// <param name="clickCount">The release's click count (2 = double-click, 3 = triple-click).</param>
    /// <param name="nowMs">The schedule time.</param>
    /// <param name="scale">The monitor's DPI scale (1.5 at 150 %), which turns the DIP threshold into pixels.</param>
    public static GestureAnchor Anchor(Point down, Point up, uint? upTimeMs, int clickCount, uint nowMs, double scale)
    {
        // Unchecked: the tick count wraps after 49.7 days.
        var recentMouseUp = upTimeMs is { } upTime && unchecked(nowMs - upTime) < DoubleClickWindowMs;
        var isDoubleClick = clickCount == 2 && recentMouseUp;
        double dx = up.X - down.X, dy = up.Y - down.Y;
        var isDrag = Math.Sqrt(dx * dx + dy * dy) >= DragThresholdDip * scale;
        var mouseDriven = recentMouseUp && (isDrag || isDoubleClick);
        // AppKit is y-up, so macOS tests up.y <= down.y; Windows is y-down, so the same "downward on screen" is
        // up.Y >= down.Y. Equality stays downward on both, so a horizontal drag puts the panel below.
        bool? grewDownward = mouseDriven && isDrag ? up.Y >= down.Y : null;
        return new(mouseDriven ? up : null, grewDownward, isDoubleClick);
    }

    /// <summary>
    /// Merges a fresh anchor with the pending one of the same gesture's earlier, cancelled schedule: the richer value
    /// wins per field. This keeps the double-click tag when the word's own selection event reschedules within the
    /// debounce, after the mouse-up state was consumed.
    /// </summary>
    public static GestureAnchor Merge(GestureAnchor fresh, GestureAnchor pending) => new(
        fresh.MouseReleasePoint ?? pending.MouseReleasePoint,
        fresh.GrewDownward ?? pending.GrewDownward,
        fresh.IsDoubleClick || pending.IsDoubleClick);

    /// <summary>
    /// The anchor a capture schedule uses, which also becomes the new pending anchor. A mouse-up starts a new gesture
    /// and drops the pending anchor (so a triple-click never inherits the double-click tag); any other schedule merges.
    /// </summary>
    public static GestureAnchor Schedule(GestureAnchor fresh, GestureAnchor pending, bool fromMouseUp) =>
        fromMouseUp ? fresh : Merge(fresh, pending);

    /// <summary>
    /// True when the full capture of an inconclusive probe should be skipped: a bare click on the mouse-up path (no
    /// drag, no double-click).
    /// </summary>
    public static bool ShouldSkipInconclusiveFallback(bool fromMouseUp, Point? mouseReleasePoint, bool isDoubleClick) =>
        fromMouseUp && mouseReleasePoint is null && !isDoubleClick;

    /// <summary>
    /// True when the Ctrl+C clipboard fallback may run for a selection UI Automation could not read: a mouse-up, a
    /// real drag and a Monaco editor. Bare clicks, caret moves and keyboard selections never send a phantom Ctrl+C.
    /// </summary>
    public static bool ShouldAttemptClipboardFallback(bool fromMouseUp, Point? mouseReleasePoint, bool usesClipboardFallback) =>
        fromMouseUp && mouseReleasePoint is not null && usesClipboardFallback;

    /// <summary>
    /// Whether the text-select trigger may show the toolbar for a selection (macOS <c>shouldShowOnTextSelect</c>): with
    /// "Only in editable text" on, only a selection a paste can replace passes, so read-only text (web pages, chat
    /// messages) is ignored. The routing applies it to the text-select path alone: the double-click trigger, the chord
    /// and the hotkeys never check it.
    /// </summary>
    public static bool ShouldShowOnTextSelect(bool isEditable, bool editableOnly) => !editableOnly || isEditable;

    /// <summary>Whether the app with this executable file name (e.g. "Code.exe", any case) needs the Ctrl+C fallback.</summary>
    public static bool UsesClipboardFallback(string exeName) => ClipboardFallbackExeNames.Contains(exeName);

    /// <summary>
    /// Whether a key press with these held modifiers extends a text selection: Shift (Ctrl optional, for words and
    /// the document) with Page Up/Down, End, Home or an arrow, or Ctrl+A. Alt and Win never count: Alt+Shift switches
    /// the keyboard layout and Win+Shift+arrows move windows.
    /// </summary>
    public static bool IsKeyboardSelection(uint virtualKey, ShortcutModifiers modifiers)
    {
        if ((modifiers & (ShortcutModifiers.Alt | ShortcutModifiers.Win)) != 0)
            return false;
        return virtualKey switch
        {
            >= 0x21 and <= 0x28 => modifiers.HasFlag(ShortcutModifiers.Shift), // VK_PRIOR … VK_DOWN
            0x41 => modifiers == ShortcutModifiers.Control, // A
            _ => false,
        };
    }
}

/// <summary>
/// Counts a series of left-button presses the way Windows does for double-clicks, which low-level hooks never report:
/// a press within the double-click time of the previous one, and inside the double-click rectangle centred on it,
/// continues the series (2 = double-click, 3 = triple-click, …); any other press starts a new one. Points are physical
/// screen pixels, times the system tick count in milliseconds. Not thread-safe: one caller (the mouse hook).
/// </summary>
public sealed class ClickCounter
{
    private Point _last;
    private uint _lastTime;

    /// <summary>The count of the latest press (what its release reports); 0 before any press or after <see cref="Reset"/>.</summary>
    public int Count { get; private set; }

    /// <summary>Records a left-button press and returns its count.</summary>
    /// <param name="doubleClickTimeMs">The system double-click time.</param>
    /// <param name="doubleClickSize">The system double-click rectangle (width and height, centred on the previous press).</param>
    public int Press(Point point, uint timestampMs, uint doubleClickTimeMs, Size doubleClickSize)
    {
        // Unchecked: the tick count wraps after 49.7 days.
        var continues = Count > 0
            && unchecked(timestampMs - _lastTime) <= doubleClickTimeMs
            && Math.Abs(point.X - _last.X) <= doubleClickSize.Width / 2
            && Math.Abs(point.Y - _last.Y) <= doubleClickSize.Height / 2;
        Count = continues ? Count + 1 : 1;
        _last = point;
        _lastTime = timestampMs;
        return Count;
    }

    /// <summary>Ends the series: another button's press, so the next left press counts 1.</summary>
    public void Reset() => Count = 0;
}
