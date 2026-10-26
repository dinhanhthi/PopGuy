using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using PopGuy.Controls;
using PopGuy.Platform.Windowing;
using PopGuy.Services;
using PopGuy.Settings.Pages;
using Windows.Graphics;
using Windows.UI;
using DrawingPoint = System.Drawing.Point;

namespace PopGuy.Settings;

/// <summary>
/// The Settings window (spec-3 §5, macOS SettingsView.swift): one at a time, made by the App when it opens and let go
/// when it closes (the tray keeps PopGuy running). It opens at its saved frame (<see cref="FrameFile"/>), else 760×520
/// centered on its display, never below 680×460 (DIPs, in physical pixels at the window's DPI). A sidebar pick switches
/// the selection and the header at once; its page is made on a later dispatcher turn, so the click never waits for it.
/// Pages get the <see cref="AppServices"/> as their navigation parameter. UI thread only.
/// </summary>
public sealed partial class SettingsWindow : Window
{
    private const double MinWidth = 680;
    private const double MinHeight = 460;
    private const double DefaultWidth = 760;
    private const double DefaultHeight = 520;

    /// <summary>The pages by sidebar item Tag, with their header glyph (Segoe Fluent Icons); a phase adds its page here.</summary>
    private static readonly Dictionary<string, (Type Page, string Glyph)> Pages = new()
    {
        ["General"] = (typeof(GeneralPage), "\uE713"),
        ["Providers"] = (typeof(ProvidersPage), "\uE8D7"),
        ["Triggers"] = (typeof(TriggersPage), "\uE7C9"),
        ["Appearance"] = (typeof(AppearancePage), "\uE771"),
    };

    private readonly AppServices _services;
    private readonly OverlappedPresenter _presenter;
    private readonly string _frameFile;

    /// <summary>The scale the presenter's minimum size was computed for.</summary>
    private double? _appliedScale;

    private XamlRoot? _xamlRoot;
    private bool _closing;

    /// <summary>The one-shot re-realizations after the first show, kept so they tick.</summary>
    private DispatcherQueueTimer? _presentedTimer;
    private DispatcherQueueTimer? _backstopTimer;

    internal SettingsWindow(AppServices services)
    {
        _services = services;
        _frameFile = FrameFile(services);
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        ApplyCaptionButtonColors();
        RootGrid.ActualThemeChanged += OnActualThemeChanged;

        // Without the +commit suffix the SDK appends to the informational version.
        VersionText.Text = $"PopGuy v{App.Version.Split('+')[0]}";

        _presenter = (OverlappedPresenter)AppWindow.Presenter;
        Place();

        Nav.SelectionChanged += OnSelectionChanged;
        Nav.SelectedItem = Nav.MenuItems[0];
        ShowSection("General");

        RootGrid.Loaded += OnRootLoaded;
        Activated += OnFirstActivated;
        Activated += OnActivated;
        Closed += OnClosed;
    }

    /// <summary>Brings the window to the front: restored if minimized, then activated.</summary>
    internal void Show()
    {
        if (_presenter.State == OverlappedPresenterState.Minimized) _presenter.Restore();
        Activate();
    }

    // Sections.

