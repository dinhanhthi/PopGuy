using System.Globalization;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PopGuy.Platform.Windowing;
using Windows.Foundation;
using DrawingPoint = System.Drawing.Point;
using DrawingRectangle = System.Drawing.Rectangle;

namespace PopGuy.Debug;

/// <summary>
/// The Phase 3 spike toolbar (Task 3.4): a borderless, topmost tool window at the pointer that must never take the
/// foreground from the source app (the app whose text is selected). Tier 1 of the plan: WS_EX_NOACTIVATE plus
/// <c>AllowFocusOnInteraction="False"</c> buttons, a WM_MOUSEACTIVATE → MA_NOACTIVATE subclass on every HWND, and a
/// foreground hand-back after each press. The Prompt box is the one exception: its bounds are the activation region,
/// where the subclass answers MA_ACTIVATE so Windows activates the toolbar for that click; text input ends (activation
/// off, the foreground handed back) on Escape, Enter, focus loss, deactivation, any other press, and hide. It reports
/// what it sees through <see cref="Logged"/> (one record per click, with the measured <c>activation</c>: never,
/// handedBack or stuck) and the button clicks through <see cref="Clicked"/>. UI thread only.
/// </summary>
public sealed partial class SpikeToolbarWindow : Window
{
    /// <summary>The size before the bar's first layout (task 3.4: 280×50 DIP).</summary>
    private const double StartWidth = 280;
    private const double StartHeight = 50;

    /// <summary>The toolbar's top edge sits this far below the pointer (above it when there is no room below).</summary>
    private const double PointerGap = 12;

    /// <summary>The tooltip opens this far below the window.</summary>
    private const double TooltipGap = 4;

    /// <summary>When the foreground is read after a click: the pass bound, then the stuck bound (plan 3.5 (b)).</summary>
    private static readonly TimeSpan FirstCheck = TimeSpan.FromMilliseconds(100);
    private static readonly TimeSpan SecondCheck = TimeSpan.FromMilliseconds(300);

    /// <summary>How often a drag reads the pointer (the window cannot capture it while it is not the foreground).</summary>
    private static readonly TimeSpan DragPollInterval = TimeSpan.FromMilliseconds(15);

    private readonly List<string> _messages = [];
    private bool _closed;
    private bool _textInput;
    private bool _dragging;
    private XamlRoot? _xamlRoot;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _dragTimer;

    /// <summary>The drag's start: the pointer and the window's top-left corner (physical pixels), and the moves so far.</summary>
    private DrawingPoint _dragPointer;
    private DrawingPoint _dragOrigin;
    private int _dragMoves;

    /// <summary>The Prompt box's bounds last given to the subclass (client pixels).</summary>
    private DrawingRectangle _activationRegion;

    /// <summary>The bar's last laid-out size in DIPs; the start size before the first layout.</summary>
    private Size _barSize = new(StartWidth, StartHeight);

    /// <summary>The toolbar (or one of its windows) was the foreground at some point of the current press.</summary>
    private bool _wasForeground;

    /// <summary>The hand-back gave the foreground back during the current press.</summary>
    private bool _handedBack;

    private nint _fgAtPress;

    /// <summary>The window's style and backdrop, logged with the first show (nobody listens in the constructor).</summary>
    private Dictionary<string, object?>? _pendingStartRecord;

    public SpikeToolbarWindow()
    {
        InitializeComponent();

        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(false, false);
            presenter.IsResizable = false;
        }
        Hwnd = Win32Interop.GetWindowFromWindowId(AppWindow.Id);
        var styled = ToolbarWindowStyle.Apply(Hwnd);
        _dragTimer = DispatcherQueue.CreateTimer();
        _dragTimer.Interval = DragPollInterval;
        _dragTimer.IsRepeating = true;
        _dragTimer.Tick += OnDragTick;

