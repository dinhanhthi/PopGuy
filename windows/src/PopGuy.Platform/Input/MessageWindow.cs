using System.Collections.Concurrent;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;

namespace PopGuy.Platform.Input;

/// <summary>
/// A hidden message-only window (parent HWND_MESSAGE): a target for Windows notifications sent to a window handle
/// (clipboard updates; 3.3: hot keys, and the thread the low-level hooks run on). Handlers are added per message.
/// <para>
/// Threading: the window belongs to the thread that creates it, and its handlers run there. Either create it on a
/// thread that already pumps messages (the constructor), or with <see cref="StartOnNewThread"/>, which gives it a
/// dedicated background thread with its own GetMessage loop. Add or remove handlers on the window's thread only (from
/// the <c>onCreated</c> callback or a <see cref="Post"/>ed action). A handler or posted action that throws is logged
/// and the message goes to DefWindowProc: an exception must not cross the native frame (FailFast).
/// </para>
/// </summary>
internal sealed class MessageWindow : IDisposable
{
    /// <summary>Gets a message's result, or null to pass it on (to the next handler, then DefWindowProc).</summary>
    internal delegate LRESULT? Handler(WPARAM wParam, LPARAM lParam);

    /// <summary>Runs the actions queued by <see cref="Post"/>.</summary>
    private const uint WmInvoke = PInvoke.WM_APP + 1;

    /// <summary>Disposes a window that owns its thread, then ends the thread's message loop.</summary>
    private const uint WmQuitThread = PInvoke.WM_APP + 2;

    /// <summary>How long <see cref="Dispose"/> waits for an owned thread to end.</summary>
    private static readonly TimeSpan JoinTimeout = TimeSpan.FromSeconds(5);

    /// <summary>Rooted for the process's life: a collected delegate behind a live window class would crash.</summary>
    private static readonly WNDPROC Callback = WndProc;

    /// <summary>Live windows by handle, which also keeps each one alive until disposed.</summary>
    private static readonly Dictionary<HWND, MessageWindow> Windows = [];

    private readonly Dictionary<uint, List<Handler>> _handlers = [];
    private readonly ConcurrentQueue<Action> _posted = new();
    private readonly int _threadId = Environment.CurrentManagedThreadId;
    private readonly HINSTANCE _instance;
    private readonly string _className = "PopGuy.MessageWindow." + Guid.NewGuid().ToString("N");
    private readonly Action<string>? _log;

    /// <summary>The dedicated thread from <see cref="StartOnNewThread"/>, or null when the creator pumps.</summary>
    private readonly Thread? _ownedThread;

    /// <summary>Creates the window on the calling thread, which must pump messages. Throws <see cref="Win32Exception"/> if Windows refuses.</summary>
    /// <param name="log">Gets failures: handler exceptions, a failed destroy.</param>
    internal MessageWindow(Action<string>? log = null)
        : this(log, ownsThread: false)
    {
    }

    private unsafe MessageWindow(Action<string>? log, bool ownsThread)
    {
        _log = log;
        _ownedThread = ownsThread ? Thread.CurrentThread : null;
        _instance = new HINSTANCE(PInvoke.GetModuleHandle(default(PCWSTR)).Value);
        fixed (char* className = _className)
        {
            var windowClass = new WNDCLASSEXW
            {
                cbSize = (uint)Marshal.SizeOf<WNDCLASSEXW>(),
                lpfnWndProc = Callback,
                hInstance = _instance,
                lpszClassName = className,
            };
            // A class per window: a shared name would fail to register twice, and could not be unregistered while
            // another window uses it.
            if (PInvoke.RegisterClassEx(windowClass) == 0) throw new Win32Exception();

            Handle = PInvoke.CreateWindowEx(
                0, className, default(PCWSTR), 0, 0, 0, 0, 0, HWND.HWND_MESSAGE, HMENU.Null, _instance, null);
            if (Handle.IsNull)
            {
                var error = new Win32Exception();
                PInvoke.UnregisterClass(className, _instance);
                throw error;
            }
        }
        // Messages sent while CreateWindowEx runs (WM_NCCREATE, WM_CREATE) find no entry and go to DefWindowProc.
        lock (Windows) Windows[Handle] = this;
        AddHandler(WmInvoke, OnInvoke);
        AddHandler(WmQuitThread, OnQuitThread);
    }

    internal HWND Handle { get; }

