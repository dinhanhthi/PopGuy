using Windows.Win32;
using Windows.Win32.UI.Input.KeyboardAndMouse;

namespace PopGuy.Platform.Input;

/// <summary>
/// Synthetic Ctrl+C and Ctrl+V into the foreground app, through SendInput. Every event carries
/// <see cref="Marker"/> in its extra info, so PopGuy's own low-level hooks can tell them from the user's keys.
/// </summary>
public static class InputSynth
{
    /// <summary>The extra info on every event PopGuy synthesizes: "PGUY".</summary>
    public const uint Marker = 0x50475559;

    /// <summary>Modifiers a hotkey may still hold, each side separately so the key-up targets the key actually down.</summary>
    private static readonly VIRTUAL_KEY[] Modifiers =
    [
        VIRTUAL_KEY.VK_LCONTROL, VIRTUAL_KEY.VK_RCONTROL,
        VIRTUAL_KEY.VK_LSHIFT, VIRTUAL_KEY.VK_RSHIFT,
        VIRTUAL_KEY.VK_LMENU, VIRTUAL_KEY.VK_RMENU,
        VIRTUAL_KEY.VK_LWIN, VIRTUAL_KEY.VK_RWIN,
    ];

    /// <summary>
    /// An unassigned key, tapped before Alt or Win are released: a lone Alt or Win release would otherwise open the
    /// app's menu bar or the Start menu (the hotkey's letter went to RegisterHotKey, not to the app).
    /// </summary>
    private const VIRTUAL_KEY MaskKey = (VIRTUAL_KEY)0xE8;

    /// <summary>Releases held modifiers, then sends Ctrl+C. False if Windows blocked some of the events (UIPI).</summary>
    public static bool SendCopy() => SendChord(VIRTUAL_KEY.VK_C);

    /// <summary>Releases held modifiers, then sends Ctrl+V. False if Windows blocked some of the events (UIPI).</summary>
    public static bool SendPaste() => SendChord(VIRTUAL_KEY.VK_V);

    private static unsafe bool SendChord(VIRTUAL_KEY key)
    {
        var inputs = new List<INPUT>(16);
        var held = Modifiers.Where(IsDown).ToList();
        if (held.Any(vk => vk is VIRTUAL_KEY.VK_LMENU or VIRTUAL_KEY.VK_RMENU or VIRTUAL_KEY.VK_LWIN or VIRTUAL_KEY.VK_RWIN))
        {
            inputs.Add(Key(MaskKey, up: false));
            inputs.Add(Key(MaskKey, up: true));
        }
        foreach (var vk in held) inputs.Add(Key(vk, up: true));

        inputs.Add(Key(VIRTUAL_KEY.VK_LCONTROL, up: false));
        inputs.Add(Key(key, up: false));
        inputs.Add(Key(key, up: true));
        inputs.Add(Key(VIRTUAL_KEY.VK_LCONTROL, up: true));

        // One call: the events reach the input stream together, never interleaved with the user's.
        var sent = PInvoke.SendInput(inputs.ToArray(), sizeof(INPUT));
        return sent == inputs.Count;
    }

    private static bool IsDown(VIRTUAL_KEY vk) => (PInvoke.GetAsyncKeyState((int)vk) & 0x8000) != 0;

    private static INPUT Key(VIRTUAL_KEY vk, bool up)
    {
        var flags = up ? KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP : 0;
        if (vk is VIRTUAL_KEY.VK_RCONTROL or VIRTUAL_KEY.VK_RMENU or VIRTUAL_KEY.VK_LWIN or VIRTUAL_KEY.VK_RWIN)
        {
            flags |= KEYBD_EVENT_FLAGS.KEYEVENTF_EXTENDEDKEY;
        }
        var input = new INPUT { type = INPUT_TYPE.INPUT_KEYBOARD };
        input.ki = new KEYBDINPUT { wVk = vk, dwFlags = flags, dwExtraInfo = Marker };
        return input;
    }
}
