using System.Security;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PopGuy.Core.Settings;
using PopGuy.Controls;
using PopGuy.Core.Text;
using PopGuy.Platform.SystemServices;
using PopGuy.Services;

namespace PopGuy.Settings.Pages;

/// <summary>
/// Settings → General (macOS GeneralView.swift, spec-3 §5.1). The navigation parameter is the AppServices. Toggles
/// save through <see cref="SettingsStore.Update"/> at once (its <see cref="SettingsStore.Changed"/> applies them); the
/// Global Prompt saves 500 ms after the last keystroke, and when the box loses focus or the page goes, so typing does
/// not re-apply the triggers on every key. A change from elsewhere (the tray) shows while the page is open. Start at
/// login is the Run key's real state (<see cref="LaunchAtLogin"/>), read each time the page shows (macOS
/// <c>onAppear</c>).
/// </summary>
public sealed partial class GeneralPage : Page
{
    private static readonly TimeSpan PromptSaveDelay = TimeSpan.FromMilliseconds(500);

    private AppServices? _services;
    private DispatcherQueueTimer? _promptTimer;
    private bool _subscribed;

    /// <summary>The controls are being set from the settings: their change events are not the user's.</summary>
    private bool _syncing;

    public GeneralPage()
    {
        InitializeComponent();
        EnabledToggle.Toggled += (_, _) => Save("popGuyEnabled", s => s with { PopGuyEnabled = EnabledToggle.IsOn });
        ConfirmCloseToggle.Toggled += (_, _) =>
            Save("confirmCloseAfterResult", s => s with { ConfirmCloseAfterResult = ConfirmCloseToggle.IsOn });
        LoginToggle.Toggled += (_, _) => OnLoginToggled();
        SetupGuideButton.Click += (_, _) => _services?.RequestSetupGuide();
        HoverTooltip.SetText(SetupGuideButton, "Replay the first-run setup guide");
        PromptBox.TextChanged += (_, _) => OnPromptChanged();
        PromptBox.LostFocus += (_, _) => SavePrompt();
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
        RefreshLogin();
    }

    /// <summary>
    /// A pending prompt is saved before the page goes. The window's first-show re-attach takes the page out and puts it
    /// back in one tick, and its Loaded may come before this Unloaded: a page still loaded keeps listening.
    /// </summary>
    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_services is null) return;
        SavePrompt();
        if (IsLoaded) return;
        _services.Settings.Changed -= OnSettingsChanged;
        _subscribed = false;
    }

    /// <summary>Queued: a change may be saved from any thread.</summary>
    private void OnSettingsChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    /// <summary>Every control shows the current settings; the prompt only while the user is not editing it.</summary>
    private void Refresh()
    {
        if (_services is null) return;
        RefreshToggles();
        var prompt = _services.Settings.Current.GlobalPrompt;
        var editing = PromptBox.FocusState != FocusState.Unfocused || _promptTimer?.IsRunning == true;
        if (editing || LineEndings.ToLf(PromptBox.Text) == prompt) return;
        _syncing = true;
        PromptBox.Text = prompt;
        _syncing = false;
    }

    private void RefreshToggles()
    {
        if (_services is null) return;
        var current = _services.Settings.Current;
        _syncing = true;
        EnabledToggle.IsOn = current.PopGuyEnabled;
        ConfirmCloseToggle.IsOn = current.ConfirmCloseAfterResult;
        _syncing = false;
    }

    /// <summary>
    /// Saves one change; a failed write is logged and the toggles go back to the saved settings (the prompt keeps the
    /// user's text, saved again on the next edit or focus loss).
    /// </summary>
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
            RefreshToggles();
        }
    }

    // Global Prompt.

    private void OnPromptChanged()
    {
        if (_syncing || _services is null) return;
        if (_promptTimer is null)
        {
            _promptTimer = DispatcherQueue.CreateTimer();
            _promptTimer.Interval = PromptSaveDelay;
            _promptTimer.IsRepeating = false;
            _promptTimer.Tick += (_, _) => SavePrompt();
        }
        _promptTimer.Stop();
        _promptTimer.Start();
    }

    /// <summary>Saves the box's text ("\n" line breaks, as macOS) when it differs from the saved prompt.</summary>
    private void SavePrompt()
    {
        _promptTimer?.Stop();
        if (_services is null) return;
        var prompt = LineEndings.ToLf(PromptBox.Text);
        if (prompt == _services.Settings.Current.GlobalPrompt) return;
        Save("globalPrompt", s => s with { GlobalPrompt = prompt });
    }

    // Start at login.

    /// <summary>The toggle shows the Run key's state; an unreadable key shows off with the error.</summary>
    private void RefreshLogin()
    {
        bool enabled;
        try
        {
            enabled = LaunchAtLogin.IsEnabled();
            ShowLoginError(null);
        }
        catch (Exception e) when (IsRegistryError(e))
        {
            enabled = false;
            ShowLoginError($"Could not read launch at login: {e.Message}");
        }
        _syncing = true;
        LoginToggle.IsOn = enabled;
        _syncing = false;
    }

    /// <summary>Writes the Run key (a few microseconds); on failure the toggle goes back and the error shows.</summary>
    private void OnLoginToggled()
    {
        if (_syncing) return;
        var enable = LoginToggle.IsOn;
        try
        {
            LaunchAtLogin.SetEnabled(enable);
            ShowLoginError(null);
        }
        catch (Exception e) when (IsRegistryError(e))
        {
            _services?.Log.Write($"launch at login: not {(enable ? "enabled" : "disabled")}, {e.GetType().Name}");
            _syncing = true;
            LoginToggle.IsOn = !enable;
            _syncing = false;
            ShowLoginError($"Could not {(enable ? "enable" : "disable")} launch at login: {e.Message}");
        }
    }

    private void ShowLoginError(string? message)
    {
        LoginErrorText.Text = message ?? "";
        LoginErrorText.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private static bool IsRegistryError(Exception e) =>
        e is IOException or UnauthorizedAccessException or SecurityException or InvalidOperationException;
}
