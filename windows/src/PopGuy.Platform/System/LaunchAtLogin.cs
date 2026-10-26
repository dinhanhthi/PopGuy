using Microsoft.Win32;

// Not PopGuy.Platform.System: that namespace would hide System for every System.-qualified name under PopGuy.Platform.
namespace PopGuy.Platform.SystemServices;

/// <summary>
/// Start at login (macOS <c>SMAppService.mainApp</c>): the value <see cref="ValueName"/> under
/// <c>HKCU\Software\Microsoft\Windows\CurrentVersion\Run</c>, the quoted path of <see cref="TargetPath"/>. The registry
/// is the only record (settings.json has no flag). A value that points at another copy of PopGuy (an older install, a
/// dev build) reads as off; turning it on replaces it. Every call may throw <see cref="IOException"/>,
/// <see cref="UnauthorizedAccessException"/> or <see cref="System.Security.SecurityException"/> (a policy refuses the
/// key), or <see cref="InvalidOperationException"/> when the process path is unknown; Settings shows the message.
/// </summary>
public static class LaunchAtLogin
{
    /// <summary>The Run value's name.</summary>
    public const string ValueName = "PopGuy";

    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    /// <summary>Whether the Run value starts this copy of PopGuy.</summary>
    public static bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        if (key?.GetValue(ValueName) is not string command) return false;
        return string.Equals(command.Trim().Trim('"'), CurrentTarget(), StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Writes the Run value (on) or deletes it (off; nothing when there is none).</summary>
    public static void SetEnabled(bool enabled)
    {
        if (enabled)
        {
            var command = $"\"{CurrentTarget()}\"";
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            key.SetValue(ValueName, command, RegistryValueKind.String);
        }
        else
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            key?.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }

    /// <summary>
    /// What the Run value starts: the Velopack stub <c>&lt;LocalAppData&gt;\PopGuy\PopGuy.exe</c> when
    /// <paramref name="processPath"/> is inside <c>&lt;LocalAppData&gt;\PopGuy\current\</c> (an update replaces that
    /// folder; the stub starts whichever version is current), else <paramref name="processPath"/> itself.
    /// </summary>
    internal static string TargetPath(string processPath, string localAppData)
    {
        var install = Path.Combine(localAppData, "PopGuy");
        var current = Path.Combine(install, "current") + Path.DirectorySeparatorChar;
        return processPath.StartsWith(current, StringComparison.OrdinalIgnoreCase)
            ? Path.Combine(install, "PopGuy.exe")
            : processPath;
    }

    private static string CurrentTarget()
    {
        var processPath = Environment.ProcessPath
            ?? throw new InvalidOperationException("PopGuy's own path is unknown.");
        return TargetPath(
            Path.GetFullPath(processPath), Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
    }
}
