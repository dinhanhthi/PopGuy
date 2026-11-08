using PopGuy.Platform.Capture;
using PopGuy.Platform.Output;

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

    // The remote clients and terminals added after review: no synthetic key (copy or paste) ever reaches them.
    [Theory]
    [InlineData("msrdc", "remoteDesktop")]
    [InlineData("vmware-view", "remoteDesktop")]
    [InlineData("rustdesk", "remoteDesktop")]
    [InlineData("Moonlight", "remoteDesktop")]
    [InlineData("mRemoteNG", "remoteDesktop")]
    [InlineData("Termius", "console")]
    [InlineData("warp", "console")]
    public void UnsafeTargetReason(string processName, string reason) =>
        Assert.Equal(reason, CaptureFallbackPolicy.UnsafeTargetReason(ChromiumClass, processName, null));

    // Security: Paste back fails closed. An unknown editability pastes only in an allowlisted editable host (where the
    // editor rules still apply); an IDE that can host a terminal (JetBrains, Visual Studio) pastes only when UI
    // Automation says the focused element is editable.
    [Theory]
    [InlineData("SunAwtFrame", "idea64", null, null, "editabilityUnknown")]
    [InlineData("SunAwtFrame", "idea64", true, null, null)]
    [InlineData("Notepad", "notepad", null, null, null)]
    [InlineData(ChromiumClass, "Code", null, "inputarea", null)]
    public void PasteTargetRefusal(string windowClass, string processName, bool? isEditable, string? hint, string? reason) =>
        Assert.Equal(reason, PasteBack.TargetRefusal(new UiaPasteTarget(isEditable, hint), windowClass, processName));

    // Security: the Terminal Composer pastes into terminals (a terminal control has no value pattern), but never into a
    // password field, and everywhere else it refuses exactly what the toolbar's paste refuses.
    [Theory]
    [InlineData("CASCADIA_HOSTING_WINDOW_CLASS", "WindowsTerminal", null, null, false, null)]
    [InlineData("CASCADIA_HOSTING_WINDOW_CLASS", "WindowsTerminal", false, null, false, null)]
    [InlineData(ChromiumClass, "Code", null, "xterm-helper-textarea", false, null)]
    [InlineData("ConsoleWindowClass", "conhost", null, null, true, "passwordField")]
    [InlineData("SunAwtFrame", "idea64", null, null, false, "editabilityUnknown")]
    [InlineData("TscShellContainerClass", "mstsc", null, null, false, "remoteDesktop")]
    public void ComposePasteTargetRefusal(
        string windowClass, string processName, bool? isEditable, string? hint, bool isPassword, string? reason)
    {
        var target = new UiaPasteTarget(isEditable, hint, isPassword);

        Assert.Equal(reason, PasteBack.TargetRefusal(target, windowClass, processName, forCompose: true));
        if (CaptureFallbackPolicy.UnsafeTargetReason(windowClass, processName, hint) is not ("console" or "integratedTerminal"))
        {
            Assert.Equal(PasteBack.TargetRefusal(target, windowClass, processName), reason);
        }
    }

    // Security: the Emoji Picker types Unicode keys, harmless in a terminal, so it refuses only a password field and a
    // remote session; the toolbar's paste (default flags) still refuses the console.
    [Theory]
    [InlineData("CASCADIA_HOSTING_WINDOW_CLASS", "WindowsTerminal", false, true, null)]
    [InlineData("Notepad", "notepad", true, true, "passwordField")]
    [InlineData("TscShellContainerClass", "mstsc", false, true, "remoteDesktop")]
    [InlineData("CASCADIA_HOSTING_WINDOW_CLASS", "WindowsTerminal", false, false, "console")]
    public void EmojiTargetRefusal(string windowClass, string processName, bool isPassword, bool forEmoji, string? reason) =>
        Assert.Equal(reason, PasteBack.TargetRefusal(new UiaPasteTarget(null, null, isPassword), windowClass, processName, forEmoji: forEmoji));
}
