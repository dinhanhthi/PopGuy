using System.Diagnostics;
using System.Text;
using Microsoft.UI.Dispatching;
using PopGuy.Core;
using PopGuy.Core.Composer;
using PopGuy.Platform.Capture;
using PopGuy.Platform.Output;
using PopGuy.Platform.SystemServices;
using PopGuy.Platform.Windowing;

namespace PopGuy.Composer;

/// <summary>
/// Delivers Compose-mode text to the source window. The controller makes <paramref name="hwnd"/> the foreground window
/// first; the implementation (paste back and Enter, wired in the composition root) refuses when it no longer is.
/// </summary>
internal interface IComposeOutput
{
    /// <summary>Pastes <paramref name="text"/> into <paramref name="hwnd"/>; <see cref="PasteBackStatus.Pasted"/> when it went through.</summary>
    Task<PasteBackResult> PasteAsync(string text, nint hwnd);

    /// <summary>Presses Enter in <paramref name="hwnd"/> while it is the foreground window. True when sent.</summary>
    Task<bool> SendEnterAsync(nint hwnd);
}

/// <summary>
/// Runs the Terminal Composer (macOS ComposerController.swift): owns the pipe server, one <see cref="ComposerWindow"/>
/// per composer, and the draft store.
/// <list type="bullet">
/// <item>CLI session (popguy-edit): "open" shows a composer with the file's text; Done replies "done", Cancel / Esc /
/// the close button reply "cancel". The client going away while the composer is open shows "Session ended". Done &amp;
/// Submit waits for the CLI to confirm the write ("written") and exit, then presses Enter in the source window.</item>
/// <item>Compose (hotkey, tray): an empty composer whose footer names the target app; Done pastes into it, Done &amp;
/// Submit pastes and presses Enter. Without a target (also an app that runs as administrator while PopGuy does not, or
/// a remote session: the paste would always be refused), Done is Copy &amp; Close. A target the tray guessed from the
/// Z order gets no Done &amp; Submit (paste only, no Enter). A paste that does not go through copies the text
/// instead.</item>
/// </list>
/// Drafts: autosaved while the text differs from the opening text; saved at Done and deleted once the text was
/// delivered (the CLI confirmed the write after "done", or a successful paste); kept otherwise. Focus returns to the
/// source window on Done and Cancel. UI thread only. UNTRUSTED DATA: the text is never logged, only states, byte counts
/// and session ids.
/// </summary>
internal sealed class ComposerController
{
    /// <summary>Pause between the text arriving (CLI exit or paste) and the auto-submit Enter.</summary>
    public static readonly TimeSpan AutoSubmitDelay = TimeSpan.FromMilliseconds(300);

    /// <summary>How long Done &amp; Submit / draft cleanup waits for the CLI to exit after "done".</summary>
    private static readonly TimeSpan SessionEndTimeout = TimeSpan.FromSeconds(5);

    /// <summary>How long a paste or auto-submit waits for the source window to become the foreground.</summary>
    private static readonly TimeSpan ActivationTimeout = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan ActivationPollInterval = TimeSpan.FromMilliseconds(30);

    /// <summary>
    /// The open composer. <see cref="Session"/> is null in Compose mode; <see cref="Source"/> 0 when none;
    /// <see cref="AllowSubmit"/> false when Done &amp; Submit must not press Enter.
    /// </summary>
    private sealed record OpenComposer(
        ComposerWindow Window, ComposerSession? Session, nint Source, Guid DraftId, string OpenedText, bool AllowSubmit);

    /// <summary>A CLI session that got its "done" reply and has not ended yet.</summary>
    private sealed record Delivery(Guid DraftId, bool Submit, nint Source);

    private readonly ComposerPipeServer _server;
    private readonly ComposerDraftStore _store;
    private readonly IComposeOutput _output;
    private readonly Action<string> _log;
    private readonly Dictionary<ComposerSession, Delivery> _awaitingEnd = [];
    private OpenComposer? _open;

