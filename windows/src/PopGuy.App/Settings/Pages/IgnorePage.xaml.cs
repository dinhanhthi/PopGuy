using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using PopGuy.Controls;
using PopGuy.Core.Settings;
using PopGuy.Platform.SystemServices;
using PopGuy.Services;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace PopGuy.Settings.Pages;

/// <summary>
/// Settings → Ignore (macOS AppsView.swift, spec-3 §5.7 Ignored Apps). The navigation parameter is the AppServices.
/// "Enable Ignored Apps" gates the list (the saved list is kept). An app is its lowercase exe name
/// (<see cref="IgnoredApps"/>, the gate's rule); a row shows the exe's icon and FileDescription when it can be found
/// (a running process, or the path picked this session), else the generic icon and the exe name. "Add App…" opens a
/// picker of the running apps with a window (<see cref="AppIcons.RunningApps"/>) with Browse… for an .exe. Rows show at
/// once; names and icons fill in from the thread pool. Every change saves through <see cref="SettingsStore.Update"/>;
/// a change from elsewhere (the toolbar's "Ignore this app") shows while the page is open.
/// </summary>
public sealed partial class IgnorePage : Page
{
    /// <summary>AppIconDefault: an app whose icon is unknown or not loaded yet (macOS <c>app.dashed</c>).</summary>
    private const string GenericAppGlyph = "";

    private static readonly TimeSpan SpinnerDelay = TimeSpan.FromMilliseconds(150);

    /// <summary>Resolved apps and their icons by exe name, for the page's life (a new page resolves again).</summary>
    private readonly Dictionary<string, AppInfo> _apps = new();
    private readonly Dictionary<string, ImageSource> _icons = new();

    /// <summary>Paths picked this session: an app that is not running still gets its icon.</summary>
    private readonly Dictionary<string, string> _pickedPaths = new();

    private readonly HashSet<string> _resolving = [];
    private readonly Dictionary<string, SettingsCard> _rows = new();
    private IReadOnlyList<string> _shown = [];
    private AppServices? _services;
    private bool _subscribed;
    private bool _picking;

    /// <summary>The toggle is being set from the settings: its change event is not the user's.</summary>
    private bool _syncing;

