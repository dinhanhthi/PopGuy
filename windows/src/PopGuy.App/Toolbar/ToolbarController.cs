using System.Drawing;
using Microsoft.UI.Dispatching;
using PopGuy.Core.Actions;
using PopGuy.Core.Settings;
using PopGuy.Core.Toolbar;
using PopGuy.Platform.Capture;
using PopGuy.Platform.Input;
using PopGuy.Platform.Output;
using PopGuy.Platform.SystemServices;

namespace PopGuy.Toolbar;

/// <summary>
/// Wires the triggers to the toolbar (macOS <c>ToolbarController.swift</c>, the explicit triggers of spec-1 §1.4-1.5):
/// the Ctrl+C+C chord, the chord-replacement hotkey and the per-action hotkeys capture the selection, pass
/// <see cref="PresentationGate"/> and show <see cref="ToolbarWindow"/> below the selection (or at the cursor); an action
/// hotkey then runs its action. It also handles the toolbar's clicks (actions, Stop, Copy, Paste back, Close) and the
/// dismissal rules of spec-1 §3.8.
/// <para>
/// Threading: the chord and hotkey events and both input loops run on the thread pool; everything that touches the
/// window, the view model or the presentation state runs on the UI thread (<see cref="DispatcherQueue"/>). Captures
/// and clipboard writes run off it. Selected text, results and clipboard contents are never logged, only lengths.
/// </para>
/// </summary>
internal sealed class ToolbarController : IDisposable
{
    private const string AdminAppMessage = "PopGuy can't read or paste in apps running as administrator.";

    private readonly SettingsStore _settings;
    private readonly ToolbarSession _session;
    private readonly ToolbarWindow _window;
    private readonly ToolbarViewModel _viewModel;
    private readonly GlobalInput _input;
    private readonly ChordMonitor _chord;
    private readonly HotkeyService _hotkeys;
    private readonly DispatcherQueue _dispatcher;
    private readonly Action<string> _log;
    private readonly CancellationTokenSource _stop = new();

    /// <summary>One capture at a time (the chord and the hotkeys can fire together). Interlocked.</summary>
    private int _capturing;

    /// <summary>The toolbar is on screen, for the pool threads (the window's own flag is UI thread only).</summary>
    private volatile bool _shown;

    // UI thread only.
    private CapturedSelection? _current;
    private int _presentation;
    private bool _pasting;

    /// <summary>A selection the toolbar was (or is about to be) shown for.</summary>
    /// <param name="Text">The selection; "" for <paramref name="Blocked"/>.</param>
    /// <param name="IsEditable">Paste back is offered.</param>
    /// <param name="Selection">UI Automation's first selection rect, or empty (the toolbar then goes to the cursor).</param>
    /// <param name="Source">The foreground app when the trigger fired.</param>
    /// <param name="Blocked">The source runs as administrator: the toolbar shows the admin-app error instead.</param>
    private sealed record CapturedSelection(string Text, bool IsEditable, Rectangle Selection, ForegroundApp Source, bool Blocked = false);

    public ToolbarController(
        SettingsStore settings, ToolbarSession session, ToolbarWindow window, GlobalInput input, ChordMonitor chord,
        HotkeyService hotkeys, DispatcherQueue dispatcher, Action<string> log)
    {
        _settings = settings;
        _session = session;
        _window = window;
        _viewModel = window.ViewModel;
        _input = input;
        _chord = chord;
        _hotkeys = hotkeys;
        _dispatcher = dispatcher;
        _log = log;
    }

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
        _viewModel.CloseAnywayRequested += Hide;
        _viewModel.DisableCloseConfirmationRequested += OnDisableCloseConfirmation;
        ApplySettings();

