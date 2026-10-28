using System.Diagnostics;
using Windows.Win32;
using Windows.Win32.UI.Input.KeyboardAndMouse;

namespace PopGuy.Platform.Input;

/// <summary>How a synthetic chord ended.</summary>
public enum InputSendResult
{
    /// <summary>SendInput inserted every event (a UIPI block is not reported: check the effect).</summary>
    Sent,

    /// <summary>SendInput did not insert every event.</summary>
    NotInserted,

    /// <summary>
    /// Nothing was sent: the caller's <c>stillAllowed</c> check failed right before SendInput (e.g. the foreground
    /// window changed during the modifier wait).
    /// </summary>
    Aborted,
}

/// <summary>
/// Synthetic copy (Ctrl+Insert) and paste (Ctrl+V) into the foreground app, through SendInput. Every event carries
/// <see cref="Marker"/> in its extra info, so PopGuy's own low-level hooks can tell them from the user's keys.
/// <para>
/// The copy is Ctrl+Insert, not Ctrl+C: Ctrl+Insert is the standard Windows copy accelerator (edit controls, rich
/// edit, Chromium/Electron, Office), while in a console or terminal Ctrl+C is an interrupt (SIGINT) that stops the
/// running command. Terminals (Windows Terminal, VS Code's integrated terminal) treat Ctrl+Insert as copy or ignore
/// it, never as an interrupt, so a copy that slips past <see cref="Capture.CaptureFallbackPolicy"/> cannot kill a
/// command. Paste stays Ctrl+V (Shift+Insert is not universal, and the paste target is the user's own editable field).
/// </para>
/// <para>
/// Foreground recheck: a send takes an optional <c>stillAllowed</c> check, called after the modifier wait and
/// immediately before SendInput; false aborts the send (<see cref="InputSendResult.Aborted"/>, nothing sent), so the
/// keys never reach a window that became the foreground meanwhile (a terminal, a password field).
/// </para>
/// <para>
/// Held modifiers: a hotkey's modifiers are usually still down when it fires, and Ctrl+Alt+V is not Ctrl+V. A send
/// first waits up to 500 ms (polling every 10 ms) for the user to release every modifier. Any still held at the
/// deadline are released (key-ups) before the chord and, afterwards, the ones the user still holds are pressed again
/// (key-downs, also marked), so a key the user keeps holding (a third C of a chord, the hotkey letter's auto-repeat)
/// still arrives with its modifiers instead of typing a plain letter over the selection. "Still holds" comes from
/// <c>isUserKeyDown</c> (<see cref="GlobalInput.IsUserKeyDown"/>): the async key state cannot tell, since the
/// synthetic key-ups clear it. Only modifiers that were down before the send (async key state) and are still down for
/// the hook are pressed again, so a release the hook missed never leaves a phantom key down. Residual cases: without
/// <c>isUserKeyDown</c>, or for a modifier the hook never saw go down (held since before the hook started), nothing
/// is pressed again; a release in the few milliseconds between the two reads leaves that modifier down until the
/// user's next press of it.
/// </para>
/// <para>
/// <see cref="InputSendResult.Sent"/> only says that SendInput inserted every event. It does not reveal a UIPI block
/// (an elevated foreground app silently drops the events): check the effect (e.g. the clipboard's sequence number).
/// </para>
/// </summary>
public static class InputSynth
{
    /// <summary>The extra info on every event PopGuy synthesizes: "PGUY".</summary>
    public const uint Marker = 0x50475559;

    /// <summary>How long a send waits for the user to release the modifiers.</summary>
    private static readonly TimeSpan ModifierReleaseTimeout = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan ModifierPollInterval = TimeSpan.FromMilliseconds(10);

    /// <summary>Modifiers a hotkey may still hold, each side separately so the key-up targets the key actually down.</summary>
    private static readonly VIRTUAL_KEY[] Modifiers =
    [
        VIRTUAL_KEY.VK_LCONTROL, VIRTUAL_KEY.VK_RCONTROL,
        VIRTUAL_KEY.VK_LSHIFT, VIRTUAL_KEY.VK_RSHIFT,
        VIRTUAL_KEY.VK_LMENU, VIRTUAL_KEY.VK_RMENU,
        VIRTUAL_KEY.VK_LWIN, VIRTUAL_KEY.VK_RWIN,
    ];

    /// <summary>
    /// An unassigned key, tapped while Alt or Win is down: a lone Alt or Win press and release would otherwise open the
    /// app's menu bar or the Start menu (the hotkey's letter went to RegisterHotKey, not to the app).
    /// </summary>
    private const VIRTUAL_KEY MaskKey = (VIRTUAL_KEY)0xE8;

