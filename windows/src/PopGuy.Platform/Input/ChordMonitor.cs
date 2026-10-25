using PopGuy.Core.Settings;
using PopGuy.Core.Toolbar;
using PopGuy.Platform.Capture;
using PopGuy.Platform.SystemServices;
using Windows.Win32.UI.Input.KeyboardAndMouse;

namespace PopGuy.Platform.Input;

/// <summary>A Ctrl+C+C chord that fired (spec-1 §1.4).</summary>
/// <param name="Timestamp">The second tap's time in milliseconds of the system tick count.</param>
/// <param name="App">The foreground app when the chord fired (the capture's source).</param>
/// <param name="ClipboardText">
/// The text the user's own copy put on the clipboard (read once the copy settled), or null when the clipboard did not
/// change since the first tap (or the first tap had no clipboard sequence number), holds no text, or could not be read. Use it only when UI Automation captures nothing,
/// never when UI Automation reports a password field (the user's copy may hold the password), and only in memory
/// (never log it).
/// </param>
/// <param name="IsTruncated">The copy was longer than 1,000,000 characters: <paramref name="ClipboardText"/> holds the first million.</param>
public sealed record ChordFire(uint Timestamp, ForegroundApp App, string? ClipboardText, bool IsTruncated);

/// <summary>
/// The Ctrl+C+C chord: feeds <see cref="GlobalInput.Keys"/> into Core's <see cref="DoubleTapDetector"/> and, when it
/// fires, reads the user's own copy and puts the clipboard from before the first tap back afterwards.
/// <para>
/// What reaches the detector: key-downs only, never a modifier (re-pressing Ctrl between the taps must not reset it),
/// never PopGuy's own synthetic keys, and never an auto-repeat (low-level hooks do not flag repeats, so a key-down
/// for a key already down is dropped: a held Ctrl+C repeats about 30 ms apart and would fire). The chord key is the
/// C key (VK_C, whatever the layout) with Ctrl and no Shift, Alt or Win, as <see cref="GlobalInput.IsUserKeyDown"/>
/// sees them (the user's keys, not PopGuy's synthetic modifier releases). Any other key-down resets a pending tap.
/// </para>
/// <para>
/// The chord never sends a copy: both of the user's Ctrl+C presses reached the app, which copied the selection. On
/// fire, the monitor waits for the second copy (500 ms at most), lets it settle (150 ms, OLE apps write twice), reads
/// its text, raises <see cref="Fired"/>, and 150 ms later restores the cached snapshot keyed by the first tap's
/// clipboard sequence number (<see cref="ClipboardHistoryCache"/>), only if it is complete and nobody copied since the
/// settle point. A missing or incomplete entry means no restore (logged): the clipboard keeps the user's copy. The
/// wait-to-restore window holds <see cref="ClipboardTransaction.Gate"/>, so no capture or paste runs in between.
/// The App must not run <see cref="SelectionCapture"/> in <see cref="CaptureMode.Explicit"/> for the chord (that
/// would send a synthetic copy on top): it reads UI Automation and falls back to <see cref="ChordFire.ClipboardText"/>.
/// </para>
/// <para>
/// Threading: call <see cref="Handle"/> from the one loop that drains <see cref="GlobalInput.Keys"/> (not
/// thread-safe). <see cref="Enabled"/> and <see cref="Apply"/> may be called from any thread. <see cref="Fired"/> is
/// raised on the thread pool.
/// </para>
/// </summary>
public sealed class ChordMonitor
{
    /// <summary>How long the monitor waits for the second tap's copy to land.</summary>
    private static readonly TimeSpan CopyTimeout = TimeSpan.FromMilliseconds(500);

    /// <summary>After the copy landed: it counts as settled and is read.</summary>
    private static readonly TimeSpan SettleDelay = TimeSpan.FromMilliseconds(150);

    /// <summary>After the capture (the settle point): the clipboard from before the chord comes back.</summary>
    private static readonly TimeSpan RestoreDelay = TimeSpan.FromMilliseconds(300);

