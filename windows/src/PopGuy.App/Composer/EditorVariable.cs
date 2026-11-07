using System.Security;
using Microsoft.Win32;
using PopGuy.Core.Composer;

namespace PopGuy.Composer;

/// <summary>
/// Sets and removes the user's editor variable, <c>HKCU\Environment\VISUAL</c> = <c>popguy-edit</c> (the macOS "Set up
/// shell" button's twin), so terminal tools open PopGuy as their editor. Another editor's value is replaced only with
/// <c>overwrite</c> (the Settings page asks first) and never removed (<see cref="EditorVariablePolicy"/>). Set and Remove
/// broadcast the change, which can block for a while on a slow window: call them off the UI thread.
/// </summary>
internal static class EditorVariable
{
    private const string EnvironmentKey = "Environment";

    /// <summary>The variable as stored, unexpanded; NotSet also when it cannot be read.</summary>
    public static EditorVariableStatus Status
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(EnvironmentKey);
                return Classify(key);
            }
            catch (Exception e) when (e is SecurityException or UnauthorizedAccessException or IOException)
            {
                return EditorVariablePolicy.Classify(null);
            }
        }
    }

    /// <summary>Writes <c>VISUAL=popguy-edit</c> as <c>REG_SZ</c>. False when refused (another editor's, no overwrite) or failed.</summary>
    public static bool Set(bool overwrite = false)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(EnvironmentKey, writable: true);
            if (!EditorVariablePolicy.MaySet(Classify(key), overwrite)) return false;
            key.SetValue(EditorVariablePolicy.Name, EditorVariablePolicy.Value, RegistryValueKind.String);
            CommandInstaller.BroadcastEnvironmentChange();
            return true;
        }
        catch (Exception e) when (e is SecurityException or UnauthorizedAccessException or IOException)
        {
            return false;
        }
    }

    /// <summary>Deletes VISUAL only when it is ours. False when refused (not ours) or failed.</summary>
    public static bool Remove()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(EnvironmentKey, writable: true);
            if (key is null || !EditorVariablePolicy.MayRemove(Classify(key))) return false;
            key.DeleteValue(EditorVariablePolicy.Name, throwOnMissingValue: false);
            CommandInstaller.BroadcastEnvironmentChange();
            return true;
        }
        catch (Exception e) when (e is SecurityException or UnauthorizedAccessException or IOException)
        {
            return false;
        }
    }

    /// <summary>A value of another type (not a string) is someone else's: Other, shown by its kind.</summary>
    private static EditorVariableStatus Classify(RegistryKey? key)
    {
        if (key is null) return EditorVariablePolicy.Classify(null);
        return key.GetValue(EditorVariablePolicy.Name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) switch
        {
            null => EditorVariablePolicy.Classify(null),
            string text => EditorVariablePolicy.Classify(text),
            _ => new EditorVariableStatus(EditorVariableKind.Other, $"({key.GetValueKind(EditorVariablePolicy.Name)})"),
        };
    }
}
