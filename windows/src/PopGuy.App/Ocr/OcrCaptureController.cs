using Microsoft.UI.Windowing;
using PopGuy.Platform.Ocr;
using PopGuy.Platform.Windowing;
using Windows.Graphics.Imaging;
using DrawingPoint = System.Drawing.Point;
using DrawingRectangle = System.Drawing.Rectangle;

namespace PopGuy.Ocr;

/// <summary>
/// One OCR screen-text capture from start to finish (macOS OCRCaptureController): freeze-frame → region overlay → crop
/// → OCR → <see cref="OnText"/>. Decoupled from the toolbar on purpose: the text goes out through the callbacks, and
/// the caller (the toolbar controller) shows it. One capture at a time: <see cref="BeginCapture"/> does nothing while
/// one runs.
/// <para>
/// Freeze-frame: the whole virtual screen is captured first, each monitor's overlay shows its part of that picture
/// dimmed, and the selected region is cut from the same picture (physical pixels). A WinUI window is not see-through,
/// so a live translucent overlay is not possible; and the OCR reads exactly what the user saw, with no wait for the
/// overlays to leave the screen before a second capture. Windows has no Screen Recording permission (macOS's first
/// step). UI thread only.
/// </para>
/// UNTRUSTED DATA: the recognized text is never logged.
/// </summary>
public sealed class OcrCaptureController(Action<string> log)
{
    internal const string NoTextTitle = "No Text Found";
    internal const string NoTextMessage = "No text found in the selected area.";
    internal const string FailedTitle = "Screen Capture Failed";
    internal const string FailedMessage = "Screen capture failed.";

    private readonly List<RegionOverlayWindow> _overlays = [];
    private TaskCompletionSource<RegionSelection?>? _selection;

    /// <summary>Where the drag started (physical screen pixels); null when no drag is in progress.</summary>
    private DrawingPoint? _dragStart;

    /// <summary>
    /// The recognized text (trimmed, "\n" line breaks), the mouse-up point (physical screen pixels, the space of
    /// <c>ToolbarWindow.ShowAt</c>'s pointer: the toolbar's anchor) and the captured region (BGRA8, its physical
    /// pixels; for the toolbar's thumbnail). The callback owns the bitmap and disposes it.
    /// </summary>
    public Action<string, DrawingPoint, SoftwareBitmap>? OnText { get; set; }

    /// <summary>
    /// A capture that ended without text, as a title and a message for the user (macOS shows them in an alert): no text
    /// in the region, no OCR language installed, or the capture failed. Not called on cancel (Esc, a click without a
    /// drag).
    /// </summary>
    public Action<string, string>? OnFailed { get; set; }

    /// <summary>A capture is in progress (the overlay is up, or the OCR is running).</summary>
    public bool IsCapturing { get; private set; }

    /// <summary>Begins a capture. Does nothing while one is in progress (macOS too).</summary>
    public void BeginCapture()
    {
        if (IsCapturing) return;
        IsCapturing = true;
        _ = RunCaptureAsync();
    }

    private async Task RunCaptureAsync()
    {
        // Given back when the overlay closes: Esc returns to where the user was.
        var foreground = ToolbarWindowStyle.ForegroundWindow();
        SoftwareBitmap?[] backgrounds = [];
        SoftwareBitmap? region = null;
        try
        {
            var virtualPx = ScreenCapture.VirtualScreen();
            using var frozen = await Task.Run(() => ScreenCapture.Capture(virtualPx));
            if (frozen is null)
            {
                log("ocr: the screen capture failed");
                OnFailed?.Invoke(FailedTitle, FailedMessage);
                return;
            }

            var monitors = Monitors();
            if (monitors.Count == 0)
            {
                // macOS: no screens is a cancel.
                log("ocr: no monitor");
                return;
            }
            var monitorRects = monitors.Select(m => Relative(m, virtualPx)).ToList();
            backgrounds = await Task.Run(() => ScreenCapture.Crop(frozen, monitorRects));

            var selection = await SelectRegionAsync(monitors, backgrounds);
            CloseOverlays();
            ToolbarWindowStyle.SetForeground(foreground);
            if (selection is null) return;

            region = (await Task.Run(() => ScreenCapture.Crop(frozen, [Relative(selection.RectPx, virtualPx)])))[0];
            if (region is null)
            {
                log("ocr: the region is off the screen");
                OnFailed?.Invoke(FailedTitle, FailedMessage);
                return;
            }

            var outcome = await OcrRecognizer.RecognizeAsync(region);
            if (!outcome.Succeeded)
            {
                log($"ocr: recognition failed, {outcome.Failure}");
                OnFailed?.Invoke(FailedTitle, outcome.Message ?? FailedMessage);
                return;
            }
            var text = outcome.Text.Trim();
            if (text.Length == 0)
            {
                OnFailed?.Invoke(NoTextTitle, NoTextMessage);
                return;
            }
            if (OnText is { } onText)
            {
                var image = region;
                region = null;
                onText(text, selection.MouseUpPx, image);
            }
        }
        catch (Exception e)
        {
            log($"ocr: capture failed, {e.GetType().Name}");
            OnFailed?.Invoke(FailedTitle, FailedMessage);
        }
        finally
        {
            CloseOverlays();
            foreach (var background in backgrounds) background?.Dispose();
            region?.Dispose();
            IsCapturing = false;
        }
    }