    public IgnorePage()
    {
        InitializeComponent();
        EnabledToggle.Toggled += (_, _) =>
            Save("ignoredAppsEnabled", s => s with { IgnoredAppsEnabled = EnabledToggle.IsOn });
        AddButton.Click += (_, _) => _ = PickAsync();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _services = e.Parameter as AppServices;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_services is null) return;
        if (!_subscribed) _services.Settings.Changed += OnSettingsChanged;
        _subscribed = true;
        Refresh();
    }

    /// <summary>The window's first-show re-attach may raise Loaded before this Unloaded: a page still loaded keeps listening.</summary>
    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_services is null || IsLoaded) return;
        _services.Settings.Changed -= OnSettingsChanged;
        _subscribed = false;
    }

    /// <summary>Queued: a change may be saved from any thread.</summary>
    private void OnSettingsChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    /// <summary>The toggle and the rows show the current settings; apps not resolved yet are looked up.</summary>
    private void Refresh()
    {
        if (_services is null) return;
        var current = _services.Settings.Current;
        _syncing = true;
        EnabledToggle.IsOn = current.IgnoredAppsEnabled;
        _syncing = false;
        AppsPanel.Visibility = current.IgnoredAppsEnabled ? Visibility.Visible : Visibility.Collapsed;
        var keys = IgnoredApps.Keys(current.IgnoredAppExeNames);
        EmptyText.Visibility = keys.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (!keys.SequenceEqual(_shown)) ShowRows(keys);
        _ = ResolveAsync(keys);
    }

    // Rows (macOS IgnoredAppRow).

    /// <summary>One card per app in list order; an app's card is kept while it stays in the list.</summary>
    private void ShowRows(IReadOnlyList<string> keys)
    {
        _shown = keys;
        AppRows.Children.Clear();
        foreach (var gone in _rows.Keys.Except(keys).ToList()) _rows.Remove(gone);
        foreach (var exe in keys)
        {
            if (!_rows.TryGetValue(exe, out var row))
            {
                row = NewRow(exe);
                _rows[exe] = row;
            }
            AppRows.Children.Add(row);
        }
    }

    private SettingsCard NewRow(string exe)
    {
        var remove = new Button
        {
            VerticalAlignment = VerticalAlignment.Center,
            Style = AppStyle("SubtleButtonStyle"),
            Content = new FontIcon { Glyph = "", Style = PageStyle("CriticalIconStyle") },
        };
        HoverTooltip.SetText(remove, "Remove");
        remove.Click += (_, _) =>
            Save("ignoredAppExeNames", s => s with { IgnoredAppExeNames = IgnoredApps.Remove(s.IgnoredAppExeNames, exe) });
        var row = new SettingsCard { Content = remove };
        FillRow(row, exe);
        return row;
    }

    /// <summary>The app's name and icon as far as they are known; the exe name as the caption under a friendly name.</summary>
    private void FillRow(SettingsCard row, string exe)
    {
        var name = _apps.TryGetValue(exe, out var app) ? app.DisplayName : exe;
        row.Header = name;
        if (string.Equals(name, exe, StringComparison.OrdinalIgnoreCase)) row.ClearValue(SettingsCard.DescriptionProperty);
        else row.Description = exe;
        row.HeaderIcon = _icons.TryGetValue(exe, out var icon)
            ? new ImageIcon { Source = icon }
            : new FontIcon { Glyph = GenericAppGlyph, Style = PageStyle("SecondaryIconStyle") };
        if (row.Content is Button remove) AutomationProperties.SetName(remove, $"Remove {name}");
    }

    /// <summary>Looks up the apps not resolved yet on the thread pool, then fills their rows.</summary>
    private async Task ResolveAsync(IReadOnlyList<string> keys)
    {
        var missing = keys.Where(exe => !_apps.ContainsKey(exe) && !_resolving.Contains(exe)).ToList();
        if (missing.Count == 0) return;
        _resolving.UnionWith(missing);
        var picked = missing.ToDictionary(exe => exe, exe => _pickedPaths.GetValueOrDefault(exe));
        try
        {
            var found = await Task.Run(() => missing.Select(exe => WithIcon(AppIcons.Resolve(exe, picked[exe]))).ToList());
            foreach (var (app, pixels) in found)
            {
                _apps[app.Exe] = app;
                if (pixels is not null) _icons[app.Exe] = ToImage(pixels);
            }
        }
        catch (Exception e)
        {
            _services?.Log.Write($"settings: ignored apps not resolved, {e.GetType().Name}");
        }
        finally
        {
            _resolving.ExceptWith(missing);
        }
        foreach (var exe in missing)
        {
            if (_rows.TryGetValue(exe, out var row)) FillRow(row, exe);
        }
    }

    private static (AppInfo App, AppIconPixels? Pixels) WithIcon(AppInfo app) =>
        (app, app.Path is null ? null : AppIcons.Load(app.Path));

    /// <summary>
    /// Adds an app by its exe name (once, the gate's rule). A path picked now replaces a lookup that found no icon, so
    /// the row gets one.
    /// </summary>
    private void Add(string exeOrPath, string? path)
    {
        if (IgnoredApps.Key(exeOrPath) is not { } exe) return;
        if (path is not null)
        {
            _pickedPaths[exe] = path;
            if (!_icons.ContainsKey(exe)) _apps.Remove(exe);
        }
        Save("ignoredAppExeNames", s => s with { IgnoredAppExeNames = IgnoredApps.Add(s.IgnoredAppExeNames, exe) });
    }

    // Add App… (macOS: NSOpenPanel "Choose an Application"): the running apps, or Browse… for an .exe.

    private async Task PickAsync()
    {
        if (_picking || XamlRoot is null) return;
        _picking = true;
        try
        {
            var (choice, browse) = await ShowRunningAppsAsync();
            if (choice is not null) Add(choice.Exe, choice.Path);
            else if (browse) await BrowseAsync();
        }
        catch (COMException e)
        {
            // Another dialog is open, or the file picker cannot open (e.g. PopGuy runs elevated).
            _services?.Log.Write($"settings: add app failed, {e.GetType().Name} 0x{e.HResult:X8}");
        }
        finally
        {
            _picking = false;
        }
    }

    /// <summary>
    /// The dialog shows at once with the list empty (a spinner after 150 ms); the apps, then their icons, fill in from
    /// the thread pool. A click on an app picks it and closes the dialog.
    /// </summary>
    private async Task<(AppInfo? Choice, bool Browse)> ShowRunningAppsAsync()
    {
        var list = new ListView
        {
            Height = 320,
            IsItemClickEnabled = true,
            SelectionMode = ListViewSelectionMode.None,
        };
        AutomationProperties.SetName(list, "Running apps");
        var spinner = new ProgressRing { IsActive = false, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var none = new TextBlock
        {
            Text = "No other apps with a window are running.",
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Style = PageStyle("CaptionStyle"),
            Visibility = Visibility.Collapsed,
        };
        var content = new Grid { Width = 420 };
        content.Children.Add(list);
        content.Children.Add(spinner);
        content.Children.Add(none);

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Style = AppStyle("DefaultContentDialogStyle"),
            Title = "Choose an Application",
            Content = content,
            SecondaryButtonText = "Browse…",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        AppInfo? choice = null;
        list.ItemClick += (_, e) =>
        {
            if (e.ClickedItem is not FrameworkElement { Tag: AppInfo app }) return;
            choice = app;
            dialog.Hide();
        };

        var spinnerTimer = DispatcherQueue.CreateTimer();
        spinnerTimer.Interval = SpinnerDelay;
        spinnerTimer.IsRepeating = false;
        spinnerTimer.Tick += (timer, _) =>
        {
            timer.Stop();
            spinner.IsActive = true;
        };
        spinnerTimer.Start();

        var showing = dialog.ShowAsync();
        await FillRunningAppsAsync(list, none, () =>
        {
            spinnerTimer.Stop();
            spinner.IsActive = false;
        });
        var result = await showing;
        return (choice, choice is null && result == ContentDialogResult.Secondary);
    }

    private async Task FillRunningAppsAsync(ListView list, TextBlock none, Action loaded)
    {
        IReadOnlyList<AppInfo> apps = [];
        try
        {
            apps = await Task.Run(AppIcons.RunningApps);
        }
        catch (Exception e)
        {
            _services?.Log.Write($"settings: running apps not listed, {e.GetType().Name}");
        }
        loaded();
        none.Visibility = apps.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        var slots = apps.Select(app =>
        {
            var (item, slot) = PickerItem(app);
            list.Items.Add(item);
            return slot;
        }).ToList();

        var missing = apps.Where(app => !_icons.ContainsKey(app.Exe) && app.Path is not null).ToList();
        if (missing.Count == 0) return;
        try
        {
            var found = await Task.Run(() => missing.Select(app => (app.Exe, Pixels: AppIcons.Load(app.Path!))).ToList());
            foreach (var (exe, pixels) in found)
            {
                if (pixels is not null) _icons[exe] = ToImage(pixels);
            }
        }
        catch (Exception e)
        {
            _services?.Log.Write($"settings: running app icons not loaded, {e.GetType().Name}");
        }
        for (var i = 0; i < apps.Count; i++)
        {
            if (_icons.TryGetValue(apps[i].Exe, out var icon)) slots[i].Child = IconImage(icon);
        }
    }

    /// <summary>A picker row: icon, name and exe name; the returned slot holds the icon.</summary>
    private (FrameworkElement Item, Border Slot) PickerItem(AppInfo app)
    {
        var slot = new Border
        {
            Width = 20,
            Height = 20,
            VerticalAlignment = VerticalAlignment.Center,
            Child = _icons.TryGetValue(app.Exe, out var icon)
                ? IconImage(icon)
                : new FontIcon { Glyph = GenericAppGlyph, FontSize = 16, Style = PageStyle("SecondaryIconStyle") },
        };
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = app.DisplayName, TextTrimming = TextTrimming.CharacterEllipsis });
        if (!string.Equals(app.DisplayName, app.Exe, StringComparison.OrdinalIgnoreCase))
        {
            text.Children.Add(new TextBlock { Text = app.Exe, Style = PageStyle("CaptionStyle"), TextWrapping = TextWrapping.NoWrap });
        }
        var item = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 6, 0, 6), Tag = app };
        item.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        item.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(text, 1);
        item.Children.Add(slot);
        item.Children.Add(text);
        AutomationProperties.SetName(item, app.DisplayName);
        return (item, slot);
    }

    /// <summary>Browse…: an .exe from the file picker, owned by the Settings window.</summary>
    private async Task BrowseAsync()
    {
        if (XamlRoot?.ContentIslandEnvironment is not { } environment) return;
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.ComputerFolder, ViewMode = PickerViewMode.List };
        picker.FileTypeFilter.Add(".exe");
        InitializeWithWindow.Initialize(picker, Win32Interop.GetWindowFromWindowId(environment.AppWindowId));
        var file = await picker.PickSingleFileAsync();
        if (file?.Path is { Length: > 0 } path) Add(path, path);
    }

    // Helpers.

    private static Image IconImage(ImageSource source) => new() { Source = source, Width = 20, Height = 20 };

    /// <summary>A WinUI bitmap of the icon: WriteableBitmap takes premultiplied BGRA, the icon's alpha is straight.</summary>
    private static WriteableBitmap ToImage(AppIconPixels icon)
    {
        var bytes = new byte[icon.Pixels.Length * 4];
        for (var i = 0; i < icon.Pixels.Length; i++)
        {
            var pixel = icon.Pixels[i];
            var alpha = pixel >> 24;
            bytes[i * 4] = (byte)((pixel & 0xFF) * alpha / 255);
            bytes[i * 4 + 1] = (byte)((pixel >> 8 & 0xFF) * alpha / 255);
            bytes[i * 4 + 2] = (byte)((pixel >> 16 & 0xFF) * alpha / 255);
            bytes[i * 4 + 3] = (byte)alpha;
        }
        var bitmap = new WriteableBitmap(icon.Width, icon.Height);
        bytes.CopyTo(bitmap.PixelBuffer);
        bitmap.Invalidate();
        return bitmap;
    }

    private Style PageStyle(string key) => (Style)Resources[key];

    private static Style AppStyle(string key) => (Style)Application.Current.Resources[key];

    /// <summary>Saves one change; a failed write is logged and the page goes back to the saved settings.</summary>
    private void Save(string key, Func<AppSettings, AppSettings> change)
    {
        if (_syncing || _services is null) return;
        try
        {
            _services.Settings.Update(change);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _services.Log.Write($"settings: {key} not saved, {e.GetType().Name}");
            Refresh();
        }
    }
}
