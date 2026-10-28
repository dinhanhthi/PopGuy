using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace PopGuy.Controls;

/// <summary>
/// The fast hover tooltip (macOS <c>ToolbarTooltipModifier</c> and <c>HoverTooltip.swift</c>): the only tooltip in the
/// app, since the default WinUI tooltip's delay cannot be made short enough (the Windows form of the <c>.help()</c> ban).
/// Set <see cref="TextProperty"/> on an element: 120 ms after the pointer enters it, a Popup shows the text below it,
/// right-aligned with it (left-aligned when that would start left of the window). The Popup is unconstrained (its own
/// window, so it may extend past a small window) and not hit-testable; the Phase 3 spike showed it never activates the
/// toolbar. Any press on the element hides it until the pointer enters again. One tooltip at a time. UI thread only.
/// </summary>
public static class HoverTooltip
{
    /// <summary>How long the pointer rests on the element first (macOS: 120 ms, instant but no flicker on a pass).</summary>
    private static readonly TimeSpan Delay = TimeSpan.FromMilliseconds(120);

    /// <summary>The space between the element and the tooltip.</summary>
    private const double Gap = 4;

    /// <summary>Longer text wraps (macOS: 300).</summary>
    private const double MaxTextWidth = 300;

    public static readonly DependencyProperty TextProperty = DependencyProperty.RegisterAttached(
        "Text", typeof(string), typeof(HoverTooltip), new PropertyMetadata(null, OnTextChanged));

    private static readonly PointerEventHandler EnteredHandler = OnPointerEntered;
    private static readonly PointerEventHandler ExitedHandler = OnPointerExited;
    private static readonly PointerEventHandler PressedHandler = OnPointerPressed;
    private static readonly RoutedEventHandler UnloadedHandler = OnUnloaded;

    private static DispatcherQueueTimer? _timer;
    private static Popup? _popup;
    private static TextBlock? _label;

    /// <summary>The element under the pointer: waiting for the delay, or showing its tooltip.</summary>
    private static FrameworkElement? _hovered;

    /// <summary>
    /// The element last pressed: no tooltip until the pointer really leaves it. A button disabled while its action runs
    /// and enabled again gets a new pointer-entered with the pointer still on it (VM QA: the tooltip came back after a click).
    /// </summary>
    private static FrameworkElement? _pressed;

    public static string? GetText(DependencyObject element) => (string?)element.GetValue(TextProperty);

    /// <summary>Sets the tooltip of <paramref name="element"/>; null or empty removes it.</summary>
    public static void SetText(DependencyObject element, string? value) => element.SetValue(TextProperty, value);

    /// <summary>Hides the tooltip now (its window hides, a menu opens).</summary>
    public static void Dismiss()
    {
        _timer?.Stop();
        _hovered = null;
        if (_popup is not null) _popup.IsOpen = false;
    }

    private static void OnTextChanged(DependencyObject sender, DependencyPropertyChangedEventArgs e)
    {
        if (sender is not FrameworkElement element) return;
        var had = !string.IsNullOrEmpty(e.OldValue as string);
        var has = !string.IsNullOrEmpty(e.NewValue as string);
        if (has && !had)
        {
            element.PointerEntered += EnteredHandler;
            element.PointerExited += ExitedHandler;
            element.PointerCanceled += ExitedHandler;
            // Buttons handle their presses: listen to handled ones too.
            element.AddHandler(UIElement.PointerPressedEvent, PressedHandler, true);
            element.Unloaded += UnloadedHandler;
        }
        else if (had && !has)
        {
            element.PointerEntered -= EnteredHandler;
            element.PointerExited -= ExitedHandler;
            element.PointerCanceled -= ExitedHandler;
            element.RemoveHandler(UIElement.PointerPressedEvent, PressedHandler);
            element.Unloaded -= UnloadedHandler;
            if (_hovered == element) Dismiss();
        }
        else if (has && _hovered == element && _label is not null)
        {
            _label.Text = (string)e.NewValue;
        }
    }

    private static void OnPointerEntered(object sender, PointerRoutedEventArgs e)
    {
        if (sender is not FrameworkElement element || ReferenceEquals(_pressed, element)) return;
        Dismiss();
        _hovered = element;
        _timer ??= CreateTimer();
        _timer.Start();
    }

    private static void OnPointerExited(object sender, PointerRoutedEventArgs e)
    {
        if (ReferenceEquals(_hovered, sender)) Dismiss();
        if (ReferenceEquals(_pressed, sender) && sender is FrameworkElement element)
        {
            // An exit with the pointer still inside (the element was disabled) keeps the suppression.
            var point = e.GetCurrentPoint(element).Position;
            if (point.X < 0 || point.Y < 0 || point.X >= element.ActualWidth || point.Y >= element.ActualHeight) _pressed = null;
        }
    }

    private static void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        Dismiss();
        _pressed = sender as FrameworkElement;
    }

    private static void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (ReferenceEquals(_hovered, sender)) Dismiss();
        if (ReferenceEquals(_pressed, sender)) _pressed = null;
    }

    private static DispatcherQueueTimer CreateTimer()
    {
        var timer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        timer.Interval = Delay;
        timer.IsRepeating = false;
        timer.Tick += OnTick;
        return timer;
    }

    private static void OnTick(DispatcherQueueTimer sender, object args)
    {
        sender.Stop();
        if (_hovered is not { XamlRoot: { } root } element || GetText(element) is not { Length: > 0 } text) return;
        if (element.ActualWidth <= 0 || element.Visibility != Visibility.Visible) return;
        var popup = PopupFor(root);
        _label!.Text = text;
        var bubble = (FrameworkElement)popup.Child;
        bubble.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        // In the window's coordinates, the element's render transforms (the toolbar zoom) included.
        var bounds = element.TransformToVisual(null).TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));
        var x = bounds.Right - bubble.DesiredSize.Width;
        popup.HorizontalOffset = x < 0 ? bounds.Left : x;
        popup.VerticalOffset = bounds.Bottom + Gap;
        popup.IsOpen = true;
    }

    /// <summary>The tooltip's Popup for the window of <paramref name="root"/>, made the first time (and after a window change).</summary>
    private static Popup PopupFor(XamlRoot root)
    {
        if (_popup is not null && _popup.XamlRoot == root) return _popup;
        if (_popup is not null) _popup.IsOpen = false;
        _label = new TextBlock
        {
            Foreground = Resource<Brush>("ToolTipForeground"),
            Style = Resource<Style>("CaptionTextBlockStyle"),
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = MaxTextWidth,
        };
        var bubble = new Border
        {
            Padding = new Thickness(8, 5, 8, 7),
            Background = Resource<Brush>("ToolTipBackground"),
            BorderBrush = Resource<Brush>("ToolTipBorderBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = Resource<CornerRadius>("OverlayCornerRadius"),
            IsHitTestVisible = false,
            Child = _label,
        };
        _popup = new Popup
        {
            XamlRoot = root,
            Child = bubble,
            IsLightDismissEnabled = false,
            ShouldConstrainToRootBounds = false,
        };
        return _popup;
    }

    private static T Resource<T>(string key) => (T)Application.Current.Resources[key];
}
