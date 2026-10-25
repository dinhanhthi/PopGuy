#if DEBUG
using System.ComponentModel;
using System.Globalization;
using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using PopGuy.Platform.Capture;
using PopGuy.Platform.Input;
using PopGuy.Platform.Windowing;

namespace PopGuy.Debug;

/// <summary>
/// DEBUG harnesses for the Phase 3 spike gate (plan task 3.4), started from the command line instead of the main
/// window, writing to %APPDATA%\PopGuy\Probes. Selected text is never written, only its length.
/// <list type="bullet">
/// <item><c>--spike &lt;seconds&gt;</c>: a resident run (<see cref="SpikeSession"/>) for that long, then exit.</item>
/// <item><c>--probe-uia &lt;delaySeconds&gt;</c>: after the delay, one UI Automation read of the focused selection into
/// <c>probe-uia-&lt;ts&gt;.json</c>, then exit.</item>
/// </list>
/// Exit code 0, or 1 after an exception (written to <c>error-&lt;ts&gt;.txt</c>).
/// </summary>
internal static class Probes
{
    internal static readonly JsonSerializerOptions Indented = new() { WriteIndented = true };

    internal static string Folder { get; } = Path.Combine(App.DataRoot, "Probes");

    /// <summary>
    /// Starts the harness the process's command line asks for (not LaunchActivatedEventArgs, which unpackaged apps get
    /// empty), and calls <paramref name="exit"/> on this (UI) thread when it ends. False when it asks for none.
    /// </summary>
    internal static bool TryStart(Action exit)
    {
        var args = Environment.GetCommandLineArgs();
        var spike = Array.IndexOf(args, "--spike");
        var probeUia = Array.IndexOf(args, "--probe-uia");
        if (spike < 0 && probeUia < 0) return false;

        var dispatcher = DispatcherQueue.GetForCurrentThread();
        // A crash on the UI thread still leaves its error file and a non-zero exit code.
        Application.Current.UnhandledException += (_, e) =>
        {
            WriteError(e.Exception);
            Environment.ExitCode = 1;
        };
        void Finish(int code) => dispatcher.TryEnqueue(() =>
        {
            Environment.ExitCode = code;
            exit();
        });

        try
        {
            Directory.CreateDirectory(Folder);
            if (spike >= 0) SpikeSession.Start(SecondsAfter(args, spike, minimum: 1), dispatcher, Finish);
            else RunProbeUia(SecondsAfter(args, probeUia, minimum: 0), Finish);
        }
        catch (Exception e)
        {
            WriteError(e);
            Finish(1);
        }
        return true;
    }

    /// <summary>The time stamp in file names: local time, to the second.</summary>
    internal static string Stamp() => DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);

    /// <summary>Writes <paramref name="e"/> to <c>error-&lt;ts&gt;.txt</c>; never throws.</summary>
    internal static void WriteError(Exception e)
    {
        try
        {
            Directory.CreateDirectory(Folder);
            File.AppendAllText(Path.Combine(Folder, $"error-{Stamp()}.txt"), e + Environment.NewLine);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Debug.WriteLine($"PopGuy probe error not written: {ex.Message}");
        }
    }

    /// <summary>The process name behind <paramref name="hwnd"/> ("notepad"), or "?" when it cannot be read.</summary>
    internal static string ExeOf(nint hwnd)
    {
        var processId = ToolbarWindowStyle.ProcessIdOf(hwnd);
        if (processId == 0) return "?";
        try
        {
            using var process = System.Diagnostics.Process.GetProcessById((int)processId);
            return process.ProcessName;
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or Win32Exception)
        {
            return "?";
        }
    }

    private static int SecondsAfter(string[] args, int index, int minimum)
    {
        if (index + 1 < args.Length
            && int.TryParse(args[index + 1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var seconds)
            && seconds >= minimum)
        {
            return seconds;
        }
        throw new ArgumentException($"{args[index]} needs a whole number of seconds (at least {minimum}).");
    }

    private static void RunProbeUia(int delaySeconds, Action<int> finish)
    {
        _ = Task.Run(async () =>
        {
            var code = 1;
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(delaySeconds));
                var foreground = ToolbarWindowStyle.ForegroundWindow();
                var selection = UiaSelectionReader.ReadFocused();
                var record = new Dictionary<string, object?>
                {
                    ["status"] = selection.Status.ToString(),
                    ["textLength"] = selection.Text.Length,
                    ["isEditable"] = selection.IsEditable,
                    ["isTruncated"] = selection.IsTruncated,
                    ["focusedElementHint"] = selection.FocusedElementHint,
                    ["rects"] = selection.SelectionRects
                        .Select(r => new Dictionary<string, int> { ["x"] = r.X, ["y"] = r.Y, ["width"] = r.Width, ["height"] = r.Height })
                        .ToArray(),
                    ["exe"] = ExeOf(foreground),
                };
                File.WriteAllText(Path.Combine(Folder, $"probe-uia-{Stamp()}.json"), JsonSerializer.Serialize(record, Indented));
                code = 0;
            }
            catch (Exception e)
            {
                WriteError(e);
            }
            finally
            {
                finish(code);
            }
        });
    }
}

