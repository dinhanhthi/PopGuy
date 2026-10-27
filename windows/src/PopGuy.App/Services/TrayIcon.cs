using Microsoft.UI.Dispatching;
using PopGuy.Core.Settings;
using PopGuy.Platform.SystemServices;

namespace PopGuy.Services;

/// <summary>
/// The tray icon and its menu (spec-3 §5.9, the macOS status item, in its order): Disable/Enable PopGuy, Show on Text
/// Selection, Show on Double-Click, Capture Screen Text…, Settings…, History…, About PopGuy…, Setup Guide…, Check for
/// Updates… and Quit PopGuy, with Update to vX… first while an update is ready; rebuilt each time it opens. The macOS
/// Accessibility items have no Windows counterpart. Capture Screen Text… is always enabled (macOS): with Screen Text
/// Capture off it opens Settings › Triggers at the OCR section instead of capturing. The icon follows the taskbar's
/// theme (a dark glyph on a light taskbar, a white one on a dark taskbar) and dims while PopGuy is disabled. A left
/// click opens Settings.
/// <para>
/// Toggles save through <see cref="SettingsStore.Update"/>, whose <see cref="SettingsStore.Changed"/> also re-applies
/// the triggers (ToolbarController). Create, use and dispose on the UI thread.
/// </para>
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    private readonly SettingsStore _settings;
    private readonly UpdateService _updates;
    private readonly DispatcherQueue _dispatcher;
    private readonly Action _openSettings;
    private readonly Action<string, bool> _openSettingsSection;
    private readonly Action _captureScreenText;
    private readonly Action _openSetupGuide;
    private readonly Action _quit;
    private readonly Action<string> _log;
    private readonly NotifyIcon _icon;

    /// <summary>Capture Screen Text…'s wait for the menu to fade (kept so it ticks); null until the first click.</summary>
    private DispatcherQueueTimer? _captureTimer;

    /// <param name="openSettings">Opens the Settings window. Runs from the dispatcher queue, after the menu closed.</param>
    /// <param name="openSettingsSection">
    /// Opens Settings on a page (a sidebar tag), with Triggers scrolled to its OCR section when the flag is set. Runs from
    /// the dispatcher queue.
    /// </param>
    /// <param name="captureScreenText">Starts an OCR capture (Screen Text Capture is on). Runs from the dispatcher queue.</param>
    /// <param name="openSetupGuide">Opens the first-launch wizard again. Runs from the dispatcher queue.</param>
    /// <param name="quit">Quit PopGuy. Runs from the dispatcher queue, never inside the icon's window procedure.</param>
    /// <exception cref="System.ComponentModel.Win32Exception">Windows refused the icon's window.</exception>
    public TrayIcon(
        SettingsStore settings, UpdateService updates, DispatcherQueue dispatcher, Action openSettings, Action<string, bool> openSettingsSection,
        Action captureScreenText, Action openSetupGuide, Action quit, Action<string> log)
    {
        _settings = settings;
        _updates = updates;
        _dispatcher = dispatcher;
        _openSettings = openSettings;
        _openSettingsSection = openSettingsSection;
        _captureScreenText = captureScreenText;
        _openSetupGuide = openSetupGuide;
        _quit = quit;
        _log = log;
        _icon = new NotifyIcon(IconPath(), !settings.Current.PopGuyEnabled, "PopGuy", log);
        _icon.MenuItems = MenuItems;
        _icon.Clicked += OnClicked;
        _icon.TaskbarThemeChanged += Refresh;
        _settings.Changed += OnSettingsChanged;
    }

    /// <summary>The session ends (see <see cref="NotifyIcon.SessionEnding"/>). UI thread, inside the icon's window procedure.</summary>
    public event Action? SessionEnding
    {
        add => _icon.SessionEnding += value;
        remove => _icon.SessionEnding -= value;
    }

    /// <summary>Removes the icon. UI thread, never from one of the menu's clicks.</summary>
    public void Dispose()
    {
        _settings.Changed -= OnSettingsChanged;
        _icon.Clicked -= OnClicked;
        _icon.TaskbarThemeChanged -= Refresh;
        _captureTimer?.Stop();
        _icon.Dispose();
    }

    /// <summary>The icon for the taskbar's theme: <c>TrayIcon-light.ico</c> (dark glyph) on a light taskbar.</summary>
    private static string IconPath() => Path.Combine(
        AppContext.BaseDirectory, "Assets", NotifyIcon.TaskbarUsesLightTheme() ? "TrayIcon-light.ico" : "TrayIcon-dark.ico");

    private IReadOnlyList<NotifyIconMenuItem> MenuItems()
    {
        var current = _settings.Current;
        var enabled = current.PopGuyEnabled;
        List<NotifyIconMenuItem> items = [];
        // macOS: "Update to vX…" and a separator first while an update waits (Update now restarts PopGuy).
        if (_updates.State == UpdateState.Ready)
        {
            items.Add(new($"Update to v{_updates.PendingVersion}…", () => _dispatcher.TryEnqueue(_updates.ApplyAndRestart)));
            items.Add(NotifyIconMenuItem.Separator);
        }
        items.AddRange(
        [
            new(enabled ? "Disable PopGuy" : "Enable PopGuy",
                () => Toggle("popGuyEnabled", s => s with { PopGuyEnabled = !s.PopGuyEnabled })),
            NotifyIconMenuItem.Separator,
            // Greyed out while the master switch is off (macOS parity).
            new("Show on Text Selection",
                () => Toggle("triggerOnSelect", s => s with { TriggerOnSelectEnabled = !s.TriggerOnSelectEnabled }),
                Enabled: enabled, Checked: current.TriggerOnSelectEnabled),
            new("Show on Double-Click",
                () => Toggle("triggerDoubleClick", s => s with { TriggerDoubleClickEnabled = !s.TriggerDoubleClickEnabled }),
                Enabled: enabled, Checked: current.TriggerDoubleClickEnabled),
            // Queued like the others: a capture makes windows, which must not happen inside the icon's window procedure.
            new("Capture Screen Text…", () => _dispatcher.TryEnqueue(CaptureScreenText)),
            NotifyIconMenuItem.Separator,
            new("Settings…", () => _dispatcher.TryEnqueue(() => _openSettings())),
            new("History…", () => _dispatcher.TryEnqueue(() => _openSettingsSection("History", false))),
            new("About PopGuy…", () => _dispatcher.TryEnqueue(() => _openSettingsSection("About", false))),
            new("Setup Guide…", () => _dispatcher.TryEnqueue(() => _openSetupGuide())),
            NotifyIconMenuItem.Separator,
            // On About, where the result shows (macOS: Sparkle's window for a check the user starts).
            new("Check for Updates…", () => _dispatcher.TryEnqueue(() =>
            {
                _openSettingsSection("About", false);
                _updates.CheckNow();
            }), Enabled: _updates.CanCheck),
            NotifyIconMenuItem.Separator,
            // Queued: quitting disposes the icon, which must not happen inside its own window procedure.
            new("Quit PopGuy", () => _dispatcher.TryEnqueue(() => _quit())),
        ]);
        return items;
    }

    private void OnClicked() => _dispatcher.TryEnqueue(() => _openSettings());

    private static readonly TimeSpan MenuFadeDelay = TimeSpan.FromMilliseconds(350);

    /// <summary>
    /// macOS captureScreenTextOCR: a capture once Screen Text Capture is on (read at the click), else Settings › Triggers
    /// at the OCR section, so the item never silently does nothing. Not gated by the master switch (macOS).
    /// </summary>
    private void CaptureScreenText()
    {
        if (!_settings.Current.OcrEnabled)
        {
            _openSettingsSection("Triggers", true);
            return;
        }
        // The menu fades out after the click: capturing at once froze it into the picture. A second click while it waits
        // restarts the wait: one capture.
        if (_captureTimer is null)
        {
            _captureTimer = _dispatcher.CreateTimer();
            _captureTimer.Interval = MenuFadeDelay;
            _captureTimer.IsRepeating = false;
            _captureTimer.Tick += (t, _) =>
            {
                t.Stop();
                _captureScreenText();
            };
        }
        _captureTimer.Stop();
        _captureTimer.Start();
    }

    /// <summary>Flips one setting; <see cref="SettingsStore.Changed"/> then updates the triggers and the icon.</summary>
    private void Toggle(string key, Func<AppSettings, AppSettings> change)
    {
        try
        {
            _settings.Update(change);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log($"settings: {key} not saved, {e.GetType().Name}");
        }
    }

    /// <summary>Queued: a change may be saved from any thread, and the icon is UI thread only.</summary>
    private void OnSettingsChanged(object? sender, EventArgs e) => _dispatcher.TryEnqueue(Refresh);

    /// <summary>The icon for the current taskbar theme, dimmed while PopGuy is disabled. A disposed icon ignores it.</summary>
    private void Refresh() => _icon.SetIcon(IconPath(), !_settings.Current.PopGuyEnabled);
}
