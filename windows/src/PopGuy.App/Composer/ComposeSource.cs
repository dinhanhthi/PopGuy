using System.Runtime.InteropServices;
using PopGuy.Platform.Capture;
using PopGuy.Platform.Windowing;

namespace PopGuy.Composer;

/// <summary>The tray composer's target window (0: none, copy only); <see cref="FromZOrder"/> when it was not the foreground.</summary>
internal readonly record struct ComposeTarget(nint Hwnd, bool FromZOrder);

/// <summary>
/// The window the tray's New Composer pastes into (macOS: the frontmost app, since a status menu does not activate
/// PopGuy). A click on the notification area makes the taskbar the foreground window, so the foreground when the menu
/// opens is used only when it is an app's (not the shell's, not PopGuy's); else the first ordinary app window in the
/// Z order (visible, not minimized or cloaked, unowned, not a tool window, not always-on-top, with a title), which is
/// the one that was in front. A Z-order target is a guess: its composer pastes only, never presses Enter. None when
/// nothing qualifies. Any thread.
/// </summary>
internal static class ComposeSource
{
    private const int GwlExStyle = -20;
    private const long WsExTopmost = 0x8;
    private const long WsExToolWindow = 0x80;
    private const uint GwHwndNext = 2;
    private const uint GwOwner = 4;
    private const uint DwmwaCloaked = 14;

    /// <summary>The taskbars, the tray overflow, the desktop and the shell's own surfaces (Start, search).</summary>
    private static readonly HashSet<string> ShellClasses = new(StringComparer.Ordinal)
    {
        "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland",
        "Progman", "WorkerW", "Windows.UI.Core.CoreWindow",
    };

    public static ComposeTarget Find(nint foreground)
    {
        if (foreground != 0 && !IsOwnOrShell(foreground)) return new(foreground, FromZOrder: false);
        for (var hwnd = GetTopWindow(0); hwnd != 0; hwnd = GetWindow(hwnd, GwHwndNext))
        {
            if (IsAppWindow(hwnd)) return new(hwnd, FromZOrder: true);
        }
        return new(0, FromZOrder: false);
    }

    private static bool IsOwnOrShell(nint hwnd) =>
        ToolbarWindowStyle.ProcessIdOf(hwnd) == (uint)Environment.ProcessId
        || CaptureFallbackPolicy.ClassNameOf(hwnd) is { } name && ShellClasses.Contains(name);

    private static bool IsAppWindow(nint hwnd) =>
        IsWindowVisible(hwnd)
        && !IsIconic(hwnd)
        && GetWindow(hwnd, GwOwner) == 0
        && (GetWindowLongPtr(hwnd, GwlExStyle) & (WsExToolWindow | WsExTopmost)) == 0
        && !IsCloaked(hwnd)
        && !IsOwnOrShell(hwnd)
        // After the own-window check: for PopGuy's own windows this would send a message.
        && GetWindowTextLength(hwnd) > 0;

    /// <summary>Hidden by DWM: a suspended UWP app, a window on another virtual desktop.</summary>
    private static bool IsCloaked(nint hwnd) =>
        DwmGetWindowAttribute(hwnd, DwmwaCloaked, out var cloaked, sizeof(int)) == 0 && cloaked != 0;

    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern nint GetTopWindow(nint hwnd);

    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern nint GetWindow(nint hwnd, uint command);

    [DllImport("user32.dll", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(nint hwnd);

    [DllImport("user32.dll", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(nint hwnd);

    [DllImport("user32.dll", EntryPoint = "GetWindowTextLengthW", ExactSpelling = true)]
    private static extern int GetWindowTextLength(nint hwnd);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", ExactSpelling = true)]
    private static extern nint GetWindowLongPtr(nint hwnd, int index);

    [DllImport("dwmapi.dll", ExactSpelling = true)]
    private static extern int DwmGetWindowAttribute(nint hwnd, uint attribute, out int value, int size);
}
