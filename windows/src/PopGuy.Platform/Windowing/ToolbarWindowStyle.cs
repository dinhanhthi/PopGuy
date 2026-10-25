using System.Drawing;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Dwm;
using Windows.Win32.UI.Input.KeyboardAndMouse;
using Windows.Win32.UI.Shell;
using Windows.Win32.UI.WindowsAndMessaging;

namespace PopGuy.Platform.Windowing;

/// <summary>An activation or focus message one of the toolbar's windows received (the spike logs them per window).</summary>
/// <param name="Hwnd">The window that received it: the toolbar's top-level window or one of its child windows.</param>
/// <param name="ClassName">The window's class (e.g. the XAML input site's), for telling the windows apart in a log.</param>
/// <param name="Message">WM_MOUSEACTIVATE, WM_ACTIVATE or WM_SETFOCUS.</param>
/// <param name="Detail">What happened: the answer to WM_MOUSEACTIVATE, the state of WM_ACTIVATE.</param>
public readonly record struct ToolbarWindowMessage(nint Hwnd, string ClassName, string Message, string Detail);

/// <summary>
/// The floating toolbar's window: a topmost tool window that does not take the foreground from the app whose text is
/// selected. Handles are a WinUI window's HWND (<c>Win32Interop.GetWindowFromWindowId</c>). Points and rects are
/// physical screen pixels.
/// <para>
/// Order for the App (the presenter lives in Microsoft.UI.Windowing, which Platform does not reference):
/// <c>OverlappedPresenter.SetBorderAndTitleBar(false, false)</c> and <c>IsResizable = false</c>, then <see cref="Apply"/>,
/// then <c>AppWindow.Show(activateWindow: false)</c>; never <c>Window.Activate()</c>. <see cref="Apply"/> must run
/// before the first show: Windows reads WS_EX_TOOLWINDOW (no taskbar button, not in Alt+Tab) when the window is shown.
/// After the first show, <see cref="SubclassNoActivate"/>.
/// </para>
/// <para>
/// Text input (a prompt box) is the one time the toolbar takes the foreground: a click inside the
/// <see cref="SetActivationRegion">activation region</see> activates it (the subclass answers MA_ACTIVATE for it, so
/// Windows activates the window for that click itself), every other click never does. When text input ends, the App
/// calls <see cref="AllowActivation"/> with false and hands the foreground back.
/// </para>
/// <para>
/// WS_EX_NOACTIVATE does not hold for every activation (a press can still make a WinUI window the foreground), so the
/// App also remembers the foreground window when it shows the toolbar and hands it back after each press
/// (<see cref="RememberForeground"/>, <see cref="HandBackForeground"/>). Threading: the window's (UI) thread for
/// everything that changes the window; the reads (<see cref="ForegroundWindow"/>, <see cref="CursorPosition"/>, …) from
/// any thread.
/// </para>
/// </summary>
public static class ToolbarWindowStyle
{
    private const int ClassNameCapacity = 256;

    /// <summary>Rooted for the process's life: a collected delegate behind a live subclass would crash.</summary>
    private static readonly SUBCLASSPROC SubclassCallback = SubclassProc;

    /// <summary>The subclass id: one subclass of PopGuy's per window.</summary>
    private const nuint SubclassId = 0x50475559;

    /// <summary>Subclassed windows by handle. UI thread only, guarded anyway.</summary>
    private static readonly Dictionary<HWND, Subclassed> Windows = [];

    /// <summary>Per toolbar (top-level window): whether clicks may activate it, and who gets its messages.</summary>
    private static readonly Dictionary<HWND, ToolbarState> Toolbars = [];

