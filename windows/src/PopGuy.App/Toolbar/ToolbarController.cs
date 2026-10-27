using System.Drawing;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Media.Imaging;
using PopGuy.Core.Actions;
using PopGuy.Core.Dictionaries;
using PopGuy.Core.Settings;
using PopGuy.Core.Speak;
using PopGuy.Core.Toolbar;
using PopGuy.Ocr;
using PopGuy.Platform.Browser;
using PopGuy.Platform.Capture;
using PopGuy.Platform.Input;
using PopGuy.Platform.Output;
using PopGuy.Platform.SystemServices;
using PopGuy.Platform.Windowing;
using Windows.Graphics.Imaging;

namespace PopGuy.Toolbar;

/// <summary>
/// Wires the triggers to the toolbar (macOS <c>ToolbarController.swift</c>, spec-1 §1.3-1.5): the Ctrl+C+C chord, the
/// chord-replacement hotkey and the per-action hotkeys capture the selection, pass <see cref="PresentationGate"/> and
/// show <see cref="ToolbarWindow"/> below the selection (or at the cursor); an action hotkey then runs its action (the
/// Prompt hotkey opens the prompt input). The passive selections of <see cref="SelectionPipeline"/> (a drag, a keyboard
/// selection, a double-click) are routed by spec-1 §1.3 and shown at the gesture; only a double-click with an assigned
/// action runs one. It also handles the toolbar's clicks (actions, the prompt, Stop, Copy, Paste back, Close, Ignore
/// this site, Ignore this app, Settings), a script action's after-run delivery (spec-4 §4.4) and the dismissal rules of
/// spec-1 §3.8. Speak and a Speech custom action (its button, its hotkey, an assigned double-click) toggle
/// <see cref="SpeakCoordinator"/> on the selection, orthogonal to the action runs; closing the toolbar or a new selection
/// drops its "Listen again" (macOS). Look up and
/// Dictionary custom actions run through the session like the other actions; a lookup's Listen speaks its headword.
/// While Ignored Domains is on, a selection in a browser reads the tab's host (<see cref="BrowserUrlReader"/>) before it
/// is presented: the gate's ignored domains and <c>{{domain}}</c> use it (macOS reads it only then, too). The OCR
/// hotkey and the tray's Capture Screen Text… start an <see cref="OcrCaptureController"/> capture, whose text shows
/// like a selection with no source app, copy-only, under a thumbnail of the region (macOS handleOCRCapture).
/// <para>
/// Threading: the chord and hotkey events and the three input loops run on the thread pool; everything that touches the
/// window, the view model or the presentation state runs on the UI thread (<see cref="DispatcherQueue"/>). Captures
/// and clipboard writes run off it, and so does the browser read. Selected text, results and clipboard contents are never
/// logged, only lengths; browser addresses and hosts are never logged either.
/// </para>
/// </summary>
internal sealed class ToolbarController : IDisposable
{
    private const string AdminAppMessage = "PopGuy can't read or paste in apps running as administrator.";

    private static readonly ActionIdentifier PromptId = ActionIdentifier.Builtin(ActionKind.Prompt);

    private readonly SettingsStore _settings;
    private readonly ToolbarSession _session;
    private readonly SpeakCoordinator _speak;
    private readonly ToolbarWindow _window;
    private readonly ToolbarViewModel _viewModel;
    private readonly OcrCaptureController _ocr;
    private readonly GlobalInput _input;
    private readonly ChordMonitor _chord;
    private readonly HotkeyService _hotkeys;
    private readonly SelectionPipeline _pipeline;
    private readonly DispatcherQueue _dispatcher;
    private readonly Action<string> _log;
    private readonly CancellationTokenSource _stop = new();

    /// <summary>The toolbar's window handle, for the pool threads.</summary>
    private readonly nint _toolbarHwnd;

    /// <summary>One capture at a time (the chord and the hotkeys can fire together). Interlocked.</summary>
    private int _capturing;

    /// <summary>Settings' shortcut recorder listens: no hotkey and no chord, so every key reaches it. Any thread.</summary>
    private volatile bool _hotkeysSuspended;

    /// <summary>One settings apply at a time, each reading the latest settings and suspension when it starts.</summary>
    private readonly Lock _applyGate = new();

    /// <summary>The toolbar is on screen, for the pool threads (the window's own flag is UI thread only).</summary>
    private volatile bool _shown;

    /// <summary>The last left press was on the toolbar: its release is not a selection either. Mouse loop only.</summary>
    private bool _pressOnToolbar;

    // UI thread only.
    private CapturedSelection? _current;
    private int _presentation;
    private bool _pasting;

    /// <summary>
    /// Counts passive selections, presses outside the toolbar and shows, so a browser read that finishes after newer
    /// input presents nothing.
    /// </summary>
    private int _passiveSelections;

    /// <summary>A selection the toolbar was (or is about to be) shown for.</summary>
    /// <param name="Text">The selection; "" for <paramref name="Blocked"/>.</param>
    /// <param name="IsEditable">Paste back is offered.</param>
    /// <param name="Selection">UI Automation's first selection rect, or empty (the toolbar then goes to the cursor).</param>
    /// <param name="Source">The foreground app when the trigger fired.</param>
    /// <param name="Blocked">The source runs as administrator: the toolbar shows the admin-app error instead.</param>
    /// <param name="Pointer">A passive selection's release point (a drag or a double-click), else null.</param>
    /// <param name="GrewDownward">A passive drag's direction, else null.</param>
    /// <param name="Host">The browser tab's host (<see cref="ReadHost"/>), else null.</param>
    /// <param name="IsOcr">An OCR capture (<see cref="OcrSource"/>): shown while PopGuy is off too.</param>
    /// <param name="Failure">
    /// An OCR capture that ended without text (with <paramref name="Blocked"/>): the toolbar shows this error instead of
    /// the admin-app one, past the gate.
    /// </param>
    private sealed record CapturedSelection(
        string Text, bool IsEditable, Rectangle Selection, ForegroundApp Source, bool Blocked = false,
        Point? Pointer = null, bool? GrewDownward = null, string? Host = null, bool IsOcr = false, string? Failure = null);

