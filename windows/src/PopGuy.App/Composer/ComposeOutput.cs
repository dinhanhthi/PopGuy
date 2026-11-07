using PopGuy.Platform.Input;
using PopGuy.Platform.Output;
using PopGuy.Platform.Windowing;

namespace PopGuy.Composer;

/// <summary>
/// <see cref="IComposeOutput"/> over PopGuy.Platform: the Compose paste (<see cref="PasteBack.PasteForComposeAsync"/>)
/// and the auto-submit Enter (<see cref="InputSynth.SendEnter"/>, only while the window is still the foreground).
/// </summary>
/// <param name="log">Thread-safe: the paste's reason code arrives on the thread pool.</param>
internal sealed class ComposeOutput(GlobalInput input, Action<string> log) : IComposeOutput
{
    /// <summary>UI thread: the paste may give <paramref name="hwnd"/> the foreground only from there.</summary>
    public Task<PasteBackResult> PasteAsync(string text, nint hwnd) =>
        PasteBack.PasteForComposeAsync(text, hwnd, input.IsUserKeyDown, log);

    /// <summary>Off the UI thread: the send waits up to 500 ms for held modifiers.</summary>
    public async Task<bool> SendEnterAsync(nint hwnd) =>
        await Task.Run(() => InputSynth.SendEnter(input.IsUserKeyDown, () => ForegroundGuard.IsStill(hwnd)))
            == InputSendResult.Sent;
}