    /// <summary>The open composer's window handle (0: none), for <see cref="IsComposerWindow"/> on the pool threads.</summary>
    private nint _openHwnd;

    public ComposerController(AppPaths paths, IComposeOutput output, DispatcherQueue dispatcher, Action<string> log)
    {
        _output = output;
        _log = log;
        _store = new ComposerDraftStore(ComposerDraftStore.DefaultDirectory(paths), log);
        _server = new ComposerPipeServer(dispatcher, log);
        _server.SessionOpened += OnSessionOpened;
        _server.SessionEnded += OnSessionEnded;
        _server.BusyRejected += BringForward;
    }

    public bool IsServerRunning { get; private set; }

    /// <summary>
    /// <paramref name="hwnd"/> is the open composer's window: the toolbar works on a selection there (PopGuy's other
    /// windows are not a source). Any thread.
    /// </summary>
    public bool IsComposerWindow(nint hwnd) => hwnd != 0 && hwnd == Volatile.Read(ref _openHwnd);

    /// <summary>
    /// The toolbar's Paste back into the open composer <paramref name="hwnd"/>, in-process (no synthetic input): its
    /// selection becomes <paramref name="text"/>. False when that composer is no longer open.
    /// </summary>
    public bool ReplaceSelection(nint hwnd, string text)
    {
        if (_open is not { } open || open.Window.Hwnd != hwnd) return false;
        open.Window.ReplaceSelection(text);
        return true;
    }

    // Server lifecycle.

    public bool StartServer() => IsServerRunning = _server.Start();

    /// <summary>Stops listening; an open CLI composer switches to "Session ended".</summary>
    public void StopServer()
    {
        _server.Stop();
        IsServerRunning = false;
    }

    /// <summary>App exit (call before the windows close): writes the open composer's and pending drafts, stops the pipe.</summary>
    public void Shutdown()
    {
        if (_open is { } open) SaveDraft(open, now: true);
        _store.Flush();
        StopServer();
    }

    // Opening.

    /// <summary>
    /// Compose mode: an empty composer whose Done pastes into <paramref name="sourceHwnd"/>, named in its footer. No
    /// target (0, PopGuy's own window, an app without a name, an elevated app while PopGuy is not, or a window the paste
    /// always refuses, such as a remote session): Done copies the text instead.
    /// <paramref name="allowSubmit"/> false (a target the tray guessed) hides Done &amp; Submit, so no Enter is sent. If a
    /// composer is already open, brings it forward instead.
    /// </summary>
    public void BeginCompose(nint sourceHwnd, bool allowSubmit)
    {
        if (_open is not null)
        {
            BringForward();
            return;
        }
        var app = ForegroundApp.Of(sourceHwnd);
        // UIPI: PopGuy's paste into an elevated app is always refused, so it is no target.
        var elevated = sourceHwnd != 0 && app.IsElevated && !Environment.IsPrivilegedProcess;
        // The paste's window-level rule (a remote session, an unreadable process): always refused, so it is no target.
        var refusal = sourceHwnd != 0 && !elevated ? WindowRefusal(app) : null;
        var hasSource = sourceHwnd != 0 && !app.IsOwnProcess && app.DisplayName.Length > 0 && !elevated && refusal is null;
        var label = hasSource ? TargetLabel(app) : null;
        var sourceState = elevated ? "elevated, none" : refusal is not null ? $"{refusal}, none"
            : !hasSource ? "none" : allowSubmit ? "app" : "app, paste only";
        _log($"composer: compose opened (source {sourceState})");
        var noTargetHint = elevated ? "Compose (the target app runs as administrator: Copy & Close copies the text)"
            : refusal == "remoteDesktop" ? "Compose (the target is a remote session: Copy & Close copies the text)"
            : refusal is not null ? "Compose (PopGuy can't paste into this app: Copy & Close copies the text)"
            : null;
        Open("", session: null, hasSource ? sourceHwnd : 0, label, allowSubmit && hasSource, fromPipe: false, noTargetHint);
    }

