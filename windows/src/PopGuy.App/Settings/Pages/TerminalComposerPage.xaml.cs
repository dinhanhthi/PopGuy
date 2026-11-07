using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PopGuy.Composer;
using PopGuy.Controls;
using PopGuy.Core.Settings;
using PopGuy.Platform.Capture;
using PopGuy.Platform.Input;
using PopGuy.Services;

namespace PopGuy.Settings.Pages;

/// <summary>
/// Settings → Composer (macOS TerminalComposerView.swift). The navigation parameter is the AppServices. Every
/// control saves through <see cref="SettingsStore.Update"/> at once; its <see cref="SettingsStore.Changed"/> applies the
/// hotkeys. While the Compose shortcut records, PopGuy's own hotkeys and chord are off
/// (<see cref="AppServices.SetHotkeysSuspended"/>) so a combo PopGuy owns reaches the recorder; after each apply its
/// registration status shows under its row. The command row installs or removes popguy-edit off the UI thread.
/// </summary>
public sealed partial class TerminalComposerPage : Page
{
    private AppServices? _services;
    private bool _subscribed;

    /// <summary>The controls are being set from the settings: their change events are not the user's.</summary>
    private bool _syncing;

    private const string PowerShellSnippet = "setx VISUAL popguy-edit";
    private const string ClaudeSnippet = "{ \"env\": { \"VISUAL\": \"popguy-edit\" } }";
    private const string GitSnippet = "git config --global core.editor popguy-edit";

    /// <summary>An Install or Remove of the popguy-edit command is running.</summary>
    private bool _commandBusy;

