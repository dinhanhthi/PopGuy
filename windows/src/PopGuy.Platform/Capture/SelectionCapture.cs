using System.Drawing;
using PopGuy.Core.Text;
using PopGuy.Core.Toolbar;
using PopGuy.Platform.Input;
using PopGuy.Platform.SystemServices;
using PopGuy.Platform.Windowing;

namespace PopGuy.Platform.Capture;

/// <summary>What asked for the capture: it decides when the synthetic copy may run (spec-1 §1.2, §1.4).</summary>
public enum CaptureMode
{
    /// <summary>
    /// A hotkey or the chord-replacement shortcut: the synthetic copy for any app <see cref="CaptureFallbackPolicy"/>
    /// allows. Never the Ctrl+C+C chord, which reads the copy the user's own presses made (no synthetic copy on top).
    /// </summary>
    Explicit,

    /// <summary>
    /// The passive selection pipeline: the synthetic copy only for a mouse-up drag in a Monaco editor
    /// (<see cref="SelectionGesture.ShouldAttemptClipboardFallback"/>), and still only where the policy allows it.
    /// </summary>
    Passive,
}

/// <summary>How a capture ended.</summary>
public enum SelectionCaptureStatus
{
    /// <summary><see cref="SelectionCaptureResult.Text"/> holds the selection (never empty or only white space).</summary>
    Captured,

    /// <summary>UI Automation found no selection, and no copy ran.</summary>
    Empty,

    /// <summary>Nothing was read: see <see cref="SelectionCaptureResult.Reason"/>.</summary>
    Unavailable,

    /// <summary>
    /// The target runs elevated and PopGuy does not ("uipi"): Windows drops PopGuy's synthetic input there, so none
    /// was sent.
    /// </summary>
    Blocked,
}

/// <summary>Where the captured text came from.</summary>
public enum SelectionCaptureMethod
{
    /// <summary>Nothing was captured.</summary>
    None,

    /// <summary>UI Automation's text pattern.</summary>
    Uia,

    /// <summary>The synthetic copy (Ctrl+Insert) through a <see cref="ClipboardTransaction"/>.</summary>
    SyntheticCopy,
}

/// <summary>A capture's outcome, for the toolbar (Core PresentationGate's text) and for logs (never log the text).</summary>
/// <param name="Status">How it ended.</param>
/// <param name="Text">The selection; "" unless <see cref="SelectionCaptureStatus.Captured"/>.</param>
/// <param name="IsEditable">
/// A paste can replace the selection (spec-1 §2.5): UI Automation's verdict; for the synthetic copy, true in
/// <see cref="CaptureMode.Passive"/> (it only runs in editors) and false in <see cref="CaptureMode.Explicit"/>.
/// </param>
/// <param name="Method">Where the text came from.</param>
/// <param name="Reason">
/// A short reason for logs: "uia" (UI Automation captured it); "uipi" (blocked); "noGesture" (passive: no drag in a
/// Monaco editor); a <see cref="CaptureFallbackDecision.Reason"/> (a refusal, or, for a copy, why it was allowed); a
/// <see cref="ClipboardTransaction.TryBegin"/> refusal; "foregroundChanged" (the source lost the foreground before the
/// copy, nothing sent); "foreignClipboardWrite" (another app or process wrote the clipboard around the copy: nothing
/// read, and the restore never overwrites that write); "notInserted", "copyNotLanded" or "copyEmpty" (the copy brought no text).
/// </param>
/// <param name="SelectionRects">UI Automation's selection rectangles (screen pixels); empty for a copy, which has none.</param>
/// <param name="UiaStatus">How the UI Automation read ended.</param>
/// <param name="IsTruncated">The selection was longer than 1,000,000 characters: <paramref name="Text"/> holds the first million.</param>
/// <param name="ClipboardRestore">How the clipboard came back after the copy; null when no copy ran.</param>
public sealed record SelectionCaptureResult(
    SelectionCaptureStatus Status,
    string Text,
    bool IsEditable,
    SelectionCaptureMethod Method,
    string Reason,
    IReadOnlyList<Rectangle> SelectionRects,
    UiaCaptureStatus UiaStatus,
    bool IsTruncated = false,
    ClipboardRestoreResult? ClipboardRestore = null);