    /// <summary>
    /// The window-level refusal the Compose paste would always return for <paramref name="app"/> (as PasteBack's check
    /// before the foreground moves): a <see cref="CaptureFallbackPolicy.UnsafeTargetReason"/> other than a terminal's;
    /// null when the paste may go through.
    /// </summary>
    private static string? WindowRefusal(ForegroundApp app)
    {
        var processName = app.Exe is null ? null : Path.GetFileNameWithoutExtension(app.Exe);
        var reason = CaptureFallbackPolicy.UnsafeTargetReason(CaptureFallbackPolicy.ClassNameOf(app.Hwnd), processName, null);
        return reason is "console" or "integratedTerminal" ? null : reason;
    }

    /// <summary>"Notepad (notepad.exe)"; the name alone when it is the executable's.</summary>
    private static string TargetLabel(ForegroundApp app) =>
        app.Exe is { } exe && !exe.Equals(app.DisplayName, StringComparison.OrdinalIgnoreCase)
            ? $"{app.DisplayName} ({exe})"
            : app.DisplayName;

    /// <summary>Brings the open composer to the front (no-op when none is open).</summary>
    public void BringForward() => _open?.Window.ShowAndActivate(fromPipe: true);

    private void OnSessionOpened(ComposerSession session, string text, string fileName)
    {
        if (_open is not null)
        {
            _server.Reply(session, new ComposerMessage.Busy());
            BringForward();
            return;
        }
        // The source is the foreground window before the composer shows (not PopGuy's own windows).
        var foreground = ForegroundApp.Snapshot();
        var hasSource = foreground.Hwnd != 0 && !foreground.IsOwnProcess;
        var name = hasSource && foreground.DisplayName.Length > 0 ? foreground.DisplayName : null;
        _log($"composer: session {session.Id} shown (source {(hasSource ? "app" : "none")})");
        Open(text, session, hasSource ? foreground.Hwnd : 0, name, allowSubmit: true, fromPipe: true);
    }

    private void Open(
        string text, ComposerSession? session, nint source, string? sourceName, bool allowSubmit, bool fromPipe,
        string? noTargetHint = null)
    {
        var window = new ComposerWindow();
        var open = new OpenComposer(window, session, source, Guid.NewGuid(), text, allowSubmit);
        _open = open;
        Volatile.Write(ref _openHwnd, window.Hwnd);
        window.Text = text;
        window.ComposeMode = session is null;
        window.CanSubmit = allowSubmit;
        window.SourceAppName = sourceName;
        window.NoTargetHint = noTargetHint;
        window.DoneRequested += submit => Done(open, submit);
        window.CancelRequested += () => Cancel(open);
        // Copy & Close already copied the text (the session ended, or Compose has no target): a Cancel that keeps the draft.
        window.CopyAndCloseRequested += () => Cancel(open);
        window.RestoreDraftRequested += () => _ = RestoreDraftAsync(open);
        window.TextEdited += () =>
        {
            if (_open == open) SaveDraft(open, now: false);
        };
        window.ShowAndActivate(fromPipe);
        _ = OfferDraftAsync(open);
    }

    /// <summary>Prunes old drafts and shows "Restore draft" when another draft exists (file I/O off the UI thread).</summary>
    private async Task OfferDraftAsync(OpenComposer open)
    {
        var available = await Task.Run(() =>
        {
            _store.Prune();
            return _store.LatestDraft(excluding: open.DraftId) is not null;
        });
        if (_open == open) open.Window.DraftAvailable = available;
    }

    private async Task RestoreDraftAsync(OpenComposer open)
    {
        var draft = await Task.Run(() => _store.LatestDraft(excluding: open.DraftId));
        if (_open != open || draft is not { } found) return;
        open.Window.Text = found.Text;
        open.Window.DraftAvailable = false;
        // The text now lives on as this composer's draft.
        _store.Delete(found.Id);
        SaveDraft(open, now: false);
        _log($"composer: draft restored ({Encoding.UTF8.GetByteCount(found.Text)} bytes)");
    }