    /// <summary>
    /// Starts a background thread named <paramref name="name"/>, creates the window there and runs the thread's
    /// GetMessage loop until <see cref="Dispose"/>. Returns once the window exists and <paramref name="onCreated"/>
    /// (run on the new thread, e.g. to add handlers) has returned; rethrows a failure of either.
    /// </summary>
    internal static MessageWindow StartOnNewThread(string name, Action<string>? log = null, Action<MessageWindow>? onCreated = null)
    {
        var started = new TaskCompletionSource<MessageWindow>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() => Run(started, log, onCreated)) { IsBackground = true, Name = name };
        thread.Start();
        return started.Task.GetAwaiter().GetResult();
    }

    /// <summary>Queues <paramref name="action"/> to run on the window's thread. Any thread. False if the window is gone.</summary>
    internal bool Post(Action action)
    {
        _posted.Enqueue(action);
        return PostMessage(WmInvoke, default, default);
    }

    /// <summary>Posts <paramref name="message"/> to the window. Any thread. False if Windows refuses (window gone).</summary>
    internal bool PostMessage(uint message, WPARAM wParam, LPARAM lParam) =>
        PInvoke.PostMessage(Handle, message, wParam, lParam);

    /// <summary>
    /// Adds <paramref name="handler"/> for <paramref name="message"/>, after any handler already added for it.
    /// Thread of the window only.
    /// </summary>
    internal void AddHandler(uint message, Handler handler)
    {
        CheckThread();
        if (!_handlers.TryGetValue(message, out var list)) _handlers[message] = list = [];
        list.Add(handler);
    }

    /// <summary>Removes <paramref name="handler"/> for <paramref name="message"/>. Thread of the window only.</summary>
    internal void RemoveHandler(uint message, Handler handler)
    {
        CheckThread();
        if (_handlers.TryGetValue(message, out var list) && list.Remove(handler) && list.Count == 0) _handlers.Remove(message);
    }

    /// <summary>
    /// Destroys the window and unregisters its class; no handler runs afterwards. A window from
    /// <see cref="StartOnNewThread"/> may be disposed from any thread: it ends the message loop and waits (up to 5 s)
    /// for the thread to exit, unless called on that thread. Otherwise thread of the window only.
    /// </summary>
    public void Dispose()
    {
        var thread = _ownedThread;
        if (thread is null)
        {
            DestroyCore();
            return;
        }
        if (Environment.CurrentManagedThreadId == _threadId)
        {
            OnQuitThread(default, default);
            return;
        }
        // Fails when the window is gone already; the thread then has ended or is ending.
        PostMessage(WmQuitThread, default, default);
        if (!thread.Join(JoinTimeout)) _log?.Invoke($"message window: thread {thread.Name} did not exit");
    }

    /// <summary>Throws unless called on the thread that created the window.</summary>
    internal void CheckThread()
    {
        if (Environment.CurrentManagedThreadId != _threadId)
        {
            throw new InvalidOperationException("MessageWindow must be used on the thread that created it.");
        }
    }

    private static void Run(TaskCompletionSource<MessageWindow> started, Action<string>? log, Action<MessageWindow>? onCreated)
    {
        MessageWindow window;
        try
        {
            window = new MessageWindow(log, ownsThread: true);
        }
        catch (Exception e)
        {
            started.SetException(e);
            return;
        }
        try
        {
            onCreated?.Invoke(window);
        }
        catch (Exception e)
        {
            window.DestroyCore();
            started.SetException(e);
            return;
        }
        started.SetResult(window);

        // 0 is WM_QUIT, -1 an error: both end the loop.
        while (PInvoke.GetMessage(out var message, HWND.Null, 0, 0).Value > 0)
        {
            PInvoke.TranslateMessage(message);
            PInvoke.DispatchMessage(message);
        }
        // A loop ended by an error rather than by OnQuitThread leaves the window alive.
        window.DestroyCore();
    }

    private LRESULT? OnInvoke(WPARAM wParam, LPARAM lParam)
    {
        while (_posted.TryDequeue(out var action))
        {
            try
            {
                action();
            }
            catch (Exception e)
            {
                _log?.Invoke($"message window: a posted action threw, {e.GetType().Name} {e.Message}");
            }
        }
        return new LRESULT(0);
    }

    private LRESULT? OnQuitThread(WPARAM wParam, LPARAM lParam)
    {
        if (_ownedThread is null) return new LRESULT(0); // never end a loop the window does not own
        DestroyCore();
        PInvoke.PostQuitMessage(0);
        return new LRESULT(0);
    }

    /// <summary>Destroys the window and unregisters its class, once. Thread of the window only.</summary>
    private unsafe void DestroyCore()
    {
        CheckThread();
        lock (Windows)
        {
            if (!Windows.Remove(Handle)) return; // destroyed already
        }
        _handlers.Clear();
        if (!PInvoke.DestroyWindow(Handle)) _log?.Invoke($"message window: DestroyWindow failed, {Marshal.GetLastPInvokeError()}");
        fixed (char* className = _className)
        {
            if (!PInvoke.UnregisterClass(className, _instance))
            {
                _log?.Invoke($"message window: UnregisterClass failed, {Marshal.GetLastPInvokeError()}");
            }
        }
    }

    private static LRESULT WndProc(HWND hwnd, uint message, WPARAM wParam, LPARAM lParam)
    {
        MessageWindow? window;
        lock (Windows) Windows.TryGetValue(hwnd, out window);
        if (window is not null && window._handlers.TryGetValue(message, out var list))
        {
            // A copy: a handler may add or remove handlers.
            foreach (var handler in list.ToArray())
            {
                try
                {
                    if (handler(wParam, lParam) is { } result) return result;
                }
                catch (Exception e)
                {
                    window._log?.Invoke($"message window: a handler for 0x{message:X4} threw, {e.GetType().Name} {e.Message}");
                }
            }
        }
        return PInvoke.DefWindowProc(hwnd, message, wParam, lParam);
    }
}