/// <summary>
/// The <c>--spike</c> resident run: global input, the clipboard history cache, the Ctrl+Alt+Shift+I hotkey and an
/// inline Ctrl+C+C detector; each trigger captures the selection (UI Automation; for the chord, else the user's own
/// copy; for the hotkey, else a synthetic copy (Ctrl+Insert) where <see cref="CaptureFallbackPolicy"/> allows it, through a
/// <see cref="ClipboardTransaction"/>) and shows <see cref="SpikeToolbarWindow"/> at the pointer. Logs JSON lines to
/// <c>spike-&lt;ts&gt;.jsonl</c>.
/// </summary>
internal sealed class SpikeSession
{
    private const uint VkC = 0x43;
    private const uint VkI = 0x49;
    private const string PastedText = "PASTED-BY-POPGUY";

    /// <summary>The second Ctrl+C must come this soon after the first.</summary>
    private const uint ChordWindowMs = 300;

    private static readonly TimeSpan CaptureRestoreDelay = TimeSpan.FromMilliseconds(300);

    /// <summary>
    /// Within <see cref="CaptureRestoreDelay"/>: when the copy counts as settled, and its sequence number is taken as the
    /// one a restore may replace (OLE apps write twice: their data object, then the flushed formats).
    /// </summary>
    private static readonly TimeSpan CaptureSettleDelay = TimeSpan.FromMilliseconds(150);
    private static readonly TimeSpan PasteRestoreDelay = TimeSpan.FromMilliseconds(150);

    /// <summary>After giving the foreground back before a paste: the source's focus settles before Ctrl+V arrives.</summary>
    private static readonly TimeSpan ForegroundSettleDelay = TimeSpan.FromMilliseconds(50);

    private readonly DispatcherQueue _dispatcher;
    private readonly Action<int> _finish;
    private readonly SpikeLog _log;
    private readonly CancellationTokenSource _stop = new();
    private readonly SpikeToolbarWindow _toolbar;
    private ClipboardHistoryCache? _cache;
    private GlobalInput? _input;
    private int _hotKeyId;
    private int _busy;
    private int _ended;
    private volatile bool _failed;

    /// <summary>The last capture, for Copy. Kept in memory only, never logged.</summary>
    private volatile string? _capturedText;

    // The Ctrl+C+C detector (input channel reader only).
    private (uint Time, uint Sequence)? _firstTap;
    private bool _cDown;
    private readonly HashSet<uint> _controlsDown = [];