    /// <summary>
    /// WS_EX_TOOLWINDOW, WS_EX_NOACTIVATE and topmost (through <c>SetWindowPos(HWND_TOPMOST)</c>: setting
    /// WS_EX_TOPMOST alone does not take), plus the DWM round corner preference. False when Windows refused.
    /// </summary>
    public static unsafe bool Apply(nint hwnd)
    {
        var window = (HWND)hwnd;
        var style = (WINDOW_EX_STYLE)PInvoke.GetWindowLong(window, WINDOW_LONG_PTR_INDEX.GWL_EXSTYLE);
        style = (style | WINDOW_EX_STYLE.WS_EX_TOOLWINDOW | WINDOW_EX_STYLE.WS_EX_NOACTIVATE | WINDOW_EX_STYLE.WS_EX_TOPMOST)
            & ~WINDOW_EX_STYLE.WS_EX_APPWINDOW;
        PInvoke.SetWindowLong(window, WINDOW_LONG_PTR_INDEX.GWL_EXSTYLE, (int)style);
        var placed = PInvoke.SetWindowPos(window, HWND.HWND_TOPMOST, 0, 0, 0, 0,
            SET_WINDOW_POS_FLAGS.SWP_NOMOVE | SET_WINDOW_POS_FLAGS.SWP_NOSIZE | SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE
            | SET_WINDOW_POS_FLAGS.SWP_FRAMECHANGED);
        var corner = DWM_WINDOW_CORNER_PREFERENCE.DWMWCP_ROUND;
        var rounded = PInvoke.DwmSetWindowAttribute(
            window, DWMWINDOWATTRIBUTE.DWMWA_WINDOW_CORNER_PREFERENCE, &corner, (uint)sizeof(DWM_WINDOW_CORNER_PREFERENCE));
        return placed && rounded.Succeeded;
    }

    /// <summary>
    /// Moves and sizes the window without activating it, and raises it above the other topmost windows. False when
    /// Windows refused.
    /// </summary>
    public static bool SetBounds(nint hwnd, Rectangle bounds) =>
        PInvoke.SetWindowPos((HWND)hwnd, HWND.HWND_TOPMOST, bounds.X, bounds.Y, bounds.Width, bounds.Height,
            SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE | SET_WINDOW_POS_FLAGS.SWP_NOOWNERZORDER);

    /// <summary>Moves the window's top-left corner to (<paramref name="x"/>, <paramref name="y"/>) without activating it.</summary>
    public static bool Move(nint hwnd, int x, int y) =>
        PInvoke.SetWindowPos((HWND)hwnd, HWND.Null, x, y, 0, 0,
            SET_WINDOW_POS_FLAGS.SWP_NOSIZE | SET_WINDOW_POS_FLAGS.SWP_NOZORDER | SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE);

    /// <summary>Sizes the window, its top-left corner fixed, without activating it.</summary>
    public static bool Resize(nint hwnd, int width, int height) =>
        PInvoke.SetWindowPos((HWND)hwnd, HWND.Null, 0, 0, width, height,
            SET_WINDOW_POS_FLAGS.SWP_NOMOVE | SET_WINDOW_POS_FLAGS.SWP_NOZORDER | SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE);

    /// <summary>The window's frame; empty when it cannot be read.</summary>
    public static Rectangle WindowRect(nint hwnd) =>
        PInvoke.GetWindowRect((HWND)hwnd, out var rect)
            ? Rectangle.FromLTRB(rect.left, rect.top, rect.right, rect.bottom)
            : Rectangle.Empty;

    /// <summary>False once the window is destroyed.</summary>
    public static bool IsAlive(nint hwnd) => hwnd != 0 && PInvoke.IsWindow((HWND)hwnd);

    /// <summary>The foreground window; 0 when none.</summary>
    public static nint ForegroundWindow() => PInvoke.GetForegroundWindow();

    /// <summary>The id of the process that owns <paramref name="hwnd"/>; 0 when the window is gone.</summary>
    public static uint ProcessIdOf(nint hwnd)
    {
        if (hwnd == 0) return 0;
        PInvoke.GetWindowThreadProcessId((HWND)hwnd, out var processId);
        return processId;
    }

