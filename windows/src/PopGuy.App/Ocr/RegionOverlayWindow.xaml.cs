using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using PopGuy.Platform.Windowing;
using Windows.Graphics;
using Windows.Graphics.Imaging;
using DrawingPoint = System.Drawing.Point;
using DrawingRectangle = System.Drawing.Rectangle;
using VirtualKey = Windows.System.VirtualKey;

namespace PopGuy.Ocr;

/// <summary>
/// One monitor's part of the OCR region overlay (macOS RegionSelectionOverlay): a full-screen, topmost window over the
/// whole monitor (the taskbar too) that shows the freeze-frame <see cref="OcrCaptureController"/> took of it, dimmed
/// (black at 25%) except inside the selection, with a 1 DIP white outline and the crosshair cursor. macOS uses one
/// window over the union of the screens; here each monitor has its own window, so each gets its own DPI, and the
/// controller keeps the drag in physical screen pixels across them. The window reports the left button's press, moves
/// and release, and Esc, as physical pixels; <see cref="ShowSelection"/> draws the selection the controller sends back.
/// Unlike the toolbar, the overlay takes the foreground (the keyboard focus, for Esc). UI thread only.
/// </summary>
public sealed partial class RegionOverlayWindow : Window
{
    private readonly RectangleGeometry _dimBounds = new();
    private readonly RectangleGeometry _dimHole = new();
    private SoftwareBitmapSource? _background;
    private bool _closed;

    /// <param name="boundsPx">The monitor's full bounds (with the taskbar), in physical screen pixels.</param>
    public RegionOverlayWindow(DrawingRectangle boundsPx)
    {
        BoundsPx = boundsPx;
        InitializeComponent();
        Hwnd = Win32Interop.GetWindowFromWindowId(AppWindow.Id);
        // No taskbar button, not in Alt+Tab.
        AppWindow.IsShownInSwitchers = false;
        // On the monitor first: the full-screen presenter fills the monitor the window is on, over the taskbar and with
        // no frame (a borderless overlapped window keeps a 3 px one), so the client area is the monitor.
        AppWindow.MoveAndResize(new RectInt32(boundsPx.X, boundsPx.Y, boundsPx.Width, boundsPx.Height));
        AppWindow.SetPresenter(AppWindowPresenterKind.FullScreen);

        Dim.Data = new GeometryGroup { FillRule = FillRule.EvenOdd, Children = { _dimBounds, _dimHole } };
        Root.SizeChanged += OnRootSizeChanged;
        Root.PointerPressed += OnPointerPressed;
        Root.PointerMoved += OnPointerMoved;
        Root.PointerReleased += OnPointerReleased;
        Root.KeyDown += OnKeyDown;
        Root.Loaded += OnRootLoaded;
        Activated += OnActivated;
        Closed += OnClosed;
    }

    /// <summary>The left button went down, at this physical screen point.</summary>
    public event Action<DrawingPoint>? Pressed;

    /// <summary>The pointer moved with the left button down (also outside this window, while it has the capture).</summary>
    public event Action<DrawingPoint>? Moved;

    /// <summary>The left button went up, at this physical screen point.</summary>
    public event Action<DrawingPoint>? Released;

    /// <summary>Esc.</summary>
    public event Action? Cancelled;

    /// <summary>The monitor this window covers, in physical screen pixels: also its client area's.</summary>
    public DrawingRectangle BoundsPx { get; }

    public nint Hwnd { get; }

    /// <summary>
    /// Shows <paramref name="bitmap"/> (this monitor's part of the freeze-frame, BGRA8 premultiplied, its pixels the
    /// monitor's) as the background. Before <see cref="Present"/>, so the overlay never shows without it. The caller
    /// still owns the bitmap.
    /// </summary>
    public async Task SetBackgroundAsync(SoftwareBitmap bitmap)
    {
        if (_closed) return;
        _background = new SoftwareBitmapSource();
        await _background.SetBitmapAsync(bitmap);
        if (!_closed) Frozen.Source = _background;
    }

    /// <summary>
    /// Shows the window above every other topmost window (the toolbar, the taskbar); <paramref name="activate"/> also
    /// gives it the foreground and the keyboard focus (the overlay under the pointer, so Esc works before any click).
    /// </summary>
    public void Present(bool activate)
    {
        if (_closed) return;
        AppWindow.Show(activateWindow: false);
        ToolbarWindowStyle.SetBounds(Hwnd, BoundsPx);
        if (activate) Activate();
    }

