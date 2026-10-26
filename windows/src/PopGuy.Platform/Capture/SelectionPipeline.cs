using System.Drawing;
using System.Threading.Channels;
using PopGuy.Core.Settings;
using PopGuy.Core.Toolbar;
using PopGuy.Platform.Input;
using PopGuy.Platform.SystemServices;
using PopGuy.Platform.Windowing;
using Windows.Win32.UI.Input.KeyboardAndMouse;

namespace PopGuy.Platform.Capture;

/// <summary>A selection the passive pipeline captured (spec-1 §1.2), for the routing of spec-1 §1.3.</summary>
/// <param name="Capture">
/// The capture, always <see cref="SelectionCaptureStatus.Captured"/>: the text, whether a paste can replace it (true for
/// the Monaco copy fallback), UI Automation's rects (none for the copy) and the method.
/// </param>
/// <param name="Source">The foreground app at the capture (the toolbar's source app).</param>
/// <param name="Anchor">The gesture's release point, drag direction and double-click tag, taken when it was scheduled.</param>
/// <param name="FromMouseUp">The capture came from a left mouse-up, not a keyboard selection.</param>
public sealed record SelectionPipelineEvent(SelectionCaptureResult Capture, ForegroundApp Source, GestureAnchor Anchor, bool FromMouseUp);

/// <summary>
/// The passive selection pipeline (spec-1 §1.2, triggers A-D: drag, keyboard selection, double- and triple-click). Every
/// left mouse-up schedules a capture, and so does a keyboard-selection key (<see cref="SelectionGesture.IsKeyboardSelection"/>:
/// Windows has no app-wide "selection changed" event, so the keys stand in for macOS's notification). Each schedule
/// takes the gesture anchor at once (<see cref="SelectionGesture.Anchor"/>, merged with the pending one by
/// <see cref="SelectionGesture.Schedule"/>) and cancels the previous one; 80 ms after the last, the cheap UI Automation
/// probe decides whether to capture:
/// <list type="bullet">
/// <item>present: the full capture;</item>
/// <item>absent: the full capture only for a mouse-up drag or double-click in a Monaco editor
/// (<see cref="SelectionGesture.ShouldAttemptClipboardFallback"/>), whose large selections UI Automation reports as
/// empty; otherwise nothing;</item>
/// <item>inconclusive: nothing for a bare click (<see cref="SelectionGesture.ShouldSkipInconclusiveFallback"/>), else
/// the full capture.</item>
/// </list>
/// The full capture is <see cref="SelectionCapture.CaptureAsync"/> in <see cref="CaptureMode.Passive"/>: UI Automation,
/// then the synthetic copy only for that Monaco gesture and only where <see cref="CaptureFallbackPolicy"/> allows it,
/// through a <see cref="ClipboardTransaction"/> that restores the clipboard. So a keyboard selection, a bare click, a
/// browser or any other app never gets a synthetic copy (no phantom copy, no beep on a tab-strip drag).
/// <para>
/// Only captured selections are emitted, into <see cref="Events"/>, which holds the newest one alone (an unread one is
/// replaced). A capture overtaken by a newer schedule is dropped. An elevated target (<see cref="SelectionCaptureStatus.Blocked"/>)
/// stays silent. The editable-only option (<see cref="SelectionGesture.ShouldShowOnTextSelect"/>) is the routing's,
/// since a double-click with its own trigger ignores it.
/// </para>
/// <para>
/// Off until <see cref="Enabled"/> is set. Threading: <see cref="Handle(MouseEvent)"/> and <see cref="Handle(KeyEvent)"/>
/// are called from the loops that drain <see cref="GlobalInput.Mouse"/> and <see cref="GlobalInput.Keys"/> (any thread,
/// never the hook's), and return at once; the probe and the capture run on the thread pool. Selected text is never
/// logged, only statuses and lengths.
/// </para>
/// </summary>
public sealed class SelectionPipeline : IDisposable
{
    /// <summary>The wait after the last schedule, so a burst of mouse-ups or key repeats makes one capture.</summary>
    private static readonly TimeSpan Debounce = TimeSpan.FromMilliseconds(80);

    private readonly GlobalInput _input;
    private readonly Action<string>? _log;

