using System.Runtime.InteropServices;
using PopGuy.Platform.Input;
using PopGuy.Platform.SystemServices;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace PopGuy.Platform.Tests;

// Regression (VM QA): the tray's callback shared WM_APP + 1 with the message window's own queued-action message, whose
// handler answers first, so every tray click was lost.
public sealed class NotifyIconTests
{
    [Fact]
    public void TrayCallbackReachesItsHandler()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("The tray window needs Windows.");
        using var window = new MessageWindow(topLevel: true);
        var received = 0u;
        window.AddHandler(NotifyIcon.CallbackMessage, (_, lParam) =>
        {
            received = (uint)(lParam.Value & 0xFFFF);
            return (LRESULT)0;
        });

        // Same thread: SendMessage calls the window procedure directly, no message loop needed.
        SendMessageW(window.Handle, NotifyIcon.CallbackMessage, 0, (nint)PInvoke.NIN_SELECT);

        Assert.Equal(PInvoke.NIN_SELECT, received);
    }

    [Fact]
    public void TheWindowsOwnMessagesCannotTakeAnotherHandler()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("The message window needs Windows.");
        using var window = new MessageWindow(topLevel: true);

        Assert.Throws<ArgumentOutOfRangeException>(() => window.AddHandler(PInvoke.WM_APP + 1, (_, _) => (LRESULT)0));
        Assert.Throws<ArgumentOutOfRangeException>(() => window.AddHandler(PInvoke.WM_APP + 2, (_, _) => (LRESULT)0));
    }

    [DllImport("user32.dll")]
    private static extern nint SendMessageW(nint hWnd, uint msg, nuint wParam, nint lParam);
}
