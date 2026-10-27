using System.ComponentModel;
using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PopGuy.Controls;
using PopGuy.Core.Settings;
using PopGuy.Services;

namespace PopGuy.Settings.Pages;

/// <summary>
/// Settings → About (macOS AboutView.swift, spec-3 §5.8). The version line is the informational version without the
/// +commit suffix, as the window's footer shows it; there is no build date (macOS PGReleaseDate): the SDK's
/// deterministic build leaves no build time in the assembly, and the exe's file time is whatever the copy or unzip gave
/// it. The Updates card shows <see cref="UpdateService"/>: the automatic checks switch
/// (<see cref="AppSettings.AutomaticallyChecksForUpdates"/>), Check for Updates… (disabled while a check runs or when
/// PopGuy is not installed) and the last result, with Update now once an update is ready. The links open through
/// HyperlinkButton's NavigateUri; Acknowledgements opens <c>Licenses\ThirdPartyNotices.txt</c> next to PopGuy.exe in the
/// default text editor. The navigation parameter is the AppServices.
/// </summary>
public sealed partial class AboutPage : Page
{
    private AppServices? _services;
    private bool _subscribed;

    /// <summary>The switch is being set from the settings: its change event is not the user's.</summary>
    private bool _syncing;

    public AboutPage()
    {
        InitializeComponent();
        VersionText.Text = $"v{App.Version.Split('+')[0]}";
        AutoCheckToggle.Toggled += (_, _) => OnAutoCheckToggled();
        CheckButton.Click += (_, _) => _services?.Updates.CheckNow();
        UpdateNowButton.Click += (_, _) => _services?.Updates.ApplyAndRestart();
        AcknowledgementsButton.Click += (_, _) => OpenAcknowledgements();
        HoverTooltip.SetText(CheckButton, "Check for a newer version of PopGuy");
        HoverTooltip.SetText(UpdateNowButton, "Restart PopGuy into the new version");
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
        if (!_subscribed)
        {
            _services.Updates.Changed += Refresh;
            _services.Settings.Changed += OnSettingsChanged;
        }
        _subscribed = true;
        Refresh();
    }

    /// <summary>The window's first-show re-attach may raise Loaded before this Unloaded: a page still loaded keeps listening.</summary>
    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_services is null || IsLoaded) return;
        _services.Updates.Changed -= Refresh;
        _services.Settings.Changed -= OnSettingsChanged;
        _subscribed = false;
    }

    /// <summary>Queued: a change may be saved from any thread.</summary>
    private void OnSettingsChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    private void Refresh()
    {
        if (_services is null) return;
        var updates = _services.Updates;
        _syncing = true;
        AutoCheckToggle.IsOn = _services.Settings.Current.AutomaticallyChecksForUpdates;
        _syncing = false;
        AutoCheckToggle.IsEnabled = updates.IsInstalled;
        CheckButton.IsEnabled = updates.CanCheck;
        UpdateNowButton.Visibility = updates.State == UpdateState.Ready ? Visibility.Visible : Visibility.Collapsed;
        UpdateStatusText.Text = updates.StatusText ?? "";
        UpdateStatusText.Style = (Style)Resources[updates.State == UpdateState.Ready ? "AccentStatusStyle" : "CaptionStyle"];
    }

    /// <summary>The notices file in the default app for .txt; a failure (no file, no handler) is logged.</summary>
    private void OpenAcknowledgements()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Licenses", "ThirdPartyNotices.txt");
        try
        {
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true })?.Dispose();
        }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            _services?.Log.Write($"about: acknowledgements not opened, {e.GetType().Name}");
        }
    }

    private void OnAutoCheckToggled()
    {
        if (_syncing || _services is null) return;
        var on = AutoCheckToggle.IsOn;
        try
        {
            _services.Settings.Update(s => s with { AutomaticallyChecksForUpdates = on });
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _services.Log.Write($"settings: automaticallyChecksForUpdates not saved, {e.GetType().Name}");
            Refresh();
        }
    }
}