    /// <summary>
    /// Every monitor's full bounds (with the taskbar), physical screen pixels. By index: enumerating the list WinUI
    /// returns can fail.
    /// </summary>
    private static List<DrawingRectangle> Monitors()
    {
        var areas = DisplayArea.FindAll();
        var monitors = new List<DrawingRectangle>(areas.Count);
        for (var i = 0; i < areas.Count; i++)
        {
            var bounds = areas[i].OuterBounds;
            if (bounds.Width > 0 && bounds.Height > 0) monitors.Add(new(bounds.X, bounds.Y, bounds.Width, bounds.Height));
        }
        return monitors;
    }

    /// <summary>A screen rect relative to the freeze-frame (the virtual screen's top-left may be negative).</summary>
    private static DrawingRectangle Relative(DrawingRectangle screenPx, DrawingRectangle virtualPx) =>
        screenPx with { X = screenPx.X - virtualPx.X, Y = screenPx.Y - virtualPx.Y };

    /// <summary>
    /// Shows one overlay per monitor (the one under the pointer activated, for Esc) and waits for the selection: null
    /// on Esc or a click without a drag (zero width or height).
    /// </summary>
    private async Task<RegionSelection?> SelectRegionAsync(List<DrawingRectangle> monitors, SoftwareBitmap?[] backgrounds)
    {
        // Asynchronous continuations: the overlays close after the pointer or key handler that finished, not inside it.
        var selection = new TaskCompletionSource<RegionSelection?>(TaskCreationOptions.RunContinuationsAsynchronously);
        _selection = selection;
        _dragStart = null;
        for (var i = 0; i < monitors.Count; i++)
        {
            var overlay = new RegionOverlayWindow(monitors[i]);
            overlay.Pressed += OnPressed;
            overlay.Moved += OnMoved;
            overlay.Released += OnReleased;
            overlay.Cancelled += OnCancelled;
            _overlays.Add(overlay);
            if (backgrounds[i] is { } background) await overlay.SetBackgroundAsync(background);
        }

        var cursor = ToolbarWindowStyle.CursorPosition();
        var active = _overlays.Find(o => o.BoundsPx.Contains(cursor)) ?? _overlays[0];
        foreach (var overlay in _overlays) overlay.Present(activate: overlay == active);
        return await selection.Task;
    }

    private void OnPressed(DrawingPoint point)
    {
        if (_selection is null) return;
        _dragStart = point;
        ShowSelection(Normalized(point, point));
    }

    private void OnMoved(DrawingPoint point)
    {
        if (_dragStart is { } start) ShowSelection(Normalized(start, point));
    }

    /// <summary>The release ends the selection, on whichever overlay it lands (a drag may cross monitors).</summary>
    private void OnReleased(DrawingPoint point)
    {
        if (_dragStart is not { } start) return;
        _dragStart = null;
        var rect = Normalized(start, point);
        Finish(rect.Width > 0 && rect.Height > 0 ? new RegionSelection(rect, point) : null);
    }

    private void OnCancelled()
    {
        _dragStart = null;
        Finish(null);
    }

    /// <summary>Completes the selection once; later finishes (Esc after the release) do nothing.</summary>
    private void Finish(RegionSelection? result)
    {
        var selection = _selection;
        _selection = null;
        selection?.TrySetResult(result);
    }

    /// <summary>Every overlay draws the selection: the part on its monitor shows.</summary>
    private void ShowSelection(DrawingRectangle? rectPx)
    {
        foreach (var overlay in _overlays) overlay.ShowSelection(rectPx);
    }

    private void CloseOverlays()
    {
        Finish(null);
        _dragStart = null;
        foreach (var overlay in _overlays)
        {
            overlay.Pressed -= OnPressed;
            overlay.Moved -= OnMoved;
            overlay.Released -= OnReleased;
            overlay.Cancelled -= OnCancelled;
            overlay.Dismiss();
        }
        _overlays.Clear();
    }

    private static DrawingRectangle Normalized(DrawingPoint a, DrawingPoint b) =>
        DrawingRectangle.FromLTRB(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));

    /// <summary>A finished drag: the region and the mouse-up point, physical screen pixels.</summary>
    private sealed record RegionSelection(DrawingRectangle RectPx, DrawingPoint MouseUpPx);
}