    /// <summary>Saves the text as the composer's draft while it differs from the opening text; else removes the draft.</summary>
    private void SaveDraft(OpenComposer open, bool now)
    {
        var text = open.Window.Text;
        if (text == open.OpenedText) _store.Delete(open.DraftId);
        else if (now) _store.SaveNow(open.DraftId, text);
        else _store.ScheduleSave(open.DraftId, text);
    }

    // Done / Cancel.

    private void Done(OpenComposer open, bool submit)
    {
        if (_open != open) return;
        var text = ComposerFileRules.NormalizeLineEndings(open.Window.Text);
        // The final text is on disk before the reply, so a failed write loses nothing.
        _store.SaveNow(open.DraftId, text);
        Close(open);
        if (open.Session is { } session)
        {
            _server.Reply(session, new ComposerMessage.Done(text, submit));
            _log($"composer: session {session.Id} done ({Encoding.UTF8.GetByteCount(text)} bytes, submit {submit})");
            _awaitingEnd[session] = new Delivery(open.DraftId, submit, open.Source);
            _ = ExpireDeliveryAsync(session);
        }
        else
        {
            // The window hides Done & Submit then; checked here too.
            _ = DeliverComposeAsync(open, text, submit && open.AllowSubmit);
        }
    }

    /// <summary>Cancel, Esc, the close button, and Copy &amp; Close (which copied the text already).</summary>
    private void Cancel(OpenComposer open)
    {
        if (_open != open) return;
        if (open.Session is { } session && !open.Window.SessionEnded) _server.Reply(session, new ComposerMessage.Cancel());
        SaveDraft(open, now: true);
        _store.Flush();
        _log("composer: cancelled; draft kept");
        Close(open);
    }

    /// <summary>
    /// Gives the foreground back to the source window (while the composer still has it, so Windows allows it), then
    /// closes the composer.
    /// </summary>
    private void Close(OpenComposer open)
    {
        _open = null;
        Volatile.Write(ref _openHwnd, 0);
        var back = open.Source != 0 ? open.Source : open.Window.PreviousForeground;
        ToolbarWindowStyle.SetForeground(back);
        open.Window.CloseComposer();
    }

    private async Task ExpireDeliveryAsync(ComposerSession session)
    {
        await Task.Delay(SessionEndTimeout);
        if (_awaitingEnd.Remove(session))
            _log($"composer: session {session.Id} did not end in time; draft kept, no auto-submit");
    }

    /// <summary>
    /// Pastes the Compose text into the target. When the target cannot be activated or the paste does not go through,
    /// the text is copied instead (the toolbar's "Copied instead"), and the draft is kept; no Enter.
    /// </summary>
    private async Task DeliverComposeAsync(OpenComposer open, string text, bool submit)
    {
        var pasted = false;
        try
        {
            if (open.Source == 0 || text.Length == 0)
            {
                _log("composer: compose done without a target or text; nothing pasted");
                return;
            }
            if (!await ActivateAsync(open.Source))
            {
                _log("composer: compose target is not the foreground; draft kept");
                await CopyInsteadAsync(text);
                return;
            }
            var result = await _output.PasteAsync(text, open.Source);
            if (result.Status != PasteBackStatus.Pasted)
            {
                _log($"composer: compose paste {result.Status} ({result.Reason}); draft kept");
                // Copying would replace a clipboard PopGuy could not save first (the toolbar's rule), or put text meant
                // for a password field or a remote session on the clipboard: the draft only.
                if (!IsClipboardRefusal(result.Reason) && !IsSensitiveTargetRefusal(result.Reason)) await CopyInsteadAsync(text);
                return;
            }
            pasted = true;
            _store.Delete(open.DraftId);
            _log($"composer: compose pasted ({Encoding.UTF8.GetByteCount(text)} bytes)");
            if (!submit) return;
            await Task.Delay(AutoSubmitDelay);
            await PressEnterAsync(open.Source);
        }
        catch (Exception e)
        {
            _log($"composer: compose delivery failed, {e.GetType().Name}; draft kept");
            if (!pasted) await CopyInsteadAsync(text);
        }
    }