    /// <summary>
    /// Draws <paramref name="selectionPx"/> (physical screen pixels; it may span monitors, the part off this one is
    /// simply not seen), or no selection when null.
    /// </summary>
    public void ShowSelection(DrawingRectangle? selectionPx)
    {
        if (_closed) return;
        var scale = Scale();
        if (selectionPx is not { } px)
        {
            _dimHole.Rect = default;
            SelectionBorder.Visibility = Visibility.Collapsed;
            return;
        }
        var local = new Windows.Foundation.Rect(
            (px.X - BoundsPx.X) / scale, (px.Y - BoundsPx.Y) / scale, px.Width / scale, px.Height / scale);
        _dimHole.Rect = local;
        Canvas.SetLeft(SelectionBorder, local.X);
        Canvas.SetTop(SelectionBorder, local.Y);
        SelectionBorder.Width = local.Width;
        SelectionBorder.Height = local.Height;
        SelectionBorder.Visibility = Visibility.Visible;
    }

    /// <summary>Closes the window (once).</summary>
    public void Dismiss()
    {
        if (!_closed) Close();
    }

    /// <summary>The window's physical pixels per DIP: its monitor's scale (1 when not laid out yet).</summary>
    private double Scale()
    {
        var scale = Root.XamlRoot?.RasterizationScale ?? 0;
        return scale > 0 && double.IsFinite(scale) ? scale : 1;
    }

    /// <summary>
    /// A point relative to the root, in DIPs, as a physical screen point. Exact on mixed-DPI setups: the window's own
    /// scale, and a captured pointer's points outside the window keep that same mapping.
    /// </summary>
    private DrawingPoint ToPixels(Windows.Foundation.Point dip)
    {
        var scale = Scale();
        return new(BoundsPx.X + (int)Math.Round(dip.X * scale), BoundsPx.Y + (int)Math.Round(dip.Y * scale));
    }

    private void OnRootSizeChanged(object sender, SizeChangedEventArgs e) =>
        _dimBounds.Rect = new Windows.Foundation.Rect(0, 0, e.NewSize.Width, e.NewSize.Height);

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_closed) return;
        var point = e.GetCurrentPoint(Root);
        if (!point.Properties.IsLeftButtonPressed) return;
        e.Handled = true;
        // The moves keep coming when the drag leaves this monitor; the press also activates the window (Esc).
        Root.CapturePointer(e.Pointer);
        Root.Focus(FocusState.Pointer);
        Pressed?.Invoke(ToPixels(point.Position));
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_closed) return;
        var point = e.GetCurrentPoint(Root);
        if (!point.Properties.IsLeftButtonPressed) return;
        e.Handled = true;
        Moved?.Invoke(ToPixels(point.Position));
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_closed) return;
        var point = e.GetCurrentPoint(Root);
        if (point.Properties.PointerUpdateKind != PointerUpdateKind.LeftButtonReleased) return;
        e.Handled = true;
        Root.ReleasePointerCapture(e.Pointer);
        Released?.Invoke(ToPixels(point.Position));
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_closed || e.Key != VirtualKey.Escape) return;
        e.Handled = true;
        Cancelled?.Invoke();
    }

    /// <summary>
    /// The keyboard focus goes to the root once the window is active, so Esc reaches it before any click. Enqueued: the
    /// window can be activated before its first layout, when the root cannot take the focus yet.
    /// </summary>
    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (_closed || args.WindowActivationState == WindowActivationState.Deactivated) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_closed) Root.Focus(FocusState.Programmatic);
        });
    }

    /// <summary>Activated before the first layout: the focus is taken once the root is in the tree.</summary>
    private void OnRootLoaded(object sender, RoutedEventArgs e)
    {
        if (!_closed && ToolbarWindowStyle.ForegroundWindow() == Hwnd) Root.Focus(FocusState.Programmatic);
    }

    /// <summary>
    /// A close from outside (Alt+F4) cancels the capture: otherwise it never ends and the selection pipeline stays
    /// muted. The controller unsubscribes before <see cref="Dismiss"/>, so its own close raises nothing.
    /// </summary>
    private void OnClosed(object sender, WindowEventArgs args)
    {
        var cancelled = Cancelled;
        _closed = true;
        Root.SizeChanged -= OnRootSizeChanged;
        Root.PointerPressed -= OnPointerPressed;
        Root.PointerMoved -= OnPointerMoved;
        Root.PointerReleased -= OnPointerReleased;
        Root.KeyDown -= OnKeyDown;
        Root.Loaded -= OnRootLoaded;
        Activated -= OnActivated;
        Frozen.Source = null;
        _background?.Dispose();
        _background = null;
        Pressed = null;
        Moved = null;
        Released = null;
        Cancelled = null;
        cancelled?.Invoke();
    }
}

/// <summary>The overlay's root: a Grid with the crosshair cursor (a UIElement's cursor can only be set from a subclass).</summary>
public sealed partial class CrosshairGrid : Grid
{
    public CrosshairGrid() => ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Cross);
}
