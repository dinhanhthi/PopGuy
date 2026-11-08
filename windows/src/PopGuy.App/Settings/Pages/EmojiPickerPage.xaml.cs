using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PopGuy.Controls;
using PopGuy.Core.Emojis;
using PopGuy.Core.Settings;
using PopGuy.Platform.Input;
using PopGuy.Services;

namespace PopGuy.Settings.Pages;

/// <summary>
/// Settings → Emoji (macOS EmojiPickerSettingsView.swift). The navigation parameter is the AppServices. Every control
/// saves through <see cref="SettingsStore.Update"/> at once; its <see cref="SettingsStore.Changed"/> applies the hotkeys.
/// While the picker shortcut records, PopGuy's own hotkeys and chord are off (<see cref="AppServices.SetHotkeysSuspended"/>)
/// so a combo PopGuy owns reaches the recorder; after each apply its registration status shows under its row. Clear
/// deletes the Frequently Used history and is enabled only while one is saved.
/// </summary>
public sealed partial class EmojiPickerPage : Page
{
    private AppServices? _services;
    private bool _subscribed;

    /// <summary>The controls are being set from the settings: their change events are not the user's.</summary>
    private bool _syncing;

    public EmojiPickerPage()
    {
        InitializeComponent();
        PickerToggle.Toggled += (_, _) =>
            Save("emojiPickerEnabled", s => s with { EmojiPickerEnabled = PickerToggle.IsOn });
        ShortcutClearButton.Click += (_, _) => Save("emojiPickerShortcut", s => s with { EmojiPickerShortcut = null });
        ShortcutRecordButton.Click += (_, _) => PickerRecorder.Start();
        PickerRecorder.RecordingStarted += OnRecordingStarted;
        PickerRecorder.RecordingEnded += OnRecordingEnded;
        HoverTooltip.SetText(ShortcutClearButton, "Remove shortcut");
        HoverTooltip.SetText(ShortcutRecordButton, "Record shortcut");
        SkinToneBox.SelectionChanged += (_, _) =>
        {
            if (SkinToneBox.SelectedIndex < 0) return;
            Save("emojiSkinTone", s => s with { EmojiSkinTone = (SkinTone)SkinToneBox.SelectedIndex });
        };
        ClearFrequentlyUsedButton.Click += (_, _) => OnClearFrequentlyUsed();
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
        PickerToggle.IsOn = current.EmojiPickerEnabled;
        ShortcutCard.IsEnabled = current.EmojiPickerEnabled;
        if (!PickerRecorder.IsRecording) PickerRecorder.Shortcut = current.EmojiPickerShortcut;
        SkinToneBox.SelectedIndex = (int)current.EmojiSkinTone;
        _syncing = false;
        RefreshRecorderButtons();
        RefreshStatus();
        RefreshClearButton();
    }

    // Shortcut.

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
            Save("emojiPickerShortcut", s => s with { EmojiPickerShortcut = recorded });
        }
        else if (outcome == ShortcutKeyOutcome.Clear)
        {
            Save("emojiPickerShortcut", s => s with { EmojiPickerShortcut = null });
        }
        _services?.SetHotkeysSuspended(false);
        RefreshRecorderButtons();
    }

    private void RefreshRecorderButtons() =>
        ShortcutRowStatus.RefreshButtons(PickerRecorder, ShortcutClearButton, ShortcutRecordButton);

    /// <summary>A message under the row when Windows refused the shortcut; nothing while recording or while off.</summary>
    private void RefreshStatus()
    {
        if (_services is null) return;
        var current = _services.Settings.Current;
        ShortcutRowStatus.Show(ShortcutStatusText,
            !PickerRecorder.IsRecording && current.EmojiPickerEnabled && current.EmojiPickerShortcut is { } shortcut
                ? ShortcutRowStatus.Message(current, _services.HotkeyRegistrations, HotkeyService.EmojiPickerId, shortcut)
                : null);
    }

    // Frequently Used.

    /// <summary>macOS: Clear only while a history is saved (read when the page shows, and after a clear).</summary>
    private void RefreshClearButton()
    {
        if (_services is null) return;
        ClearFrequentlyUsedButton.IsEnabled = File.Exists(_services.Paths.EmojiUsageFile);
    }

    private void OnClearFrequentlyUsed()
    {
        _services?.EmojiPicker.ClearFrequentlyUsed();
        RefreshClearButton();
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
