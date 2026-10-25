using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.Input.KeyboardAndMouse;
using Windows.Win32.UI.WindowsAndMessaging;

namespace PopGuy.Platform.Input;

/// <summary>
/// A key press or release seen by the low-level keyboard hook. Only the keys PopGuy watches (every modifier, C, and the
/// keys of the registered hotkeys) carry their codes; any other key arrives as <see cref="OtherKey"/> with no virtual
/// key or scan code, so the stream never holds what the user types (passwords), yet still breaks a double tap.
/// </summary>
/// <param name="VirtualKey">
/// The virtual-key code (the hook reports the left and right modifiers separately: VK_LCONTROL…), or
/// <see cref="OtherKey"/> for a key PopGuy does not watch.
/// </param>
/// <param name="ScanCode">The hardware scan code; 0 for <see cref="OtherKey"/>.</param>
/// <param name="IsKeyDown">A press (or an auto-repeat), else a release.</param>
/// <param name="Timestamp">The event's time in milliseconds of the system tick count (wraps after 49.7 days).</param>
/// <param name="Injected">The event came from SendInput (PopGuy's or another app's, e.g. a remote-control tool), not a keyboard.</param>
/// <param name="IsPopGuyMarker">The event is injected and carries <see cref="InputSynth.Marker"/>: PopGuy synthesized it.</param>
/// <param name="ClipboardSequence">
/// On a C press while Ctrl is down only: the clipboard sequence number before the app copies, for
/// <see cref="Capture.ClipboardHistoryCache.MarkArming"/>. Null on every other event.
/// </param>
public readonly record struct KeyEvent(
    uint VirtualKey, uint ScanCode, bool IsKeyDown, uint Timestamp, bool Injected, bool IsPopGuyMarker, uint? ClipboardSequence)
{
    /// <summary>The <see cref="VirtualKey"/> of a key PopGuy does not watch (no real key has code 0).</summary>
    public const uint OtherKey = 0;

    public bool IsKeyUp => !IsKeyDown;

    /// <summary>A key PopGuy does not watch: its code was not published.</summary>
    public bool IsOtherKey => VirtualKey == OtherKey;
}

/// <summary>What a <see cref="MouseEvent"/> is. Low-level hooks deliver no double-clicks, only each press and release.</summary>
public enum MouseEventKind
{
    Move,
    LeftDown,
    LeftUp,
    RightDown,
    RightUp,
    MiddleDown,
    MiddleUp,
    XDown,
    XUp,
    Wheel,
    HorizontalWheel,
}

/// <summary>A mouse event seen by the low-level mouse hook.</summary>
/// <param name="Kind">What happened.</param>
/// <param name="X">The pointer's x in physical screen pixels (per-monitor aware).</param>
/// <param name="Y">The pointer's y in physical screen pixels (per-monitor aware).</param>
/// <param name="WheelDelta">For <see cref="MouseEventKind.Wheel"/> and <see cref="MouseEventKind.HorizontalWheel"/>: the signed distance (120 per notch), else 0.</param>
/// <param name="XButton">For <see cref="MouseEventKind.XDown"/> and <see cref="MouseEventKind.XUp"/>: 1 or 2, else 0.</param>
/// <param name="Timestamp">The event's time in milliseconds of the system tick count (wraps after 49.7 days).</param>
/// <param name="Injected">The event came from SendInput, not a mouse.</param>
/// <param name="IsPopGuyMarker">The event is injected and carries <see cref="InputSynth.Marker"/>: PopGuy synthesized it.</param>
public readonly record struct MouseEvent(
    MouseEventKind Kind, int X, int Y, int WheelDelta, int XButton, uint Timestamp, bool Injected, bool IsPopGuyMarker);

/// <summary>
/// Global keyboard and mouse input on one dedicated thread ("PopGuy input"): the WH_KEYBOARD_LL and WH_MOUSE_LL hooks,
/// and global hotkeys (RegisterHotKey on the same thread's message-only window).
/// <para>
/// The hook callbacks only copy the event into <see cref="Keys"/> or <see cref="Mouse"/> and pass it on: Windows
/// silently removes a low-level hook whose callback exceeds LowLevelHooksTimeout, so they take no lock, open nothing
/// and never wait. The one extra call: on a C press while Ctrl is down, the keyboard callback reads the clipboard
/// sequence number (cheap; it does not open the clipboard) into <see cref="KeyEvent.ClipboardSequence"/>, which the
/// Ctrl+C+C chord needs from before the app copies.
/// </para>
/// <para>
/// Threading: every member may be called from any thread. Read the channels from other threads; their continuations
/// never run on the input thread. Dispose completes the channels.
/// </para>
/// <para>
/// The key and mouse channels are bounded (256 events each): when nobody drains them, the oldest events are dropped,
/// so nothing accumulates. Key events carry codes only for the watched keys (see <see cref="KeyEvent"/>).
/// </para>
/// </summary>
public sealed class GlobalInput : IDisposable
{
    /// <summary>ERROR_HOTKEY_ALREADY_REGISTERED: another app (or another id here) has the hotkey.</summary>
    public const int ErrorAlreadyRegistered = 1409;