    private SpikeSession(DispatcherQueue dispatcher, Action<int> finish)
    {
        _dispatcher = dispatcher;
        _finish = finish;
        _log = new SpikeLog(Path.Combine(Probes.Folder, $"spike-{Probes.Stamp()}.jsonl"));
        _toolbar = new SpikeToolbarWindow();
        _toolbar.Logged += record => _log.Write(record);
        _toolbar.Clicked += OnClicked;
    }

    /// <summary>Starts the run on the UI thread; it ends after <paramref name="seconds"/> and calls <paramref name="finish"/>.</summary>
    internal static void Start(int seconds, DispatcherQueue dispatcher, Action<int> finish)
    {
        var session = new SpikeSession(dispatcher, finish);
        try
        {
            session.StartCore(seconds);
        }
        catch (Exception e)
        {
            // End exits; the caller must not exit again.
            Probes.WriteError(e);
            session.End(1);
        }
    }

    private void StartCore(int seconds)
    {
        _log.Write(Record("start", ("seconds", seconds), ("version", App.Version)));
        _cache = new ClipboardHistoryCache(PlatformLog);
        _input = new GlobalInput(PlatformLog);
        try
        {
            _hotKeyId = _input.Register(HotKeyModifiers.Control | HotKeyModifiers.Alt | HotKeyModifiers.Shift, VkI);
            _log.Write(Record("hotkeyRegistered", ("id", _hotKeyId)));
        }
        catch (Win32Exception e)
        {
            // Not fatal: the chord can still be checked.
            _log.Write(Record("hotkeyFailed", ("error", e.NativeErrorCode)));
        }

        var token = _stop.Token;
        Watch(Task.Run(() => ReadKeysAsync(token)));
        Watch(Task.Run(() => ReadHotKeysAsync(token)));
        Watch(Task.Run(() => ReadMouseAsync(token)));
        Watch(Task.Run(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(seconds), token);
            End(_failed ? 1 : 0);
        }, token));
    }

    // Triggers.

    private async Task ReadKeysAsync(CancellationToken token)
    {
        await foreach (var key in _input!.Keys.ReadAllAsync(token))
        {
            OnKey(key);
        }
    }

    /// <summary>
    /// Throwaway spike detector (Task 7.2 replaces it with Core's DoubleTapDetector): two C presses with Ctrl down
    /// within 300 ms, auto-repeat and PopGuy's own (marker) events ignored. The first tap arms the clipboard cache with
    /// the sequence number from before the app's copy.
    /// </summary>
    private void OnKey(KeyEvent key)
    {
        if (IsControl(key.VirtualKey))
        {
            // Watch-list: which Ctrl the VM's keys arrive as, and whether injected.
            if (key.IsKeyDown && _controlsDown.Add(key.VirtualKey))
            {
                _log.Write(Record("ctrlKey", ("vk", key.VirtualKey), ("injected", key.Injected), ("marker", key.IsPopGuyMarker)));
            }
            else if (key.IsKeyUp)
            {
                _controlsDown.Remove(key.VirtualKey);
            }
            return;
        }
        if (key.IsPopGuyMarker)
        {
            // PopGuy's own keys (the Ctrl+Insert copy, the Ctrl+V paste): never counted by the detector.
            if (key.IsKeyDown && !IsModifier(key.VirtualKey))
            {
                _log.Write(Record("syntheticKey", ("injected", key.Injected), ("marker", true), ("counted", false)));
            }
            return;
        }
        if (key.VirtualKey != VkC)
        {
            if (key.IsKeyDown && !IsModifier(key.VirtualKey)) _firstTap = null;
            return;
        }
        if (key.IsKeyUp)
        {
            _cDown = false;
            return;
        }
        if (_cDown) return; // auto-repeat
        _cDown = true;
        if (key.ClipboardSequence is not { } sequence)
        {
            _firstTap = null; // C without Ctrl
            return;
        }
        _log.Write(Record("ctrlC", ("injected", key.Injected), ("marker", false), ("counted", true)));
        if (_firstTap is { } first && unchecked(key.Timestamp - first.Time) <= ChordWindowMs)
        {
            _firstTap = null;
            Trigger("chord", new ChordTaps(first.Sequence, sequence), key.Injected);
            return;
        }
        _firstTap = (key.Timestamp, sequence);
        _cache!.MarkArming(sequence);
    }

    private async Task ReadHotKeysAsync(CancellationToken token)
    {
        await foreach (var id in _input!.HotKeys.ReadAllAsync(token))
        {
            if (id == _hotKeyId) Trigger("hotkey", chord: null, injected: null);
        }
    }

    /// <summary>
    /// The chord's two Ctrl+C presses: the clipboard sequence number before each (the first is the arming one, from
    /// before the app's first copy).
    /// </summary>
    private readonly record struct ChordTaps(uint Arming, uint Second);

    private void Trigger(string kind, ChordTaps? chord, bool? injected)
    {
        if (Interlocked.Exchange(ref _busy, 1) == 1)
        {
            _log.Write(Record("triggerIgnored", ("trigger", kind), ("reason", "a capture is running")));
            return;
        }
        Watch(Task.Run(async () =>
        {
            try
            {
                await CaptureAsync(kind, chord, injected);
            }
            finally
            {
                Volatile.Write(ref _busy, 0);
            }
        }));
    }

    /// <summary>
    /// Captures the foreground app's selection and shows the toolbar. UI Automation first. When it captures nothing:
    /// <list type="bullet">
    /// <item>The chord: the user's own Ctrl+C presses already copied the selection, so it is only read (never a
    /// synthetic copy on top). 300 ms after the capture, the clipboard from before the first press (the cache's
    /// snapshot at the arming sequence number) comes back, unless someone copied again meanwhile.</item>
    /// <item>The hotkey: a synthetic copy (Ctrl+Insert), only where <see cref="CaptureFallbackPolicy"/> allows it, only
    /// when <see cref="ClipboardTransaction.TryBegin"/> could save the clipboard first (else the capture is unavailable
    /// and nothing touches the clipboard), and only while the source is still the foreground window (checked before the
    /// send and again after the modifier wait; else "foregroundChanged" and nothing is sent); restored 300 ms later
    /// unless someone copied again meanwhile.</item>
    /// </list>
    /// For the chord, the cache's snapshot comes back only when it is complete (no format left out): a partial one
    /// would lose the rest, so the clipboard then keeps the user's copy of the selection.
    /// </summary>
    private async Task CaptureAsync(string kind, ChordTaps? chord, bool? injected)
    {
        var source = ToolbarWindowStyle.ForegroundWindow();
        if (ToolbarWindowStyle.IsToolbarOrOwned(source, _toolbar.Hwnd))
        {
            _log.Write(Record("triggerIgnored", ("trigger", kind), ("reason", "the toolbar is the foreground window")));
            return;
        }
        var exe = Probes.ExeOf(source);
        var selection = UiaSelectionReader.ReadFocused();

        string method;
        string? text = null;
        string? fallback = null;
        string? refusal = null;
        bool? copySent = null;
        ClipboardTransaction? transaction = null;
        try
        {
            if (chord is { } taps)
            {
                // The second press's copy: wait for it, so the restore comes after it.
                ClipboardGuard.WaitForChange(taps.Second);
                if (selection.Status == UiaCaptureStatus.Captured)
                {
                    method = "uia";
                    text = selection.Text;
                }
                else if (selection.Status == UiaCaptureStatus.PasswordField)
                {
                    method = "none";
                    refusal = "passwordField";
                }
                else
                {
                    method = "userCopy";
                    text = ClipboardGuard.SequenceNumber != taps.Arming ? ClipboardGuard.ReadText() : null;
                }
            }
            else if (selection.Status == UiaCaptureStatus.Captured)
            {
                method = "uia";
                text = selection.Text;
            }
            else
            {
                var decision = CaptureFallbackPolicy.Decide(selection.Status, source, selection.FocusedElementHint);
                fallback = decision.Reason;
                if (!decision.Allowed || !ClipboardTransaction.TryBegin(out transaction, out refusal))
                {
                    method = "none";
                }
                else if (!ForegroundGuard.IsStill(source))
                {
                    // The UI Automation read and the snapshot took time: the copy would hit another window.
                    method = "none";
                    refusal = "foregroundChanged";
                }
                else
                {
                    var sent = InputSynth.SendCopy(_input!.IsUserKeyDown, () => ForegroundGuard.IsStill(source));
                    if (sent == InputSendResult.Aborted)
                    {
                        method = "none";
                        refusal = "foregroundChanged";
                    }
                    else
                    {
                        method = "ctrlInsert";
                        copySent = sent == InputSendResult.Sent;
                        if (ClipboardGuard.WaitForChange(transaction.SequenceBefore)) text = ClipboardGuard.ReadText();
                    }
                }
            }
            _capturedText = text;

            var pointer = ToolbarWindowStyle.CursorPosition();
            _dispatcher.TryEnqueue(() => _toolbar.ShowAt(source, pointer));

            await Task.Delay(CaptureSettleDelay);
            // What the copy left on the clipboard: a restore replaces only that, never a newer copy. A copy that landed
            // after the 500 ms wait counts too (any change since the snapshot is taken for it), so the restore does not
            // skip and leave the synthetic copy on the clipboard.
            var settled = ClipboardGuard.SequenceNumber;
            if (method == "ctrlInsert" && settled != transaction!.SequenceBefore)
            {
                transaction.MarkCurrentAsOwn();
                if (text is null)
                {
                    text = ClipboardGuard.ReadText();
                    _capturedText = text;
                }
            }
            await Task.Delay(CaptureRestoreDelay - CaptureSettleDelay);

            ClipboardRestoreResult? clipboardRestore = transaction?.Restore();
            string? chordRestore = null;
            if (chord is { } done)
            {
                // Only a complete snapshot comes back; otherwise the clipboard keeps the user's copy of the selection.
                chordRestore = !_cache!.TryGetBefore(done.Arming, out var cached) ? "missing"
                    : cached.IsTooLarge ? "tooLarge"
                    : !cached.IsComplete ? "incomplete"
                    : Describe(ClipboardGuard.RestoreIfUnchanged(cached, settled));
                _cache.CompleteArming(done.Arming);
            }

            _log.Write(Record(kind,
                ("fgBefore", SpikeToolbarWindow.Hex(source)),
                ("fgAfter", SpikeToolbarWindow.Hex(ToolbarWindowStyle.ForegroundWindow())),
                ("exe", exe),
                ("uiaStatus", selection.Status.ToString()),
                ("capture", text is null ? "Unavailable" : "Captured"),
                ("textLength", text?.Length),
                ("isEditable", selection.IsEditable),
                ("isTruncated", selection.IsTruncated),
                ("focusedElementHint", selection.FocusedElementHint),
                ("method", method),
                ("fallback", fallback),
                ("refusal", refusal),
                ("copySent", copySent),
                ("clipboardRestored", clipboardRestore is null ? null : clipboardRestore is ClipboardRestoreResult.Restored or ClipboardRestoreResult.Unchanged),
                ("clipboardRestore", clipboardRestore is { } r ? Describe(r) : null),
                ("chordRestore", chordRestore),
                ("restoreSkipped", clipboardRestore == ClipboardRestoreResult.SkippedClipboardChanged || chordRestore == "skipped" ? "clipboardChanged" : null),
                ("injected", injected),
                ("marker", kind == "chord" ? (bool?)false : null)));
        }
        finally
        {
            transaction?.Dispose();
        }
    }

    private static string Describe(ClipboardRestoreResult result) => result switch
    {
        ClipboardRestoreResult.Restored => "restored",
        ClipboardRestoreResult.Unchanged => "unchanged",
        ClipboardRestoreResult.SkippedClipboardChanged => "skipped",
        ClipboardRestoreResult.NotRestorable => "notRestorable",
        _ => "failed",
    };

    // Toolbar actions (UI thread).

    private void OnClicked(string name)
    {
        switch (name)
        {
            case "paste":
                Paste();
                break;
            case "copy":
                {
                    var text = _capturedText;
                    Watch(Task.Run(() =>
                    {
                        // The user asked for the clipboard to change; a failed write still gets the old contents back.
                        using var snapshot = text is null ? null : ClipboardGuard.Snapshot();
                        var written = text is not null
                            && ClipboardGuard.WriteText(text, excludeFromHistory: false, snapshot is { IsComplete: true } ? snapshot : null);
                        _log.Write(Record("copy", ("textLength", text?.Length), ("written", written)));
                    }));
                    break;
                }
            default:
                _log.Write(Record(name));
                break;
        }
    }

    /// <summary>
    /// The source gets the foreground back if needed, then PASTED-BY-POPGUY goes in through the clipboard (kept out
    /// of clipboard history) and Ctrl+V; the clipboard comes back 150 ms later unless someone copied meanwhile. Refused,
    /// with the reason logged and the clipboard left as it was (or put back), when the source is not the foreground
    /// window, the clipboard could not be saved first, or the write failed.
    /// </summary>
    private void Paste()
    {
        var source = _toolbar.Source;
        var fgBefore = ToolbarWindowStyle.ForegroundWindow();
        var switched = fgBefore != source;
        var sourceForeground = _toolbar.ReturnForegroundToSource();
        _toolbar.Dismiss("paste", handBack: false);
        Watch(Task.Run(async () =>
        {
            if (switched) await Task.Delay(ForegroundSettleDelay);
            string? refused = null;
            bool? written = null;
            bool? sent = null;
            ClipboardRestoreResult? restore = null;
            if (!sourceForeground || !ForegroundGuard.IsStill(source))
            {
                refused = "sourceNotForeground";
            }
            else if (!ClipboardTransaction.TryBegin(out var transaction, out var refusal))
            {
                refused = refusal;
            }
            else
            {
                using (transaction)
                {
                    written = transaction.WriteText(PastedText, excludeFromHistory: true);
                    if (written != true)
                    {
                        refused = "writeFailed"; // the transaction already put the clipboard back
                    }
                    else if (!ForegroundGuard.IsStill(source))
                    {
                        refused = "sourceNotForeground";
                        restore = transaction.Restore();
                    }
                    else
                    {
                        // Checked again after the modifier wait, right before Ctrl+V.
                        var result = InputSynth.SendPaste(_input!.IsUserKeyDown, () => ForegroundGuard.IsStill(source));
                        if (result == InputSendResult.Aborted)
                        {
                            refused = "foregroundChanged";
                            restore = transaction.Restore();
                        }
                        else
                        {
                            sent = result == InputSendResult.Sent;
                            await Task.Delay(PasteRestoreDelay);
                            restore = transaction.Restore();
                        }
                    }
                }
            }
            _log.Write(Record("paste",
                ("fgBefore", SpikeToolbarWindow.Hex(fgBefore)),
                ("fgAfter", SpikeToolbarWindow.Hex(ToolbarWindowStyle.ForegroundWindow())),
                ("source", SpikeToolbarWindow.Hex(source)),
                ("exe", Probes.ExeOf(source)),
                ("foregroundSwitched", switched),
                ("sourceForeground", sourceForeground),
                ("refused", refused),
                ("message", refused is null ? null : "Paste not possible, the clipboard was left as it was"),
                ("written", written),
                ("injected", sent),
                ("clipboardRestored", restore is null ? null : restore is ClipboardRestoreResult.Restored or ClipboardRestoreResult.Unchanged),
                ("clipboardRestore", restore is { } r ? Describe(r) : null),
                ("restoreSkipped", restore == ClipboardRestoreResult.SkippedClipboardChanged ? "clipboardChanged" : null)));
        }));
    }

    // Outside clicks dismiss the toolbar.

    private async Task ReadMouseAsync(CancellationToken token)
    {
        await foreach (var mouse in _input!.Mouse.ReadAllAsync(token))
        {
            if (mouse.Kind is not (MouseEventKind.LeftDown or MouseEventKind.RightDown or MouseEventKind.MiddleDown)) continue;
            _dispatcher.TryEnqueue(() =>
            {
                if (_toolbar.IsShown && !_toolbar.Contains(mouse.X, mouse.Y)) _toolbar.Dismiss("outside click", handBack: false);
            });
        }
    }

    // Lifetime.

    /// <summary>Logs a failed background task (and ends the run with code 1 later) instead of losing it.</summary>
    private void Watch(Task task) => task.ContinueWith(
        t =>
        {
            if (t.Exception is not { } error) return;
            _failed = true;
            Probes.WriteError(error);
            _log.Write(Record("error", ("message", error.GetBaseException().Message)));
        },
        CancellationToken.None,
        TaskContinuationOptions.OnlyOnFaulted,
        TaskScheduler.Default);

    /// <summary>Stops everything once and exits with <paramref name="code"/>. Any thread.</summary>
    private void End(int code)
    {
        if (Interlocked.Exchange(ref _ended, 1) != 0) return;
        _stop.Cancel();
        _dispatcher.TryEnqueue(() =>
        {
            // First: whatever stops the dispatcher from here on, the process exits with this code. The toolbar is not
            // closed here (closing the last window starts the shutdown); Exit tears it down.
            Environment.ExitCode = code;
            try
            {
                _toolbar.Dismiss("end", handBack: true);
                _input?.Dispose();
                _cache?.Dispose();
                _log.Write(Record("end", ("exitCode", code)));
            }
            catch (Exception e)
            {
                Probes.WriteError(e);
                code = 1;
                Environment.ExitCode = code;
            }
            finally
            {
                _log.Dispose();
                _finish(code);
            }
        });
    }

    private void PlatformLog(string message) => _log.Write(Record("platform", ("message", message)));

    private static bool IsControl(uint vk) => vk is 0x11 or 0xA2 or 0xA3;

    /// <summary>Shift, Ctrl, Alt (generic and sided) and the Windows keys: they do not break a Ctrl+C pair.</summary>
    private static bool IsModifier(uint vk) => vk is 0x10 or 0x11 or 0x12 or (>= 0xA0 and <= 0xA5) or 0x5B or 0x5C;

    private static Dictionary<string, object?> Record(string evt, params (string Key, object? Value)[] fields)
    {
        var record = new Dictionary<string, object?> { ["event"] = evt };
        foreach (var (key, value) in fields) record[key] = value;
        return record;
    }

    /// <summary>One JSON object per line, flushed at once, from any thread.</summary>
    private sealed class SpikeLog : IDisposable
    {
        private readonly Lock _gate = new();
        private StreamWriter? _writer;

        internal SpikeLog(string path)
        {
            _writer = new StreamWriter(path, append: true) { AutoFlush = true };
        }

        internal void Write(Dictionary<string, object?> record)
        {
            var line = new Dictionary<string, object?> { ["time"] = DateTimeOffset.Now.ToString("O", CultureInfo.InvariantCulture) };
            foreach (var (key, value) in record) line[key] = value;
            var json = JsonSerializer.Serialize(line);
            lock (_gate)
            {
                try
                {
                    _writer?.WriteLine(json);
                }
                catch (IOException e)
                {
                    System.Diagnostics.Debug.WriteLine($"PopGuy spike log write failed: {e.Message}");
                }
            }
        }

        public void Dispose()
        {
            lock (_gate)
            {
                _writer?.Dispose();
                _writer = null;
            }
        }
    }
}
#endif
