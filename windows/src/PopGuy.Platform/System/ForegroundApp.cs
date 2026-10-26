using System.Diagnostics;
using System.Runtime.InteropServices;
using PopGuy.Platform.Windowing;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Security;
using Windows.Win32.System.Threading;
using Windows.Win32.UI.WindowsAndMessaging;

// Not PopGuy.Platform.System: that namespace would hide System for every System.-qualified name under PopGuy.Platform.
namespace PopGuy.Platform.SystemServices;

/// <summary>The foreground window's app, taken when a trigger fires (the capture's and the paste's source).</summary>
/// <param name="Hwnd">The foreground window; 0 when there is none.</param>
/// <param name="ProcessId">Its process (a Store app's own, not its frame host's, when found); 0 when unknown.</param>
/// <param name="Exe">The executable's file name in lowercase ("notepad.exe"), or null when it cannot be read.</param>
/// <param name="DisplayName">The executable's FileDescription ("Notepad"), else <paramref name="Exe"/>, else "".</param>
/// <param name="IsElevated">
/// The process runs elevated (as administrator), or Windows denied the query (which only happens across privilege
/// levels): UIPI then drops PopGuy's synthetic input to it.
/// </param>
/// <param name="IsOwnProcess">The window is PopGuy's own (e.g. its Settings window).</param>
public sealed record ForegroundApp(nint Hwnd, uint ProcessId, string? Exe, string DisplayName, bool IsElevated, bool IsOwnProcess)
{
    private const int PathCapacity = 1024;

    /// <summary>The frame host of Store (UWP) app windows.</summary>
    private const string FrameHostExe = "applicationframehost.exe";

    /// <summary>
    /// The foreground window's app right now. A Store (UWP) app's window belongs to the frame host
    /// (applicationframehost.exe): the app is the process of its hosted child window, when there is one (none while it
    /// is suspended or minimized). <see cref="Hwnd"/> stays the frame window. Any thread.
    /// </summary>
    public static ForegroundApp Snapshot()
    {
        var hwnd = ToolbarWindowStyle.ForegroundWindow();
        var processId = ToolbarWindowStyle.ProcessIdOf(hwnd);
        if (processId == 0) return new(hwnd, 0, null, "", IsElevated: false, IsOwnProcess: false);

        var (path, isElevated) = Inspect(processId);
        if (path is not null && Path.GetFileName(path).Equals(FrameHostExe, StringComparison.OrdinalIgnoreCase)
            && HostedProcessId(hwnd, processId) is var hosted and not 0)
        {
            processId = hosted;
            (path, isElevated) = Inspect(processId);
        }

        var exe = path is null ? null : Path.GetFileName(path).ToLowerInvariant();
        return new(hwnd, processId, exe, DescriptionOf(path) ?? exe ?? "", isElevated, processId == (uint)Environment.ProcessId);
    }

    /// <summary>The process's image path (null when unreadable) and whether it runs elevated.</summary>
    private static (string? Path, bool IsElevated) Inspect(uint processId)
    {
        // The limited right is granted even on elevated processes, so the path and the token query still work there.
        var process = PInvoke.OpenProcess(PROCESS_ACCESS_RIGHTS.PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
        if (process.IsNull) return (null, Marshal.GetLastPInvokeError() == (int)WIN32_ERROR.ERROR_ACCESS_DENIED);
        try
        {
            return (ImagePathOf(process), IsElevatedProcess(process));
        }
        finally
        {
            PInvoke.CloseHandle(process);
        }
    }

    /// <summary>The process of the frame window's first child window owned by another process (the hosted app); 0 when none.</summary>
    private static uint HostedProcessId(nint frame, uint frameProcessId)
    {
        uint hosted = 0;
        WNDENUMPROC find = (child, _) =>
        {
            var processId = ToolbarWindowStyle.ProcessIdOf(child);
            if (processId == 0 || processId == frameProcessId) return true;
            hosted = processId;
            return false;
        };
        PInvoke.EnumChildWindows((HWND)frame, find, default);
        GC.KeepAlive(find);
        return hosted;
    }

    private static unsafe string? ImagePathOf(HANDLE process)
    {
        var buffer = stackalloc char[PathCapacity];
        var length = (uint)PathCapacity;
        return PInvoke.QueryFullProcessImageName(process, PROCESS_NAME_FORMAT.PROCESS_NAME_WIN32, new PWSTR(buffer), &length)
            ? new string(buffer, 0, (int)length)
            : null;
    }

    /// <summary>TokenElevation of the process's token; a token Windows refuses to open counts as elevated.</summary>
    private static unsafe bool IsElevatedProcess(HANDLE process)
    {
        HANDLE token;
        if (!PInvoke.OpenProcessToken(process, TOKEN_ACCESS_MASK.TOKEN_QUERY, &token))
        {
            return Marshal.GetLastPInvokeError() == (int)WIN32_ERROR.ERROR_ACCESS_DENIED;
        }
        try
        {
            TOKEN_ELEVATION elevation;
            uint returned;
            return PInvoke.GetTokenInformation(token, TOKEN_INFORMATION_CLASS.TokenElevation, &elevation, (uint)sizeof(TOKEN_ELEVATION), &returned)
                && elevation.TokenIsElevated != 0;
        }
        finally
        {
            PInvoke.CloseHandle(token);
        }
    }

    /// <summary>The executable's FileDescription, or null when it has none or cannot be read.</summary>
    private static string? DescriptionOf(string? path)
    {
        if (path is null) return null;
        try
        {
            var description = FileVersionInfo.GetVersionInfo(path).FileDescription?.Trim();
            return string.IsNullOrEmpty(description) ? null : description;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return null;
        }
    }
}
