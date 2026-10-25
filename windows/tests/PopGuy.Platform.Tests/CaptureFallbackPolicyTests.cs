using PopGuy.Platform.Capture;

namespace PopGuy.Platform.Tests;

// Security: the synthetic copy (Ctrl+Insert) must never reach a password field, a console or terminal, a remote
// session, an unknown process or an editor's integrated terminal, and must not run when the UI Automation read failed.
// One row per refusal class, plus the two paths where the fallback is allowed. Pure: no clipboard, no window.
public sealed class CaptureFallbackPolicyTests
{
    private const string ChromiumClass = "Chrome_WidgetWin_1";

    [Theory]
    [InlineData(UiaCaptureStatus.PasswordField, ChromiumClass, "chrome", null, false, false, "passwordField")]
    [InlineData(UiaCaptureStatus.Unavailable, "CASCADIA_HOSTING_WINDOW_CLASS", "WindowsTerminal", null, false, false, "console")]
    [InlineData(UiaCaptureStatus.Unavailable, "Transparent Windows Client", "wfica32", null, false, false, "remoteDesktop")]
    [InlineData(UiaCaptureStatus.Unavailable, ChromiumClass, null, null, false, false, "unknownProcess")]
    [InlineData(UiaCaptureStatus.Empty, ChromiumClass, "Code", "xterm-helper-textarea", false, false, "integratedTerminal")]
    [InlineData(UiaCaptureStatus.Unavailable, "Notepad", "notepad", null, true, false, "uiaReadFailed")]
    [InlineData(UiaCaptureStatus.Empty, ChromiumClass, "Cursor", null, false, false, "unknownFocusInEditor")]
    [InlineData(UiaCaptureStatus.Empty, "Notepad", "notepad", null, false, false, "empty")]
    [InlineData(UiaCaptureStatus.Unavailable, "Notepad", "notepad", null, false, true, "unavailable")]
    [InlineData(UiaCaptureStatus.Empty, ChromiumClass, "Code", "inputarea", false, true, "emptyKnownEditor")]
    public void Decide(
        UiaCaptureStatus status, string? windowClass, string? processName, string? hint, bool readFailed,
        bool allowed, string reason)
    {
        var decision = CaptureFallbackPolicy.Decide(status, windowClass, processName, hint, readFailed);

        Assert.Equal(new CaptureFallbackDecision(allowed, reason), decision);
    }
}
