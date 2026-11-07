using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PopGuy.Controls;
using PopGuy.Core.Settings;
using PopGuy.Services;
using PopGuy.Settings.ViewModels;
using PopGuy.Toolbar;

namespace PopGuy.Settings.Pages;

/// <summary>
/// Settings → Appearance (macOS SettingsView.swift AppearanceView, spec-3 §5.5, plus macOS's Show logo only, Show
/// Settings button on toolbar (on the Actions page before), Hide logo and Remove gap before system buttons toggles,
/// which the spec leaves out). Hide logo is disabled while Show logo only is on: the toolbar expands from the logo
/// (macOS). The navigation parameter is the AppServices. Every control saves
/// through <see cref="SettingsStore.Update"/> at once; the toolbar reads these settings on each presentation, so the
/// next toolbar shows the change; the toolbar preview (the layout editor, preview-only) shows it at once. The sample
/// sentence shows the result text's size: the font size, grown by the zoom when "Include font size in zoom" is on. A
/// change from elsewhere (the tray's Show Logo Only too) shows while the page is open. A SelectorBar (as on the Ignore
/// page) shows the Toolbar Style, Toolbar Zoom or Result Text tab under the preview; a new page opens on Toolbar Style.
/// </summary>
public sealed partial class AppearancePage : Page
{
    private const string SettingsButtonTooltip = "Settings stay available from the PopGuy tray icon";

    private AppServices? _services;
    private ActionsViewModel? _model;
    private bool _subscribed;

    /// <summary>The controls are being set from the settings: their change events are not the user's.</summary>
    private bool _syncing;

    public AppearancePage()
    {
        InitializeComponent();
        TabBar.SelectedItem = TabBar.Items[0];
        TabBar.SelectionChanged += (_, _) => ShowTab();
        ToolbarStyleBar.SelectionChanged += (_, _) => OnToolbarStyleChanged();
        ZoomBar.SelectionChanged += (_, _) => OnZoomChanged();
        FontSizeBar.SelectionChanged += (_, _) => OnFontSizeChanged();
        ShowLogoOnlyToggle.Toggled += (_, _) =>
        {
            UpdateHideLogoState();
            Save("showLogoOnly", s => s with { ShowLogoOnly = ShowLogoOnlyToggle.IsOn });
        };
        ToolbarSettingsToggle.Toggled += (_, _) =>
            Save("showToolbarSettingsButton", s => s with { ShowToolbarSettingsButton = ToolbarSettingsToggle.IsOn });
        HoverTooltip.SetText(ToolbarSettingsToggle, SettingsButtonTooltip);
        ZoomFontToggle.Toggled += (_, _) =>
            Save("zoomIncludesFontSize", s => s with { ZoomIncludesFontSize = ZoomFontToggle.IsOn });
        HideLogoToggle.Toggled += (_, _) =>
            Save("hideToolbarLogo", s => s with { HideToolbarLogo = HideLogoToggle.IsOn });
        InlineSystemButtonsToggle.Toggled += (_, _) =>
            Save("inlineToolbarSystemButtons", s => s with { InlineToolbarSystemButtons = InlineSystemButtonsToggle.IsOn });
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _services = e.Parameter as AppServices;
        if (_services is null || _model is not null) return;
        _model = new ActionsViewModel(_services.Settings, _services.Credentials, _services.Providers, _services.Log.Write);
        ToolbarPreview.Initialize(_model, _services, isEditable: false);
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

    /// <summary>The picked tab's panel, scrolled to its top.</summary>
    private void ShowTab()
    {
        var index = TabBar.Items.IndexOf(TabBar.SelectedItem);
        if (index < 0) return;
        StyleTab.Visibility = index == 0 ? Visibility.Visible : Visibility.Collapsed;
        ZoomTab.Visibility = index == 1 ? Visibility.Visible : Visibility.Collapsed;
        ResultTextTab.Visibility = index == 2 ? Visibility.Visible : Visibility.Collapsed;
        TabScroller.ChangeView(null, 0, null, disableAnimation: true);
    }

    /// <summary>Queued: a change may be saved from any thread.</summary>
    private void OnSettingsChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    /// <summary>Every control, the toolbar preview and the sample show the current settings.</summary>
    private void Refresh()
    {
        if (_services is null) return;
        var current = _services.Settings.Current;
        _syncing = true;
        // The bars' items are in the enums' order (here, in the change handlers and in UpdateSample).
        ToolbarStyleBar.SelectedItem = ToolbarStyleBar.Items[(int)current.ToolbarStyle];
        ShowLogoOnlyToggle.IsOn = current.ShowLogoOnly;
        ToolbarSettingsToggle.IsOn = current.ShowToolbarSettingsButton;
        ZoomBar.SelectedItem = ZoomBar.Items[(int)current.ToolbarZoom];
        FontSizeBar.SelectedItem = FontSizeBar.Items[(int)current.ResultFontSize];
        ZoomFontToggle.IsOn = current.ZoomIncludesFontSize;
        HideLogoToggle.IsOn = current.HideToolbarLogo;
        InlineSystemButtonsToggle.IsOn = current.InlineToolbarSystemButtons;
        _syncing = false;
        ToolbarPreview.Refresh();
        UpdateToolbarStyleCaption();
        UpdateHideLogoState();
        UpdateSample();
    }

    private void OnToolbarStyleChanged()
    {
        var index = ToolbarStyleBar.Items.IndexOf(ToolbarStyleBar.SelectedItem);
        if (index < 0) return;
        UpdateToolbarStyleCaption();
        Save("toolbarStyle", s => s with { ToolbarStyle = (ToolbarStyle)index });
    }

    /// <summary>The selected style's caption (macOS AppearanceView's).</summary>
    private void UpdateToolbarStyleCaption() =>
        ToolbarStyleCard.Description = ToolbarStyleBar.Items.IndexOf(ToolbarStyleBar.SelectedItem) == (int)ToolbarStyle.Menu
            ? "Actions appear in a list like a context menu; extra actions open from More actions."
            : "Actions appear in a horizontal toolbar.";

    /// <summary>The logo always shows while Show logo only is on (macOS AppearanceView): Hide logo is disabled.</summary>
    private void UpdateHideLogoState()
    {
        HideLogoToggle.IsEnabled = !ShowLogoOnlyToggle.IsOn;
        HideLogoCard.Description = ShowLogoOnlyToggle.IsOn
            ? "The logo always shows while Show logo only is on."
            : "Hide the PopGuy logo to save space on the toolbar.";
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
    /// 12 / 14 / 18), times its zoom's scale (ToolbarViewModel.ZoomScale) when the zoom includes the font size.
    /// </summary>
    private void UpdateSample()
    {
        var size = FontSizeBar.Items.IndexOf(FontSizeBar.SelectedItem) switch
        {
            0 => 12,
            2 => 18,
            _ => 14,
        };
        var index = ZoomBar.Items.IndexOf(ZoomBar.SelectedItem);
        var zoom = ToolbarViewModel.ZoomScale(index < 0 ? ToolbarZoom.X1 : (ToolbarZoom)index);
        SampleText.FontSize = ZoomFontToggle.IsOn ? size * zoom : size;
    }
}