    /// <summary>
    /// <paramref name="window"/> is the toolbar or one of the windows it owns (an unconstrained popup's window).
    /// </summary>
    public static bool IsToolbarOrOwned(nint window, nint toolbar) =>
        window != 0 && (window == toolbar || PInvoke.GetAncestor((HWND)window, GET_ANCESTOR_FLAGS.GA_ROOTOWNER) == (HWND)toolbar);

    /// <summary>The foreground window is the toolbar or one of the windows it owns: a press made it the foreground.</summary>
    public static bool IsToolbarOrOwnedForeground(nint toolbar) => IsToolbarOrOwned(ForegroundWindow(), toolbar);

    /// <summary>
    /// The foreground window to hand back to later: the current one, unless it is the toolbar or one of its windows
    /// (then 0: keep what was remembered before).
    /// </summary>
    public static nint RememberForeground(nint toolbar)
    {
        var foreground = ForegroundWindow();
        return foreground != 0 && !IsToolbarOrOwned(foreground, toolbar) ? foreground : 0;
    }

    /// <summary>
    /// Gives the foreground back to <paramref name="source"/> when the toolbar (or one of its windows) has it; allowed
    /// while this process has the foreground. True only when it handed back.
    /// </summary>
    public static bool HandBackForeground(nint toolbar, nint source) =>
        source != 0 && IsToolbarOrOwnedForeground(toolbar) && SetForeground(source);

    /// <summary>
    /// Gives the foreground to <paramref name="window"/> when it still exists. Windows allows it only while this process
    /// has the foreground or received the last input. False when the window is gone or Windows refused.
    /// </summary>
    public static bool SetForeground(nint window) => IsAlive(window) && PInvoke.SetForegroundWindow((HWND)window);

    /// <summary>
    /// Lets <paramref name="processId"/> take the foreground itself (it must then activate its own window). Only works
    /// while this process may set the foreground (it has it, or received the last input).
    /// </summary>
    public static bool AllowForegroundFor(uint processId) => PInvoke.AllowSetForegroundWindow(processId);

    /// <summary>
    /// Lets the toolbar be activated (text input: WS_EX_NOACTIVATE off) or stops it again (on), and records it for the
    /// <see cref="SubclassNoActivate"/> log. A click in the activation region turns it on by itself; the App turns it
    /// off when text input ends, then hands the foreground back. Clicks outside the activation region never activate
    /// the toolbar either way. False when Windows refused the frame update.
    /// </summary>
    public static bool AllowActivation(nint hwnd, bool allow)
    {
        var window = (HWND)hwnd;
        SetNoActivateStyle(window, !allow);
        lock (Windows)
        {
            if (Toolbars.TryGetValue(window, out var state)) state.AllowActivation = allow;
        }
        return PInvoke.SetWindowPos(window, HWND.Null, 0, 0, 0, 0,
            SET_WINDOW_POS_FLAGS.SWP_NOMOVE | SET_WINDOW_POS_FLAGS.SWP_NOSIZE | SET_WINDOW_POS_FLAGS.SWP_NOZORDER
            | SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE | SET_WINDOW_POS_FLAGS.SWP_FRAMECHANGED);
    }

    /// <summary>Whether text input has activation on (<see cref="AllowActivation"/>, or a click in the activation region).</summary>
    public static bool IsActivationAllowed(nint toolbar)
    {
        lock (Windows)
        {
            return Toolbars.TryGetValue((HWND)toolbar, out var state) && state.AllowActivation;
        }
    }

    /// <summary>
    /// The part of the toolbar where a click activates it (the prompt box), in physical pixels relative to the toolbar
    /// window's top-left corner (its client area: the toolbar has no frame), so moving the window does not change it.
    /// Set it again when the layout or the DPI changes; <see cref="Rectangle.Empty"/> = nowhere. Any thread.
    /// </summary>
    public static void SetActivationRegion(nint toolbar, Rectangle clientRegion)
    {
        lock (Windows)
        {
            var root = (HWND)toolbar;
            if (!Toolbars.TryGetValue(root, out var state)) Toolbars[root] = state = new ToolbarState();
            state.ActivationRegion = clientRegion;
        }
    }

