using System.ComponentModel;
using PopGuy.Platform.Windowing;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace PopGuy.Platform.Capture;

/// <summary>Whether a synthetic copy (Ctrl+Insert) may read the selection, and why (a short reason for logs).</summary>
/// <param name="Allowed">The fallback may run (still through <see cref="ClipboardTransaction"/>).</param>
/// <param name="Reason">
/// "captured" (UI Automation read it: no fallback needed), "passwordField", "console" (a console or terminal: a copy
/// key there may interrupt the running command), "remoteDesktop" (a remote desktop or VM viewer, which forwards the
/// keys to a remote session that may be a terminal), "integratedTerminal" (an editor's xterm.js terminal has the
/// focus), "unavailable" (allowed: no text pattern), "emptyKnownEditor" (allowed: an editor that hides its selection
/// from UI Automation), "empty" (refused: the app has no selection).
/// </param>
public readonly record struct CaptureFallbackDecision(bool Allowed, string Reason);

/// <summary>
/// When PopGuy may fall back on a synthetic copy after UI Automation captured nothing. The copy is Ctrl+Insert
/// (<see cref="Input.InputSynth.SendCopy"/>), which terminals do not take as an interrupt, but the copy still lands in
/// the source app's clipboard (and its clipboard history), and a terminal or remote session may bind the key to
/// something else, so:
/// <list type="bullet">
/// <item>never in a password field, and never in a console or terminal: the window classes ConsoleWindowClass,
/// CASCADIA_HOSTING_WINDOW_CLASS, VirtualConsoleClass (ConEmu, Cmder), PuTTY, KiTTY and mintty, or the processes
/// conhost, WindowsTerminal, OpenConsole, cmd, powershell, pwsh, wsl, alacritty, wezterm-gui, mintty, putty, kitty
/// (KiTTY and kitty), MobaXterm, ConEmu, ConEmu64, ConEmuC, ConEmuC64, Tabby, Hyper, SecureCRT and Xshell;</item>
/// <item>never in a remote desktop or VM viewer, which forwards the keys to a remote session (the window class
/// TscShellContainerClass, or the processes mstsc, vmconnect, vmware, vmware-vmx, VirtualBoxVM and
/// prl_client_app);</item>
/// <item>never when the focused element is an xterm.js terminal (its helper textarea: the UI Automation AutomationId
/// or ClassName contains "xterm"), as in VS Code's or Cursor's integrated terminal;</item>
/// <item>on <see cref="UiaCaptureStatus.Unavailable"/> (no text pattern) in any other app;</item>
/// <item>on <see cref="UiaCaptureStatus.Empty"/> only in the Monaco/Electron editors that show UI Automation an empty
/// hidden textarea (Code, Code - Insiders, Cursor, VSCodium, Windsurf): elsewhere an empty selection is just empty.</item>
/// </list>
/// Names compare case-insensitively; process names come without ".exe".
/// </summary>
public static class CaptureFallbackPolicy
{
    private static readonly HashSet<string> ConsoleWindowClasses = new(StringComparer.OrdinalIgnoreCase)
    {
        "ConsoleWindowClass", "CASCADIA_HOSTING_WINDOW_CLASS", "VirtualConsoleClass", "PuTTY", "KiTTY", "mintty",
    };

    private static readonly HashSet<string> ConsoleProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "conhost", "WindowsTerminal", "OpenConsole", "cmd", "powershell", "pwsh", "wsl", "alacritty", "wezterm-gui", "mintty",
        "putty", "kitty", "MobaXterm", "ConEmu", "ConEmu64", "ConEmuC", "ConEmuC64", "Tabby", "Hyper", "SecureCRT", "Xshell",
    };

    private static readonly HashSet<string> RemoteDesktopWindowClasses = new(StringComparer.OrdinalIgnoreCase)
    {
        "TscShellContainerClass",
    };

    private static readonly HashSet<string> RemoteDesktopProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "mstsc", "vmconnect", "vmware", "vmware-vmx", "VirtualBoxVM", "prl_client_app",
    };

    /// <summary>xterm.js's helper textarea (VS Code's, Cursor's integrated terminal) shows this in its AutomationId or ClassName.</summary>
    private const string XtermMarker = "xterm";

    private static readonly HashSet<string> HiddenSelectionEditors = new(StringComparer.OrdinalIgnoreCase)
    {
        "Code", "Code - Insiders", "Cursor", "VSCodium", "Windsurf",
    };

    private const int ClassNameCapacity = 256;

    /// <summary>
    /// The decision for UI Automation's <paramref name="status"/> in the foreground window of class
    /// <paramref name="windowClass"/>, owned by the process <paramref name="processName"/> (null when unknown: then
    /// only the window class can rule out a console, and an empty selection is refused). Pure: no system calls.
    /// </summary>
    /// <param name="focusedElementHint">
    /// The focused element's UI Automation AutomationId and ClassName (<see cref="UiaSelection.FocusedElementHint"/>),
    /// or null when unknown: one containing "xterm" is a terminal, whatever the app.
    /// </param>
    public static CaptureFallbackDecision Decide(
        UiaCaptureStatus status, string? windowClass, string? processName, string? focusedElementHint = null)
    {
        if (status == UiaCaptureStatus.Captured) return new(false, "captured");
        if (status == UiaCaptureStatus.PasswordField) return new(false, "passwordField");
        if (windowClass is not null && ConsoleWindowClasses.Contains(windowClass)) return new(false, "console");
        if (processName is not null && ConsoleProcesses.Contains(processName)) return new(false, "console");
        if (windowClass is not null && RemoteDesktopWindowClasses.Contains(windowClass)) return new(false, "remoteDesktop");
        if (processName is not null && RemoteDesktopProcesses.Contains(processName)) return new(false, "remoteDesktop");
        if (focusedElementHint is not null && focusedElementHint.Contains(XtermMarker, StringComparison.OrdinalIgnoreCase))
        {
            return new(false, "integratedTerminal");
        }
        if (status == UiaCaptureStatus.Unavailable) return new(true, "unavailable");
        return processName is not null && HiddenSelectionEditors.Contains(processName)
            ? new(true, "emptyKnownEditor")
            : new(false, "empty");
    }

    /// <summary>
    /// <see cref="Decide(UiaCaptureStatus, string?, string?, string?)"/> for the top-level window
    /// <paramref name="window"/>.
    /// </summary>
    public static CaptureFallbackDecision Decide(UiaCaptureStatus status, nint window, string? focusedElementHint) =>
        Decide(status, ClassNameOf(window), ProcessNameOf(window), focusedElementHint);

    /// <summary>The window's class name, or null.</summary>
    public static string? ClassNameOf(nint window)
    {
        if (window == 0) return null;
        Span<char> buffer = stackalloc char[ClassNameCapacity];
        var length = PInvoke.GetClassName((HWND)window, buffer);
        return length > 0 ? new string(buffer[..length]) : null;
    }

    /// <summary>The process name behind the window ("notepad", without ".exe"), or null when it cannot be read.</summary>
    public static string? ProcessNameOf(nint window)
    {
        var processId = ToolbarWindowStyle.ProcessIdOf(window);
        if (processId == 0) return null;
        try
        {
            using var process = System.Diagnostics.Process.GetProcessById((int)processId);
            return process.ProcessName;
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or Win32Exception)
        {
            return null;
        }
    }
}
