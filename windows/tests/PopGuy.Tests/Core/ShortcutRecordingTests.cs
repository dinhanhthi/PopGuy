using PopGuy.Core.Settings;

namespace PopGuy.Tests.Core;

// Contract: which key presses the Settings shortcut recorder accepts (Ctrl or Alt required, Esc cancels, Backspace
// clears, bare modifiers wait) and the Windows display of a recorded shortcut.
public sealed class ShortcutRecordingTests
{
    [Fact]
    public void CtrlShiftSpaceIsRecordedAndShownWithWindowsNames()
    {
        var outcome = Shortcut.Interpret(0x20, ShortcutModifiers.Control | ShortcutModifiers.Shift, out var recorded);

        Assert.Equal(ShortcutKeyOutcome.Record, outcome);
        Assert.Equal("Ctrl+Shift+Space", recorded?.ToString());
    }

    [Theory]
    [InlineData(0x20u, ShortcutModifiers.Shift, ShortcutKeyOutcome.Ignore)] // Shift+Space: no Ctrl or Alt
    [InlineData(0x41u, ShortcutModifiers.Win, ShortcutKeyOutcome.Ignore)] // Win+A: no Ctrl or Alt
    [InlineData(0xA2u, ShortcutModifiers.Control, ShortcutKeyOutcome.Ignore)] // bare Left Ctrl: waits for the key
    [InlineData(0x1Bu, ShortcutModifiers.Control, ShortcutKeyOutcome.Cancel)] // Esc
    [InlineData(0x08u, ShortcutModifiers.None, ShortcutKeyOutcome.Clear)] // Backspace
    public void OtherPressesDoNotRecord(uint virtualKey, ShortcutModifiers held, ShortcutKeyOutcome expected)
    {
        Assert.Equal(expected, Shortcut.Interpret(virtualKey, held, out var recorded));
        Assert.Null(recorded);
    }
}