    /// <summary>
    /// Sends the copy chord, Ctrl+Insert (never Ctrl+C: see the class), with held modifiers handled as described on the
    /// class. Blocks up to 500 ms: call it off the UI thread.
    /// </summary>
    /// <param name="isUserKeyDown">Whether the user still holds a virtual key (PopGuy's own events ignored); null: never press modifiers again.</param>
    /// <param name="stillAllowed">Checked after the modifier wait, right before SendInput; false: nothing is sent (<see cref="InputSendResult.Aborted"/>).</param>
    public static InputSendResult SendCopy(Func<uint, bool>? isUserKeyDown = null, Func<bool>? stillAllowed = null) =>
        SendChord(VIRTUAL_KEY.VK_INSERT, isUserKeyDown, stillAllowed);

    /// <summary>
    /// Sends Ctrl+V (held modifiers handled as described on the class). Blocks up to 500 ms: call it off the UI thread.
    /// </summary>
    /// <param name="isUserKeyDown">Whether the user still holds a virtual key (PopGuy's own events ignored); null: never press modifiers again.</param>
    /// <param name="stillAllowed">Checked after the modifier wait, right before SendInput; false: nothing is sent (<see cref="InputSendResult.Aborted"/>).</param>
    public static InputSendResult SendPaste(Func<uint, bool>? isUserKeyDown = null, Func<bool>? stillAllowed = null) =>
        SendChord(VIRTUAL_KEY.VK_V, isUserKeyDown, stillAllowed);

    private static InputSendResult SendChord(VIRTUAL_KEY key, Func<uint, bool>? isUserKeyDown, Func<bool>? stillAllowed)
    {
        var held = WaitForModifierRelease();

        var inputs = new List<INPUT>(16);
        if (held.Any(IsAltOrWin)) AddMaskTap(inputs);
        foreach (var vk in held) inputs.Add(Key(vk, up: true));
        inputs.Add(Key(VIRTUAL_KEY.VK_LCONTROL, up: false));
        inputs.Add(Key(key, up: false));
        inputs.Add(Key(key, up: true));
        inputs.Add(Key(VIRTUAL_KEY.VK_LCONTROL, up: true));
        // Last check, after the wait: nothing has been sent yet, so an abort needs no cleanup.
        if (stillAllowed is not null && !stillAllowed()) return InputSendResult.Aborted;
        // One call: the events reach the input stream together, never interleaved with the user's.
        var ok = Send(inputs);

        if (held.Count > 0 && isUserKeyDown is not null)
        {
            var stillHeld = held.Where(vk => isUserKeyDown((uint)vk)).ToList();
            if (stillHeld.Count > 0)
            {
                var repress = new List<INPUT>(stillHeld.Count + 2);
                foreach (var vk in stillHeld) repress.Add(Key(vk, up: false));
                // A key while Alt or Win is down: the user's own release of it then opens no menu.
                if (stillHeld.Any(IsAltOrWin)) AddMaskTap(repress);
                ok = Send(repress) && ok;
            }
        }
        return ok ? InputSendResult.Sent : InputSendResult.NotInserted;
    }

    /// <summary>Polls until no modifier is down or 500 ms passed; returns the ones still down.</summary>
    private static List<VIRTUAL_KEY> WaitForModifierRelease()
    {
        var watch = Stopwatch.StartNew();
        while (true)
        {
            var held = Modifiers.Where(IsDown).ToList();
            if (held.Count == 0 || watch.Elapsed >= ModifierReleaseTimeout) return held;
            Thread.Sleep(ModifierPollInterval);
        }
    }

    private static unsafe bool Send(List<INPUT> inputs) =>
        PInvoke.SendInput(inputs.ToArray(), sizeof(INPUT)) == inputs.Count;

    private static void AddMaskTap(List<INPUT> inputs)
    {
        inputs.Add(Key(MaskKey, up: false));
        inputs.Add(Key(MaskKey, up: true));
    }

    private static bool IsAltOrWin(VIRTUAL_KEY vk) =>
        vk is VIRTUAL_KEY.VK_LMENU or VIRTUAL_KEY.VK_RMENU or VIRTUAL_KEY.VK_LWIN or VIRTUAL_KEY.VK_RWIN;

    private static bool IsDown(VIRTUAL_KEY vk) => (PInvoke.GetAsyncKeyState((int)vk) & 0x8000) != 0;

    private static INPUT Key(VIRTUAL_KEY vk, bool up)
    {
        var flags = up ? KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP : 0;
        // Insert too: without the flag, it is the numeric keypad's 0/Ins key, which NumLock turns into a "0".
        if (vk is VIRTUAL_KEY.VK_RCONTROL or VIRTUAL_KEY.VK_RMENU or VIRTUAL_KEY.VK_LWIN or VIRTUAL_KEY.VK_RWIN or VIRTUAL_KEY.VK_INSERT)
        {
            flags |= KEYBD_EVENT_FLAGS.KEYEVENTF_EXTENDEDKEY;
        }
        var input = new INPUT { type = INPUT_TYPE.INPUT_KEYBOARD };
        input.ki = new KEYBDINPUT { wVk = vk, dwFlags = flags, dwExtraInfo = Marker };
        return input;
    }
}
