using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using PopGuy.Controls;
using VirtualKey = Windows.System.VirtualKey;

namespace PopGuy.Settings.Panels;

/// <summary>
/// The Settings window's slide-over (macOS SlideOverPanel.swift): a dimmed backdrop over the whole window content and,
/// on the right, a sheet 3/4 of the window wide (never under 480 DIPs) that slides in. Esc or a click on the backdrop
/// closes it. One panel at a time: presenting another replaces it. The window hosts one above its content; a page finds
/// it with <see cref="Of"/>. The content lays out its own header with <see cref="HeaderPadding"/> (the macOS
/// ActionLibraryView structure: the same gap above and below the header, which never moves on resize). The backdrop and
/// sheet styles come from the window's XAML, so they follow the theme. UI thread only.
/// </summary>
public sealed partial class SlideOverPanel : Grid
{
    private const double WidthFraction = 0.75;
    private const double MinSheetWidth = 480;
    private static readonly TimeSpan SlideDuration = TimeSpan.FromMilliseconds(280);

    private readonly Border _backdrop;
    private readonly Border _sheet;
    private readonly TranslateTransform _slide = new();
    private Storyboard? _animation;
    private Action? _closed;
    private UIElement? _returnFocus;

    /// <param name="backdropStyle">A Border style: the dimming fill.</param>
    /// <param name="sheetStyle">A Border style: the sheet's opaque background and left edge.</param>
    public SlideOverPanel(Style backdropStyle, Style sheetStyle)
    {
        Visibility = Visibility.Collapsed;
        _backdrop = new Border { Style = backdropStyle, Opacity = 0 };
        _backdrop.Tapped += (_, e) =>
        {
            e.Handled = true;
            Close();
        };
        _sheet = new Border
        {
            Style = sheetStyle,
            HorizontalAlignment = HorizontalAlignment.Right,
            RenderTransform = _slide,
            // Tab stays in the sheet while it is open.
            TabFocusNavigation = KeyboardNavigationMode.Cycle,
        };
        Children.Add(_backdrop);
        Children.Add(_sheet);
        SizeChanged += (_, _) => UpdateWidth();
        KeyDown += OnKeyDown;
    }

    /// <summary>The header's padding: the page margin across, macOS cardPadding + 6 above and below.</summary>
    public static Thickness HeaderPadding { get; } = new(24, 18, 24, 18);

    public bool IsOpen { get; private set; }

    /// <summary>The panel of the window <paramref name="element"/> is in: a child of one of its ancestors.</summary>
    public static SlideOverPanel? Of(DependencyObject element)
    {
        for (var node = element; node is not null; node = VisualTreeHelper.GetParent(node))
        {
            if (node is not Panel panel) continue;
            foreach (var child in panel.Children)
            {
                if (child is SlideOverPanel found) return found;
            }
        }
        return null;
    }

    /// <summary>
    /// Shows <paramref name="content"/> at once and slides it in; <paramref name="initialFocus"/> (else the first control
    /// in it) takes the focus, so Esc reaches the panel. <paramref name="closed"/> runs once the panel has closed, however
    /// it closed.
    /// </summary>
    public void Present(FrameworkElement content, UIElement? initialFocus = null, Action? closed = null)
    {
        // Open or still sliding out: that one finishes first.
        if (_sheet.Child is not null) Finish();
        HoverTooltip.Dismiss();
        _returnFocus = XamlRoot is { } root ? FocusManager.GetFocusedElement(root) as UIElement : null;
        _closed = closed;
        _sheet.Child = content;
        IsOpen = true;
        Visibility = Visibility.Visible;
        UpdateWidth();
        Animate(opening: true);

        // Once the content is in the live tree.
        void FocusFirst()
        {
            if (IsOpen && _sheet.Child == content
                && (initialFocus ?? FocusManager.FindFirstFocusableElement(content) as UIElement) is { } first)
                first.Focus(FocusState.Programmatic);
        }
        RoutedEventHandler? loaded = null;
        loaded = (_, _) =>
        {
            content.Loaded -= loaded;
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, FocusFirst);
        };
        content.Loaded += loaded;
    }

    /// <summary>Slides the panel out; the content goes once it is out.</summary>
    public void Close()
    {
        if (!IsOpen) return;
        IsOpen = false;
        HoverTooltip.Dismiss();
        Animate(opening: false);
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Escape || !IsOpen) return;
        e.Handled = true;
        Close();
    }

    private void UpdateWidth()
    {
        var width = SheetWidth();
        if (width > 0) _sheet.Width = width;
    }

    /// <summary>3/4 of the host (never under 480, never over the host). The host's width: the panel is laid out only once shown.</summary>
    private double SheetWidth()
    {
        var width = Parent is FrameworkElement host && host.ActualWidth > 0 ? host.ActualWidth : ActualWidth;
        return Math.Min(width, Math.Max(width * WidthFraction, MinSheetWidth));
    }

    /// <summary>
    /// Slides the sheet in or out and fades the backdrop with it (macOS easeInOut, 0.28 s). The last animation holds its
    /// end values until the next one, or <see cref="Finish"/>, stops it.
    /// </summary>
    private void Animate(bool opening)
    {
        var distance = SheetWidth();
        var fromX = opening ? distance : _slide.X;
        var fromOpacity = opening ? 0 : _backdrop.Opacity;
        _animation?.Stop();
        var ease = new CubicEase { EasingMode = EasingMode.EaseInOut };
        var slide = new DoubleAnimation
        {
            From = fromX,
            To = opening ? 0 : distance,
            Duration = SlideDuration,
            EasingFunction = ease,
        };
        Storyboard.SetTarget(slide, _slide);
        Storyboard.SetTargetProperty(slide, "X");
        var fade = new DoubleAnimation
        {
            From = fromOpacity,
            To = opening ? 1 : 0,
            Duration = SlideDuration,
            EasingFunction = ease,
        };
        Storyboard.SetTarget(fade, _backdrop);
        Storyboard.SetTargetProperty(fade, "Opacity");
        var animation = _animation = new Storyboard();
        animation.Children.Add(slide);
        animation.Children.Add(fade);
        animation.Completed += (_, _) =>
        {
            if (_animation == animation && !opening) Finish();
        };
        animation.Begin();
    }

    /// <summary>The panel is out: hidden, its content let go, the focus back where it was, the caller told.</summary>
    private void Finish()
    {
        _animation?.Stop();
        _animation = null;
        IsOpen = false;
        Visibility = Visibility.Collapsed;
        _sheet.Child = null;
        var closed = _closed;
        var returnFocus = _returnFocus;
        _closed = null;
        _returnFocus = null;
        returnFocus?.Focus(FocusState.Programmatic);
        closed?.Invoke();
    }
}