    public TerminalComposerPage()
    {
        InitializeComponent();
        ComposerToggle.Toggled += (_, _) =>
            Save("terminalComposerEnabled", s => s with { TerminalComposerEnabled = ComposerToggle.IsOn });
        ComposeClearButton.Click += (_, _) => Save("composeShortcut", s => s with { ComposeShortcut = null });
        ComposeRecordButton.Click += (_, _) => ComposeRecorder.Start();
        ComposeRecorder.RecordingStarted += OnRecordingStarted;
        ComposeRecorder.RecordingEnded += OnRecordingEnded;
        HoverTooltip.SetText(ComposeClearButton, "Remove shortcut");
        HoverTooltip.SetText(ComposeRecordButton, "Record shortcut");
        CommandButton.Click += (_, _) => OnCommandClick();
        SnippetPowerShellText.Text = PowerShellSnippet;
        SnippetClaudeText.Text = ClaudeSnippet;
        SnippetGitText.Text = GitSnippet;
        SnippetPowerShellCopyButton.Click += (_, _) => Copy(PowerShellSnippet, "powershell");
        SnippetClaudeCopyButton.Click += (_, _) => Copy(ClaudeSnippet, "claude");
        SnippetGitCopyButton.Click += (_, _) => Copy(GitSnippet, "git");
        HoverTooltip.SetText(SnippetPowerShellCopyButton, "Copy");
        HoverTooltip.SetText(SnippetClaudeCopyButton, "Copy");
        HoverTooltip.SetText(SnippetGitCopyButton, "Copy");
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
            _services.Settings.Changed += OnSettingsChanged;
            _services.HotkeysApplied += OnHotkeysApplied;
        }
        _subscribed = true;
        Refresh();
    }

    /// <summary>
    /// The window's first-show re-attach takes the page out and puts it back in one tick, and its Loaded may come before
    /// this Unloaded: a page still loaded keeps listening. (The recorder cancels itself when it really leaves.)
    /// </summary>
    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_services is null || IsLoaded) return;
        _services.Settings.Changed -= OnSettingsChanged;
        _services.HotkeysApplied -= OnHotkeysApplied;
        _subscribed = false;
    }

    /// <summary>Queued: a change may be saved from any thread.</summary>
    private void OnSettingsChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    /// <summary>Raised on the thread pool once the hotkeys are registered again.</summary>
    private void OnHotkeysApplied() => DispatcherQueue.TryEnqueue(RefreshStatus);

    /// <summary>Every control shows the current settings.</summary>
    private void Refresh()
    {
        if (_services is null) return;
        var current = _services.Settings.Current;
        _syncing = true;
        ComposerToggle.IsOn = current.TerminalComposerEnabled;
        ComposeShortcutCard.IsEnabled = current.TerminalComposerEnabled;
        if (!ComposeRecorder.IsRecording) ComposeRecorder.Shortcut = current.ComposeShortcut;
        _syncing = false;
        RefreshRecorderButtons();
        RefreshStatus();
        RefreshCommand();
    }

    // Compose shortcut.

    /// <summary>The hotkeys go off first, so the combo the user presses reaches the recorder.</summary>
    private void OnRecordingStarted()
    {
        _services?.SetHotkeysSuspended(true);
        RefreshRecorderButtons();
        RefreshStatus();
    }

    /// <summary>Saves the recorded (or cleared) shortcut, then turns the hotkeys back on: the status follows that apply.</summary>
    private void OnRecordingEnded(ShortcutKeyOutcome outcome, Shortcut? recorded)
    {
        if (outcome == ShortcutKeyOutcome.Record)
        {
            Save("composeShortcut", s => s with { ComposeShortcut = recorded });
        }
        else if (outcome == ShortcutKeyOutcome.Clear)
        {
            Save("composeShortcut", s => s with { ComposeShortcut = null });
        }
        _services?.SetHotkeysSuspended(false);
        RefreshRecorderButtons();
    }

    private void RefreshRecorderButtons() =>
        ShortcutRowStatus.RefreshButtons(ComposeRecorder, ComposeClearButton, ComposeRecordButton);

    /// <summary>A message under the row when Windows refused the shortcut; nothing while recording or while off.</summary>
    private void RefreshStatus()
    {
        if (_services is null) return;
        var current = _services.Settings.Current;
        ShortcutRowStatus.Show(ComposeStatusText,
            !ComposeRecorder.IsRecording && current.TerminalComposerEnabled && current.ComposeShortcut is { } compose
                ? ShortcutRowStatus.Message(current, _services.HotkeyRegistrations, HotkeyService.ComposeId, compose)
                : null);
    }

    // Command and snippets.

    /// <summary>The popguy-edit command's status (a quick registry read) and the button that flips it.</summary>
    private void RefreshCommand()
    {
        var installed = CommandInstaller.Status == CommandInstallStatus.Installed;
        CommandStatusText.Text = installed ? "Installed — popguy-edit is on your PATH." : "Not installed.";
        CommandButton.Content = installed ? "Remove" : "Install";
        CommandButton.IsEnabled = !_commandBusy;
    }

    /// <summary>
    /// Installs or removes the command off the UI thread (its environment broadcast can block for seconds); the button
    /// stays disabled until it is done, then the status is read again.
    /// </summary>
    private void OnCommandClick()
    {
        if (_commandBusy || _services is not { } services) return;
        var install = CommandInstaller.Status != CommandInstallStatus.Installed;
        _commandBusy = true;
        CommandButton.IsEnabled = false;
        var queue = DispatcherQueue;
        _ = Task.Run(() =>
        {
            var ok = install ? CommandInstaller.Install() : CommandInstaller.Remove();
            services.Log.Write($"composer command {(install ? "install" : "remove")}: {(ok ? "done" : "failed")}");
            queue.TryEnqueue(() =>
            {
                _commandBusy = false;
                RefreshCommand();
            });
        });
    }

    /// <summary>A deliberate copy, as History's: off the UI thread; the log gets the outcome only.</summary>
    private void Copy(string text, string what)
    {
        if (_services is not { } services) return;
        _ = Task.Run(() =>
        {
            try
            {
                services.Log.Write($"snippet copy {what}: written {ClipboardGuard.WriteText(text, excludeFromHistory: false)}");
            }
            catch (Exception e)
            {
                services.Log.Write($"snippet copy {what}: failed, {e.GetType().Name}");
            }
        });
    }

    /// <summary>Saves one change; a failed write is logged and the controls go back to the saved settings.</summary>
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
