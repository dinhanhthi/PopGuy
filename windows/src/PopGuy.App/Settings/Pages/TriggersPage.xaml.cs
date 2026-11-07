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
/// the replacement or the Screen Text Capture shortcut records, PopGuy's own hotkeys and chord are off
/// (<see cref="AppServices.SetHotkeysSuspended"/>) so a combo PopGuy owns reaches the recorder; after each apply each
/// one's registration status shows under its row. A change from elsewhere (the tray) shows while the page is open. A
/// SelectorBar (as on the Ignore page) shows the On Text Selection, Keyboard Shortcut or Screen Text Capture (OCR) tab;
/// a new page opens on On Text Selection, and the tray's Capture Screen Text… selects the OCR tab
/// (<see cref="FocusOcrSection"/>).
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
        TabBar.SelectedItem = TabBar.Items[0];
        TabBar.SelectionChanged += (_, _) => ShowTab();
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
        OcrToggle.Toggled += (_, _) => Save("ocrEnabled", s => s with { OcrEnabled = OcrToggle.IsOn });
        OcrClearButton.Click += (_, _) => Save("ocrShortcut", s => s with { OcrShortcut = null });
        OcrRecordButton.Click += (_, _) => OcrRecorder.Start();
        OcrRecorder.RecordingStarted += OnRecordingStarted;
        OcrRecorder.RecordingEnded += OnOcrRecordingEnded;
        HoverTooltip.SetText(ClearButton, "Clear — revert to Ctrl+C+C");
        HoverTooltip.SetText(RecordButton, "Record a replacement shortcut (e.g. Ctrl+Shift+Space)");
        HoverTooltip.SetText(OcrClearButton, "Remove shortcut");
        HoverTooltip.SetText(OcrRecordButton, "Record shortcut");
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
        OcrToggle.IsOn = current.OcrEnabled;
        // macOS: the shortcut row is disabled until the feature is on.
        OcrShortcutCard.IsEnabled = current.OcrEnabled;
        if (!OcrRecorder.IsRecording) OcrRecorder.Shortcut = current.OcrShortcut;
        _syncing = false;
        RefreshRecorderButtons();
        RefreshStatus();
    }

    /// <summary>Selects the OCR tab (macOS scrollToOCRSectionIfRequested), loaded or not.</summary>
    internal void FocusOcrSection()
    {
        TabBar.SelectedItem = TabBar.Items[2];
        ShowTab();
    }

    /// <summary>The picked tab's panel, scrolled to its top.</summary>
    private void ShowTab()
    {
        var index = TabBar.Items.IndexOf(TabBar.SelectedItem);
        if (index < 0) return;
        SelectionTab.Visibility = index == 0 ? Visibility.Visible : Visibility.Collapsed;
        ShortcutTab.Visibility = index == 1 ? Visibility.Visible : Visibility.Collapsed;
        OcrTab.Visibility = index == 2 ? Visibility.Visible : Visibility.Collapsed;
        TabScroller.ChangeView(null, 0, null, disableAnimation: true);
    }

    // Default action (macOS doubleClickActionPicker).

    /// <summary>
    /// "Unassign (show toolbar)", then every id in the action order; the assigned one selected. The items are rebuilt
    /// only when their labels changed.
    /// </summary>
    private void RefreshPicker(AppSettings current)
    {
        _pickerIds = current.ActionOrder;
        List<string> labels =
            ["Unassign (show toolbar)", .. _pickerIds.Select(id => ShortcutRowStatus.ActionLabel(current, id))];
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

    // Replacement and Screen Text Capture shortcuts.

    /// <summary>The hotkeys go off first, so the combo the user presses reaches the recorder (either one).</summary>
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

    /// <summary>As <see cref="OnRecordingEnded"/>, for the Screen Text Capture shortcut.</summary>
    private void OnOcrRecordingEnded(ShortcutKeyOutcome outcome, Shortcut? recorded)
    {
        if (outcome == ShortcutKeyOutcome.Record)
        {
            Save("ocrShortcut", s => s with { OcrShortcut = recorded });
        }
        else if (outcome == ShortcutKeyOutcome.Clear)
        {
            Save("ocrShortcut", s => s with { OcrShortcut = null });
        }
        _services?.SetHotkeysSuspended(false);
        RefreshRecorderButtons();
    }

    private void RefreshRecorderButtons()
    {
        ShortcutRowStatus.RefreshButtons(Recorder, ClearButton, RecordButton);
        ShortcutRowStatus.RefreshButtons(OcrRecorder, OcrClearButton, OcrRecordButton);
    }

    /// <summary>
    /// A message under the replacement's and the Screen Text Capture shortcut's rows when Windows refused one; nothing
    /// while recording or when it is not registered at all (its feature is off).
    /// </summary>
    private void RefreshStatus()
    {
        if (_services is null) return;
        var current = _services.Settings.Current;
        var registrations = _services.HotkeyRegistrations;
        ShortcutRowStatus.Show(ReplacementStatusText,
            !Recorder.IsRecording && current.TriggerChordEnabled && current.ChordReplacementShortcut is { } replacement
                ? ShortcutRowStatus.Message(current, registrations, HotkeyService.ChordReplacementId, replacement)
                : null);
        ShortcutRowStatus.Show(OcrStatusText,
            !OcrRecorder.IsRecording && current.OcrEnabled && current.OcrShortcut is { } ocr
                ? ShortcutRowStatus.Message(current, registrations, HotkeyService.OcrCaptureId, ocr)
                : null);
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
