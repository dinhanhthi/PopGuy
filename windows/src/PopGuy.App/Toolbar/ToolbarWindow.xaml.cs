using System.ComponentModel;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PopGuy.Core.Toolbar;
using PopGuy.Platform.SystemServices;
using PopGuy.Platform.Windowing;
using DrawingPoint = System.Drawing.Point;
using DrawingRectangle = System.Drawing.Rectangle;
using DrawingSize = System.Drawing.Size;

namespace PopGuy.Toolbar;

/// <summary>
/// The floating toolbar (spec-1 §3.1): a borderless, topmost tool window that never takes the foreground from the
/// source app (the app whose text is selected). Tier 1 of the plan, lifted from the Phase 3 spike: WS_EX_NOACTIVATE
/// plus <c>AllowFocusOnInteraction="False"</c> buttons, a WM_MOUSEACTIVATE → MA_NOACTIVATE subclass on every HWND, and
/// a foreground hand-back after each press. It shows <see cref="ViewModel"/>; the controller wires the view model's
/// events and calls <see cref="ShowAt"/> and <see cref="Hide"/>. Points and rects are physical screen pixels. UI
/// thread only.
/// </summary>
public sealed partial class ToolbarWindow : Window
{
    /// <summary>The size before the card's first layout (spec-1 §3.1: 280×50 DIP).</summary>
    private const double StartWidth = 280;
    private const double StartHeight = 50;

    /// <summary>The body's minimum width, so a short bar does not wrap the result into a narrow column (spec-1 §3.3).</summary>
    private const double MinBodyWidth = 340;

    /// <summary>The work area when no monitor can be read (spec-1 §3.2).</summary>
    private static readonly DrawingRectangle FallbackWorkArea = new(0, 0, 1280, 800);

    /// <summary>How long Copy shows "Copied" (macOS: the checkmark for 500 ms).</summary>
    private static readonly TimeSpan CopiedInterval = TimeSpan.FromMilliseconds(500);

    /// <summary>How often a drag reads the pointer (the window cannot capture it while it is not the foreground).</summary>
    private static readonly TimeSpan DragPollInterval = TimeSpan.FromMilliseconds(15);

    private readonly DispatcherQueueTimer _dragTimer;
    private readonly DispatcherQueueTimer _copiedTimer;
    private readonly DiffView _diffView;
    private bool _closed;
    private bool _dragging;
    private XamlRoot? _xamlRoot;

    /// <summary>The window to hand the foreground back to: the source, or the foreground window at the last press.</summary>
    private nint _handBackTo;

    /// <summary>The work area the toolbar is kept in: the selection's monitor at show, the window's after a drag.</summary>
    private DrawingRectangle _workArea = FallbackWorkArea;

    /// <summary>The drag's start: the pointer and the window's top-left corner.</summary>
    private DrawingPoint _dragPointer;
    private DrawingPoint _dragOrigin;

    /// <summary>The card's last laid-out size in DIPs; the start size before the first layout.</summary>
    private Windows.Foundation.Size _cardSize = new(StartWidth, StartHeight);

    public ToolbarWindow(ToolbarSession session)
    {
        ViewModel = new ToolbarViewModel(session, DispatcherQueue.GetForCurrentThread());
        InitializeComponent();
        // A Window's x:Bind bindings start on its content's Loading, which this never-activated window did not get
        // (VM QA: every state panel showed at once). Start them now; ShowAt refreshes them again.
        Bindings.Update();

        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(false, false);
            presenter.IsResizable = false;
        }
        Hwnd = Win32Interop.GetWindowFromWindowId(AppWindow.Id);
        // Before the first show: Windows reads WS_EX_TOOLWINDOW (no taskbar button, not in Alt+Tab) at show time.
        ToolbarWindowStyle.Apply(Hwnd);