    /// <summary>The newest captured selection only, never blocking the writer.</summary>
    private readonly Channel<SelectionPipelineEvent> _events = Channel.CreateBounded<SelectionPipelineEvent>(
        new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = false,
            AllowSynchronousContinuations = false,
        });

    private readonly Lock _gate = new();

    // The last gesture, under _gate.
    private Point _down;
    private Point _up;
    private uint? _upTime;
    private int _clickCount;

    /// <summary>The anchor of the schedule in flight, merged into the next one of the same gesture. Under _gate.</summary>
    private GestureAnchor _pending;

    /// <summary>Bumped by every schedule (and by turning off): a debounce or capture of an older one is cancelled. Under _gate.</summary>
    private long _generation;

    private bool _enabled;

    /// <param name="input">For the user's held keys (the keyboard gestures, the copy's modifiers).</param>
    /// <param name="log">Gets capture outcomes (statuses, reasons and lengths); never the text.</param>
    public SelectionPipeline(GlobalInput input, Action<string>? log = null)
    {
        _input = input;
        _log = log;
    }

    /// <summary>The captured selections, newest only. Completed by <see cref="Dispose"/>.</summary>
    public ChannelReader<SelectionPipelineEvent> Events => _events.Reader;

    /// <summary>
    /// Whether gestures schedule captures. Off by default; turning it off cancels a pending capture. Any thread.
    /// </summary>
    public bool Enabled
    {
        get
        {
            lock (_gate) return _enabled;
        }
        set
        {
            lock (_gate)
            {
                if (_enabled == value) return;
                _enabled = value;
                _generation++;
                _pending = default;
                _upTime = null;
                _clickCount = 0;
            }
        }
    }

    /// <summary>Feeds one mouse event: a left press records where the gesture began, a release schedules a capture.</summary>
    public void Handle(MouseEvent mouse)
    {
        if (mouse.IsPopGuyMarker || mouse.Kind is not (MouseEventKind.LeftDown or MouseEventKind.LeftUp)) return;
        var point = new Point(mouse.X, mouse.Y);
        lock (_gate)
        {
            if (!_enabled) return;
            if (mouse.Kind == MouseEventKind.LeftDown)
            {
                _down = point;
                return;
            }
            // A mouse-up starts a new gesture: a triple-click must not inherit the double-click's pending tag.
            _pending = default;
            _up = point;
            _clickCount = mouse.ClickCount;
            _upTime = mouse.Timestamp;
            ScheduleLocked(fromMouseUp: true);
        }
    }

    /// <summary>
    /// Feeds one key event: a keyboard-selection key press schedules a capture (auto-repeats too, so a held Shift+Right
    /// captures once, after the last). While the left button is down the user is still dragging: the pending capture
    /// is cancelled and the mouse-up captures.
    /// </summary>
    public void Handle(KeyEvent key)
    {
        if (key.IsPopGuyMarker || key.IsKeyUp || key.IsOtherKey) return;
        if (!SelectionGesture.IsKeyboardSelection(key.VirtualKey, HeldModifiers())) return;
        var dragging = ToolbarWindowStyle.IsPrimaryButtonDown();
        lock (_gate)
        {
            if (!_enabled) return;
            if (dragging)
            {
                _generation++;
                return;
            }
            ScheduleLocked(fromMouseUp: false);
        }
    }

    /// <summary>Turns the pipeline off and completes <see cref="Events"/>.</summary>
    public void Dispose()
    {
        Enabled = false;
        _events.Writer.TryComplete();
    }

    /// <summary>
    /// Takes the anchor now, before the debounce, and consumes the mouse-up (a later keyboard schedule gets no pointer
    /// and no double-click tag), then starts the debounce. Under _gate.
    /// </summary>
    private void ScheduleLocked(bool fromMouseUp)
    {
        var fresh = SelectionGesture.Anchor(_down, _up, _upTime, _clickCount, (uint)Environment.TickCount, MonitorInfo.Scale(_up));
        _upTime = null;
        _clickCount = 0;
        var anchor = SelectionGesture.Schedule(fresh, _pending, fromMouseUp);
        _pending = anchor;
        var generation = ++_generation;
        _ = Task.Run(() => RunAsync(anchor, fromMouseUp, generation));
    }

    private async Task RunAsync(GestureAnchor anchor, bool fromMouseUp, long generation)
    {
        try
        {
            await Task.Delay(Debounce).ConfigureAwait(false);
            lock (_gate)
            {
                if (generation != _generation) return;
                // Not overtaken: an unrelated later gesture starts from a clean anchor.
                _pending = default;
            }

            var probe = UiaSelectionReader.Probe();
            if (probe == UiaProbeResult.Inconclusive
                && SelectionGesture.ShouldSkipInconclusiveFallback(fromMouseUp, anchor.MouseReleasePoint, anchor.IsDoubleClick))
            {
                return;
            }
            // After the probe, like UI Automation's focused element: the app the selection is in now.
            var app = ForegroundApp.Snapshot();
            if (probe == UiaProbeResult.Absent)
            {
                var inEditor = app.Exe is { } exe && SelectionGesture.UsesClipboardFallback(exe);
                if (!SelectionGesture.ShouldAttemptClipboardFallback(fromMouseUp, anchor.MouseReleasePoint, inEditor)) return;
            }

            var capture = await SelectionCapture.CaptureAsync(
                CaptureMode.Passive, app, fromMouseUp, anchor.MouseReleasePoint, _input.IsUserKeyDown).ConfigureAwait(false);
            var stale = IsStale(generation);
            _log?.Invoke($"selection: {(fromMouseUp ? "mouse-up" : "keyboard")}, probe {probe}, {capture.Status} ({capture.Reason}), "
                + $"{capture.Text.Length} chars{(stale ? ", overtaken" : "")}");
            if (capture.Status != SelectionCaptureStatus.Captured || stale) return;
            _events.Writer.TryWrite(new SelectionPipelineEvent(capture, app, anchor, fromMouseUp));
        }
        catch (Exception e)
        {
            _log?.Invoke($"selection: capture failed, {e.GetType().Name} {e.Message}");
        }
    }

    private bool IsStale(long generation)
    {
        lock (_gate) return generation != _generation;
    }

    /// <summary>The modifiers the user holds now (PopGuy's own synthetic keys do not count).</summary>
    private ShortcutModifiers HeldModifiers()
    {
        var modifiers = ShortcutModifiers.None;
        if (_input.IsUserKeyDown((uint)VIRTUAL_KEY.VK_CONTROL)) modifiers |= ShortcutModifiers.Control;
        if (_input.IsUserKeyDown((uint)VIRTUAL_KEY.VK_SHIFT)) modifiers |= ShortcutModifiers.Shift;
        if (_input.IsUserKeyDown((uint)VIRTUAL_KEY.VK_MENU)) modifiers |= ShortcutModifiers.Alt;
        if (_input.IsUserKeyDown((uint)VIRTUAL_KEY.VK_LWIN) || _input.IsUserKeyDown((uint)VIRTUAL_KEY.VK_RWIN)) modifiers |= ShortcutModifiers.Win;
        return modifiers;
    }
}