        var token = _stop.Token;
        Watch(Task.Run(() => ReadKeysAsync(token)), "keys");
        Watch(Task.Run(() => ReadMouseAsync(token)), "mouse");
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
        _viewModel.CloseAnywayRequested -= Hide;
        _viewModel.DisableCloseConfirmationRequested -= OnDisableCloseConfirmation;
        Hide();
    }

    // Settings.

    private void OnSettingsChanged(object? sender, EventArgs e) => ApplySettings();

    /// <summary>
    /// The chord and the hotkeys follow the settings (bindings, custom actions, the chord flag and replacement, OCR).
    /// Off the calling thread: registering waits on the input thread. Each run reads the latest settings, so runs that
    /// overlap still end on the newest.
    /// </summary>
    private void ApplySettings() => Watch(Task.Run(() =>
    {
        var settings = _settings.Current;
        _chord.Apply(settings);
        // The master switch: nothing arms while PopGuy is off (spec-1 §1.4).
        if (!settings.PopGuyEnabled) _chord.Enabled = false;
        var refused = _hotkeys.Apply(settings).Count(r => r.Status != HotkeyStatus.Registered);
        _log($"settings applied: chord {(_chord.Enabled ? "on" : "off")}, {_hotkeys.Registrations.Count} hotkeys, {refused} refused");
    }), "apply settings");

    // Triggers (pool threads until the hand-off to the UI thread).

    private async Task ReadKeysAsync(CancellationToken token)
    {
        try
        {
            // The one reader of the key channel (Phase 10 adds the selection gestures here).
            await foreach (var key in _input.Keys.ReadAllAsync(token).ConfigureAwait(false)) _chord.Handle(key);
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
            _log("hotkey: OCR capture is not available yet");
            return;
        }
        var source = ForegroundApp.Snapshot();
        _dispatcher.TryEnqueue(() => OnHotkey(id, source));
    }

    /// <summary>
    /// The chord replacement behaves like the chord (no-op while showing). An action hotkey (spec-1 §1.5), if the action
    /// is enabled: while the toolbar shows a selection, runs on it (no re-capture); else captures, shows, then runs.
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
        if (id.Type is ActionIdentifierType.Speak or ActionIdentifierType.Dictionary
            || id == ActionIdentifier.Builtin(ActionKind.Prompt))
        {
            // Speak (Phase 17), Look up (Phase 18) and the prompt input (Phase 9.3) do not exist yet.
            _log($"hotkey: {id} is not available yet");
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
                    SelectionCaptureStatus.Captured => new(result.Text, result.IsEditable, FirstRect(result.SelectionRects), source),
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

    // Presentation (UI thread).

    /// <summary>
    /// Shows the toolbar for <paramref name="capture"/> if <see cref="PresentationGate"/> lets it (an ignored app, no
    /// enabled action, or a re-entrant same-text event drops it), then runs <paramref name="autoRun"/>.
    /// </summary>
    private void Present(CapturedSelection capture, ActionIdentifier? autoRun)
    {
        var settings = _settings.Current;
        if (!settings.PopGuyEnabled) return;
        var verdict = PresentationGate.Evaluate(new PresentationInput(
            // A blocked capture has no text but still shows (its error): the message stands in for the gate.
            capture.Blocked ? AdminAppMessage : capture.Text,
            IsShowing: _window.IsShown,
            CurrentText: _current?.Text ?? "",
            ActionInProgress: _session.State is not ToolbarState.IdleState,
            SpeakActive: _session.SpeakPhase != SpeakPhase.Idle,
            SourceExeName: capture.Source.Exe,
            IsOwnProcess: capture.Source.IsOwnProcess), settings).Verdict;
        if (verdict != PresentationVerdict.Show)
        {
            _log($"present: dropped, {verdict}");
            return;
        }

        _current = capture;
        _presentation++;
        _pasting = false;
        _viewModel.Present(settings, capture.IsEditable);
        // No pointer: placed below the selection rect, or at the cursor when there is none (spec-1 §3.2).
        _window.ShowAt(pointer: null, grewDownward: null, capture.Selection, capture.Source);
        _shown = true;
        if (capture.Blocked)
        {
            _viewModel.Fail(AdminAppMessage);
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
        _viewModel.Present(_settings.Current, isEditable: true);
        // Before ShowAt: it sizes the window for the content it finds.
        _session.ShowCanned(text);
        _window.ShowAt(PopGuy.Platform.Windowing.ToolbarWindowStyle.CursorPosition(), grewDownward: null, Rectangle.Empty, source);
        _shown = true;
        _log($"selftest: canned result, {text.Length} chars");
    }
#endif

    /// <summary>An action button or hotkey: runs the action on the current selection, if it is enabled.</summary>
    private void RunAction(ActionIdentifier id)
    {
        if (_current is not { Blocked: false, Text.Length: > 0 } capture) return;
        var settings = _settings.Current;
        if (!ToolbarLayout.IsEnabled(settings, id)) return;
        var source = capture.Source;
        // The gate already dropped ignored sources at show time; checked again in case the ignore list changed since.
        var ignored = PresentationGate.Evaluate(
            new PresentationInput(capture.Text, SourceExeName: source.Exe, IsOwnProcess: source.IsOwnProcess), settings).Verdict
            is PresentationVerdict.IgnoredApp or PresentationVerdict.IgnoredDomain;
        _log($"run: {id.Type} {id.BuiltinKind}, {capture.Text.Length} chars");
        _viewModel.Run(new ToolbarRun(id, capture.Text)
        {
            SourceExeName = source.IsOwnProcess ? null : source.Exe,
            SourceAppName = source.DisplayName.Length > 0 ? source.DisplayName : null,
            SkipHistory = ignored,
        });
    }

    /// <summary>Hides the toolbar (which stops the session) and forgets the selection.</summary>
    private void Hide()
    {
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
                if (!_shown || mouse.IsPopGuyMarker) continue;
                if (mouse.Kind is not (MouseEventKind.LeftDown or MouseEventKind.RightDown or MouseEventKind.MiddleDown)) continue;
                var point = new Point(mouse.X, mouse.Y);
                _dispatcher.TryEnqueue(() =>
                {
                    if (_window.IsShown && !_window.Contains(point)) RequestDismiss();
                });
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    /// <summary>
    /// An outside click or Close: ignored while an action runs or a paste is in flight; on a result with
    /// confirmCloseAfterResult on, the close confirmation (a second request leaves it up); otherwise hides. Esc does not
    /// reach the toolbar yet: it never activates in this phase (the prompt input that activates it comes in Phase 9).
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

    /// <summary>
    /// Paste back, called from the click on the UI thread (PasteBack may give the source the foreground only from
    /// there). One at a time. Pasted → the toolbar hides; Blocked → the admin-app error; Refused → the result is copied
    /// instead with a short reason, or, when the clipboard could not be saved, left alone with a note.
    /// </summary>
    private async void OnPasteBackRequested(string text)
    {
        if (_pasting || _current is not { Blocked: false } capture || text.Length == 0) return;
        _pasting = true;
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
                Hide();
                break;
            case PasteBackStatus.Blocked:
                _viewModel.Fail(AdminAppMessage);
                break;
            default:
                if (IsClipboardRefusal(result.Reason))
                {
                    // Copying would replace a clipboard PopGuy could not save: leave it as it is.
                    _viewModel.ShowNotice("Not pasted: PopGuy couldn't save your clipboard first. Use Copy to copy the result.");
                }
                else
                {
                    CopyInBackground(text, "paste refused, copied instead");
                    _viewModel.ShowNotice($"Copied instead — {RefusalReason(result.Reason)}");
                }
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

    private static bool IsBlocked(ForegroundApp app) => app.IsElevated && !Environment.IsPrivilegedProcess;

    private static Rectangle FirstRect(IReadOnlyList<Rectangle> rects) =>
        rects.FirstOrDefault(r => r.Width > 0 && r.Height > 0);

    /// <summary>Logs a background task that failed instead of losing the exception.</summary>
    private void Watch(Task task, string what) => task.ContinueWith(
        t => _log($"{what}: failed, {t.Exception!.GetBaseException().GetType().Name} {t.Exception.GetBaseException().Message}"),
        CancellationToken.None,
        TaskContinuationOptions.OnlyOnFaulted,
        TaskScheduler.Default);
}
