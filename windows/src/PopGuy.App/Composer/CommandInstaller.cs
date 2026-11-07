using System.Runtime.InteropServices;
using System.Security;
using Microsoft.Win32;
using PopGuy.Core.Composer;

namespace PopGuy.Composer;

internal enum CommandInstallStatus
{
    NotInstalled,
    Installed,
}

/// <summary>
/// Installs and removes the <c>popguy-edit</c> command (macOS CommandInstaller.swift, which links it into ~/.local/bin):
/// on Windows, <see cref="Entry"/> (the folder with popguy-edit.exe) goes into the user PATH, <c>HKCU\Environment\Path</c>.
/// The value is read and written unexpanded, in its own kind (<c>REG_EXPAND_SZ</c> when missing), and only our entry
/// is ever added or removed (<see cref="UserPathEdit"/>). Install and Remove broadcast the change, which can block for
/// a while on a slow window: call them off the UI thread.
/// </summary>
internal static class CommandInstaller
{
    private const string EnvironmentKey = "Environment";
    private const string PathName = "Path";

    private const nint HwndBroadcast = 0xFFFF;
    private const uint WmSettingChange = 0x001A;
    private const uint SmtoAbortIfHung = 0x0002;
    private const uint BroadcastTimeoutMs = 5000;

    /// <summary>
    /// The PATH entry: the "bin" folder next to the running PopGuy.exe (a Setup install: the stable
    /// <c>%LOCALAPPDATA%\PopGuy\current\bin</c>). Status, Remove and the uninstall hook use this same value.
    /// </summary>
    public static string Entry { get; } = Path.Combine(AppContext.BaseDirectory, "bin");

    /// <summary>Installed when the user PATH has <see cref="Entry"/>; NotInstalled also when the PATH cannot be read.</summary>
    public static CommandInstallStatus Status
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(EnvironmentKey);
                return key?.GetValue(PathName, null, RegistryValueOptions.DoNotExpandEnvironmentNames) is string path
                    && UserPathEdit.Contains(path, Entry)
                    ? CommandInstallStatus.Installed
                    : CommandInstallStatus.NotInstalled;
            }
            catch (Exception e) when (e is SecurityException or UnauthorizedAccessException or IOException)
            {
                return CommandInstallStatus.NotInstalled;
            }
        }
    }

    /// <summary>Adds <see cref="Entry"/> to the user PATH. True when it is there afterwards.</summary>
    public static bool Install() => Edit(path => UserPathEdit.Add(path, Entry));

    /// <summary>Removes only <see cref="Entry"/> from the user PATH. True when it is gone afterwards.</summary>
    public static bool Remove() => Edit(path => UserPathEdit.Remove(path, Entry));

    private static bool Edit(Func<string?, string> change)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(EnvironmentKey, writable: true);
            // Unexpanded: the default read expands "%VAR%" segments, and writing that back would bake them in.
            var value = key.GetValue(PathName, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
            // A Path of another type (not a string) is not ours to rewrite.
            if (value is not (null or string)) return false;
            var current = (string?)value;
            var updated = change(current);
            if (updated == (current ?? "")) return true;
            key.SetValue(PathName, updated, KindOf(key));
            // New processes started by Explorer pick up the new PATH.
            SendMessageTimeout(HwndBroadcast, WmSettingChange, 0, EnvironmentKey, SmtoAbortIfHung, BroadcastTimeoutMs, out _);
            return true;
        }
        catch (Exception e) when (e is SecurityException or UnauthorizedAccessException or IOException)
        {
            return false;
        }
    }

    /// <summary>The Path value's kind: <c>REG_SZ</c> stays; anything else (or missing) is <c>REG_EXPAND_SZ</c>.</summary>
    private static RegistryValueKind KindOf(RegistryKey key)
    {
        try
        {
            return key.GetValueKind(PathName) == RegistryValueKind.String ? RegistryValueKind.String : RegistryValueKind.ExpandString;
        }
        catch (IOException)
        {
            // No Path value yet.
            return RegistryValueKind.ExpandString;
        }
    }

    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern nint SendMessageTimeout(
        nint hwnd, uint message, nuint wParam, string lParam, uint flags, uint timeout, out nuint result);
}
