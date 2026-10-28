using System.Diagnostics;
using PopGuy.Platform.Capture;
using PopGuy.Platform.Input;
using PopGuy.Platform.SystemServices;
using PopGuy.Platform.Windowing;

namespace PopGuy.Platform.Output;

/// <summary>How a paste-back ended.</summary>
public enum PasteBackStatus
{
    /// <summary>Ctrl+V reached the source (the effect is not checked: the paste replaces its selection, or lands at the caret).</summary>
    Pasted,

    /// <summary>The source runs elevated and PopGuy does not ("uipi"): nothing was sent, the clipboard was not touched.</summary>
    Blocked,

    /// <summary>
    /// Not pasted (see <see cref="PasteBackResult.Reason"/>): no key reached the source (but for "notInserted"), and the
    /// user's clipboard was never touched or is back. The App can offer the result as a copy instead.
    /// </summary>
    Refused,
}

/// <summary>A paste-back's outcome, for the App and for logs (never log the text).</summary>
/// <param name="Status">How it ended.</param>
/// <param name="Reason">
/// A short reason for logs: "pasted"; "uipi" (blocked); "empty" (no text); a
/// <see cref="CaptureFallbackPolicy.UnsafeTargetReason"/> ("console", "remoteDesktop", "unknownProcess",
/// "integratedTerminal"); "unknownFocusInEditor" (an editor that hosts xterm.js terminals, with no focused-element hint
/// to rule its terminal out); "passwordField"; "readOnly" (the focused element's value pattern is read-only);
/// "editabilityUnknown" (UI Automation could not tell whether the focused element is editable, and the app is not a
/// known editable host); "sourceGone" (the source window was closed); "sourceNotForeground" (the source did not come
/// to the front within 300 ms); a <see cref="ClipboardTransaction.TryBegin"/> refusal; "writeFailed"; "foregroundChanged" (the source lost
/// the foreground before Ctrl+V, nothing sent); any focus refusal above ("console" to "editabilityUnknown") again when
/// the focus moved during the modifier wait (nothing sent); "notInserted" (SendInput did not insert every event).
/// </param>
/// <param name="ClipboardRestore">How the clipboard came back; null when it was never written.</param>
public sealed record PasteBackResult(PasteBackStatus Status, string Reason, ClipboardRestoreResult? ClipboardRestore = null);

/// <summary>
/// Pastes a result back into the source app (spec-1 §5 "Paste back"), through the clipboard, which is always given
/// back: <see cref="ClipboardTransaction"/> (one at a time per process) snapshots it, the text goes on it as plain text
/// kept out of clipboard history, Ctrl+V goes to the source (<see cref="InputSynth.SendPaste"/>, only while the source
/// is still the foreground window), and the user's clipboard comes back 150 ms later unless someone copied meanwhile.
/// Every refusal leaves the clipboard untouched (or already back).
/// <para>
/// Gating: the targets <see cref="CaptureFallbackPolicy"/> refuses for a synthetic copy are refused here too (consoles,
/// terminals and SSH clients, remote desktop and VM viewers, a process whose name cannot be read, xterm.js panes, and
/// an editor that hosts them without a focused-element hint), so multi-line AI output never reaches a shell. Fails
/// closed: a password field or a read-only value pattern is refused, and so is an element UI Automation cannot call
/// editable (no value pattern, no answer), unless the app is a known editable host (Notepad, WordPad, Office, the
/// xterm.js-hosting editors, Chromium and Firefox browsers). IDEs that host terminals without an xterm.js hint
/// (JetBrains, Visual Studio) are left off that list on purpose. Right before Ctrl+V (after the modifier wait), the
/// focused element is probed again with the same rules: any refusal there aborts the paste.
/// </para>
/// </summary>
public static class PasteBack
{
    /// <summary>
    /// After Ctrl+V: the user's clipboard comes back. Raise it to 300 ms if MVP QA shows a race (a slow target that reads
    /// the clipboard later pastes the restored contents instead of the result).
    /// </summary>
    private static readonly TimeSpan RestoreDelay = TimeSpan.FromMilliseconds(150);

    /// <summary>How long the source has to come to the front after PopGuy gave it the foreground.</summary>
    private static readonly TimeSpan ForegroundTimeout = TimeSpan.FromMilliseconds(300);

    private static readonly TimeSpan ForegroundPollInterval = TimeSpan.FromMilliseconds(10);

    /// <summary>After giving the foreground back: the source's focus settles before its focused element is read.</summary>
    private static readonly TimeSpan ForegroundSettleDelay = TimeSpan.FromMilliseconds(50);

    /// <summary>
    /// Apps known to take a paste wherever their focus is, so an unknown editability does not refuse there: Notepad,
    /// WordPad, Office, the xterm.js-hosting editors (whose terminal rules still apply) and Chromium/Firefox browsers.
    /// </summary>
    private static readonly HashSet<string> KnownEditableHosts = new(StringComparer.OrdinalIgnoreCase)
    {
        "notepad", "wordpad", "winword", "outlook", "powerpnt", "excel", "onenote",
        "Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium",
        "msedge", "chrome", "firefox", "brave",
    };