        string backdrop;
        if (DesktopAcrylicController.IsSupported())
        {
            SystemBackdrop = new AlwaysActiveAcrylicBackdrop();
            backdrop = "acrylic";
        }
        else
        {
            RootCanvas.Background = (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"];
            backdrop = "solid";
        }
        _pendingStartRecord = new Dictionary<string, object?>
        {
            ["toolbar"] = Hex(Hwnd),
            ["styleApplied"] = styled,
            ["backdrop"] = backdrop,
        };

        ImproveButton.Click += OnButtonClick;
        CopyButton.Click += OnButtonClick;
        PasteButton.Click += OnButtonClick;
        ImproveButton.PointerEntered += OnImproveEntered;
        ImproveButton.PointerExited += OnImproveExited;
        PromptBox.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(OnPromptPressed), true);
        PromptBox.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnPromptKeyDown), true);
        PromptBox.LostFocus += OnPromptLostFocus;
        PromptBox.SizeChanged += OnPromptSizeChanged;
        Activated += OnActivated;

        // Every press and release, the buttons' and the Prompt box's (handled) too.
        Bar.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(OnAnyPointerPressed), true);
        Bar.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(OnAnyPointerReleased), true);
        // Drag: presses outside the buttons and the Prompt box reach these (those controls handle theirs).
        Bar.PointerPressed += OnBackgroundPressed;
        Bar.PointerMoved += OnPointerMoved;
        Bar.PointerReleased += OnPointerReleased;
        Bar.PointerCaptureLost += OnPointerCaptureLost;

        Bar.SizeChanged += OnBarSizeChanged;
        Bar.Loaded += OnBarLoaded;
        Closed += OnClosed;
    }

    /// <summary>An Improve, Copy or Paste click: "improve", "copy" or "paste".</summary>
    public event Action<string>? Clicked;

    /// <summary>A record for the spike log: "event" plus its fields. Selected text is never in it.</summary>
    public event Action<Dictionary<string, object?>>? Logged;

    /// <summary>The toolbar's window handle.</summary>
    public nint Hwnd { get; }

    /// <summary>The window the toolbar was shown for (the source app's foreground window); 0 before the first show.</summary>
    public nint Source { get; private set; }

    /// <summary>The toolbar is on screen.</summary>
    public bool IsShown { get; private set; }

    /// <summary>
    /// Shows the toolbar for <paramref name="source"/> just below <paramref name="pointer"/> (physical pixels), sized
    /// with the DPI of the monitor under the pointer, without activating it.
    /// </summary>
    public void ShowAt(nint source, DrawingPoint pointer)
    {
        if (_closed) return;
        if (_pendingStartRecord is { } start)
        {
            _pendingStartRecord = null;
            Log("toolbarCreated", start);
        }
        EndTextInput("show", handBack: false);
        TooltipPopup.IsOpen = false;
        Source = source;

        var scale = ToolbarWindowStyle.DpiAt(pointer) / 96.0;
        var width = Pixels(_barSize.Width, scale);
        var height = Pixels(_barSize.Height, scale);
        var gap = (int)Math.Round(PointerGap * scale);
        var x = pointer.X;
        var y = pointer.Y + gap;
        var work = ToolbarWindowStyle.MonitorWorkArea(pointer);
        if (!work.IsEmpty)
        {
            x = Math.Max(Math.Min(x, work.Right - width), work.Left);
            if (y + height > work.Bottom) y = pointer.Y - gap - height;
            y = Math.Max(y, work.Top);
        }
        var placed = ToolbarWindowStyle.SetBounds(Hwnd, new DrawingRectangle(x, y, width, height));

        // Never Activate(): it would take the foreground from the source app.
        AppWindow.Show(activateWindow: false);
        IsShown = true;

        // The XAML input-site windows exist only once the window is shown.
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_closed) return;
            int? count;
            try
            {
                count = ToolbarWindowStyle.SubclassNoActivate(Hwnd, OnWindowMessage);
            }
            catch (Exception ex)
            {
                // Tier 1 goes on without the subclass lever; the log says so.
                count = null;
                Log("error", new() { ["where"] = "subclass", ["message"] = $"{ex.GetType().Name}: {ex.Message}" });
            }
            Log("shown", new()
            {
                ["fgBefore"] = Hex(source),
                ["fgAfter"] = Hex(ToolbarWindowStyle.ForegroundWindow()),
                ["placed"] = placed,
                ["scale"] = scale,
                ["subclassedWindows"] = count,
            });
        });
    }

    /// <summary>
    /// Hides the toolbar. With <paramref name="handBack"/>, first gives the foreground back to the source if the toolbar
    /// has it (not after a click elsewhere: the clicked window is the user's choice).
    /// </summary>
    public void Dismiss(string reason, bool handBack)
    {
        if (_closed || !IsShown) return;
        StopDrag();
        EndTextInput("dismiss", handBack: false);
        var handedBack = handBack && ToolbarWindowStyle.HandBackForeground(Hwnd, Source);
        TooltipPopup.IsOpen = false;
        AppWindow.Hide();
        IsShown = false;
        Log("dismissed", new() { ["reason"] = reason, ["handedBack"] = handedBack });
    }

    /// <summary>
    /// Before a paste: ends text input and makes the source the foreground window again if it is not. True when the
    /// source has the foreground.
    /// </summary>
    public bool ReturnForegroundToSource()
    {
        EndTextInput("paste", handBack: false);
        if (ToolbarWindowStyle.ForegroundWindow() == Source) return true;
        return ToolbarWindowStyle.SetForeground(Source);
    }

    /// <summary>The point (physical pixels) is on the toolbar's window.</summary>
    public bool Contains(int x, int y) => ToolbarWindowStyle.WindowRect(Hwnd).Contains(x, y);

    // Clicks and the activation check.

    private void OnButtonClick(object sender, RoutedEventArgs e)
    {
        if (_closed || sender is not Button { Tag: string name }) return;
        EndTextInput("button", handBack: true);
        Clicked?.Invoke(name);
    }

    private void OnAnyPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_closed) return;
        // The window to hand back to: the foreground now, unless it is the toolbar (then the one from before).
        var foreground = ToolbarWindowStyle.RememberForeground(Hwnd);
        if (foreground != 0) Source = foreground;
        // A press anywhere but the Prompt box ends text input: the toolbar must not stay the foreground.
        if (TargetOf(e.OriginalSource as DependencyObject) != "prompt") EndTextInput("press", handBack: true);
        _fgAtPress = ToolbarWindowStyle.ForegroundWindow();
        _wasForeground = ToolbarWindowStyle.IsToolbarOrOwned(_fgAtPress, Hwnd);
        _handedBack = false;
    }

    /// <summary>
    /// A press is over (a button's click has run): gives the foreground back if the toolbar took it, then reads the
    /// foreground 100 ms and 300 ms later and logs the activation. Not for the Prompt box, which activates on purpose.
    /// </summary>
    private void OnAnyPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_closed || _textInput) return;
        var target = TargetOf(e.OriginalSource as DependencyObject);
        if (target == "prompt") return;
        var fgAtRelease = ToolbarWindowStyle.ForegroundWindow();
        _wasForeground |= ToolbarWindowStyle.IsToolbarOrOwned(fgAtRelease, Hwnd);
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_closed && !_dragging && !_textInput) _handedBack |= ToolbarWindowStyle.HandBackForeground(Hwnd, Source);
        });
        _ = MeasureActivationAsync("click", target, Source, _fgAtPress, fgAtRelease);
    }

    /// <summary>
    /// never = the toolbar never had the foreground and the source has it after 100 ms; handedBack = it had it, and the
    /// source has it again after 100 ms; stuck = the source does not have the foreground after 300 ms. A source that
    /// gets it back only between 100 and 300 ms is handedBack with fg100IsSource false.
    /// </summary>
    private async Task MeasureActivationAsync(string evt, string target, nint source, nint fgAtPress, nint fgAtRelease)
    {
        try
        {
            await Task.Delay(FirstCheck);
            var fg100 = ToolbarWindowStyle.ForegroundWindow();
            _wasForeground |= ToolbarWindowStyle.IsToolbarOrOwned(fg100, Hwnd);
            await Task.Delay(SecondCheck - FirstCheck);
            var fg300 = ToolbarWindowStyle.ForegroundWindow();
            var activation = fg300 != source ? "stuck" : _wasForeground || _handedBack || fg100 != source ? "handedBack" : "never";
            Log(evt, new()
            {
                ["target"] = target,
                ["fgBefore"] = Hex(source),
                ["fgAtPress"] = Hex(fgAtPress),
                ["fgAtRelease"] = Hex(fgAtRelease),
                ["fg100"] = Hex(fg100),
                ["fgAfter"] = Hex(fg300),
                ["fg100IsSource"] = fg100 == source,
                ["activation"] = activation,
                ["handBackCalled"] = _handedBack,
            });
        }
        catch (Exception ex)
        {
            Log("error", new() { ["where"] = "activation check", ["message"] = ex.Message });
        }
    }

    private string TargetOf(DependencyObject? element)
    {
        for (; element is not null && element != Bar; element = VisualTreeHelper.GetParent(element))
        {
            if (element is Button { Tag: string name }) return name;
            if (element == PromptBox) return "prompt";
        }
        return "background";
    }

    // Text input: the only time the toolbar is activated on purpose. The click itself activates it (the Prompt box is
    // the subclass's activation region, answered MA_ACTIVATE); SetForegroundWindow here is the second lever.

    private void OnPromptPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_closed || _textInput) return;
        _textInput = true;
        var fgAtPress = ToolbarWindowStyle.ForegroundWindow();
        var activatedByClick = fgAtPress == Hwnd;
        var allowed = ToolbarWindowStyle.AllowActivation(Hwnd, true);
        bool? setForeground = activatedByClick ? null : ToolbarWindowStyle.SetForeground(Hwnd);
        var fgAfter = ToolbarWindowStyle.ForegroundWindow();
        // Focus once the window is active (the press is still being handled now).
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_closed && _textInput) PromptBox.Focus(FocusState.Pointer);
        });
        Log("textInput", new()
        {
            ["fgBefore"] = Hex(Source),
            ["fgAtPress"] = Hex(fgAtPress),
            ["activatedByClick"] = activatedByClick,
            ["activationAllowed"] = allowed,
            ["setForeground"] = setForeground,
            ["fgAfter"] = Hex(fgAfter),
            ["toolbarForeground"] = fgAfter == Hwnd,
            ["region"] = RegionText(_activationRegion),
        });
        _ = CheckTextInputAsync();
    }

    /// <summary>
    /// 100 ms after the press: logs whether the toolbar is the foreground and the Prompt box focused. When the toolbar
    /// did not become the foreground, text input ends at once (typing goes to the source anyway), so activation never
    /// stays on.
    /// </summary>
    private async Task CheckTextInputAsync()
    {
        try
        {
            await Task.Delay(FirstCheck);
            if (_closed || !_textInput) return;
            var foreground = ToolbarWindowStyle.ForegroundWindow();
            var focused = _xamlRoot is not null && ReferenceEquals(FocusManager.GetFocusedElement(_xamlRoot), PromptBox);
            Log("textInputCheck", new()
            {
                ["fg100"] = Hex(foreground),
                ["toolbarForeground"] = foreground == Hwnd,
                ["promptFocused"] = focused,
            });
            if (foreground != Hwnd) EndTextInput("not foreground", handBack: false);
        }
        catch (Exception ex)
        {
            Log("error", new() { ["where"] = "text input check", ["message"] = ex.Message });
        }
    }

    private void OnPromptKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_closed || !_textInput) return;
        if (e.Key is not (Windows.System.VirtualKey.Escape or Windows.System.VirtualKey.Enter)) return;
        // Enter would submit the prompt in the real toolbar; the spike logs the length only, never the text.
        if (e.Key == Windows.System.VirtualKey.Enter) Log("promptSubmitted", new() { ["textLength"] = PromptBox.Text.Length });
        e.Handled = true;
        EndTextInput(e.Key == Windows.System.VirtualKey.Enter ? "enter" : "escape", handBack: true);
    }

    private void OnPromptLostFocus(object sender, RoutedEventArgs e)
    {
        if (!_closed) EndTextInput("focus lost", handBack: true);
    }

    /// <summary>Another window took the foreground (a click elsewhere): it keeps it, only activation goes off.</summary>
    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (!_closed && args.WindowActivationState == WindowActivationState.Deactivated) EndTextInput("deactivated", handBack: false);
    }

    /// <summary>
    /// Ends text input: clicks stop activating the toolbar (WS_EX_NOACTIVATE back on) and, with
    /// <paramref name="handBack"/>, the source gets the foreground back if the toolbar has it. Also when only the
    /// subclass turned activation on (a click in the region whose press never reached the Prompt box).
    /// </summary>
    private void EndTextInput(string reason, bool handBack)
    {
        if (!_textInput && !ToolbarWindowStyle.IsActivationAllowed(Hwnd)) return;
        _textInput = false;
        var noActivate = ToolbarWindowStyle.AllowActivation(Hwnd, false);
        var handedBack = handBack && ToolbarWindowStyle.HandBackForeground(Hwnd, Source);
        Log("textInputEnded", new()
        {
            ["reason"] = reason,
            ["noActivateRestored"] = noActivate,
            ["handedBack"] = handedBack,
            ["fgAfter"] = Hex(ToolbarWindowStyle.ForegroundWindow()),
            // Where the focus went: tells a focus move WinUI made itself from the user's.
            ["focusedNow"] = _xamlRoot is null ? null : FocusManager.GetFocusedElement(_xamlRoot)?.GetType().Name,
        });
    }

    /// <summary>The Prompt box's bounds in client pixels become the subclass's activation region.</summary>
    private void UpdateActivationRegion()
    {
        if (_xamlRoot is null || PromptBox.ActualWidth <= 0 || PromptBox.ActualHeight <= 0) return;
        var scale = _xamlRoot.RasterizationScale;
        if (scale <= 0 || !double.IsFinite(scale)) return;
        var bounds = PromptBox.TransformToVisual(RootCanvas)
            .TransformBounds(new Rect(0, 0, PromptBox.ActualWidth, PromptBox.ActualHeight));
        var region = DrawingRectangle.FromLTRB(
            (int)Math.Floor(bounds.Left * scale), (int)Math.Floor(bounds.Top * scale),
            (int)Math.Ceiling(bounds.Right * scale), (int)Math.Ceiling(bounds.Bottom * scale));
        if (region == _activationRegion) return;
        _activationRegion = region;
        ToolbarWindowStyle.SetActivationRegion(Hwnd, region);
        Log("activationRegion", new() { ["region"] = RegionText(region), ["scale"] = scale });
    }

    private void OnPromptSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!_closed) UpdateActivationRegion();
    }

    private static string RegionText(DrawingRectangle r) =>
        string.Create(CultureInfo.InvariantCulture, $"{r.X},{r.Y} {r.Width}x{r.Height}");

    // The one tooltip: does a popup below the window activate it?

    private void OnImproveEntered(object sender, PointerRoutedEventArgs e)
    {
        if (_closed || TooltipPopup.IsOpen) return;
        var origin = ImproveButton.TransformToVisual(RootCanvas).TransformPoint(new Point(0, 0));
        TooltipPopup.HorizontalOffset = origin.X;
        TooltipPopup.VerticalOffset = Bar.ActualHeight + TooltipGap;
        TooltipPopup.IsOpen = true;
        var fgAtOpen = ToolbarWindowStyle.ForegroundWindow();
        _wasForeground = ToolbarWindowStyle.IsToolbarOrOwned(fgAtOpen, Hwnd);
        _handedBack = false;
        _ = MeasureActivationAsync("tooltip", "improve", Source, fgAtOpen, fgAtOpen);
    }

    private void OnImproveExited(object sender, PointerRoutedEventArgs e)
    {
        if (!_closed) TooltipPopup.IsOpen = false;
    }

    // Drag: no title bar, so a press on the bar's background (Transparent, so it hit-tests) moves the window by how far
    // the pointer moved since the press, in screen pixels. A window that is not the foreground cannot really capture
    // the pointer (Windows sends it the pointer's moves only while the pointer is over it), so the drag also reads the
    // pointer and the button every 15 ms and ends when the button is up. The press never activates the toolbar (it is
    // outside the activation region).

    private void OnBackgroundPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_closed || _dragging) return;
        var point = e.GetCurrentPoint(Bar);
        if (!point.Properties.IsLeftButtonPressed) return;
        EndTextInput("drag", handBack: true);
        var captured = Bar.CapturePointer(e.Pointer);
        _dragPointer = ToolbarWindowStyle.CursorPosition();
        _dragOrigin = ToolbarWindowStyle.WindowRect(Hwnd).Location;
        _dragMoves = 0;
        _dragging = true;
        _dragTimer.Start();
        e.Handled = true;
        Log("dragStarted", new()
        {
            ["captured"] = captured,
            ["pointerX"] = _dragPointer.X,
            ["pointerY"] = _dragPointer.Y,
            ["x"] = _dragOrigin.X,
            ["y"] = _dragOrigin.Y,
        });
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging || _closed) return;
        DragToPointer();
        e.Handled = true;
    }

    private void OnDragTick(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        if (!_dragging || _closed)
        {
            sender.Stop();
            return;
        }
        if (!ToolbarWindowStyle.IsPrimaryButtonDown())
        {
            // Released where the window did not see it (outside it, without a capture).
            StopDrag();
            EndDrag("button up");
            return;
        }
        DragToPointer();
    }

    /// <summary>The window's top-left corner follows the pointer from where the drag started.</summary>
    private void DragToPointer()
    {
        var pointer = ToolbarWindowStyle.CursorPosition();
        var x = _dragOrigin.X + pointer.X - _dragPointer.X;
        var y = _dragOrigin.Y + pointer.Y - _dragPointer.Y;
        var frame = ToolbarWindowStyle.WindowRect(Hwnd);
        if (frame.IsEmpty || (frame.X == x && frame.Y == y)) return;
        if (ToolbarWindowStyle.Move(Hwnd, x, y)) _dragMoves++;
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging) return;
        DragToPointer();
        StopDrag();
        if (!_closed) Bar.ReleasePointerCapture(e.Pointer);
        e.Handled = true;
        EndDrag("released");
    }

    private void OnPointerCaptureLost(object sender, PointerRoutedEventArgs e)
    {
        // Without a real capture, the capture goes as soon as the pointer leaves: the poll goes on until the button is up.
        if (!_dragging || ToolbarWindowStyle.IsPrimaryButtonDown()) return;
        StopDrag();
        EndDrag("capture lost");
    }

    /// <summary>Stops the drag (no log): the poll ends with it.</summary>
    private void StopDrag()
    {
        _dragging = false;
        _dragTimer.Stop();
    }

    private void EndDrag(string how)
    {
        if (_closed) return;
        var frame = ToolbarWindowStyle.WindowRect(Hwnd);
        Log("dragEnded", new() { ["how"] = how, ["moves"] = _dragMoves, ["x"] = frame.X, ["y"] = frame.Y });
        _handedBack |= ToolbarWindowStyle.HandBackForeground(Hwnd, Source);
    }

    // Size: the window follows the bar, its top-left corner fixed.

    private void OnBarLoaded(object sender, RoutedEventArgs e)
    {
        if (_closed || _xamlRoot is not null || Bar.XamlRoot is not { } root) return;
        _xamlRoot = root;
        root.Changed += OnXamlRootChanged;
        FitToBar();
    }

    /// <summary>A move to a monitor of another DPI: the same DIPs are another number of pixels.</summary>
    private void OnXamlRootChanged(XamlRoot sender, XamlRootChangedEventArgs args)
    {
        if (!_closed) FitToBar();
    }

    private void OnBarSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!_closed) FitToBar();
    }

    private void FitToBar()
    {
        if (_xamlRoot is null || Bar.ActualWidth <= 0 || Bar.ActualHeight <= 0) return;
        var scale = _xamlRoot.RasterizationScale;
        if (scale <= 0 || !double.IsFinite(scale)) return;
        _barSize = new Size(Bar.ActualWidth, Bar.ActualHeight);
        UpdateActivationRegion();
        var width = Pixels(_barSize.Width, scale);
        var height = Pixels(_barSize.Height, scale);
        var frame = ToolbarWindowStyle.WindowRect(Hwnd);
        if (frame.Width == width && frame.Height == height) return;
        ToolbarWindowStyle.Resize(Hwnd, width, height);
    }

    /// <summary>Layout rounding leaves whole pixels; the tolerance keeps a rounding error from adding one.</summary>
    private static int Pixels(double dips, double scale) => (int)Math.Ceiling(dips * scale - 0.01);

    // Log.

    /// <summary>The subclass's report, inside a window procedure: only queued here, logged with the next record.</summary>
    private void OnWindowMessage(ToolbarWindowMessage message)
    {
        if (message.Message == "WM_ACTIVATE" && message.Hwnd == Hwnd && message.Detail != "inactive") _wasForeground = true;
        lock (_messages) _messages.Add($"{Hex(message.Hwnd)} {message.ClassName} {message.Message} {message.Detail}");
    }

    private void Log(string evt, Dictionary<string, object?> fields)
    {
        string[] messages;
        lock (_messages)
        {
            messages = [.. _messages];
            _messages.Clear();
        }
        var record = new Dictionary<string, object?> { ["event"] = evt };
        foreach (var (key, value) in fields) record[key] = value;
        record["hwndMessages"] = messages;
        Logged?.Invoke(record);
    }

    internal static string Hex(nint hwnd) => "0x" + hwnd.ToString("X", CultureInfo.InvariantCulture);

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _closed = true;
        IsShown = false;
        _dragging = false;
        _dragTimer.Stop();
        _dragTimer.Tick -= OnDragTick;
        Activated -= OnActivated;
        PromptBox.LostFocus -= OnPromptLostFocus;
        PromptBox.SizeChanged -= OnPromptSizeChanged;
        ImproveButton.Click -= OnButtonClick;
        CopyButton.Click -= OnButtonClick;
        PasteButton.Click -= OnButtonClick;
        ImproveButton.PointerEntered -= OnImproveEntered;
        ImproveButton.PointerExited -= OnImproveExited;
        Bar.PointerPressed -= OnBackgroundPressed;
        Bar.PointerMoved -= OnPointerMoved;
        Bar.PointerReleased -= OnPointerReleased;
        Bar.PointerCaptureLost -= OnPointerCaptureLost;
        Bar.SizeChanged -= OnBarSizeChanged;
        Bar.Loaded -= OnBarLoaded;
        if (_xamlRoot is not null) _xamlRoot.Changed -= OnXamlRootChanged;
        _xamlRoot = null;
        Clicked = null;
        Logged = null;
    }

    /// <summary>
    /// DesktopAcrylic that stays active: WinUI's DesktopAcrylicBackdrop follows window activation and shows its solid
    /// fallback while the window is inactive, which a toolbar that never activates always is. This one drives the
    /// controller with its own configuration (never the default one, which WinUI updates on every activation change):
    /// input always active, the theme following the content's ActualTheme. Task 8.2 promotes it to
    /// App/Toolbar/ActiveAcrylicBackdrop.cs.
    /// </summary>
    private sealed partial class AlwaysActiveAcrylicBackdrop : SystemBackdrop
    {
        private DesktopAcrylicController? _controller;
        private SystemBackdropConfiguration? _configuration;
        private FrameworkElement? _root;

        protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop connectedTarget, XamlRoot xamlRoot)
        {
            base.OnTargetConnected(connectedTarget, xamlRoot);
            if (_controller is not null) return; // one window only
            _root = xamlRoot.Content as FrameworkElement;
            _configuration = new SystemBackdropConfiguration { IsInputActive = true, Theme = ThemeOf(_root) };
            _controller = new DesktopAcrylicController();
            _controller.SetSystemBackdropConfiguration(_configuration);
            _controller.AddSystemBackdropTarget(connectedTarget);
            if (_root is not null) _root.ActualThemeChanged += OnActualThemeChanged;
        }

        protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop disconnectedTarget)
        {
            base.OnTargetDisconnected(disconnectedTarget);
            if (_root is not null) _root.ActualThemeChanged -= OnActualThemeChanged;
            _root = null;
            if (_controller is not null)
            {
                _controller.RemoveSystemBackdropTarget(disconnectedTarget);
                _controller.Dispose();
                _controller = null;
            }
            _configuration = null;
        }

        private void OnActualThemeChanged(FrameworkElement sender, object args)
        {
            if (_configuration is not null) _configuration.Theme = ThemeOf(sender);
        }

        private static SystemBackdropTheme ThemeOf(FrameworkElement? root) => root?.ActualTheme switch
        {
            ElementTheme.Light => SystemBackdropTheme.Light,
            ElementTheme.Dark => SystemBackdropTheme.Dark,
            _ => SystemBackdropTheme.Default,
        };
    }
}