    /// <summary>The highest hotkey id an app may use (0xC000 and up are for shared DLLs).</summary>
    private const int MaxHotKeyId = 0xBFFF;

    private const HotKeyModifiers AllModifiers =
        HotKeyModifiers.Alt | HotKeyModifiers.Control | HotKeyModifiers.Shift | HotKeyModifiers.Win;

    /// <summary>How long a call waits for the input thread to run it.</summary>
    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(5);

    /// <summary>
    /// One writer (the input thread), one reader, at most 256 events: an undrained channel drops its oldest event, so a
    /// write never blocks the hook. No synchronous continuations: a consumer's await must never resume inside a hook
    /// callback, on the hook thread.
    /// </summary>
    private static readonly BoundedChannelOptions ChannelOptions = new(256)
    {
        FullMode = BoundedChannelFullMode.DropOldest,
        SingleReader = true,
        SingleWriter = true,
        AllowSynchronousContinuations = false,
    };

    private readonly Channel<KeyEvent> _keys = Channel.CreateBounded<KeyEvent>(ChannelOptions);
    private readonly Channel<MouseEvent> _mouse = Channel.CreateBounded<MouseEvent>(ChannelOptions);
    private readonly Channel<int> _hotKeys = Channel.CreateBounded<int>(ChannelOptions);
    private readonly Action<string>? _log;
    private readonly bool _includeMouseMoves;

    // Rooted for this object's life, which the window keeps alive (its WM_HOTKEY handler refers to this object, and
    // live windows are held by a static table): a collected delegate behind a live hook would crash.
    private readonly HOOKPROC _keyboardProc;
    private readonly HOOKPROC _mouseProc;

    private readonly MessageWindow _window;

    /// <summary>The registered hotkeys by id. Input thread only.</summary>
    private readonly Dictionary<int, (HotKeyModifiers Modifiers, uint VirtualKey)> _registered = [];

    private int _inputThreadId;
    private HHOOK _keyboardHook;
    private HHOOK _mouseHook;
    private int _disposed;

    // Ctrl state from the hook's own events. Hook callbacks only. A missed release (e.g. across the secure desktop)
    // leaves it stuck down, which costs only a needless sequence-number read on later C presses.
    private bool _leftControlDown;
    private bool _rightControlDown;

    /// <summary>
    /// The sided modifiers the user holds (bits per <see cref="ModifierBit"/>), from every event but PopGuy's own:
    /// another app's injected input counts as the user's. Written by the keyboard hook only, read from any thread.
    /// </summary>
    private int _userModifiers;

    /// <summary>The left keys' bits in <see cref="_userModifiers"/> (see <see cref="ModifierBit"/>).</summary>
    private const int LeftBits = 0b0101_0101;

    /// <summary>
    /// Starts the input thread and installs both hooks. Throws <see cref="Win32Exception"/> if Windows refuses.
    /// </summary>
    /// <param name="log">Gets failures (unhook, a throwing callback). Never called on the hooks' normal path.</param>
    /// <param name="includeMouseMoves">
    /// Also deliver <see cref="MouseEventKind.Move"/> (hundreds per second): only when a consumer drains
    /// <see cref="Mouse"/> continuously, or the moves push the presses out of the bounded channel.
    /// </param>
    public GlobalInput(Action<string>? log = null, bool includeMouseMoves = false)
    {
        _log = log;
        _includeMouseMoves = includeMouseMoves;
        _keyboardProc = KeyboardProc;
        _mouseProc = MouseProc;
        _window = MessageWindow.StartOnNewThread("PopGuy input", log, OnCreated);
    }

    /// <summary>Every key press and release, in order; unwatched keys as <see cref="KeyEvent.OtherKey"/>.</summary>
    public ChannelReader<KeyEvent> Keys => _keys.Reader;

    /// <summary>Every mouse press, release and wheel turn (and move, if asked for), in order.</summary>
    public ChannelReader<MouseEvent> Mouse => _mouse.Reader;