    /// <summary>
    /// A Compose paste that did not go through: puts the text on the clipboard (off the UI thread), like the toolbar's
    /// "Copied instead". The user did not ask for this copy, so it stays out of clipboard history and cloud sync (only
    /// the user's Copy &amp; Close goes into history). Logs the byte count and whether it was written, never the text.
    /// </summary>
    private async Task CopyInsteadAsync(string text)
    {
        try
        {
            var written = await Task.Run(() => ClipboardGuard.WriteText(text, excludeFromHistory: true));
            _log($"composer: compose copied instead ({Encoding.UTF8.GetByteCount(text)} bytes, written {written})");
        }
        catch (Exception e)
        {
            _log($"composer: compose copy failed, {e.GetType().Name}");
        }
    }

    /// <summary>A refusal because the user's clipboard could not be saved first (as the toolbar's paste back).</summary>
    private static bool IsClipboardRefusal(string reason) =>
        reason is "transactionInProgress" or "clipboardBusy" or "tooLarge" or "formatsSkipped" or "writeFailed";

    /// <summary>A refusal because the target is sensitive (a password field or a remote session): no copy instead.</summary>
    private static bool IsSensitiveTargetRefusal(string reason) => reason is "passwordField" or "remoteDesktop";

    // Auto-submit.

    /// <summary>Reactivates <paramref name="source"/>, waits until it is the foreground, then presses Enter. Any failed check skips it.</summary>
    private async Task PressEnterAsync(nint source)
    {
        try
        {
            if (_open is not null)
            {
                _log("composer: auto-submit skipped (a composer is open)");
                return;
            }
            if (!await ActivateAsync(source))
            {
                _log("composer: auto-submit skipped (source not the foreground)");
                return;
            }
            var sent = await _output.SendEnterAsync(source);
            _log($"composer: auto-submit {(sent ? "sent" : "skipped")}");
        }
        catch (Exception e)
        {
            _log($"composer: auto-submit failed, {e.GetType().Name}");
        }
    }

    /// <summary>Makes <paramref name="hwnd"/> the foreground window and waits up to <see cref="ActivationTimeout"/> for it.</summary>
    private static async Task<bool> ActivateAsync(nint hwnd)
    {
        if (!ToolbarWindowStyle.IsAlive(hwnd)) return false;
        if (!ForegroundGuard.IsStill(hwnd)) ToolbarWindowStyle.SetForeground(hwnd);
        var elapsed = Stopwatch.StartNew();
        while (!ForegroundGuard.IsStill(hwnd) && elapsed.Elapsed < ActivationTimeout)
            await Task.Delay(ActivationPollInterval);
        return ForegroundGuard.IsStill(hwnd);
    }

    // Pipe server events (UI thread).

    private void OnSessionEnded(ComposerSession session, bool delivered)
    {
        if (_awaitingEnd.Remove(session, out var delivery))
        {
            if (!delivered)
            {
                // The CLI ended without confirming the write: keep the draft, no Enter.
                _store.Flush();
                _log($"composer: session {session.Id} ended without a confirmed write; draft kept, no auto-submit");
                return;
            }
            // Normal end after "done": the CLI wrote the file and exited.
            _store.Delete(delivery.DraftId);
            _log($"composer: delivered session {session.Id} ended; draft deleted");
            if (delivery.Submit && delivery.Source != 0) _ = AutoSubmitAsync(delivery.Source);
            return;
        }
        if (_open is { Session: { } current } open && current == session)
        {
            _log($"composer: session {session.Id} ended while open");
            open.Window.SessionEnded = true;
        }
    }

    private async Task AutoSubmitAsync(nint source)
    {
        await Task.Delay(AutoSubmitDelay);
        await PressEnterAsync(source);
    }
}
