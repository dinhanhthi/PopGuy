namespace PopGuy.Platform.Input;

/// <summary>The modifiers of a global hotkey (the values RegisterHotKey takes).</summary>
[Flags]
public enum HotKeyModifiers : uint
{
    None = 0,
    Alt = 0x1,
    Control = 0x2,
    Shift = 0x4,
    Win = 0x8,
}
