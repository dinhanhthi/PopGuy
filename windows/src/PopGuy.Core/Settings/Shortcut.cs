using System.Text.Json.Serialization;
using PopGuy.Core.Actions;

namespace PopGuy.Core.Settings;

/// <summary>Hotkey modifiers, with the values RegisterHotKey takes (MOD_ALT, MOD_CONTROL, MOD_SHIFT, MOD_WIN).</summary>
[Flags]
public enum ShortcutModifiers : uint
{
    None = 0,
    Alt = 0x1,
    Control = 0x2,
    Shift = 0x4,
    Win = 0x8,
}

/// <summary>
/// A global hotkey: a Windows virtual-key code plus modifiers. Windows-only JSON <c>{"virtualKey":73,"modifiers":7}</c>
/// (settings.json is not shared with macOS, which stores its own key codes).
/// </summary>
public sealed record Shortcut(
    [property: JsonPropertyName("virtualKey")] uint VirtualKey,
    [property: JsonPropertyName("modifiers")] ShortcutModifiers Modifiers)
{
    /// <summary>The label shown in Settings, e.g. "Ctrl+Alt+Shift+I".</summary>
    public override string ToString()
    {
        var parts = new List<string>();
        if (Modifiers.HasFlag(ShortcutModifiers.Win)) parts.Add("Win");
        if (Modifiers.HasFlag(ShortcutModifiers.Control)) parts.Add("Ctrl");
        if (Modifiers.HasFlag(ShortcutModifiers.Alt)) parts.Add("Alt");
        if (Modifiers.HasFlag(ShortcutModifiers.Shift)) parts.Add("Shift");
        parts.Add(KeyName(VirtualKey));
        return string.Join("+", parts);
    }

    // Layout-independent names only; punctuation (OEM) keys need the keyboard layout, which only Win32 knows.
    private static string KeyName(uint vk) => vk switch
    {
        >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A => ((char)vk).ToString(),
        >= 0x70 and <= 0x87 => $"F{vk - 0x6F}",
        0x08 => "Backspace",
        0x09 => "Tab",
        0x0D => "Enter",
        0x1B => "Esc",
        0x20 => "Space",
        0x21 => "Page Up",
        0x22 => "Page Down",
        0x23 => "End",
        0x24 => "Home",
        0x25 => "Left",
        0x26 => "Up",
        0x27 => "Right",
        0x28 => "Down",
        0x2D => "Insert",
        0x2E => "Delete",
        _ => $"0x{vk:X2}",
    };
}

/// <summary>An action's global hotkey. JSON: <c>{"id":&lt;ActionIdentifier&gt;,"shortcut":&lt;Shortcut&gt;}</c>.</summary>
public sealed record ShortcutBinding(
    [property: JsonPropertyName("id")] ActionIdentifier Id,
    [property: JsonPropertyName("shortcut")] Shortcut Shortcut)
{
    private const ShortcutModifiers DefaultModifiers =
        ShortcutModifiers.Control | ShortcutModifiers.Alt | ShortcutModifiers.Shift;

    /// <summary>
    /// The fresh-install hotkeys: Ctrl+Alt+Shift + I/S/P/T/K (the macOS Ctrl+Option+Cmd set; Win+ combos belong to the
    /// OS and Ctrl+Alt alone is AltGr on many layouts).
    /// </summary>
    public static IReadOnlyList<ShortcutBinding> DefaultBuiltins { get; } =
    [
        new(ActionIdentifier.Builtin(ActionKind.Improve), new('I', DefaultModifiers)),
        new(ActionIdentifier.Builtin(ActionKind.Shorten), new('S', DefaultModifiers)),
        new(ActionIdentifier.Builtin(ActionKind.Proofread), new('P', DefaultModifiers)),
        new(ActionIdentifier.Builtin(ActionKind.Translate), new('T', DefaultModifiers)),
        new(ActionIdentifier.Speak, new('K', DefaultModifiers)),
    ];
}