    /// <summary>The id of each registered hotkey press. A held hotkey does not repeat.</summary>
    public ChannelReader<int> HotKeys => _hotKeys.Reader;

    /// <summary>
    /// Whether the user holds the modifier <paramref name="virtualKey"/> (sided, e.g. VK_LCONTROL, or generic, e.g.
    /// VK_CONTROL for either side), as the keyboard hook saw it: PopGuy's own synthetic events do not count, so it stays
    /// true while the user holds a key PopGuy released with a synthetic key-up (unlike the async key state). False for
    /// any other key. For <see cref="InputSynth.SendCopy"/>'s <c>isUserKeyDown</c>. Any thread.
    /// </summary>
    public bool IsUserKeyDown(uint virtualKey)
    {
        var mask = ModifierMask(virtualKey);
        return mask != 0 && (Volatile.Read(ref _userModifiers) & mask) != 0;
    }

    /// <summary>
    /// Registers a global hotkey and returns its id (1 or more), which <see cref="HotKeys"/> reports on each press.
    /// Throws <see cref="Win32Exception"/> when Windows refuses (<see cref="ErrorAlreadyRegistered"/>: in use),
    /// <see cref="TimeoutException"/> if the input thread does not answer within 5 s.
    /// </summary>
    public int Register(HotKeyModifiers modifiers, uint virtualKey)
    {
        if ((modifiers & ~AllModifiers) != 0) throw new ArgumentOutOfRangeException(nameof(modifiers));
        return OnInputThread(() => RegisterCore(modifiers, virtualKey));
    }

    /// <summary>Removes the hotkey <paramref name="id"/>, if registered. A no-op once disposed.</summary>
    public void Unregister(int id)
    {
        if (Volatile.Read(ref _disposed) != 0) return;
        OnInputThread(() =>
        {
            if (_registered.Remove(id)) PInvoke.UnregisterHotKey(_window.Handle, id);
            return true;
        });
    }