    /// <summary>How long a fire waits for a running clipboard transaction (a capture lasts about 1.3 s at most).</summary>
    private static readonly TimeSpan GateTimeout = TimeSpan.FromSeconds(2);

    private readonly GlobalInput _input;
    private readonly ClipboardHistoryCache _cache;
    private readonly Action<string>? _log;
    private readonly DoubleTapDetector _detector = new();

    /// <summary>The watched keys held down, to drop auto-repeats. <see cref="Handle"/> only.</summary>
    private readonly HashSet<uint> _down = [];

    /// <summary>The pending first tap's clipboard sequence number (null when none, or the hook had none). <see cref="Handle"/> only.</summary>
    private uint? _arming;

    private volatile bool _enabled = true;

    /// <param name="input">For the user's modifier state.</param>
    /// <param name="cache">The clipboard history the restore comes from.</param>
    /// <param name="log">Gets restore outcomes and failures; never the clipboard's text.</param>
    public ChordMonitor(GlobalInput input, ClipboardHistoryCache cache, Action<string>? log = null)
    {
        _input = input;
        _cache = cache;
        _log = log;
    }

    /// <summary>
    /// The chord fired. Raised on the thread pool once the user's copy settled; the restore follows 150 ms later,
    /// whatever the handler does (a toolbar already showing, an empty selection).
    /// </summary>
    public event Action<ChordFire>? Fired;

    /// <summary>Whether the chord is on. While off, nothing arms or fires. Any thread.</summary>
    public bool Enabled
    {
        get => _enabled;
        set => _enabled = value;
    }

    /// <summary>
    /// Turns the chord on or off from the settings: off when <see cref="AppSettings.TriggerChordEnabled"/> is false or
    /// <see cref="AppSettings.ChordReplacementShortcut"/> is set (the replacement hotkey takes over, see
    /// <see cref="HotkeyService"/>). Any thread.
    /// </summary>
    public void Apply(AppSettings settings) =>
        Enabled = settings.TriggerChordEnabled && settings.ChordReplacementShortcut is null;

    /// <summary>Feeds one key event, in order. Call from the loop that drains <see cref="GlobalInput.Keys"/> only.</summary>
    public void Handle(KeyEvent key)
    {
        if (key.IsPopGuyMarker) return;
        if (key.IsKeyUp)
        {
            _down.Remove(key.VirtualKey);
            return;
        }
        if (IsModifier(key.VirtualKey)) return;
        // An unwatched key has no code to track; its repeats only reset an already reset detector.
        if (!key.IsOtherKey && !_down.Add(key.VirtualKey)) return; // auto-repeat
        if (!_enabled)
        {
            _detector.Reset();
            _arming = null;
            return;
        }

        var isChordKey = key.VirtualKey == (uint)VIRTUAL_KEY.VK_C && IsCtrlOnly();
        if (!_detector.Handle(key.Timestamp, isChordKey))
        {
            if (!isChordKey)
            {
                // Another key dropped the pending tap: its cached snapshot need not be kept.
                if (_arming is { } dropped) _cache.CompleteArming(dropped);
                _arming = null;
                return;
            }
            // A first tap (or a re-arm after the window): the clipboard from before this copy is the one to restore.
            _arming = key.ClipboardSequence;
            if (key.ClipboardSequence is { } sequence) _cache.MarkArming(sequence);
            else _log?.Invoke("chord: a first tap without a clipboard sequence number, no restore");
            return;
        }

        var arming = _arming;
        _arming = null;
        _ = Task.Run(() => FireAsync(key.Timestamp, arming, key.ClipboardSequence));
    }

    private async Task FireAsync(uint timestamp, uint? arming, uint? second)
    {
        try
        {
            // First, before any wait: the app the chord was typed in.
            var app = ForegroundApp.Snapshot();
            if (!await ClipboardTransaction.Gate.WaitAsync(GateTimeout).ConfigureAwait(false))
            {
                // Another transaction holds the clipboard: read it anyway, but do not restore over that transaction.
                _log?.Invoke("chord: clipboard transaction in progress, no restore");
                Raise(timestamp, app, await ReadCopyAsync(arming, second).ConfigureAwait(false));
                if (arming is { } a) _cache.CompleteArming(a);
                return;
            }
            try
            {
                var (text, settled) = await ReadCopyAsync(arming, second).ConfigureAwait(false);
                Raise(timestamp, app, (text, settled));
                await Task.Delay(RestoreDelay - SettleDelay).ConfigureAwait(false);
                Restore(arming, settled);
            }
            finally
            {
                ClipboardTransaction.Gate.Release();
            }
        }
        catch (Exception e)
        {
            _log?.Invoke($"chord: fire failed, {e.GetType().Name} {e.Message}");
        }
    }

