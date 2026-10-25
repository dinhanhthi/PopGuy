using System.ComponentModel;
using PopGuy.Platform.Windowing;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace PopGuy.Platform.Capture;

/// <summary>Whether a synthetic Ctrl+C may read the selection, and why (a short reason for logs).</summary>
/// <param name="Allowed">The fallback may run (still through <see cref="ClipboardTransaction"/>).</param>
/// <param name="Reason">
/// "captured" (UI Automation read it: no fallback needed), "passwordField", "console" (Ctrl+C would interrupt the
/// running command), "unavailable" (allowed: no text pattern), "emptyKnownEditor" (allowed: an editor that hides its
/// selection from UI Automation), "empty" (refused: the app has no selection).
/// </param>
public readonly record struct CaptureFallbackDecision(bool Allowed, string Reason);

/// <summary>
/// When PopGuy may fall back on a synthetic Ctrl+C after UI Automation captured nothing. The copy lands in the
/// source app's clipboard (and its clipboard history), and in a console Ctrl+C is an interrupt, so:
/// <list type="bullet">
/// <item>never in a password field, and never in a console host (window class ConsoleWindowClass or
/// CASCADIA_HOSTING_WINDOW_CLASS, or a console or terminal process: conhost, WindowsTerminal, OpenConsole, cmd,
/// powershell, pwsh, wsl, and the terminals alacritty, wezterm-gui and mintty), whatever UI Automation said;</item>
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
        "ConsoleWindowClass", "CASCADIA_HOSTING_WINDOW_CLASS",
    };

    private static readonly HashSet<string> ConsoleProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "conhost", "WindowsTerminal", "OpenConsole", "cmd", "powershell", "pwsh", "wsl", "alacritty", "wezterm-gui", "mintty",
    };

    private static readonly HashSet<string> HiddenSelectionEditors = new(StringComparer.OrdinalIgnoreCase)
    {
        "Code", "Code - Insiders", "Cursor", "VSCodium", "Windsurf",
    };

    private const int ClassNameCapacity = 256;

    /// <summary>
    /// The decision for UI Automation's <paramref name="status"/> in the foreground window of class
    /// <paramref name="windowClass"/>, owned by the process <paramref name="processName"/> (null when unknown: then
    /// only the window class can rule out a console, and an empty selection is refused).
    /// </summary>
    public static CaptureFallbackDecision Decide(UiaCaptureStatus status, string? windowClass, string? processName)
    {
        if (status == UiaCaptureStatus.Captured) return new(false, "captured");
        if (status == UiaCaptureStatus.PasswordField) return new(false, "passwordField");
        if (windowClass is not null && ConsoleWindowClasses.Contains(windowClass)) return new(false, "console");
        if (processName is not null && ConsoleProcesses.Contains(processName)) return new(false, "console");
        if (status == UiaCaptureStatus.Unavailable) return new(true, "unavailable");
        return processName is not null && HiddenSelectionEditors.Contains(processName)
            ? new(true, "emptyKnownEditor")
            : new(false, "empty");
    }

    /// <summary><see cref="Decide(UiaCaptureStatus, string?, string?)"/> for the top-level window <paramref name="window"/>.</summary>
    public static CaptureFallbackDecision Decide(UiaCaptureStatus status, nint window) =>
        Decide(status, ClassNameOf(window), ProcessNameOf(window));

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