    private void OnSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem { Tag: string tag }) ShowSection(tag);
    }

    /// <summary>The header now; the page on a later, low-priority dispatcher turn (a later pick wins).</summary>
    private void ShowSection(string tag)
    {
        if (!Pages.TryGetValue(tag, out var section)) return;
        HeaderIcon.Glyph = section.Glyph;
        HeaderTitle.Text = Nav.SelectedItem is NavigationViewItem { Content: string title } ? title : tag;
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            if (_closing || Nav.SelectedItem is not NavigationViewItem { Tag: string current } || current != tag) return;
            if (ContentFrame.CurrentSourcePageType == section.Page) return;
            ContentFrame.Navigate(section.Page, _services, new SuppressNavigationTransitionInfo());
        });
    }

    // Lifetime.

    private void OnRootLoaded(object sender, RoutedEventArgs e)
    {
        if (_xamlRoot is not null || RootGrid.XamlRoot is not { } root) return;
        _xamlRoot = root;
        root.Changed += OnXamlRootChanged;
    }

    /// <summary>A move to a display of another DPI changes the minimum size in physical pixels.</summary>
    private void OnXamlRootChanged(XamlRoot sender, XamlRootChangedEventArgs args)
    {
        if (!_closing) ApplyMinimumSize();
    }

    /// <summary>A shortcut recording ends when the window goes to the back: PopGuy's hotkeys are off while it records.</summary>
    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated) ShortcutRecorder.CancelActive();
    }

    /// <summary>Saves the frame while the window still answers, then lets go of everything that would call it.</summary>
    private void OnClosed(object sender, WindowEventArgs args)
    {
        _closing = true;
        ShortcutRecorder.CancelActive();
        SaveFrame();
        Nav.SelectionChanged -= OnSelectionChanged;
        RootGrid.ActualThemeChanged -= OnActualThemeChanged;
        RootGrid.Loaded -= OnRootLoaded;
        if (_xamlRoot is not null) _xamlRoot.Changed -= OnXamlRootChanged;
        Activated -= OnFirstActivated;
        Activated -= OnActivated;
        CompositionTarget.Rendering -= OnFirstPresentedRendering;
        _presentedTimer?.Stop();
        _backstopTimer?.Stop();
        // Unloads the page now, so it drops its settings subscription (a closed window may never raise Unloaded).
        ContentFrame.Content = null;
        Closed -= OnClosed;
    }

    // First show (README Follow-ups, Phase 2 QA): on the first launch of a new build the window can show Mica and the
    // caption buttons but no XAML text until the next layout. A text element makes its glyphs again only when it leaves
    // the tree and enters it again (EchoDiar's VM finding), so everything below the title bar is taken out and put back
    // in the same tick: 300 ms after the first presented frame, and once more 1.5 s after the window first shows.

    private void OnFirstActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated) return;
        Activated -= OnFirstActivated;
        CompositionTarget.Rendering += OnFirstPresentedRendering;
        _backstopTimer = StartOnce(TimeSpan.FromSeconds(1.5));
    }

    /// <summary>The first Rendering whose rendering time has started: the loss comes after the earlier ones.</summary>
    private void OnFirstPresentedRendering(object? sender, object e)
    {
        if (!_closing && (e is not RenderingEventArgs args || args.RenderingTime <= TimeSpan.Zero)) return;
        CompositionTarget.Rendering -= OnFirstPresentedRendering;
        if (!_closing) _presentedTimer = StartOnce(TimeSpan.FromMilliseconds(300));
    }

    private DispatcherQueueTimer StartOnce(TimeSpan delay)
    {
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = delay;
        timer.IsRepeating = false;
        timer.Tick += (t, _) =>
        {
            t.Stop();
            Reattach();
        };
        timer.Start();
        return timer;
    }

    /// <summary>Skipped while closing, minimized or hidden. In the same tick, so no layout pass sees the content out.</summary>
    private void Reattach()
    {
        if (_closing || _presenter.State == OverlappedPresenterState.Minimized || !AppWindow.IsVisible) return;
        var content = RootHost.Content;
        RootHost.Content = null;
        RootHost.Content = content;
    }

    // Frame: the outer frame's top-left in physical screen pixels, its size in DIPs (so it keeps its size across DPIs).

    private sealed record SavedFrame(int X, int Y, double Width, double Height);

    /// <summary><c>settings-window.json</c> next to the settings (<c>POPGUY_DATA_ROOT</c> moves it too).</summary>
    private static string FrameFile(AppServices services) =>
        Path.Combine(services.Paths.DataDirectory, "settings-window.json");

    /// <summary>The first frame: the saved one when it meets a connected display (clamped to its work area), else centered.</summary>
    private void Place()
    {
        ApplyMinimumSize();
        AppWindow.MoveAndResize(RestoredFrame() ?? CenteredFrame());
        // It may have moved to a display of another DPI.
        ApplyMinimumSize();
    }

    /// <summary>The presenter's minimum in physical pixels at the window's DPI.</summary>
    private void ApplyMinimumSize()
    {
        var scale = WindowScale();
        if (_appliedScale == scale) return;
        _appliedScale = scale;
        _presenter.PreferredMinimumWidth = Px(MinWidth, scale);
        _presenter.PreferredMinimumHeight = Px(MinHeight, scale);
    }

    /// <summary>On close; not while maximized or minimized, nor below the minimum size. A failed write is logged.</summary>
    private void SaveFrame()
    {
        if (_presenter.State != OverlappedPresenterState.Restored) return;
        var scale = WindowScale();
        var frame = new SavedFrame(
            AppWindow.Position.X, AppWindow.Position.Y,
            Math.Round(AppWindow.Size.Width / scale), Math.Round(AppWindow.Size.Height / scale));
        if (!Fits(frame)) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_frameFile)!);
            File.WriteAllText(_frameFile, JsonSerializer.Serialize(frame));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _services.Log.Write($"settings window: frame not saved, {e.GetType().Name}");
        }
    }

    private RectInt32? RestoredFrame()
    {
        if (ReadFrame() is not { } saved) return null;
        var guess = new RectInt32(saved.X, saved.Y, Px(saved.Width, WindowScale()), Px(saved.Height, WindowScale()));
        if (DisplayArea.GetFromRect(guess, DisplayAreaFallback.None) is not { } display) return null;
        var scale = Scale(display.WorkArea);
        return Clamp(new RectInt32(saved.X, saved.Y, Px(saved.Width, scale), Px(saved.Height, scale)), display.WorkArea);
    }

    /// <summary>The default size, centered on the window's display.</summary>
    private RectInt32 CenteredFrame()
    {
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var scale = Scale(work);
        var width = Math.Min(Px(DefaultWidth, scale), work.Width);
        var height = Math.Min(Px(DefaultHeight, scale), work.Height);
        return new RectInt32(work.X + (work.Width - width) / 2, work.Y + (work.Height - height) / 2, width, height);
    }

    /// <summary>Null when missing, unreadable or below the minimum size.</summary>
    private SavedFrame? ReadFrame()
    {
        try
        {
            if (!File.Exists(_frameFile)) return null;
            var frame = JsonSerializer.Deserialize<SavedFrame>(File.ReadAllText(_frameFile));
            return frame is not null && Fits(frame) ? frame : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    /// <summary>A frame below the minimum size is never saved or restored.</summary>
    private static bool Fits(SavedFrame frame) => frame.Width >= MinWidth && frame.Height >= MinHeight;

    /// <summary>Inside the work area: the size first, then the origin.</summary>
    private static RectInt32 Clamp(RectInt32 frame, RectInt32 work)
    {
        if (work.Width <= 0 || work.Height <= 0) return frame;
        var width = Math.Min(frame.Width, work.Width);
        var height = Math.Min(frame.Height, work.Height);
        var x = Math.Clamp(frame.X, work.X, work.X + work.Width - width);
        var y = Math.Clamp(frame.Y, work.Y, work.Y + work.Height - height);
        return new RectInt32(x, y, width, height);
    }

    private static int Px(double dips, double scale) => (int)Math.Round(dips * scale);

    /// <summary>The scale of the monitor under the window's center.</summary>
    private double WindowScale() =>
        Scale(new RectInt32(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height));

    /// <summary>The scale of the monitor under <paramref name="rect"/>'s center (nearest when none holds it).</summary>
    private static double Scale(RectInt32 rect) =>
        MonitorInfo.Scale(new DrawingPoint(rect.X + rect.Width / 2, rect.Y + rect.Height / 2));

    // Caption buttons.

    /// <summary>Windows switched Light and Dark: the caption buttons follow (the content follows through its ThemeResources).</summary>
    private void OnActualThemeChanged(FrameworkElement sender, object args) => ApplyCaptionButtonColors();

    /// <summary>
    /// The caption buttons (minimize, maximize, close) in the current theme: transparent at rest, the subtle fills on
    /// hover and press, the primary text colour (disabled text while the window is inactive).
    /// </summary>
    private void ApplyCaptionButtonColors()
    {
        var theme = RootGrid.ActualTheme;
        var titleBar = AppWindow.TitleBar;
        var transparent = ThemeColor("SubtleFillColorTransparent", theme);
        var foreground = ThemeColor("TextFillColorPrimary", theme);
        titleBar.ButtonBackgroundColor = transparent;
        titleBar.ButtonInactiveBackgroundColor = transparent;
        titleBar.ButtonHoverBackgroundColor = ThemeColor("SubtleFillColorSecondary", theme);
        titleBar.ButtonPressedBackgroundColor = ThemeColor("SubtleFillColorTertiary", theme);
        titleBar.ButtonForegroundColor = foreground;
        titleBar.ButtonHoverForegroundColor = foreground;
        titleBar.ButtonPressedForegroundColor = ThemeColor("TextFillColorSecondary", theme);
        titleBar.ButtonInactiveForegroundColor = ThemeColor("TextFillColorDisabled", theme);
    }

    /// <summary>
    /// <paramref name="key"/>'s colour in the theme dictionary of <paramref name="theme"/> (WinUI keeps Dark under
    /// "Default"). The app-level lookup is the fallback only: it keeps the theme the app started in.
    /// </summary>
    private static Color ThemeColor(string key, ElementTheme theme)
    {
        string[] names = theme == ElementTheme.Light ? ["Light"] : ["Dark", "Default"];
        if (FindThemeValue(Application.Current.Resources, key, names) is Color color) return color;
        return (Color)Application.Current.Resources[key];
    }

    private static object? FindThemeValue(ResourceDictionary dictionary, string key, string[] names)
    {
        foreach (var name in names)
        {
            if (dictionary.ThemeDictionaries.TryGetValue(name, out var found)
                && found is ResourceDictionary themed
                && themed.TryGetValue(key, out var value))
            {
                return value;
            }
        }

        foreach (var merged in dictionary.MergedDictionaries)
        {
            if (FindThemeValue(merged, key, names) is { } value) return value;
        }

        return null;
    }
}