    /// <summary>Waits for the second tap's copy, lets it settle, and reads its text and the settled sequence number.</summary>
    private static async Task<(string? Text, uint Settled)> ReadCopyAsync(uint? arming, uint? second)
    {
        if (second is { } before) ClipboardGuard.WaitForChange(before, CopyTimeout);
        await Task.Delay(SettleDelay).ConfigureAwait(false);
        var settled = ClipboardGuard.SequenceNumber;
        // Unchanged since the first tap: neither press copied anything (no selection), so the text is not the selection.
        // Without the first tap's number, a change cannot be told from stale contents: no text.
        var text = arming is { } first && settled != first ? ClipboardGuard.ReadText() : null;
        return (string.IsNullOrWhiteSpace(text) ? null : text, settled);
    }

    private void Raise(uint timestamp, ForegroundApp app, (string? Text, uint Settled) copy)
    {
        var text = copy.Text;
        var truncated = text is not null && text.Length > UiaSelectionReader.MaxTextLength;
        if (truncated) text = text![..UiaSelectionReader.MaxTextLength];
        var fire = new ChordFire(timestamp, app, text, truncated);
        // Off this thread: a handler that starts a clipboard transaction must not wait on the gate held here.
        _ = Task.Run(() =>
        {
            try
            {
                Fired?.Invoke(fire);
            }
            catch (Exception e)
            {
                _log?.Invoke($"chord: a Fired handler threw, {e.GetType().Name} {e.Message}");
            }
        });
    }

    /// <summary>Puts back the clipboard from before the first tap, if complete and unchanged since <paramref name="settled"/>.</summary>
    private void Restore(uint? arming, uint settled)
    {
        if (arming is not { } key) return; // logged at the tap
        try
        {
            string outcome;
            if (!_cache.TryGetBefore(key, out var cached)) outcome = "missing";
            else if (!cached.IsComplete) outcome = cached.IsTooLarge ? "tooLarge" : "incomplete";
            else outcome = ClipboardGuard.RestoreIfUnchanged(cached, settled).ToString();
            _log?.Invoke($"chord: restore {outcome}");
        }
        finally
        {
            _cache.CompleteArming(key);
        }
    }

    /// <summary>Ctrl held, and no Shift, Alt or Win (Caps Lock and Num Lock do not count).</summary>
    private bool IsCtrlOnly() =>
        _input.IsUserKeyDown((uint)VIRTUAL_KEY.VK_CONTROL)
        && !_input.IsUserKeyDown((uint)VIRTUAL_KEY.VK_SHIFT)
        && !_input.IsUserKeyDown((uint)VIRTUAL_KEY.VK_MENU)
        && !_input.IsUserKeyDown((uint)VIRTUAL_KEY.VK_LWIN)
        && !_input.IsUserKeyDown((uint)VIRTUAL_KEY.VK_RWIN);

    private static bool IsModifier(uint vk) => (VIRTUAL_KEY)vk is
        VIRTUAL_KEY.VK_CONTROL or VIRTUAL_KEY.VK_LCONTROL or VIRTUAL_KEY.VK_RCONTROL
        or VIRTUAL_KEY.VK_SHIFT or VIRTUAL_KEY.VK_LSHIFT or VIRTUAL_KEY.VK_RSHIFT
        or VIRTUAL_KEY.VK_MENU or VIRTUAL_KEY.VK_LMENU or VIRTUAL_KEY.VK_RMENU
        or VIRTUAL_KEY.VK_LWIN or VIRTUAL_KEY.VK_RWIN;
}