    public ToolbarController(
        SettingsStore settings, ToolbarSession session, SpeakCoordinator speak, ToolbarWindow window, OcrCaptureController ocr,
        GlobalInput input, ChordMonitor chord, HotkeyService hotkeys, SelectionPipeline pipeline, DispatcherQueue dispatcher,
        Action<string> log)
    {
        _settings = settings;
        _session = session;
        _speak = speak;
        _window = window;
        _viewModel = window.ViewModel;
        _ocr = ocr;
        _input = input;
        _chord = chord;
        _hotkeys = hotkeys;
        _pipeline = pipeline;
        _dispatcher = dispatcher;
        _log = log;
        _toolbarHwnd = window.Hwnd;
    }

    /// <summary>The toolbar's Settings button: the App opens the Settings window. UI thread.</summary>
    public event Action? SettingsRequested;

    /// <summary>A settings apply finished: <see cref="HotkeyService.Registrations"/> has the new statuses. Thread pool.</summary>
    public event Action? HotkeysApplied;

    /// <summary>Applies the settings, subscribes and starts the input loops. UI thread, once.</summary>
    public void Start()
    {
        _settings.Changed += OnSettingsChanged;
        _chord.Fired += OnChordFired;
        _hotkeys.Fired += OnHotkeyFired;
        _viewModel.ActionInvoked += RunAction;
        _viewModel.StopRequested += Hide;
        _viewModel.CopyRequested += OnCopyRequested;
        _viewModel.PasteBackRequested += OnPasteBackRequested;
        _viewModel.CloseRequested += RequestDismiss;
        _viewModel.EscapeRequested += RequestDismissKeepingDraft;
        _viewModel.PromptSubmitted += OnPromptSubmitted;
        _viewModel.PromptCancelRequested += Hide;
        _viewModel.CloseAnywayRequested += Hide;
        _viewModel.DisableCloseConfirmationRequested += OnDisableCloseConfirmation;
        _viewModel.IgnoreAppRequested += OnIgnoreApp;
        _viewModel.IgnoreSiteRequested += OnIgnoreSite;
        _viewModel.SettingsRequested += OnSettingsRequested;
        _viewModel.ReplayRequested += OnReplayRequested;
        _viewModel.ListenRequested += OnListenRequested;
        _viewModel.BindSpeak(_speak);
        _session.ScriptFinished += OnScriptFinished;
        _ocr.OnText = OnOcrText;
        _ocr.OnFailed = OnOcrFailed;
        ApplySettings();

        var token = _stop.Token;
        Watch(Task.Run(() => ReadKeysAsync(token)), "keys");
        Watch(Task.Run(() => ReadMouseAsync(token)), "mouse");
        Watch(Task.Run(() => ReadSelectionsAsync(token)), "selections");
    }

    /// <summary>Unsubscribes, stops the loops and hides the toolbar. UI thread.</summary>
    public void Dispose()
    {
        _stop.Cancel();
        _settings.Changed -= OnSettingsChanged;
        _chord.Fired -= OnChordFired;
        _hotkeys.Fired -= OnHotkeyFired;
        _viewModel.ActionInvoked -= RunAction;
        _viewModel.StopRequested -= Hide;
        _viewModel.CopyRequested -= OnCopyRequested;
        _viewModel.PasteBackRequested -= OnPasteBackRequested;
        _viewModel.CloseRequested -= RequestDismiss;
        _viewModel.EscapeRequested -= RequestDismissKeepingDraft;
        _viewModel.PromptSubmitted -= OnPromptSubmitted;
        _viewModel.PromptCancelRequested -= Hide;
        _viewModel.CloseAnywayRequested -= Hide;
        _viewModel.DisableCloseConfirmationRequested -= OnDisableCloseConfirmation;
        _viewModel.IgnoreAppRequested -= OnIgnoreApp;
        _viewModel.IgnoreSiteRequested -= OnIgnoreSite;
        _viewModel.SettingsRequested -= OnSettingsRequested;
        _viewModel.ReplayRequested -= OnReplayRequested;
        _viewModel.ListenRequested -= OnListenRequested;
        _session.ScriptFinished -= OnScriptFinished;
        _ocr.OnText = null;
        _ocr.OnFailed = null;
        Hide();
    }

    // Settings.

    private void OnSettingsChanged(object? sender, EventArgs e) => ApplySettings();

    /// <summary>
    /// Settings' shortcut recorder: while <paramref name="suspended"/>, every hotkey is unregistered and the chord is
    /// off, so a combo PopGuy owns reaches the recorder instead of firing. Applied off the calling thread, like a
    /// settings change. Any thread.
    /// </summary>
    public void SetHotkeysSuspended(bool suspended)
    {
        _hotkeysSuspended = suspended;
        ApplySettings();
    }

    /// <summary>
    /// The chord and the hotkeys follow the settings (bindings, custom actions, the chord flag and replacement, OCR), and
    /// the selection pipeline the passive triggers. Off the calling thread: registering waits on the input thread. Runs
    /// are serialized and each reads the latest settings, so runs that overlap still end on the newest.
    /// </summary>
    private void ApplySettings() => Watch(Task.Run(() =>
    {
        lock (_applyGate)
        {
            var settings = _settings.Current;
            var suspended = _hotkeysSuspended;
            _chord.Apply(settings);
            // The master switch: nothing arms while PopGuy is off (spec-1 §1.4), and speech stops.
            if (!settings.PopGuyEnabled || suspended) _chord.Enabled = false;
            if (!settings.PopGuyEnabled) _speak.Stop();
            // The pipeline also captures for the double-click trigger alone: the routing drops what it does not want.
            _pipeline.Enabled = settings.PopGuyEnabled && (settings.TriggerOnSelectEnabled || settings.TriggerDoubleClickEnabled);
            var hotkeys = suspended
                ? settings with { ShortcutBindings = [], ChordReplacementShortcut = null, OcrShortcut = null }
                : settings;
            var refused = _hotkeys.Apply(hotkeys).Count(r => r.Status != HotkeyStatus.Registered);
            _log($"settings applied: chord {(_chord.Enabled ? "on" : "off")}, selection {(_pipeline.Enabled ? "on" : "off")}, "
                + $"{_hotkeys.Registrations.Count} hotkeys, {refused} refused{(suspended ? ", hotkeys suspended" : "")}");
        }
        HotkeysApplied?.Invoke();
    }), "apply settings");