    /// <summary>
    /// Pastes <paramref name="text"/> into <paramref name="source"/> (the capture's <see cref="ForegroundApp"/>). When
    /// the source is not the foreground window, it gets the foreground back first; call this on the thread that
    /// received the click (the UI thread), since Windows lets PopGuy set the foreground only while it has it or received
    /// the last input. The rest runs on the thread pool; the result comes after the clipboard restore.
    /// </summary>
    /// <param name="isUserKeyDown">Whether the user still holds a key (<see cref="GlobalInput.IsUserKeyDown"/>), for Ctrl+V's held modifiers.</param>
    public static Task<PasteBackResult> PasteAsync(string text, ForegroundApp source, Func<uint, bool>? isUserKeyDown = null)
    {
        if (source.IsElevated && !Environment.IsPrivilegedProcess) return Task.FromResult(new PasteBackResult(PasteBackStatus.Blocked, "uipi"));
        if (string.IsNullOrEmpty(text)) return Task.FromResult(Refused("empty"));
        var windowClass = CaptureFallbackPolicy.ClassNameOf(source.Hwnd);
        var processName = source.Exe is null ? null : Path.GetFileNameWithoutExtension(source.Exe);
        // Before the foreground moves: a terminal or remote session is never brought to the front for nothing.
        if (CaptureFallbackPolicy.UnsafeTargetReason(windowClass, processName, null) is { } unsafeReason)
        {
            return Task.FromResult(Refused(unsafeReason));
        }
        if (!ToolbarWindowStyle.IsAlive(source.Hwnd)) return Task.FromResult(Refused("sourceGone"));
        var switched = !ForegroundGuard.IsStill(source.Hwnd);
        if (switched) ToolbarWindowStyle.SetForeground(source.Hwnd);
        return Task.Run(() => PasteCoreAsync(text, source.Hwnd, windowClass, processName, switched, isUserKeyDown));
    }

    private static async Task<PasteBackResult> PasteCoreAsync(
        string text, nint source, string? windowClass, string? processName, bool switched, Func<uint, bool>? isUserKeyDown)
    {
        if (switched)
        {
            if (!await WaitForForegroundAsync(source).ConfigureAwait(false)) return Refused("sourceNotForeground");
            await Task.Delay(ForegroundSettleDelay).ConfigureAwait(false);
        }
        // Only now: before the source is in front, the focused element is another window's (the toolbar's).
        if (TargetRefusal(UiaSelectionReader.ProbePasteTarget(), windowClass, processName) is { } refusal) return Refused(refusal);

        if (!ClipboardTransaction.TryBegin(out var transaction, out var beginRefusal)) return Refused(beginRefusal);
        using (transaction)
        {
            // The probe and the snapshot took time: the paste would hit another window.
            if (!ForegroundGuard.IsStill(source)) return Refused("foregroundChanged");
            if (!transaction.WriteText(text, excludeFromHistory: true))
            {
                // The transaction already put the snapshot back; this tries again if even that failed.
                return Refused("writeFailed") with { ClipboardRestore = transaction.Restore() };
            }
            var abortReason = "foregroundChanged";
            var sent = InputSynth.SendPaste(isUserKeyDown, () =>
            {
                // The focus may have moved during the modifier wait: probe again with the same rules, the foreground
                // check last.
                if (TargetRefusal(UiaSelectionReader.ProbePasteTarget(), windowClass, processName) is { } late)
                {
                    abortReason = late;
                    return false;
                }
                return ForegroundGuard.IsStill(source);
            });
            if (sent == InputSendResult.Aborted) return Refused(abortReason) with { ClipboardRestore = transaction.Restore() };

            await Task.Delay(RestoreDelay).ConfigureAwait(false);
            var restore = transaction.Restore();
            return sent == InputSendResult.Sent
                ? new PasteBackResult(PasteBackStatus.Pasted, "pasted", restore)
                : Refused("notInserted") with { ClipboardRestore = restore };
        }
    }

    /// <summary>
    /// The refusal for the focused element in the source: <see cref="CaptureFallbackPolicy.UnsafeTargetReason"/> with
    /// its hint, an xterm.js-hosting editor without a hint, a password field, a read-only value pattern, or an unknown
    /// editability outside <see cref="KnownEditableHosts"/>; null to paste. Pure: no system calls.
    /// </summary>
    internal static string? TargetRefusal(UiaPasteTarget target, string? windowClass, string? processName)
    {
        if (CaptureFallbackPolicy.UnsafeTargetReason(windowClass, processName, target.FocusedElementHint) is { } unsafeReason)
        {
            return unsafeReason;
        }
        if (CaptureFallbackPolicy.HostsXtermTerminals(processName) && string.IsNullOrEmpty(target.FocusedElementHint))
        {
            return "unknownFocusInEditor";
        }
        if (target.IsPassword) return "passwordField";
        if (target.IsEditable == false) return "readOnly";
        return target.IsEditable is null && (processName is null || !KnownEditableHosts.Contains(processName)) ? "editabilityUnknown" : null;
    }

    /// <summary>Polls until <paramref name="source"/> is the foreground window, for 300 ms at most.</summary>
    private static async Task<bool> WaitForForegroundAsync(nint source)
    {
        var watch = Stopwatch.StartNew();
        while (!ForegroundGuard.IsStill(source))
        {
            if (watch.Elapsed >= ForegroundTimeout) return false;
            await Task.Delay(ForegroundPollInterval).ConfigureAwait(false);
        }
        return true;
    }

    private static PasteBackResult Refused(string reason) => new(PasteBackStatus.Refused, reason);
}
