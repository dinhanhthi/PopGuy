using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PopGuy.Core.Settings;
using PopGuy.Services;

namespace PopGuy.Settings.Pages;

/// <summary>
/// Settings → Appearance (macOS SettingsView.swift AppearanceView, spec-3 §5.5, plus macOS's Hide logo and Remove gap
/// before system buttons toggles, which the spec leaves out). The navigation parameter is the
/// AppServices. Every control saves through <see cref="SettingsStore.Update"/> at once; the toolbar reads these settings
/// on each presentation, so the next toolbar shows the change. The sample sentence shows the result text's size: the
/// font size, grown by the zoom when "Include font size in zoom" is on. A change from elsewhere shows while the page is
/// open.
/// </summary>
public sealed partial class AppearancePage : Page
{
    private AppServices? _services;
    private bool _subscribed;

    /// <summary>The controls are being set from the settings: their change events are not the user's.</summary>
    private bool _syncing;

    public AppearancePage()
    {
        InitializeComponent();
        ZoomBar.SelectionChanged += (_, _) => OnZoomChanged();
        FontSizeBar.SelectionChanged += (_, _) => OnFontSizeChanged();
        ZoomFontToggle.Toggled += (_, _) =>
            Save("zoomIncludesFontSize", s => s with { ZoomIncludesFontSize = ZoomFontToggle.IsOn });
        HideLogoToggle.Toggled += (_, _) =>
            Save("hideToolbarLogo", s => s with { HideToolbarLogo = HideLogoToggle.IsOn });
        InlineSystemButtonsToggle.Toggled += (_, _) =>
            Save("inlineToolbarSystemButtons", s => s with { InlineToolbarSystemButtons = InlineSystemButtonsToggle.IsOn });
        FormattingToggle.Toggled += (_, _) =>
            Save("preserveFormatting", s => s with { PreserveFormatting = FormattingToggle.IsOn });
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

    /// <summary>
    /// The window's first-show re-attach takes the page out and puts it back in one tick, and its Loaded may come before
    /// this Unloaded: a page still loaded keeps listening.
    /// </summary>
    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_services is null || IsLoaded) return;
        _services.Settings.Changed -= OnSettingsChanged;
        _subscribed = false;
    }

    /// <summary>Queued: a change may be saved from any thread.</summary>
    private void OnSettingsChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    /// <summary>Every control, and the sample, shows the current settings.</summary>
    private void Refresh()
    {
        if (_services is null) return;
        var current = _services.Settings.Current;
        _syncing = true;
        // The bars' items are in the enums' order (here, in the change handlers and in UpdateSample).
        ZoomBar.SelectedItem = ZoomBar.Items[(int)current.ToolbarZoom];
        FontSizeBar.SelectedItem = FontSizeBar.Items[(int)current.ResultFontSize];
        ZoomFontToggle.IsOn = current.ZoomIncludesFontSize;
        HideLogoToggle.IsOn = current.HideToolbarLogo;
        InlineSystemButtonsToggle.IsOn = current.InlineToolbarSystemButtons;
        FormattingToggle.IsOn = current.PreserveFormatting;
        _syncing = false;
        UpdateSample();
    }

    private void OnZoomChanged()
    {
        var index = ZoomBar.Items.IndexOf(ZoomBar.SelectedItem);
        if (index < 0) return;
        Save("toolbarZoom", s => s with { ToolbarZoom = (ToolbarZoom)index });
    }

    private void OnFontSizeChanged()
    {
        var index = FontSizeBar.Items.IndexOf(FontSizeBar.SelectedItem);
        if (index < 0) return;
        Save("resultFontSize", s => s with { ResultFontSize = (ResultFontSize)index });
    }

    /// <summary>
    /// Saves one change and updates the sample in the same frame; a failed write is logged and the controls go back to
    /// the saved settings.
    /// </summary>
    private void Save(string key, Func<AppSettings, AppSettings> change)
    {
        if (_syncing || _services is null) return;
        try
        {
            _services.Settings.Update(change);
            UpdateSample();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _services.Log.Write($"settings: {key} not saved, {e.GetType().Name}");
            Refresh();
        }
    }

    /// <summary>
    /// The sample at the result text's on-screen size: the toolbar's font sizes (ToolbarViewModel.ResultFontSize:
    /// 12 / 14 / 18), times its zoom when the zoom includes the font size.
    /// </summary>
    private void UpdateSample()
    {
        var size = FontSizeBar.Items.IndexOf(FontSizeBar.SelectedItem) switch
        {
            0 => 12,
            2 => 18,
            _ => 14,
        };
        var zoom = ZoomBar.Items.IndexOf(ZoomBar.SelectedItem) switch
        {
            1 => 1.2,
            2 => 1.3,
            _ => 1.0,
        };
        SampleText.FontSize = ZoomFontToggle.IsOn ? size * zoom : size;
    }
}
