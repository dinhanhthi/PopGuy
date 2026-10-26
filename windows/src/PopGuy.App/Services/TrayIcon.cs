using Microsoft.UI.Dispatching;
using PopGuy.Core.Settings;
using PopGuy.Platform.SystemServices;

namespace PopGuy.Services;

/// <summary>
/// The tray icon and its menu (spec-3 §5.9, the macOS status item): Disable/Enable PopGuy, Show on Text Selection,
/// Show on Double-Click, Settings… and Quit PopGuy, rebuilt from the settings each time it opens. Later phases add
/// Capture Screen Text…, History… and About PopGuy… (20.3), Setup Guide… (22) and the update items (23); the macOS
/// Accessibility items have no Windows counterpart. The icon follows the taskbar's theme (a dark glyph on a light
/// taskbar, a white one on a dark taskbar) and dims while PopGuy is disabled. A left click opens Settings.
/// <para>
/// Toggles save through <see cref="SettingsStore.Update"/>, whose <see cref="SettingsStore.Changed"/> also re-applies
/// the triggers (ToolbarController). Create, use and dispose on the UI thread.
/// </para>
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    private readonly SettingsStore _settings;
    private readonly DispatcherQueue _dispatcher;
    private readonly Action _openSettings;
    private readonly Action _quit;
    private readonly Action<string> _log;
    private readonly NotifyIcon _icon;

    /// <param name="openSettings">Opens the Settings window. Runs from the dispatcher queue, after the menu closed.</param>
    /// <param name="quit">Quit PopGuy. Runs from the dispatcher queue, never inside the icon's window procedure.</param>
    /// <exception cref="System.ComponentModel.Win32Exception">Windows refused the icon's window.</exception>
    public TrayIcon(SettingsStore settings, DispatcherQueue dispatcher, Action openSettings, Action quit, Action<string> log)
    {
        _settings = settings;
        _dispatcher = dispatcher;
        _openSettings = openSettings;
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
        _icon.Dispose();
    }

    /// <summary>The icon for the taskbar's theme: <c>TrayIcon-light.ico</c> (dark glyph) on a light taskbar.</summary>
    private static string IconPath() => Path.Combine(
        AppContext.BaseDirectory, "Assets", NotifyIcon.TaskbarUsesLightTheme() ? "TrayIcon-light.ico" : "TrayIcon-dark.ico");

    private IReadOnlyList<NotifyIconMenuItem> MenuItems()
    {
        var current = _settings.Current;
        var enabled = current.PopGuyEnabled;
        return
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
            NotifyIconMenuItem.Separator,
            new("Settings…", () => _dispatcher.TryEnqueue(() => _openSettings())),
            NotifyIconMenuItem.Separator,
            // Queued: quitting disposes the icon, which must not happen inside its own window procedure.
            new("Quit PopGuy", () => _dispatcher.TryEnqueue(() => _quit())),
        ];
    }

    private void OnClicked() => _dispatcher.TryEnqueue(() => _openSettings());

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