    /// <summary>
    /// The primary mouse button (the left one, or the right one when the buttons are swapped) is down now. Read from
    /// the hardware state, so it holds when the pointer is outside every window of this process. Any thread.
    /// </summary>
    public static bool IsPrimaryButtonDown()
    {
        var swapped = PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_SWAPBUTTON) != 0;
        var button = swapped ? VIRTUAL_KEY.VK_RBUTTON : VIRTUAL_KEY.VK_LBUTTON;
        return (PInvoke.GetAsyncKeyState((int)button) & 0x8000) != 0;
    }

    /// <summary>
    /// Subclasses the toolbar and every child window it has now (the XAML input sites exist only after the first
    /// show): WM_MOUSEACTIVATE answers MA_ACTIVATE for a click in the <see cref="SetActivationRegion">activation
    /// region</see> (turning WS_EX_NOACTIVATE off first) and MA_NOACTIVATE everywhere else, and WM_MOUSEACTIVATE,
    /// WM_ACTIVATE and WM_SETFOCUS go to <paramref name="onMessage"/> (on the UI thread, inside the window procedure:
    /// keep it short, never throw). Call again to pick up child windows created later; windows already subclassed are
    /// skipped. The window's thread only. Returns the number of windows newly subclassed.
    /// </summary>
    public static int SubclassNoActivate(nint toolbar, Action<ToolbarWindowMessage>? onMessage)
    {
        var root = (HWND)toolbar;
        var children = new List<HWND>();
        WNDENUMPROC collect = (child, _) =>
        {
            children.Add(child);
            return true;
        };
        PInvoke.EnumChildWindows(root, collect, default);
        GC.KeepAlive(collect);

        var added = 0;
        lock (Windows)
        {
            if (!Toolbars.TryGetValue(root, out var state))
            {
                Toolbars[root] = state = new ToolbarState();
            }
            state.OnMessage = onMessage;
            foreach (var window in children.Prepend(root))
            {
                if (Windows.ContainsKey(window)) continue;
                if (!PInvoke.SetWindowSubclass(window, SubclassCallback, SubclassId, 0)) continue;
                Windows[window] = new Subclassed(root, ClassNameOf(window));
                added++;
            }
        }
        return added;
    }

    /// <summary>The pointer's position.</summary>
    public static Point CursorPosition() => PInvoke.GetCursorPos(out var point) ? point : Point.Empty;

    /// <summary>The effective DPI of the monitor under <paramref name="point"/> (or the nearest one); 96 when unreadable.</summary>
    public static uint DpiAt(Point point) => MonitorInfo.Dpi(point);

    /// <summary>
    /// The work area (the monitor without the taskbar) of the monitor under <paramref name="point"/> (or the nearest
    /// one); empty when unreadable.
    /// </summary>
    public static Rectangle MonitorWorkArea(Point point) => MonitorInfo.WorkArea(point);

    private static string ClassNameOf(HWND window)
    {
        Span<char> buffer = stackalloc char[ClassNameCapacity];
        var length = PInvoke.GetClassName(window, buffer);
        return length > 0 ? new string(buffer[..length]) : "?";
    }

    private static LRESULT SubclassProc(HWND hwnd, uint message, WPARAM wParam, LPARAM lParam, nuint id, nuint refData)
    {
        try
        {
            switch (message)
            {
                case PInvoke.WM_MOUSEACTIVATE:
                    {
                        // The message carries no point: the pointer's position now is the click's.
                        if (Lookup(hwnd, out var subclassed, out var state) && InActivationRegion(subclassed!.Root, state))
                        {
                            // Off before answering: Windows activates the window for this click once the answer is back.
                            SetNoActivateStyle(subclassed.Root, noActivate: false);
                            lock (Windows) state.AllowActivation = true;
                            Report(hwnd, subclassed, state, "WM_MOUSEACTIVATE", "MA_ACTIVATE (activation region)");
                            return new LRESULT((nint)PInvoke.MA_ACTIVATE);
                        }
                        Report(hwnd, subclassed, state, "WM_MOUSEACTIVATE", "MA_NOACTIVATE");
                        return new LRESULT((nint)PInvoke.MA_NOACTIVATE);
                    }
                case PInvoke.WM_ACTIVATE:
                    {
                        Lookup(hwnd, out var subclassed, out var state);
                        var activeState = (uint)(wParam.Value & 0xFFFF);
                        Report(hwnd, subclassed, state, "WM_ACTIVATE", activeState switch
                        {
                            PInvoke.WA_INACTIVE => "inactive",
                            1 => "active",
                            2 => "click-active",
                            _ => activeState.ToString(System.Globalization.CultureInfo.InvariantCulture),
                        });
                        break;
                    }
                case PInvoke.WM_SETFOCUS:
                    {
                        Lookup(hwnd, out var subclassed, out var state);
                        Report(hwnd, subclassed, state, "WM_SETFOCUS", $"from 0x{wParam.Value:X}");
                        break;
                    }
                case PInvoke.WM_NCDESTROY:
                    PInvoke.RemoveWindowSubclass(hwnd, SubclassCallback, id);
                    lock (Windows)
                    {
                        Windows.Remove(hwnd);
                        Toolbars.Remove(hwnd);
                    }
                    break;
            }
        }
        catch (Exception)
        {
            // Never across the native frame (FailFast): the message goes on as if not subclassed.
        }
        return PInvoke.DefSubclassProc(hwnd, message, wParam, lParam);
    }

    /// <summary>The pointer is inside the toolbar's activation region.</summary>
    private static bool InActivationRegion(HWND root, ToolbarState state)
    {
        Rectangle region;
        lock (Windows) region = state.ActivationRegion;
        if (region.IsEmpty || !PInvoke.GetCursorPos(out var point) || !PInvoke.ScreenToClient(root, ref point)) return false;
        return region.Contains(point.X, point.Y);
    }

    /// <summary>
    /// WS_EX_NOACTIVATE on or off, without the frame update (safe inside a window procedure; the bit does not change
    /// the frame).
    /// </summary>
    private static void SetNoActivateStyle(HWND window, bool noActivate)
    {
        var style = (WINDOW_EX_STYLE)PInvoke.GetWindowLong(window, WINDOW_LONG_PTR_INDEX.GWL_EXSTYLE);
        style = noActivate ? style | WINDOW_EX_STYLE.WS_EX_NOACTIVATE : style & ~WINDOW_EX_STYLE.WS_EX_NOACTIVATE;
        PInvoke.SetWindowLong(window, WINDOW_LONG_PTR_INDEX.GWL_EXSTYLE, (int)style);
    }

    private static bool Lookup(HWND hwnd, out Subclassed? subclassed, out ToolbarState state)
    {
        lock (Windows)
        {
            if (Windows.TryGetValue(hwnd, out subclassed) && Toolbars.TryGetValue(subclassed.Root, out var found))
            {
                state = found;
                return true;
            }
        }
        state = ToolbarState.None;
        return false;
    }

    private static void Report(HWND hwnd, Subclassed? subclassed, ToolbarState state, string message, string detail) =>
        state.OnMessage?.Invoke(new ToolbarWindowMessage(hwnd, subclassed?.ClassName ?? "?", message, detail));

    private sealed record Subclassed(HWND Root, string ClassName);

    private sealed class ToolbarState
    {
        /// <summary>For a window no longer known: no callback, clicks do not activate.</summary>
        internal static readonly ToolbarState None = new();

        internal bool AllowActivation { get; set; }

        /// <summary>Where a click activates the toolbar, in client pixels; empty = nowhere.</summary>
        internal Rectangle ActivationRegion { get; set; }

        internal Action<ToolbarWindowMessage>? OnMessage { get; set; }
    }
}
