#if DEBUG
using System.ComponentModel;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using PopGuy.Core;
using PopGuy.Core.Actions;
using PopGuy.Core.Json;
using PopGuy.Core.Secrets;
using PopGuy.Core.Settings;
using PopGuy.Platform.Capture;
using PopGuy.Platform.Input;
using PopGuy.Platform.SystemServices;
using PopGuy.Platform.Windowing;

namespace PopGuy.Debug;

/// <summary>
/// DEBUG harnesses for the Phase 3 spike gate (plan task 3.4) and the Phase 8 VM QA (plan task 8.4), started from the
/// command line instead of the main window, writing to %APPDATA%\PopGuy\Probes. Selected text is never written, only
/// its length; API keys never at all.
/// <list type="bullet">
/// <item><c>--spike &lt;seconds&gt;</c>: a resident run (<see cref="SpikeSession"/>) for that long, then exit.</item>
/// <item><c>--probe-uia &lt;delaySeconds&gt;</c>: after the delay, one UI Automation read of the focused selection into
/// <c>probe-uia-&lt;ts&gt;.json</c>, then exit.</item>
/// <item><c>--import-key &lt;provider|tts:raw&gt; &lt;path&gt;</c>: saves the key in a UTF-8 text file to Credential
/// Manager (<see cref="SecretIds"/>), replacing an older one, then exit.</item>
/// <item><c>--seed-settings &lt;provider&gt; &lt;model&gt; [baseUrl]</c>: maps the built-in actions to that provider and
/// model, then exit.</item>
/// <item><c>--selftest-toolbar</c>: not an exiting harness; the app starts as usual and shows the toolbar with
/// <see cref="SelfTestText"/> as a result (see <c>App.OnLaunched</c>).</item>
/// </list>
/// Exit code 0, or 1 after an exception (written to <c>error-&lt;ts&gt;.txt</c>) or a refused import or seed. The import
/// and the seed write their one status line to stdout and to <c>import-key.txt</c> / <c>seed-settings.txt</c>
/// (replaced each run): stdout is empty unless redirected, as PopGuy has no console.
/// </summary>
internal static class Probes
{
    internal static readonly JsonSerializerOptions Indented = new() { WriteIndented = true };

    internal static string Folder { get; } = Path.Combine(App.DataRoot, "Probes");

    /// <summary>A key file larger than this is refused before it is read.</summary>
    private const int MaxKeyFileBytes = 64 * 1024;

    /// <summary>The <c>--selftest-toolbar</c> result: several lines, one long enough to wrap.</summary>
    internal const string SelfTestText =
        "PopGuy toolbar self-test.\n" +
        "This is a canned result: no provider was called and nothing goes to history.\n\n" +
        "This paragraph is long on purpose, so the result area has to wrap it across several lines and the toolbar has " +
        "to grow to fit it without cutting anything off.\n" +
        "Last line.";

    /// <summary>The command line asks for the toolbar self-test.</summary>
    internal static bool SelfTestToolbarRequested => Environment.GetCommandLineArgs().Contains("--selftest-toolbar");