        if (DesktopAcrylicController.IsSupported())
            SystemBackdrop = new ActiveAcrylicBackdrop();
        else
            RootCanvas.Background = (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"];

        _dragTimer = DispatcherQueue.CreateTimer();
        _dragTimer.Interval = DragPollInterval;
        _dragTimer.IsRepeating = true;
        _dragTimer.Tick += OnDragTick;
        _copiedTimer = DispatcherQueue.CreateTimer();
        _copiedTimer.Interval = CopiedInterval;
        _copiedTimer.IsRepeating = false;
        _copiedTimer.Tick += OnCopiedTick;

        CloseButton.Click += OnCloseClick;
        StopButton.Click += OnStopClick;
        CopyButton.Click += OnCopyClick;
        PasteBackButton.Click += OnPasteBackClick;
        RegenerateButton.Click += OnRegenerateClick;
        RetryButton.Click += OnRegenerateClick;
        CloseAnywayButton.Click += OnCloseAnywayClick;
        DisableConfirmButton.Click += OnDisableConfirmClick;
        KeepOpenButton.Click += OnKeepOpenClick;
        DiffModeButton.Click += OnDiffModeClick;
        TextModeButton.Click += OnTextModeClick;
        _diffView = new DiffView(DiffBlock, OnHunkClick);
        SyncDiffMode();
        ViewModel.PropertyChanged += OnViewModelChanged;

        // Every press and release, the buttons' (handled) too: the foreground hand-back.
        Card.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(OnAnyPointerPressed), true);
        Card.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(OnAnyPointerReleased), true);
        // Drag: presses outside the buttons and the selectable text reach these (those controls handle theirs).
        Card.PointerPressed += OnBackgroundPressed;
        Card.PointerMoved += OnPointerMoved;
        Card.PointerReleased += OnPointerReleased;
        Card.PointerCaptureLost += OnPointerCaptureLost;

        Bar.SizeChanged += OnBarSizeChanged;
        Card.SizeChanged += OnCardSizeChanged;
        Card.Loaded += OnCardLoaded;
        Closed += OnClosed;
        RebuildActionRow();
    }

    public ToolbarViewModel ViewModel { get; }

    /// <summary>The toolbar's window handle.</summary>
    public nint Hwnd { get; }

    /// <summary>The toolbar is on screen.</summary>
    public bool IsShown { get; private set; }

    /// <summary>The user dragged the toolbar since the last show (the controller stops repositioning it then).</summary>
    public bool UserDragged { get; private set; }

    /// <summary>
    /// Shows the toolbar for <paramref name="source"/> without activating it, placed by
    /// <see cref="PanelPositioning.PanelOrigin"/> (spec-1 §3.2) in the work area of the monitor holding the selection.
    /// Call <see cref="ToolbarViewModel.Present"/> first, so the toolbar is sized for the new content. Also re-presents
    /// a toolbar that is already showing: the position is recomputed, unless the user dragged the toolbar since it was
    /// shown (a drag disables auto-reposition until the next show; the size still follows the content).
    /// </summary>
    /// <param name="pointer">The gesture's release point; null for the chord and the hotkeys (placed below the selection).</param>
    /// <param name="grewDownward">The drag direction; null when unknown.</param>
    /// <param name="selection">The selection's screen rect; an empty one means a zero-size rect at the pointer (or the cursor).</param>
    public void ShowAt(DrawingPoint? pointer, bool? grewDownward, DrawingRectangle selection, ForegroundApp source)
    {
        if (_closed) return;
        StopDrag();
        _handBackTo = source.Hwnd;
        if (IsShown && UserDragged)
        {
            // Where the user put it, in the work area of the monitor it was dropped on; FitToCard resizes it.
            AppWindow.Show(activateWindow: false);
            return;
        }
        UserDragged = false;

        var selectionRect = selection.Width > 0 && selection.Height > 0
            ? selection
            : new DrawingRectangle(pointer ?? ToolbarWindowStyle.CursorPosition(), DrawingSize.Empty);
        var midpoint = new DrawingPoint(selectionRect.Left + selectionRect.Width / 2, selectionRect.Top + selectionRect.Height / 2);
        var work = MonitorInfo.WorkArea(midpoint);
        _workArea = work.IsEmpty ? FallbackWorkArea : work;

        // The new content's size now, not after the show (layout runs on this thread).
        Bindings.Update();
        Card.UpdateLayout();
        if (Card.ActualWidth > 0 && Card.ActualHeight > 0) _cardSize = new(Card.ActualWidth, Card.ActualHeight);
        var scale = MonitorInfo.Scale(midpoint);
        var frame = ToolbarWindowStyle.FrameExtent(Hwnd);
        var size = new DrawingSize(Pixels(_cardSize.Width, scale) + frame.Width, Pixels(_cardSize.Height, scale) + frame.Height);
        var origin = PanelPositioning.PanelOrigin(size, selectionRect, _workArea, pointer, grewDownward);
        ToolbarWindowStyle.SetBounds(Hwnd, new DrawingRectangle(origin, size));

        // Never Activate(): it would take the foreground from the source app.
        AppWindow.Show(activateWindow: false);
        IsShown = true;

        // The XAML input-site windows exist only once the window is shown; windows already subclassed are skipped.
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_closed) return;
            try
            {
                ToolbarWindowStyle.SubclassNoActivate(Hwnd, null);
            }
            catch (Exception)
            {
                // Tier 1 goes on without the subclass lever (WS_EX_NOACTIVATE and the hand-back still hold).
            }
        });
    }

    /// <summary>
    /// Hides the toolbar and stops any run (Phase 8 → 8.3: every hide stops the session). The foreground goes back to
    /// the source only if the toolbar has it (after a click elsewhere, the clicked window keeps it).
    /// </summary>
    public void Hide()
    {
        if (_closed || !IsShown) return;
        StopDrag();
        ToolbarWindowStyle.HandBackForeground(Hwnd, _handBackTo);
        AppWindow.Hide();
        IsShown = false;
        UserDragged = false;
        ViewModel.Stop();
    }

    /// <summary>The point is on the toolbar's window (the outside-click check).</summary>
    public bool Contains(DrawingPoint point) => ToolbarWindowStyle.WindowRect(Hwnd).Contains(point);

    // The action row: built from the view model's items (the row is dynamic, from the settings).

    private void RebuildActionRow()
    {
        foreach (var child in ActionRow.Children)
        {
            if (child is Button old) old.Click -= OnActionClick;
        }
        ActionRow.Children.Clear();
        var symbols = Application.Current.Resources.TryGetValue("SymbolThemeFontFamily", out var found) && found is FontFamily family
            ? family
            : new FontFamily("Segoe Fluent Icons");
        foreach (var item in ViewModel.Actions)
        {
            FrameworkElement icon = item.Emoji is { } emoji
                ? new TextBlock { Text = emoji, VerticalAlignment = VerticalAlignment.Center }
                : new FontIcon
                {
                    FontFamily = symbols,
                    FontSize = 14,
                    Glyph = item.Glyph ?? "",
                };
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            content.Children.Add(icon);
            content.Children.Add(new TextBlock { Text = item.Label, VerticalAlignment = VerticalAlignment.Center });
            var button = new Button
            {
                Content = content,
                Tag = item,
                AllowFocusOnInteraction = false,
                VerticalAlignment = VerticalAlignment.Center,
                IsEnabled = ViewModel.ActionsEnabled,
            };
            button.Click += OnActionClick;
            ActionRow.Children.Add(button);
        }
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (_closed) return;
        switch (e.PropertyName)
        {
            case nameof(ToolbarViewModel.Actions):
                RebuildActionRow();
                break;
            case nameof(ToolbarViewModel.ActionsEnabled):
                foreach (var child in ActionRow.Children)
                {
                    if (child is Button button) button.IsEnabled = ViewModel.ActionsEnabled;
                }
                break;
            case nameof(ToolbarViewModel.IsResult):
                if (!ViewModel.IsResult) ResetCopyButton();
                break;
            case nameof(ToolbarViewModel.ShowDiff):
                SyncDiffMode();
                break;
            case nameof(ToolbarViewModel.ShowsDiffView):
                // Rebuilt only when the diff or the rejected hunks change (DiffView compares the snapshots).
                if (ViewModel.ShowsDiffView) _diffView.Show(ViewModel.DiffSegments, ViewModel.RejectedHunks);
                break;
        }
    }

    /// <summary>The Diff/Text toggle shows the view model's choice (a click toggles a ToggleButton by itself).</summary>
    private void SyncDiffMode()
    {
        DiffModeButton.IsChecked = ViewModel.ShowDiff;
        TextModeButton.IsChecked = !ViewModel.ShowDiff;
    }

    // Clicks.

    private void OnActionClick(object sender, RoutedEventArgs e)
    {
        if (!_closed && sender is Button { Tag: ToolbarActionItem item }) ViewModel.Invoke(item.Id);
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.RequestClose();
    }

    private void OnStopClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.RequestStop();
    }

    private void OnCopyClick(object sender, RoutedEventArgs e)
    {
        if (_closed) return;
        ViewModel.RequestCopy();
        // The confirmation shows at once (click reacts first): the checkmark and "Copied" for 500 ms.
        CopyIcon.Glyph = "\uE73E";
        CopyLabel.Text = "Copied";
        _copiedTimer.Stop();
        _copiedTimer.Start();
    }

    private void OnCopiedTick(DispatcherQueueTimer sender, object args)
    {
        sender.Stop();
        if (!_closed) ResetCopyButton();
    }

    private void ResetCopyButton()
    {
        _copiedTimer.Stop();
        CopyIcon.Glyph = "\uE8C8";
        CopyLabel.Text = "Copy";
    }

    private void OnPasteBackClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.RequestPasteBack();
    }

    private void OnRegenerateClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.Regenerate();
    }

    private void OnCloseAnywayClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.RequestCloseAnyway();
    }

    private void OnDisableConfirmClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.RequestDisableCloseConfirmation();
    }

    private void OnKeepOpenClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.KeepOpen();
    }

    private void OnDiffModeClick(object sender, RoutedEventArgs e)
    {
        if (_closed) return;
        ViewModel.SetShowDiff(true);
        SyncDiffMode();
    }

    private void OnTextModeClick(object sender, RoutedEventArgs e)
    {
        if (_closed) return;
        ViewModel.SetShowDiff(false);
        SyncDiffMode();
    }

    private void OnHunkClick(int hunk)
    {
        if (!_closed) ViewModel.ToggleHunk(hunk);
    }

    // The foreground hand-back: WS_EX_NOACTIVATE does not hold for every press, so after each one the source gets the
    // foreground back if the toolbar took it.

    private void OnAnyPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_closed) return;
        // The window to hand back to: the foreground now, unless it is the toolbar (then the one from before).
        var foreground = ToolbarWindowStyle.RememberForeground(Hwnd);
        if (foreground != 0) _handBackTo = foreground;
    }

    private void OnAnyPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_closed) return;
        // After the click handlers (a paste must run while PopGuy may still set the foreground).
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_closed && !_dragging) ToolbarWindowStyle.HandBackForeground(Hwnd, _handBackTo);
        });
    }

    // Drag: no title bar, so a press on the card's background (Transparent, so it hit-tests) moves the window by how far
    // the pointer moved since the press. A window that is not the foreground cannot really capture the pointer, so the
    // drag also reads the pointer and the button every 15 ms and ends when the button is up.

    private void OnBackgroundPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_closed || _dragging || !e.GetCurrentPoint(Card).Properties.IsLeftButtonPressed) return;
        Card.CapturePointer(e.Pointer);
        _dragPointer = ToolbarWindowStyle.CursorPosition();
        _dragOrigin = ToolbarWindowStyle.WindowRect(Hwnd).Location;
        _dragging = true;
        _dragTimer.Start();
        e.Handled = true;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging || _closed) return;
        DragToPointer();
        e.Handled = true;
    }

    private void OnDragTick(DispatcherQueueTimer sender, object args)
    {
        if (!_dragging || _closed)
        {
            sender.Stop();
            return;
        }
        if (!ToolbarWindowStyle.IsPrimaryButtonDown())
        {
            // Released where the window did not see it (outside it, without a capture).
            EndDrag();
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
        if (ToolbarWindowStyle.Move(Hwnd, x, y)) UserDragged = true;
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging) return;
        DragToPointer();
        if (!_closed) Card.ReleasePointerCapture(e.Pointer);
        e.Handled = true;
        EndDrag();
    }

    private void OnPointerCaptureLost(object sender, PointerRoutedEventArgs e)
    {
        // Without a real capture, the capture goes as soon as the pointer leaves: the poll goes on until the button is up.
        if (_dragging && !ToolbarWindowStyle.IsPrimaryButtonDown()) EndDrag();
    }

    /// <summary>The drag is over: later resizes keep the toolbar in the work area of the monitor it was dropped on.</summary>
    private void EndDrag()
    {
        StopDrag();
        if (_closed) return;
        var frame = ToolbarWindowStyle.WindowRect(Hwnd);
        if (!frame.IsEmpty)
        {
            var work = MonitorInfo.WorkArea(new DrawingPoint(frame.Left + frame.Width / 2, frame.Top + frame.Height / 2));
            if (!work.IsEmpty) _workArea = work;
        }
        ToolbarWindowStyle.HandBackForeground(Hwnd, _handBackTo);
    }

    private void StopDrag()
    {
        _dragging = false;
        _dragTimer.Stop();
    }

    // Size: the window follows the card, its top edge fixed, then clamped into the work area (spec-1 §3.1-3.2).

    private void OnCardLoaded(object sender, RoutedEventArgs e)
    {
        if (_closed || _xamlRoot is not null || Card.XamlRoot is not { } root) return;
        _xamlRoot = root;
        root.Changed += OnXamlRootChanged;
        FitToCard();
    }

    /// <summary>A move to a monitor of another DPI: the same DIPs are another number of pixels.</summary>
    private void OnXamlRootChanged(XamlRoot sender, XamlRootChangedEventArgs args)
    {
        if (!_closed) FitToCard();
    }

    /// <summary>The body is as wide as the bar, and at least <see cref="MinBodyWidth"/>, so its text wraps (spec-1 §3.3).</summary>
    private void OnBarSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!_closed) Body.Width = Math.Max(Bar.ActualWidth, MinBodyWidth);
    }

    private void OnCardSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!_closed) FitToCard();
    }

    private void FitToCard()
    {
        if (_xamlRoot is null || Card.ActualWidth <= 0 || Card.ActualHeight <= 0) return;
        var scale = _xamlRoot.RasterizationScale;
        if (scale <= 0 || !double.IsFinite(scale)) return;
        _cardSize = new(Card.ActualWidth, Card.ActualHeight);
        // The window is the card plus the frame Windows keeps around the client area.
        var extent = ToolbarWindowStyle.FrameExtent(Hwnd);
        var width = Pixels(_cardSize.Width, scale) + extent.Width;
        var height = Pixels(_cardSize.Height, scale) + extent.Height;
        var frame = ToolbarWindowStyle.WindowRect(Hwnd);
        if (frame.IsEmpty || (frame.Width == width && frame.Height == height)) return;

        // Keep the top-left, then clamp; wider or taller than the work area pins to its left or top edge (Max last).
        var inset = PanelPositioning.PanelEdgeInset;
        var x = Math.Max(Math.Min(frame.X, _workArea.Right - width - inset), _workArea.Left + inset);
        var y = Math.Max(Math.Min(frame.Y, _workArea.Bottom - height - inset), _workArea.Top + inset);
        ToolbarWindowStyle.SetBounds(Hwnd, new DrawingRectangle(x, y, width, height));
    }

    /// <summary>Layout rounding leaves whole pixels; the tolerance keeps a rounding error from adding one.</summary>
    private static int Pixels(double dips, double scale) => (int)Math.Ceiling(dips * scale - 0.01);

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _closed = true;
        IsShown = false;
        StopDrag();
        _dragTimer.Tick -= OnDragTick;
        _copiedTimer.Stop();
        _copiedTimer.Tick -= OnCopiedTick;
        CloseButton.Click -= OnCloseClick;
        StopButton.Click -= OnStopClick;
        CopyButton.Click -= OnCopyClick;
        PasteBackButton.Click -= OnPasteBackClick;
        RegenerateButton.Click -= OnRegenerateClick;
        RetryButton.Click -= OnRegenerateClick;
        CloseAnywayButton.Click -= OnCloseAnywayClick;
        DisableConfirmButton.Click -= OnDisableConfirmClick;
        KeepOpenButton.Click -= OnKeepOpenClick;
        DiffModeButton.Click -= OnDiffModeClick;
        TextModeButton.Click -= OnTextModeClick;
        foreach (var child in ActionRow.Children)
        {
            if (child is Button button) button.Click -= OnActionClick;
        }
        ViewModel.PropertyChanged -= OnViewModelChanged;
        ViewModel.Detach();
        Card.PointerPressed -= OnBackgroundPressed;
        Card.PointerMoved -= OnPointerMoved;
        Card.PointerReleased -= OnPointerReleased;
        Card.PointerCaptureLost -= OnPointerCaptureLost;
        Bar.SizeChanged -= OnBarSizeChanged;
        Card.SizeChanged -= OnCardSizeChanged;
        Card.Loaded -= OnCardLoaded;
        if (_xamlRoot is not null) _xamlRoot.Changed -= OnXamlRootChanged;
        _xamlRoot = null;
    }
}