/// <summary>
/// Captures the source app's selection (spec-1 §2.1, §2.4): UI Automation first; when it captures nothing, a synthetic
/// copy (Ctrl+Insert, <see cref="InputSynth.SendCopy"/>) where the mode, <see cref="CaptureFallbackPolicy"/> and the
/// target's privilege level allow it. The copy runs inside a <see cref="ClipboardTransaction"/> (one at a time per
/// process): snapshot, send (only while the source is still the foreground window and nobody wrote the clipboard since
/// the snapshot), wait up to 500 ms for the clipboard to change, read the text at the settle point 150 ms later (OLE
/// apps write twice), and restore the user's clipboard 300 ms after the change, unless someone copied again meanwhile.
/// The change is taken for the copy only if the source process owns the clipboard's contents and they changed since
/// the send; anything else is a foreign write, never read and never restored over.
/// </summary>
public static class SelectionCapture
{
    private static readonly TimeSpan CopyTimeout = TimeSpan.FromMilliseconds(500);

    /// <summary>After the copy's change: the copy counts as settled, is read, and becomes what a restore may replace.</summary>
    private static readonly TimeSpan SettleDelay = TimeSpan.FromMilliseconds(150);

    /// <summary>After the copy's change: the user's clipboard comes back.</summary>
    private static readonly TimeSpan RestoreDelay = TimeSpan.FromMilliseconds(300);

    /// <summary>
    /// Captures the selection in <paramref name="app"/> (the foreground app when the trigger fired). Runs on the
    /// thread pool; takes up to about 2 s with a copy (1.5 s for UI Automation alone). A copy's result comes after the
    /// clipboard restore.
    /// </summary>
    /// <param name="fromMouseUp">Passive only: the schedule came from a left mouse-up.</param>
    /// <param name="mouseReleasePoint">Passive only: the gesture anchor's release point (a drag or a double-click), else null.</param>
    /// <param name="isUserKeyDown">Whether the user still holds a key (<see cref="GlobalInput.IsUserKeyDown"/>), for the copy's held modifiers.</param>
    public static Task<SelectionCaptureResult> CaptureAsync(
        CaptureMode mode,
        ForegroundApp app,
        bool fromMouseUp = false,
        Point? mouseReleasePoint = null,
        Func<uint, bool>? isUserKeyDown = null) =>
        Task.Run(() => CaptureCoreAsync(mode, app, fromMouseUp, mouseReleasePoint, isUserKeyDown));

    private static async Task<SelectionCaptureResult> CaptureCoreAsync(
        CaptureMode mode, ForegroundApp app, bool fromMouseUp, Point? mouseReleasePoint, Func<uint, bool>? isUserKeyDown)
    {
        var uia = UiaSelectionReader.ReadFocused();
        if (uia.Status == UiaCaptureStatus.Captured)
        {
            return new(SelectionCaptureStatus.Captured, uia.Text, uia.IsEditable, SelectionCaptureMethod.Uia, "uia",
                uia.SelectionRects, uia.Status, uia.IsTruncated);
        }
        if (mode == CaptureMode.Passive)
        {
            var inEditor = app.Exe is { } exe && SelectionGesture.UsesClipboardFallback(exe);
            if (!SelectionGesture.ShouldAttemptClipboardFallback(fromMouseUp, mouseReleasePoint, inEditor)) return NotCaptured(uia, "noGesture");
        }
        if (app.IsElevated && !Environment.IsPrivilegedProcess)
        {
            return new(SelectionCaptureStatus.Blocked, "", false, SelectionCaptureMethod.None, "uipi", [], uia.Status);
        }
        var processName = app.Exe is null ? null : Path.GetFileNameWithoutExtension(app.Exe);
        var decision = CaptureFallbackPolicy.Decide(
            uia.Status, CaptureFallbackPolicy.ClassNameOf(app.Hwnd), processName, uia.FocusedElementHint, uia.ReadFailed);
        if (!decision.Allowed) return NotCaptured(uia, decision.Reason);
        return await CopyAsync(mode, app.Hwnd, app.ProcessId, uia, decision.Reason, isUserKeyDown).ConfigureAwait(false);
    }

