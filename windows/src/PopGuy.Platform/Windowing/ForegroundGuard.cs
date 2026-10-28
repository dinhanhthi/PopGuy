using Windows.Win32;

namespace PopGuy.Platform.Windowing;

/// <summary>
/// The time-of-use check before PopGuy synthesizes keys: a capture or paste picks its source window first, then waits
/// (a UI Automation read, a clipboard snapshot, the modifier release), and the user may switch windows meanwhile. Keys
/// meant for the source must never reach the new foreground window (a terminal, a password field). Any thread.
/// </summary>
public static class ForegroundGuard
{
    /// <summary>True while <paramref name="source"/> (not 0) is still the foreground window.</summary>
    public static bool IsStill(nint source) => source != 0 && PInvoke.GetForegroundWindow() == source;
}
