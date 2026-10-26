using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.Settings;
using PopGuy.Platform.Input;
using PopGuy.Services;

namespace PopGuy.Settings.Pages;

/// <summary>
/// Settings → Triggers (macOS TriggersView.swift, spec-3 §5.4). The navigation parameter is the AppServices. Every
/// control saves through <see cref="SettingsStore.Update"/> at once; its <see cref="SettingsStore.Changed"/> applies the
/// triggers and hotkeys. The double-click Default action lists every action of the action order, enabled or not. While
/// the replacement shortcut records, PopGuy's own hotkeys and chord are off (<see cref="AppServices.SetHotkeysSuspended"/>)
/// so a combo PopGuy owns reaches the recorder; after each apply the replacement's registration status shows under the
/// row. A change from elsewhere (the tray) shows while the page is open.
/// </summary>
public sealed partial class TriggersPage : Page
{
    private AppServices? _services;
    private bool _subscribed;

    /// <summary>The controls are being set from the settings: their change events are not the user's.</summary>
    private bool _syncing;

    /// <summary>The Default action picker's ids, after its first "Unassign (show toolbar)" item.</summary>
    private IReadOnlyList<ActionIdentifier> _pickerIds = [];

    public TriggersPage()
    {
        InitializeComponent();
        OnSelectToggle.Toggled += (_, _) =>
            Save("triggerOnSelect", s => s with { TriggerOnSelectEnabled = OnSelectToggle.IsOn });
        EditableOnlyToggle.Toggled += (_, _) =>
            Save("triggerOnSelectEditableOnly", s => s with { TriggerOnSelectEditableOnly = EditableOnlyToggle.IsOn });
        DoubleClickToggle.Toggled += (_, _) =>
            Save("triggerDoubleClick", s => s with { TriggerDoubleClickEnabled = DoubleClickToggle.IsOn });
        DefaultActionBox.SelectionChanged += (_, _) => OnDefaultActionChanged();
        ChordToggle.Toggled += (_, _) => Save("triggerChord", s => s with { TriggerChordEnabled = ChordToggle.IsOn });
        ClearButton.Click += (_, _) => Save("chordReplacementShortcut", s => s with { ChordReplacementShortcut = null });
        RecordButton.Click += (_, _) => Recorder.Start();
        Recorder.RecordingStarted += OnRecordingStarted;
        Recorder.RecordingEnded += OnRecordingEnded;
        HoverTooltip.SetText(ClearButton, "Clear — revert to Ctrl+C+C");
        HoverTooltip.SetText(RecordButton, "Record a replacement shortcut (e.g. Ctrl+Shift+Space)");
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
        OnSelectToggle.IsOn = current.TriggerOnSelectEnabled;
        EditableOnlyToggle.IsOn = current.TriggerOnSelectEditableOnly;
        EditableOnlyCard.IsEnabled = current.TriggerOnSelectEnabled;
        DoubleClickToggle.IsOn = current.TriggerDoubleClickEnabled;
        DefaultActionCard.Visibility = current.TriggerDoubleClickEnabled ? Visibility.Visible : Visibility.Collapsed;
        RefreshPicker(current);
        ChordToggle.IsOn = current.TriggerChordEnabled;
        ReplacementCard.IsEnabled = current.TriggerChordEnabled;
        if (!Recorder.IsRecording) Recorder.Shortcut = current.ChordReplacementShortcut;
        _syncing = false;
        RefreshRecorderButtons();
        RefreshStatus();
    }

    // Default action (macOS doubleClickActionPicker).

    /// <summary>
    /// "Unassign (show toolbar)", then every id in the action order; the assigned one selected. The items are rebuilt
    /// only when their labels changed.
    /// </summary>
    private void RefreshPicker(AppSettings current)
    {
        _pickerIds = current.ActionOrder;
        List<string> labels = ["Unassign (show toolbar)", .. _pickerIds.Select(id => ActionLabel(current, id))];
        if (!labels.SequenceEqual(DefaultActionBox.Items.OfType<string>()))
        {
            DefaultActionBox.Items.Clear();
            foreach (var label in labels) DefaultActionBox.Items.Add(label);
        }
        var index = current.DoubleClickAssignedAction is { } assigned ? IndexOf(_pickerIds, assigned) : -1;
        DefaultActionBox.SelectedIndex = index + 1;
    }

    private void OnDefaultActionChanged()
    {
        var index = DefaultActionBox.SelectedIndex;
        if (index < 0) return;
        ActionIdentifier? assigned = index == 0 || index > _pickerIds.Count ? null : _pickerIds[index - 1];
        Save("doubleClickAssignedAction", s => s with { DoubleClickAssignedAction = assigned });
    }

    private static int IndexOf(IReadOnlyList<ActionIdentifier> ids, ActionIdentifier id)
    {
        for (var i = 0; i < ids.Count; i++)
        {
            if (ids[i] == id) return i;
        }
        return -1;
    }

    /// <summary>The picker's label for an action (macOS TriggersView.actionLabel).</summary>
    private static string ActionLabel(AppSettings settings, ActionIdentifier id) => id.Type switch
    {
        ActionIdentifierType.Builtin => id.BuiltinKind switch
        {
            ActionKind.Improve => "Improve",
            ActionKind.Shorten => "Shorten",
            ActionKind.Proofread => "Proofread",
            ActionKind.Translate => "Translate",
            ActionKind.Prompt => "Prompt",
            _ => "Custom",
        },
        ActionIdentifierType.Speak => "Speak",
        ActionIdentifierType.Dictionary => "Look up",
        _ => settings.CustomActions.FirstOrDefault(a => a.Id == id.CustomId)?.Title ?? "Custom",
    };

    // Replacement shortcut.

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
            Save("chordReplacementShortcut", s => s with { ChordReplacementShortcut = recorded });
        }
        else if (outcome == ShortcutKeyOutcome.Clear)
        {
            Save("chordReplacementShortcut", s => s with { ChordReplacementShortcut = null });
        }
        _services?.SetHotkeysSuspended(false);
        RefreshRecorderButtons();
    }

    /// <summary>macOS: the clear button only with a shortcut; neither button while recording.</summary>
    private void RefreshRecorderButtons()
    {
        var recording = Recorder.IsRecording;
        ClearButton.Visibility = !recording && Recorder.Shortcut is not null ? Visibility.Visible : Visibility.Collapsed;
        RecordButton.Visibility = recording ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>
    /// "Shortcut in use by another app" when Windows refused the replacement's registration (another app, or one of
    /// PopGuy's own action hotkeys, has the keys); nothing while recording or when it is not registered at all.
    /// </summary>
    private void RefreshStatus()
    {
        if (_services is null) return;
        var current = _services.Settings.Current;
        HotkeyStatus? status = null;
        if (!Recorder.IsRecording && current.TriggerChordEnabled && current.ChordReplacementShortcut is { } shortcut)
        {
            status = _services.HotkeyRegistrations
                .FirstOrDefault(r => r.Id == HotkeyService.ChordReplacementId && r.Shortcut == shortcut)?.Status;
        }
        var message = status switch
        {
            HotkeyStatus.InUse => "Shortcut in use by another app",
            HotkeyStatus.Invalid => "Windows refused this shortcut",
            _ => null,
        };
        ReplacementStatusText.Text = message ?? "";
        ReplacementStatusText.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
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