    private static async Task<SelectionCaptureResult> CopyAsync(
        CaptureMode mode, nint source, uint sourceProcessId, UiaSelection uia, string allowedReason, Func<uint, bool>? isUserKeyDown)
    {
        if (!ClipboardTransaction.TryBegin(out var transaction, out var refusal)) return NotCaptured(uia, refusal);
        using (transaction)
        {
            // The UI Automation read and the snapshot took time: the copy would hit another window.
            if (!ForegroundGuard.IsStill(source)) return NotCaptured(uia, "foregroundChanged");
            var abortReason = "foregroundChanged";
            var sequenceAtSend = transaction.SequenceBefore;
            var sent = InputSynth.SendCopy(isUserKeyDown, () =>
            {
                // Right before the send: a write since the snapshot is someone else's, and the restore would erase it.
                sequenceAtSend = ClipboardGuard.SequenceNumber;
                if (sequenceAtSend != transaction.SequenceBefore)
                {
                    abortReason = "foreignClipboardWrite";
                    return false;
                }
                return ForegroundGuard.IsStill(source);
            });
            if (sent == InputSendResult.Aborted) return NotCaptured(uia, abortReason);

            ClipboardGuard.WaitForChange(sequenceAtSend, CopyTimeout);
            await Task.Delay(SettleDelay).ConfigureAwait(false);
            // A copy that landed after the 500 ms wait counts too, so the restore does not skip and leave the synthetic
            // copy on the clipboard; but only the source's own write is read and marked as PopGuy's.
            var landed = ClipboardGuard.SequenceNumber != sequenceAtSend;
            string? text = null;
            var waited = false;
            if (landed)
            {
                var owned = ClipboardGuard.TryReadCopyOf(sourceProcessId, sequenceAtSend, out var copySequence, out text, out var readRefusal);
                if (!owned && readRefusal == "clipboardBusy")
                {
                    // Someone held the clipboard open: once more at the restore point, so the copy is not left on it.
                    await Task.Delay(RestoreDelay - SettleDelay).ConfigureAwait(false);
                    waited = true;
                    owned = ClipboardGuard.TryReadCopyOf(sourceProcessId, sequenceAtSend, out copySequence, out text, out readRefusal);
                }
                if (!owned)
                {
                    // Not marked as PopGuy's: the restore skips rather than overwrite a foreign write.
                    return NotCaptured(uia, readRefusal!) with { ClipboardRestore = transaction.Restore() };
                }
                transaction.MarkAsOwn(copySequence);
            }
            if (!waited) await Task.Delay(RestoreDelay - SettleDelay).ConfigureAwait(false);
            var restore = transaction.Restore();

            if (string.IsNullOrWhiteSpace(text))
            {
                var reason = sent == InputSendResult.NotInserted ? "notInserted" : landed ? "copyEmpty" : "copyNotLanded";
                return NotCaptured(uia, reason) with { ClipboardRestore = restore };
            }
            text = LineEndings.ToLf(text);
            var truncated = text.Length > UiaSelectionReader.MaxTextLength;
            if (truncated) text = text[..UiaSelectionReader.MaxTextLength];
            return new(SelectionCaptureStatus.Captured, text, mode == CaptureMode.Passive, SelectionCaptureMethod.SyntheticCopy,
                allowedReason, [], uia.Status, truncated, restore);
        }
    }

    /// <summary>Nothing captured: <see cref="SelectionCaptureStatus.Empty"/> when UI Automation saw an empty selection.</summary>
    private static SelectionCaptureResult NotCaptured(UiaSelection uia, string reason) => new(
        uia.Status == UiaCaptureStatus.Empty ? SelectionCaptureStatus.Empty : SelectionCaptureStatus.Unavailable,
        "", false, SelectionCaptureMethod.None, reason, [], uia.Status);
}