    // Triggers (pool threads until the hand-off to the UI thread).

    private async Task ReadKeysAsync(CancellationToken token)
    {
        try
        {
            // The one reader of the key channel. Keys typed into the toolbar's own text boxes select nothing in the source.
            await foreach (var key in _input.Keys.ReadAllAsync(token).ConfigureAwait(false))
            {
                _chord.Handle(key);
                if (!(_shown && ToolbarWindowStyle.IsToolbarOrOwnedForeground(_toolbarHwnd))) _pipeline.Handle(key);
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    /// <summary>
    /// The chord (spec-1 §1.4): no-op while the toolbar shows (the chord monitor still restores the clipboard). UI
    /// Automation first; a password field is refused; else the user's own copy, which is not editable. Never a
    /// synthetic copy.
    /// </summary>
    private void OnChordFired(ChordFire fire)
    {
        if (!_settings.Current.PopGuyEnabled || fire.App.IsOwnProcess || _shown) return;
        if (Interlocked.Exchange(ref _capturing, 1) == 1)
        {
            _log("chord: ignored, a capture is running");
            return;
        }
        try
        {
            var uia = UiaSelectionReader.ReadFocused();
            CapturedSelection? capture;
            if (uia.Status == UiaCaptureStatus.Captured)
            {
                capture = new(uia.Text, uia.IsEditable, FirstRect(uia.SelectionRects), fire.App);
            }
            else if (uia.Status == UiaCaptureStatus.PasswordField)
            {
                capture = null;
            }
            else if (fire.ClipboardText is { } text)
            {
                capture = new(text, false, Rectangle.Empty, fire.App);
            }
            else
            {
                // Nothing read: an elevated app gets the admin-app error, anything else no toolbar.
                capture = IsBlocked(fire.App) ? new("", false, Rectangle.Empty, fire.App, Blocked: true) : null;
            }
            if (capture is { Blocked: false }) capture = capture with { Host = ReadHost(fire.App) };
            _log($"chord: uia {uia.Status}, {(capture is null ? "nothing captured" : capture.Blocked ? "blocked" : $"captured {capture.Text.Length} chars")}");
            if (capture is not null) _dispatcher.TryEnqueue(() => Present(capture, autoRun: null));
        }
        catch (Exception e)
        {
            _log($"chord: capture failed, {e.GetType().Name} {e.Message}");
        }
        finally
        {
            Volatile.Write(ref _capturing, 0);
        }
    }

    /// <summary>A hotkey: the source is read at once, before any wait; the rest is decided on the UI thread.</summary>
    private void OnHotkeyFired(ActionIdentifier id)
    {
        if (id == HotkeyService.OcrCaptureId)
        {
            // macOS: the hotkey checks the master switch and the opt-in when it fires (the tray item does not).
            _dispatcher.TryEnqueue(() =>
            {
                var settings = _settings.Current;
                if (settings.PopGuyEnabled && settings.OcrEnabled) BeginOcrCapture();
            });
            return;
        }
        var source = ForegroundApp.Snapshot();
        _dispatcher.TryEnqueue(() => OnHotkey(id, source));
    }

    /// <summary>
    /// The chord replacement behaves like the chord (no-op while showing). An action hotkey (spec-1 §1.5), if the action
    /// is enabled: while the toolbar shows a selection, runs on it (no re-capture); else captures, shows, then runs. The
    /// Prompt hotkey opens the prompt input instead (focused), or closes it when open (macOS triggerPromptInput). The
    /// Speak and Speech action hotkeys speak the same way, or stop speech when it is loading or playing (macOS
    /// triggerAction).
    /// </summary>
    private void OnHotkey(ActionIdentifier id, ForegroundApp source)
    {
        var settings = _settings.Current;
        if (!settings.PopGuyEnabled) return;
        if (id == HotkeyService.ChordReplacementId)
        {
            if (!_window.IsShown) StartCapture(source, autoRun: null);
            return;
        }
        if (!ToolbarLayout.IsEnabled(settings, id)) return;
        if (_window.IsShown && _current is { Blocked: false, Text.Length: > 0 })
        {
            RunAction(id);
            return;
        }
        StartCapture(source, id);
    }

    /// <summary>A full capture (UI Automation, else the synthetic copy where the policy allows it), then the toolbar. UI thread.</summary>
    private void StartCapture(ForegroundApp source, ActionIdentifier? autoRun)
    {
        if (source.IsOwnProcess) return;
        if (Interlocked.Exchange(ref _capturing, 1) == 1)
        {
            _log("hotkey: ignored, a capture is running");
            return;
        }
        Watch(Task.Run(async () =>
        {
            try
            {
                var result = await SelectionCapture.CaptureAsync(CaptureMode.Explicit, source, isUserKeyDown: _input.IsUserKeyDown)
                    .ConfigureAwait(false);
                _log($"hotkey: capture {result.Status} ({result.Reason}, {result.Method}), {result.Text.Length} chars");
                CapturedSelection? capture = result.Status switch
                {
                    SelectionCaptureStatus.Captured => new(result.Text, result.IsEditable, FirstRect(result.SelectionRects), source, Host: ReadHost(source)),
                    SelectionCaptureStatus.Blocked => new("", false, Rectangle.Empty, source, Blocked: true),
                    _ => null,
                };
                if (capture is not null) _dispatcher.TryEnqueue(() => Present(capture, autoRun));
            }
            finally
            {
                Volatile.Write(ref _capturing, 0);
            }
        }), "capture");
    }

    // OCR (UI thread).

    /// <summary>
    /// The OCR hotkey and the tray's Capture Screen Text… (Screen Text Capture is on; the tray opens Settings otherwise):
    /// hides the toolbar, so the freeze-frame does not show it, then starts a capture. Nothing while one runs.
    /// </summary>
    public void BeginOcrCapture()
    {
        if (_ocr.IsCapturing) return;
        Hide();
        _log("ocr: capture started");
        _ocr.BeginCapture();
    }

    /// <summary>
    /// An OCR capture's text (macOS handleOCRCapture): shown like a selection at the mouse-up point, with the region as a
    /// thumbnail above the bar (made first, so the window is sized for it; without it if that fails). The text came from
    /// pixels: not editable (Copy, no Paste back) and no source app (<see cref="OcrSource"/>). Never logged.
    /// </summary>
    private async void OnOcrText(string text, Point anchorPx, SoftwareBitmap bitmap)
    {
        OcrThumbnail? thumbnail = null;
        SoftwareBitmapSource? source = null;
        try
        {
            source = new SoftwareBitmapSource();
            await source.SetBitmapAsync(bitmap);
            thumbnail = new OcrThumbnail(source, bitmap);
        }
        catch (Exception e)
        {
            _log($"ocr: no thumbnail, {e.GetType().Name}");
            source?.Dispose();
            bitmap.Dispose();
        }
        _log($"ocr: {text.Length} chars");
        Present(new CapturedSelection(text, IsEditable: false, Rectangle.Empty, OcrSource(), Pointer: anchorPx, IsOcr: true),
            autoRun: null, thumbnail);
    }

    /// <summary>
    /// An OCR capture that ended without text (macOS: an alert with the title and the message): the toolbar's error at
    /// the pointer, where the user just dragged. Non-blocking and dismissed like any toolbar (Close, a click outside);
    /// a dialog would need a window of its own and take the foreground from the app behind. The message says it all,
    /// so the title only goes to the log (it is one of the controller's fixed titles).
    /// </summary>
    private void OnOcrFailed(string title, string message)
    {
        _log($"ocr: {title}");
        Present(new CapturedSelection("", false, Rectangle.Empty, OcrSource(), Blocked: true,
            Pointer: ToolbarWindowStyle.CursorPosition(), IsOcr: true, Failure: message), autoRun: null);
    }

    /// <summary>
    /// An OCR capture's source: no app (macOS: PopGuy is frontmost after the overlay, so it has no bundle id), so no
    /// Ignore this app, no history source and no ignore-list match; only the foreground window (the capture gave it
    /// back), for the toolbar's foreground hand-back.
    /// </summary>
    private static ForegroundApp OcrSource() =>
        new(ToolbarWindowStyle.ForegroundWindow(), 0, null, "", IsElevated: false, IsOwnProcess: false);

    /// <summary>The one reader of the pipeline's selections: each is routed on the UI thread.</summary>
    private async Task ReadSelectionsAsync(CancellationToken token)
    {
        try
        {
            await foreach (var selection in _pipeline.Events.ReadAllAsync(token).ConfigureAwait(false))
                _dispatcher.TryEnqueue(() => RouteSelection(selection));
        }
        catch (OperationCanceledException)
        {
        }
    }

    /// <summary>
    /// A passive selection (spec-1 §1.3, macOS order): nothing while PopGuy is off or the selection is in PopGuy itself
    /// (as for the chord and the hotkeys). A double-click with its trigger on shows the toolbar, then runs the assigned
    /// action if there is one (macOS doubleClickActionFeatureEnabled is on; the selection is reused, no re-capture), and
    /// skips the text-select gate. Anything else needs the text-select trigger and, with "Only in editable text" on, an
    /// editable selection. Placed at the gesture: the release point and drag direction, or the selection rect (a
    /// keyboard selection); the copy fallback has no rect, so its toolbar goes to the release point. UI thread.
    /// </summary>
    private void RouteSelection(SelectionPipelineEvent selection)
    {
        var settings = _settings.Current;
        if (!settings.PopGuyEnabled || selection.Source.IsOwnProcess) return;
        var result = selection.Capture;
        var anchor = selection.Anchor;
        var capture = new CapturedSelection(result.Text, result.IsEditable, FirstRect(result.SelectionRects), selection.Source,
            Pointer: anchor.MouseReleasePoint, GrewDownward: anchor.GrewDownward);
        if (anchor.IsDoubleClick && settings.TriggerDoubleClickEnabled)
        {
            var assigned = settings.DoubleClickAssignedAction;
            _log($"selection: double-click, {result.Text.Length} chars, {(assigned is null ? "show" : $"run {assigned.Type} {assigned.BuiltinKind}")}");
            PresentWithHost(capture, assigned);
            return;
        }
        if (!settings.TriggerOnSelectEnabled) return;
        if (!SelectionGesture.ShouldShowOnTextSelect(result.IsEditable, settings.TriggerOnSelectEditableOnly))
        {
            _log("selection: dropped, not editable");
            return;
        }
        PresentWithHost(capture, autoRun: null);
    }

    /// <summary>
    /// Presents a passive selection: from a browser while Ignored Domains is on, after its host is read on the thread
    /// pool (the UI thread never waits on UI Automation), unless a newer selection, a press (<see cref="ReadMouseAsync"/>)
    /// or a show came meanwhile; else at once. UI thread.
    /// </summary>
    private void PresentWithHost(CapturedSelection capture, ActionIdentifier? autoRun)
    {
        var selection = ++_passiveSelections;
        if (!ReadsHost(capture.Source))
        {
            Present(capture, autoRun);
            return;
        }
        Watch(Task.Run(() =>
        {
            var withHost = capture with { Host = ReadHost(capture.Source) };
            _dispatcher.TryEnqueue(() =>
            {
                if (selection == _passiveSelections) Present(withHost, autoRun);
            });
        }), "browser host");
    }

    // Presentation (UI thread).

    /// <summary>
    /// Shows the toolbar for <paramref name="capture"/> if <see cref="PresentationGate"/> lets it (an ignored app or
    /// domain, no enabled action, or a re-entrant same-text event drops it), then runs <paramref name="autoRun"/>. A dropped
    /// selection runs nothing: a trailing double-click on a result keeps it (macOS still dispatches then). An OCR capture
    /// shows while PopGuy is off too (macOS: the menu-bar item always captures), its failure past the gate (macOS: an
    /// alert); <paramref name="thumbnail"/> (OCR) goes above the bar, or is disposed when nothing shows.
    /// </summary>
    private void Present(CapturedSelection capture, ActionIdentifier? autoRun, OcrThumbnail? thumbnail = null)
    {
        var settings = _settings.Current;
        if (!settings.PopGuyEnabled && !capture.IsOcr)
        {
            thumbnail?.Dispose();
            return;
        }
        var verdict = capture.Failure is not null ? PresentationVerdict.Show : PresentationGate.Evaluate(new PresentationInput(
            // A blocked capture has no text but still shows (its error): the message stands in for the gate.
            capture.Blocked ? AdminAppMessage : capture.Text,
            IsShowing: _window.IsShown,
            CurrentText: _current?.Text ?? "",
            ActionInProgress: _session.State is not ToolbarState.IdleState,
            SpeakActive: _session.SpeakPhase != SpeakPhase.Idle,
            CanReplaySpeak: _viewModel.CanReplaySpeak,
            SourceExeName: capture.Source.Exe,
            IsOwnProcess: capture.Source.IsOwnProcess,
            SourceHost: capture.Host), settings).Verdict;
        if (verdict != PresentationVerdict.Show)
        {
            _log($"present: dropped, {verdict}");
            thumbnail?.Dispose();
            return;
        }

        _current = capture;
        _presentation++;
        // A chord or hotkey show cancels a passive selection's pending browser read.
        _passiveSelections++;
        _pasting = false;
        // A new selection: the previous one's speech stops and its "Listen again" goes (macOS update).
        _speak.ClearReplay();
        _viewModel.Present(settings, capture.IsEditable, CanIgnore(capture.Source), capture.Host);
        // After Present (which clears it), before the show (which sizes the window for the content).
        if (thumbnail is not null) _viewModel.ShowOcrThumbnail(thumbnail);
        // No pointer (the chord, the hotkeys, a keyboard selection): placed below the selection rect, or at the cursor
        // when there is none (spec-1 §3.2).
        _window.ShowAt(capture.Pointer, capture.GrewDownward, capture.Selection, capture.Source);
        _shown = true;
        if (capture.Blocked)
        {
            _viewModel.Fail(capture.Failure ?? AdminAppMessage);
            return;
        }
        if (autoRun is { } id) RunAction(id);
    }

#if DEBUG
    /// <summary>
    /// DEBUG only (<c>--selftest-toolbar</c>): shows the toolbar at the cursor with <paramref name="text"/> as a result
    /// for <paramref name="source"/>, without a capture or a run, and past <see cref="PresentationGate"/> (which would
    /// drop PopGuy's own window). Copy, Paste back and dismissal then behave as usual. UI thread.
    /// </summary>
    public void ShowCanned(string text, ForegroundApp source)
    {
        _current = new CapturedSelection(text, IsEditable: true, Rectangle.Empty, source);
        _presentation++;
        _pasting = false;
        _speak.ClearReplay();
        _viewModel.Present(_settings.Current, isEditable: true, CanIgnore(source));
        // Before ShowAt: it sizes the window for the content it finds.
        _session.ShowCanned(text);
        _window.ShowAt(PopGuy.Platform.Windowing.ToolbarWindowStyle.CursorPosition(), grewDownward: null, Rectangle.Empty, source);
        _shown = true;
        _log($"selftest: canned result, {text.Length} chars");
    }
#endif

    /// <summary>
    /// An action button or hotkey: runs the action on the current selection, if it is enabled. Prompt opens or closes
    /// the prompt input instead; its Run comes back through <see cref="OnPromptSubmitted"/>. Speak and a Speech custom
    /// action toggle speech (the session has no Speech run).
    /// </summary>
    private void RunAction(ActionIdentifier id)
    {
        if (ToolbarSession.SpeakVoiceFor(_settings.Current, id) is { } voice)
        {
            ToggleSpeak(id, voice);
            return;
        }
        if (id != PromptId)
        {
            StartRun(id, promptText: null);
            return;
        }
        if (_current is { Blocked: false, Text.Length: > 0 } && ToolbarLayout.IsEnabled(_settings.Current, id))
            _viewModel.TogglePromptInput();
    }

    /// <summary>The prompt input's Run: the typed prompt runs on the current selection.</summary>
    private void OnPromptSubmitted(string prompt) => StartRun(PromptId, prompt);

    private void StartRun(ActionIdentifier id, string? promptText)
    {
        if (_current is not { Blocked: false, Text.Length: > 0 } capture) return;
        var settings = _settings.Current;
        if (!ToolbarLayout.IsEnabled(settings, id)) return;
        var source = capture.Source;
        var ignored = IsIgnored(capture, settings);
        _log($"run: {id.Type} {id.BuiltinKind}, {capture.Text.Length} chars");
        // The Translate picker's target; its name is {{language}} for every action (macOS: targetLanguage.rawValue).
        var language = _viewModel.TargetLanguage;
        _viewModel.Run(new ToolbarRun(id, capture.Text)
        {
            PromptText = promptText,
            TargetLanguage = language.Code,
            LanguageName = language.Name,
            SourceExeName = source.IsOwnProcess ? null : source.Exe,
            SourceAppName = source.DisplayName.Length > 0 ? source.DisplayName : null,
            SourceDomain = source.IsOwnProcess ? null : capture.Host,
            SkipHistory = ignored,
        });
    }

    /// <summary>
    /// Speak (macOS triggerSpeak) and a Speech custom action (macOS triggerCustomAction): speaks the current selection
    /// with <paramref name="voice"/> (<see cref="ToolbarSession.SpeakVoiceFor"/>: the Speak settings, or the action's
    /// own), or stops speech while it is loading or playing (the toggle records nothing). A start is recorded in history
    /// at once (the selected engine). The coordinator publishes Loading here, on the UI thread, and routes on the thread
    /// pool.
    /// </summary>
    private void ToggleSpeak(ActionIdentifier id, SpeakVoice voice)
    {
        if (_current is not { Blocked: false } capture || capture.Text.Trim().Length == 0) return;
        var settings = _settings.Current;
        if (!ToolbarLayout.IsEnabled(settings, id)) return;
        if (_speak.Phase != SpeakPhase.Idle)
        {
            _log("speak: stop");
            _speak.Stop();
            return;
        }
        var engine = voice.Settings.SelectedEngine;
        _log($"speak: {id.Type}, {engine.DisplayName()}, {capture.Text.Length} chars");
        Watch(_speak.SpeakAsync(capture.Text, voice.Accent, voice.Settings, voice.TtsConfig), "speak");
        var source = capture.Source;
        _session.RecordSpeak(new ToolbarRun(id, capture.Text)
        {
            SourceExeName = source.IsOwnProcess ? null : source.Exe,
            SourceAppName = source.DisplayName.Length > 0 ? source.DisplayName : null,
            SkipHistory = IsIgnored(capture, settings),
        }, engine, voice.Accent);
    }

    /// <summary>"Listen again": the cached audio, or the system voice again (no new cloud request, no history).</summary>
    private void OnReplayRequested()
    {
        if (!_window.IsShown) return;
        _log("speak: listen again");
        Watch(_speak.ReplayAsync(), "listen again");
    }

    /// <summary>
    /// A lookup's Listen (macOS triggerDictionaryListen): stops speech while it is loading or playing, else speaks the
    /// entry's headword with the lookup action's voice, the entry's own recording first. Records nothing (macOS).
    /// </summary>
    private void OnListenRequested(DictionaryEntry entry)
    {
        if (!_window.IsShown || _session.DictionaryAction is not { } action) return;
        if (_speak.Phase != SpeakPhase.Idle)
        {
            _log("listen: stop");
            _speak.Stop();
            return;
        }
        var voice = ToolbarSession.ListenVoice(_settings.Current, action);
        _log($"listen: {voice.Settings.SelectedEngine.DisplayName()}, {(entry.PrimaryAudioUrl is null ? "no" : "with")} entry audio");
        Watch(_speak.SpeakDictionaryAsync(entry.Headword, entry.PrimaryAudioUrl, voice.Accent, voice.Settings, voice.TtsConfig), "listen");
    }

    /// <summary>Hides the toolbar (which stops the session and drops "Listen again", stopping speech) and forgets the selection.</summary>
    private void Hide()
    {
        _speak.ClearReplay();
        _window.Hide();
        _current = null;
        _shown = false;
        _pasting = false;
    }

    // Dismissal (spec-1 §3.8).

    private async Task ReadMouseAsync(CancellationToken token)
    {
        try
        {
            await foreach (var mouse in _input.Mouse.ReadAllAsync(token).ConfigureAwait(false))
            {
                if (mouse.IsPopGuyMarker) continue;
                FeedPipeline(mouse);
                if (mouse.Kind is not (MouseEventKind.LeftDown or MouseEventKind.RightDown or MouseEventKind.MiddleDown)) continue;
                var point = new Point(mouse.X, mouse.Y);
                // Any press outside the toolbar, shown or not, cancels a passive selection's pending browser read (the
                // click that cleared the selection). Never the gesture's own: its press is read before its release, and
                // the selection is emitted only after the release, the debounce and the capture, so it is queued later.
                var onToolbar = mouse.Kind == MouseEventKind.LeftDown ? _pressOnToolbar : IsOnToolbar(point);
                if (!onToolbar) _dispatcher.TryEnqueue(() => _passiveSelections++);
                if (!_shown) continue;
                var timestamp = mouse.Timestamp;
                _dispatcher.TryEnqueue(() =>
                {
                    // A press on an open menu (a popup window outside the toolbar's rect), or one that closed it, is not
                    // an outside click.
                    if (_window.IsShown && !_window.Contains(point) && !_window.WasMenuOpenAt(timestamp)) RequestDismissKeepingDraft();
                });
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    /// <summary>
    /// Passes a mouse event to the selection pipeline, except a left press or release on the toolbar or its menus, and
    /// the release of a press there (a drag of the toolbar, a selection in its result): a click on a toolbar button would
    /// otherwise cancel a capture in flight or re-present the toolbar. Mouse loop only.
    /// </summary>
    private void FeedPipeline(MouseEvent mouse)
    {
        var point = new Point(mouse.X, mouse.Y);
        if (mouse.Kind == MouseEventKind.LeftDown)
        {
            _pressOnToolbar = IsOnToolbar(point);
            if (_pressOnToolbar) return;
        }
        else if (mouse.Kind == MouseEventKind.LeftUp)
        {
            var onToolbar = _pressOnToolbar || IsOnToolbar(point);
            _pressOnToolbar = false;
            if (onToolbar) return;
        }
        _pipeline.Handle(mouse);
    }

    /// <summary>
    /// The point is on the shown toolbar or a window it owns (an open menu). Checked only while it shows: a hidden
    /// window keeps its last rect. Any thread.
    /// </summary>
    private bool IsOnToolbar(Point point) =>
        _shown && (ToolbarWindowStyle.WindowRect(_toolbarHwnd).Contains(point) || ToolbarWindowStyle.IsToolbarOrOwnedAt(point, _toolbarHwnd));

    /// <summary>
    /// An outside click or Esc: like <see cref="RequestDismiss"/>, but a non-empty prompt or refine draft keeps the
    /// toolbar open so an accidental click or Esc does not discard the text (macOS). Esc reaches the toolbar only while
    /// it is activated (text input): a non-activating window gets no keys.
    /// </summary>
    private void RequestDismissKeepingDraft()
    {
        if (_viewModel.HasOpenDraft) return;
        RequestDismiss();
    }

    /// <summary>
    /// Close (and an outside click or Esc without a draft): ignored while an action runs or a paste is in flight; on a
    /// result with confirmCloseAfterResult on, the close confirmation (a second request leaves it up); otherwise hides.
    /// </summary>
    private void RequestDismiss()
    {
        if (!_window.IsShown || _pasting || _viewModel.IsRunning) return;
        if (_viewModel.IsResult && _settings.Current.ConfirmCloseAfterResult)
        {
            if (!_viewModel.IsConfirmingClose) _viewModel.ShowCloseConfirmation();
            return;
        }
        Hide();
    }

    /// <summary>"Turn This Setting Off": closes first (click reacts first), then saves the setting.</summary>
    private void OnDisableCloseConfirmation()
    {
        Hide();
        try
        {
            _settings.Update(s => s with { ConfirmCloseAfterResult = false });
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log($"settings: confirmCloseAfterResult not saved, {e.GetType().Name}");
        }
    }

    /// <summary>
    /// "Ignore App" in the ignore confirmation (macOS onIgnoreApp): closes first (click reacts first), then adds the
    /// source's exe name to the ignored apps (once; the gate compares names case-insensitively).
    /// </summary>
    private void OnIgnoreApp()
    {
        var exe = _current?.Source is { } source && CanIgnore(source) ? source.Exe! : null;
        Hide();
        if (exe is null) return;
        try
        {
            _settings.Update(s => s.IgnoredAppExeNames.Contains(exe, StringComparer.OrdinalIgnoreCase)
                ? s
                : s with { IgnoredAppExeNames = [.. s.IgnoredAppExeNames, exe] });
            _log($"settings: ignored app added, {exe}");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log($"settings: ignored app not saved, {e.GetType().Name}");
        }
    }

    /// <summary>
    /// "Ignore this site" (macOS onIgnoreDomain, no confirmation): closes first (click reacts first), then adds the
    /// source tab's host to the ignored domains (once, in the gate's form). The button shows only with a host, which is
    /// read only while Ignored Domains is on, so the switch is left as it is (macOS addIgnoredDomain). The host is not
    /// logged.
    /// </summary>
    private void OnIgnoreSite()
    {
        var domain = PresentationGate.NormalizeDomain(_current?.Host);
        Hide();
        if (domain is null) return;
        try
        {
            _settings.Update(s => s.IgnoredDomains.Any(d => PresentationGate.NormalizeDomain(d) == domain)
                ? s
                : s with { IgnoredDomains = [.. s.IgnoredDomains, domain] });
            _log("settings: ignored domain added");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log($"settings: ignored domain not saved, {e.GetType().Name}");
        }
    }

    /// <summary>
    /// The Settings button (spec-1 §3): Settings opens, then the toolbar closes. In that order: Settings takes the
    /// foreground first, so closing the toolbar does not hand it back to the source app.
    /// </summary>
    private void OnSettingsRequested()
    {
        SettingsRequested?.Invoke();
        Hide();
    }

    // Script actions.

    /// <summary>A script action finished (any thread): its after-run goes to the UI thread.</summary>
    private void OnScriptFinished(ScriptRunFinished finished) => _dispatcher.TryEnqueue(() => ApplyAfterRun(finished));

    /// <summary>
    /// A script action's after-run (spec-4 §4.4), while its run is still the toolbar's (no Stop, close or new selection
    /// since): Close toolbar hides it, Copy result copies the output, Paste result pastes it into the source and keeps
    /// the toolbar open. Show result and Do nothing are already the session's state. UI thread.
    /// </summary>
    private void ApplyAfterRun(ScriptRunFinished finished)
    {
        if (!_window.IsShown || !_session.IsCurrentRun(finished.Generation)) return;
        var output = finished.Output ?? "";
        _log($"script: after run {finished.AfterRun}, {output.Length} chars");
        switch (finished.AfterRun)
        {
            case AfterRunBehavior.CloseToolbar:
                Hide();
                break;
            case AfterRunBehavior.CopyResult when output.Length > 0:
                CopyInBackground(output, "script copy");
                break;
            case AfterRunBehavior.PasteResult when output.Length > 0:
                Watch(PasteAsync(output, scriptResult: true), "script paste");
                break;
        }
    }

    // Copy and Paste back.

    /// <summary>
    /// Copy: a deliberate copy by the user (macOS <c>OutputHandler.copy</c>), so the clipboard is not restored and the
    /// text may go to clipboard history (Win+V). Off the UI thread; the "Copied" feedback is the window's.
    /// </summary>
    private void OnCopyRequested(string text)
    {
        if (text.Length > 0) CopyInBackground(text, "copy");
    }

    private void CopyInBackground(string text, string what) => Watch(Task.Run(() =>
    {
        var written = ClipboardGuard.WriteText(text, excludeFromHistory: false);
        _log($"{what}: {text.Length} chars, written {written}");
    }), what);

    /// <summary>Paste back, called from the click on the UI thread.</summary>
    private async void OnPasteBackRequested(string text) => await PasteAsync(text, scriptResult: false);

    /// <summary>
    /// Pastes into the source, on the UI thread (PasteBack may give the source the foreground only from there). One at
    /// a time. Pasted → the toolbar hides, or stays for a script's Paste result (macOS); Blocked → the admin-app error;
    /// Refused → the result is copied instead with a short reason, or, when the clipboard could not be saved, left alone
    /// with a note. A script's Paste result has no result panel for the note, so it shows as the error instead. OCR text
    /// is always copied instead.
    /// </summary>
    private async Task PasteAsync(string text, bool scriptResult)
    {
        if (_pasting || _current is not { Blocked: false } capture || text.Length == 0) return;
        if (capture.IsOcr)
        {
            // No field to paste into (macOS: Copy only); only a script's Paste result gets here. The paste policy would
            // let a window of a known class through, so it is never asked.
            CopyInBackground(text, "ocr paste, copied instead");
            const string note = "Copied instead — screen text has no field to paste into.";
            if (scriptResult) _viewModel.Fail(note);
            else _viewModel.ShowNotice(note);
            return;
        }
        _pasting = true;
        // Text input off first; PasteBack then gives the source the foreground back if the toolbar has it.
        _window.EndTextInput(handBack: false);
        var presentation = _presentation;
        PasteBackResult result;
        try
        {
            result = await PasteBack.PasteAsync(text, capture.Source, _input.IsUserKeyDown);
        }
        catch (Exception e)
        {
            _log($"paste: failed, {e.GetType().Name} {e.Message}");
            result = new PasteBackResult(PasteBackStatus.Refused, "failed");
        }
        // Resumes on the UI thread (the dispatcher's synchronization context).
        _log($"paste: {result.Status} ({result.Reason}), {text.Length} chars, restore {result.ClipboardRestore?.ToString() ?? "none"}");
        if (presentation != _presentation || !_window.IsShown) return; // hidden or re-presented meanwhile
        _pasting = false;
        switch (result.Status)
        {
            case PasteBackStatus.Pasted:
                if (!scriptResult) Hide();
                break;
            case PasteBackStatus.Blocked:
                _viewModel.Fail(AdminAppMessage);
                break;
            default:
                string note;
                if (IsClipboardRefusal(result.Reason))
                {
                    // Copying would replace a clipboard PopGuy could not save: leave it as it is.
                    note = scriptResult
                        ? "Not pasted: PopGuy couldn't save your clipboard first."
                        : "Not pasted: PopGuy couldn't save your clipboard first. Use Copy to copy the result.";
                }
                else
                {
                    CopyInBackground(text, "paste refused, copied instead");
                    note = $"Copied instead — {RefusalReason(result.Reason)}";
                }
                if (scriptResult) _viewModel.Fail(note);
                else _viewModel.ShowNotice(note);
                break;
        }
    }

    private static bool IsClipboardRefusal(string reason) =>
        reason is "transactionInProgress" or "clipboardBusy" or "tooLarge" or "formatsSkipped" or "writeFailed";

    /// <summary>Why a paste was refused, for the "Copied instead" note (PasteBack's reasons).</summary>
    private static string RefusalReason(string reason) => reason switch
    {
        "console" or "integratedTerminal" or "unknownFocusInEditor" => "PopGuy doesn't paste into terminals.",
        "remoteDesktop" => "PopGuy doesn't paste into remote sessions.",
        "unknownProcess" => "PopGuy couldn't identify the app.",
        "passwordField" => "PopGuy doesn't paste into password fields.",
        "readOnly" => "the field is read-only.",
        "editabilityUnknown" => "PopGuy couldn't tell whether the field takes text.",
        "sourceGone" => "the app's window was closed.",
        "sourceNotForeground" or "foregroundChanged" => "the app was no longer in front.",
        _ => "the paste didn't go through.",
    };

    // Helpers.

    /// <summary>
    /// The source is an ignored app or domain, so a run writes no history. The gate already dropped ignored sources at
    /// show time; checked again in case the ignore list changed since.
    /// </summary>
    private static bool IsIgnored(CapturedSelection capture, AppSettings settings) =>
        PresentationGate.Evaluate(
            new PresentationInput(
                capture.Text, SourceExeName: capture.Source.Exe, IsOwnProcess: capture.Source.IsOwnProcess, SourceHost: capture.Host),
            settings).Verdict is PresentationVerdict.IgnoredApp or PresentationVerdict.IgnoredDomain;

    /// <summary>
    /// The tab's host is read only while Ignored Domains is on, from a supported browser that is not PopGuy (macOS:
    /// never otherwise, so no browser address is touched while the feature is off). Any thread.
    /// </summary>
    private bool ReadsHost(ForegroundApp source) =>
        _settings.Current.IgnoredDomainsEnabled && !source.IsOwnProcess && BrowserUrlReader.IsSupportedBrowser(source.Exe);

    /// <summary>
    /// The source browser tab's host (<see cref="ReadsHost"/>), or null; up to 300 ms of UI Automation, so pool threads
    /// only. Logs whether a host was found, never the host.
    /// </summary>
    private string? ReadHost(ForegroundApp source)
    {
        if (!ReadsHost(source)) return null;
        var host = BrowserUrlReader.ReadHost(source.Hwnd, source.Exe);
        _log($"browser: {source.Exe}, {(host is null ? "no host" : "host found")}");
        return host;
    }

    private static bool IsBlocked(ForegroundApp app) => app.IsElevated && !Environment.IsPrivilegedProcess;

    /// <summary>"Ignore this app" needs the source's exe name (macOS: disabled without a bundle id), and never PopGuy itself.</summary>
    private static bool CanIgnore(ForegroundApp app) => !app.IsOwnProcess && !string.IsNullOrEmpty(app.Exe);

    private static Rectangle FirstRect(IReadOnlyList<Rectangle> rects) =>
        rects.FirstOrDefault(r => r.Width > 0 && r.Height > 0);

    /// <summary>Logs a background task that failed instead of losing the exception.</summary>
    private void Watch(Task task, string what) => task.ContinueWith(
        t => _log($"{what}: failed, {t.Exception!.GetBaseException().GetType().Name} {t.Exception.GetBaseException().Message}"),
        CancellationToken.None,
        TaskContinuationOptions.OnlyOnFaulted,
        TaskScheduler.Default);
}