    /// <summary>Removes both hooks and every hotkey, ends the input thread and completes the channels.</summary>
    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        // Posted before the window's quit message, so it runs first. On the input thread the window ends at once,
        // without running what is queued.
        if (Environment.CurrentManagedThreadId == _inputThreadId) Teardown();
        else _window.Post(Teardown);
        _window.Dispose();
        _keys.Writer.TryComplete();
        _mouse.Writer.TryComplete();
        _hotKeys.Writer.TryComplete();
    }

    /// <summary>Installs the hooks on the new input thread; a failure ends the thread.</summary>
    private unsafe void OnCreated(MessageWindow window)
    {
        _inputThreadId = Environment.CurrentManagedThreadId;
        var module = new HINSTANCE(PInvoke.GetModuleHandle(default(PCWSTR)).Value);
        _keyboardHook = PInvoke.SetWindowsHookEx(WINDOWS_HOOK_ID.WH_KEYBOARD_LL, _keyboardProc, module, 0);
        if (_keyboardHook.IsNull) throw new Win32Exception();
        _mouseHook = PInvoke.SetWindowsHookEx(WINDOWS_HOOK_ID.WH_MOUSE_LL, _mouseProc, module, 0);
        if (_mouseHook.IsNull)
        {
            var error = new Win32Exception();
            PInvoke.UnhookWindowsHookEx(_keyboardHook);
            _keyboardHook = default;
            throw error;
        }
        window.AddHandler(PInvoke.WM_HOTKEY, OnHotKey);
    }

    /// <summary>Removes the hooks and hotkeys. Input thread only.</summary>
    private void Teardown()
    {
        Unhook(ref _keyboardHook, "keyboard");
        Unhook(ref _mouseHook, "mouse");
        foreach (var id in _registered.Keys) PInvoke.UnregisterHotKey(_window.Handle, id);
        _registered.Clear();
    }

    private void Unhook(ref HHOOK hook, string name)
    {
        if (hook.IsNull) return;
        if (!PInvoke.UnhookWindowsHookEx(hook)) _log?.Invoke($"global input: unhook {name} failed, {Marshal.GetLastPInvokeError()}");
        hook = default;
    }

    /// <summary>Runs <paramref name="action"/> on the input thread and returns its result or rethrows its exception.</summary>
    private T OnInputThread<T>(Func<T> action)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        if (Environment.CurrentManagedThreadId == _inputThreadId) return action();
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var posted = _window.Post(() =>
        {
            try
            {
                done.SetResult(action());
            }
            catch (Exception e)
            {
                done.SetException(e);
            }
        });
        if (!posted) throw new ObjectDisposedException(nameof(GlobalInput));
        // Disposal racing this call can end the thread with the action still queued: never wait forever.
        if (Task.WaitAny([done.Task], CallTimeout) < 0) throw new TimeoutException("The input thread did not answer.");
        return done.Task.GetAwaiter().GetResult();
    }

    private int RegisterCore(HotKeyModifiers modifiers, uint virtualKey)
    {
        var id = 1;
        while (_registered.ContainsKey(id)) id++;
        if (id > MaxHotKeyId) throw new InvalidOperationException("No free hotkey id.");
        var flags = (HOT_KEY_MODIFIERS)modifiers | HOT_KEY_MODIFIERS.MOD_NOREPEAT;
        if (!PInvoke.RegisterHotKey(_window.Handle, id, flags, virtualKey)) throw new Win32Exception(Marshal.GetLastPInvokeError());
        _registered[id] = (modifiers, virtualKey);
        return id;
    }

    private LRESULT? OnHotKey(WPARAM wParam, LPARAM lParam)
    {
        var id = (int)wParam.Value;
        // A press of an id unregistered meanwhile (already posted) is dropped, and so is one whose keys (the modifiers in
        // LOWORD, the key in HIWORD) are not the id's: a message another process posted.
        if (!_registered.TryGetValue(id, out var key)) return null;
        var modifiers = (uint)(lParam.Value & 0xFFFF) & ~(uint)HOT_KEY_MODIFIERS.MOD_NOREPEAT;
        var virtualKey = (uint)((lParam.Value >> 16) & 0xFFFF);
        if (modifiers != (uint)key.Modifiers || virtualKey != key.VirtualKey) return null;
        _hotKeys.Writer.TryWrite(id);
        return new LRESULT(0);
    }

    private unsafe LRESULT KeyboardProc(int code, WPARAM wParam, LPARAM lParam)
    {
        if (code == PInvoke.HC_ACTION)
        {
            try
            {
                var data = (KBDLLHOOKSTRUCT*)lParam.Value;
                var isDown = (data->flags & KBDLLHOOKSTRUCT_FLAGS.LLKHF_UP) == 0;
                var vk = data->vkCode;
                var injected = (data->flags & KBDLLHOOKSTRUCT_FLAGS.LLKHF_INJECTED) != 0;
                var isPopGuy = injected && data->dwExtraInfo == InputSynth.Marker;
                if (!isPopGuy) TrackUserModifier(vk, isDown);
                switch ((VIRTUAL_KEY)vk)
                {
                    case VIRTUAL_KEY.VK_LCONTROL:
                        _leftControlDown = isDown;
                        break;
                    case VIRTUAL_KEY.VK_RCONTROL:
                        _rightControlDown = isDown;
                        break;
                    case VIRTUAL_KEY.VK_CONTROL: // a generic Ctrl from SendInput counts as the left one
                        _leftControlDown = isDown;
                        if (!isDown) _rightControlDown = false;
                        break;
                }
                uint? sequence = isDown && vk == (uint)VIRTUAL_KEY.VK_C && (_leftControlDown || _rightControlDown)
                    ? PInvoke.GetClipboardSequenceNumber()
                    : null;
                var watched = IsWatched(vk);
                _keys.Writer.TryWrite(new KeyEvent(
                    watched ? vk : KeyEvent.OtherKey,
                    watched ? data->scanCode : 0,
                    isDown,
                    data->time,
                    injected,
                    isPopGuy,
                    sequence));
            }
            catch (Exception e)
            {
                // Never across the native frame (FailFast); the event still goes on.
                _log?.Invoke($"global input: keyboard hook threw, {e.GetType().Name} {e.Message}");
            }
        }
        return PInvoke.CallNextHookEx(_keyboardHook, code, wParam, lParam);
    }

    private unsafe LRESULT MouseProc(int code, WPARAM wParam, LPARAM lParam)
    {
        if (code == PInvoke.HC_ACTION)
        {
            try
            {
                var data = (MSLLHOOKSTRUCT*)lParam.Value;
                var high = (int)(short)(data->mouseData >> 16);
                MouseEventKind? kind = (uint)wParam.Value switch
                {
                    PInvoke.WM_MOUSEMOVE => _includeMouseMoves ? MouseEventKind.Move : null,
                    PInvoke.WM_LBUTTONDOWN => MouseEventKind.LeftDown,
                    PInvoke.WM_LBUTTONUP => MouseEventKind.LeftUp,
                    PInvoke.WM_RBUTTONDOWN => MouseEventKind.RightDown,
                    PInvoke.WM_RBUTTONUP => MouseEventKind.RightUp,
                    PInvoke.WM_MBUTTONDOWN => MouseEventKind.MiddleDown,
                    PInvoke.WM_MBUTTONUP => MouseEventKind.MiddleUp,
                    PInvoke.WM_XBUTTONDOWN => MouseEventKind.XDown,
                    PInvoke.WM_XBUTTONUP => MouseEventKind.XUp,
                    PInvoke.WM_MOUSEWHEEL => MouseEventKind.Wheel,
                    PInvoke.WM_MOUSEHWHEEL => MouseEventKind.HorizontalWheel,
                    _ => null,
                };
                if (kind is { } k)
                {
                    var injected = (data->flags & PInvoke.LLMHF_INJECTED) != 0;
                    _mouse.Writer.TryWrite(new MouseEvent(
                        k,
                        data->pt.X,
                        data->pt.Y,
                        k is MouseEventKind.Wheel or MouseEventKind.HorizontalWheel ? high : 0,
                        k is MouseEventKind.XDown or MouseEventKind.XUp ? high : 0,
                        data->time,
                        injected,
                        injected && data->dwExtraInfo == InputSynth.Marker));
                }
            }
            catch (Exception e)
            {
                _log?.Invoke($"global input: mouse hook threw, {e.GetType().Name} {e.Message}");
            }
        }
        return PInvoke.CallNextHookEx(_mouseHook, code, wParam, lParam);
    }

    /// <summary>
    /// The keys whose codes are published: every modifier, C (the Ctrl+C+C chord) and the keys of the registered
    /// hotkeys. Keyboard hook only (it runs on the input thread, which alone touches <see cref="_registered"/>).
    /// </summary>
    private bool IsWatched(uint vk)
    {
        if (vk == (uint)VIRTUAL_KEY.VK_C || IsModifier(vk)) return true;
        foreach (var key in _registered.Values)
        {
            if (key.VirtualKey == vk) return true;
        }
        return false;
    }

    private static bool IsModifier(uint vk) => ModifierMask(vk) != 0;

    /// <summary>Keyboard hook only (the single writer of <see cref="_userModifiers"/>).</summary>
    private void TrackUserModifier(uint vk, bool isDown)
    {
        var mask = ModifierMask(vk);
        if (mask == 0) return;
        // A generic press (SendInput with VK_CONTROL…) counts as the left key; its release clears both sides.
        var bits = isDown && IsGeneric(vk) ? mask & LeftBits : mask;
        var state = Volatile.Read(ref _userModifiers);
        Volatile.Write(ref _userModifiers, isDown ? state | bits : state & ~bits);
    }

    /// <summary>The bit of each sided modifier in <see cref="_userModifiers"/>: left at even, right at odd bits.</summary>
    private static int ModifierBit(VIRTUAL_KEY vk) => vk switch
    {
        VIRTUAL_KEY.VK_LCONTROL => 1 << 0,
        VIRTUAL_KEY.VK_RCONTROL => 1 << 1,
        VIRTUAL_KEY.VK_LSHIFT => 1 << 2,
        VIRTUAL_KEY.VK_RSHIFT => 1 << 3,
        VIRTUAL_KEY.VK_LMENU => 1 << 4,
        VIRTUAL_KEY.VK_RMENU => 1 << 5,
        VIRTUAL_KEY.VK_LWIN => 1 << 6,
        VIRTUAL_KEY.VK_RWIN => 1 << 7,
        _ => 0,
    };

    /// <summary>The bits of a sided modifier, or both sides' for a generic one (VK_CONTROL, VK_SHIFT, VK_MENU); 0 otherwise.</summary>
    private static int ModifierMask(uint vk) => (VIRTUAL_KEY)vk switch
    {
        VIRTUAL_KEY.VK_CONTROL => ModifierBit(VIRTUAL_KEY.VK_LCONTROL) | ModifierBit(VIRTUAL_KEY.VK_RCONTROL),
        VIRTUAL_KEY.VK_SHIFT => ModifierBit(VIRTUAL_KEY.VK_LSHIFT) | ModifierBit(VIRTUAL_KEY.VK_RSHIFT),
        VIRTUAL_KEY.VK_MENU => ModifierBit(VIRTUAL_KEY.VK_LMENU) | ModifierBit(VIRTUAL_KEY.VK_RMENU),
        var sided => ModifierBit(sided),
    };

    private static bool IsGeneric(uint vk) =>
        (VIRTUAL_KEY)vk is VIRTUAL_KEY.VK_CONTROL or VIRTUAL_KEY.VK_SHIFT or VIRTUAL_KEY.VK_MENU;
}