    /// <summary>
    /// Starts the harness the process's command line asks for (not LaunchActivatedEventArgs, which unpackaged apps get
    /// empty), and calls <paramref name="exit"/> on this (UI) thread when it ends. False when it asks for none.
    /// </summary>
    internal static bool TryStart(Action exit)
    {
        var args = Environment.GetCommandLineArgs();
        var spike = Array.IndexOf(args, "--spike");
        var probeUia = Array.IndexOf(args, "--probe-uia");
        var importKey = Array.IndexOf(args, "--import-key");
        var seedSettings = Array.IndexOf(args, "--seed-settings");
        if (spike < 0 && probeUia < 0 && importKey < 0 && seedSettings < 0) return false;

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
            if (importKey >= 0) Finish(ImportKey(args, importKey));
            else if (seedSettings >= 0) Finish(SeedSettings(args, seedSettings));
            else if (spike >= 0) SpikeSession.Start(SecondsAfter(args, spike, minimum: 1), dispatcher, Finish);
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

    /// <summary>
    /// <c>--import-key</c>: the file's UTF-8 text without a BOM and surrounding whitespace, saved at
    /// <see cref="SecretIds.Provider"/> (or <see cref="SecretIds.Tts"/> for <c>tts:&lt;raw&gt;</c>). Reports
    /// <c>imported &lt;provider&gt;</c>, or only the error kind: never the key, its length or the file's contents.
    /// </summary>
    private static int ImportKey(string[] args, int index)
    {
        const string Name = "import-key";
        var raw = ArgAt(args, index + 1);
        var path = ArgAt(args, index + 2);
        if (raw is null || path is null) return Report(Name, "usage: --import-key <provider|tts:raw> <path>", 1);
        string? id = raw.StartsWith("tts:", StringComparison.Ordinal)
            ? RawValueEnumConverter<TtsProviderKind>.TryParse(raw[4..], out var tts) ? SecretIds.Tts(tts) : null
            : RawValueEnumConverter<ProviderKind>.TryParse(raw, out var kind) ? SecretIds.Provider(kind) : null;
        if (id is null) return Report(Name, "unknownProvider", 1);

        byte[]? bytes = null;
        try
        {
            var file = new FileInfo(path);
            if (!file.Exists) return Report(Name, "fileMissing", 1);
            if (file.Length > MaxKeyFileBytes) return Report(Name, "tooLarge", 1);
            bytes = File.ReadAllBytes(path);
            var text = bytes.AsSpan();
            if (text.StartsWith(Encoding.UTF8.Preamble)) text = text[Encoding.UTF8.Preamble.Length..];
            // Trimmed as bytes, so the key exists as one string only.
            text = text.Trim(" \t\r\n"u8);
            if (text.IsEmpty) return Report(Name, "empty", 1);
            var key = Encoding.UTF8.GetString(text);
            if (Encoding.UTF8.GetByteCount(key) > CredentialStore.MaxSecretBytes) return Report(Name, "tooLarge", 1);
            new CredentialStore().Set(id, key);
            return Report(Name, $"imported {raw}", 0);
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
        {
            return Report(Name, "fileMissing", 1);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return Report(Name, "fileUnreadable", 1);
        }
        catch (Win32Exception e)
        {
            return Report(Name, $"credWriteFailed {e.NativeErrorCode}", 1);
        }
        finally
        {
            if (bytes is not null) CryptographicOperations.ZeroMemory(bytes);
        }
    }

    /// <summary>
    /// <c>--seed-settings</c>: Improve, Shorten, Proofread, Translate and Prompt get the provider and model (their tone and
    /// custom prompt stay); the base URL, when given, becomes the Custom or Ollama one (ignored for other providers).
    /// </summary>
    private static int SeedSettings(string[] args, int index)
    {
        const string Name = "seed-settings";
        var raw = ArgAt(args, index + 1);
        var baseUrl = ArgAt(args, index + 3);
        if (raw is null || ArgAt(args, index + 2) is not { Length: > 0 } model)
            return Report(Name, "usage: --seed-settings <provider> <model> [baseUrl]", 1);
        if (!RawValueEnumConverter<ProviderKind>.TryParse(raw, out var kind)) return Report(Name, "unknownProvider", 1);

        ActionConfig Seeded(ActionConfig config) => config with { ProviderKind = kind, Model = model };
        try
        {
            new SettingsStore(AppPaths.Resolve()).Update(s =>
            {
                var seeded = s with
                {
                    ImproveConfig = Seeded(s.ImproveConfig),
                    ShortenConfig = Seeded(s.ShortenConfig),
                    ProofreadConfig = Seeded(s.ProofreadConfig),
                    TranslateConfig = Seeded(s.TranslateConfig),
                    PromptConfig = Seeded(s.PromptConfig),
                };
                return (baseUrl, kind) switch
                {
                    ({ } url, ProviderKind.Custom) => seeded with { CustomBaseUrl = url },
                    ({ } url, ProviderKind.Ollama) => seeded with { OllamaBaseUrl = url },
                    _ => seeded,
                };
            });
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return Report(Name, $"settingsWriteFailed {e.GetType().Name}", 1);
        }
        return Report(Name, $"seeded {raw} {model}", 0);
    }

    /// <summary>The argument at <paramref name="index"/>, or null when there is none (or it is the next "--" option).</summary>
    private static string? ArgAt(string[] args, int index) =>
        index < args.Length && !args[index].StartsWith("--", StringComparison.Ordinal) ? args[index] : null;

    /// <summary>Writes <paramref name="line"/> to stdout and to <c>&lt;name&gt;.txt</c> (replaced); returns <paramref name="code"/>.</summary>
    private static int Report(string name, string line, int code)
    {
        Console.Out.WriteLine(line);
        Console.Out.Flush();
        try
        {
            File.WriteAllText(Path.Combine(Folder, $"{name}.txt"), line + Environment.NewLine);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Debug.WriteLine($"PopGuy {name} status not written: {e.Message}");
        }
        return code;
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
                    ["readFailed"] = selection.ReadFailed,
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
                var decision = CaptureFallbackPolicy.Decide(selection, source);
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
                ("uiaReadFailed", selection.ReadFailed),
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
