using System.Globalization;
using PopGuy.Core.Settings;

namespace PopGuy.Core.Toolbar;

/// <summary>Why a selection event shows the toolbar or is dropped, so callers can log it.</summary>
public enum PresentationVerdict { Show, EmptyText, Reentrant, IgnoredApp, IgnoredDomain, NoEnabledAction }

/// <summary>A selection event and the toolbar's state when it arrives.</summary>
/// <param name="Text">The captured selection.</param>
/// <param name="IsShowing">The toolbar is on screen.</param>
/// <param name="CurrentText">The selection the toolbar is showing for.</param>
/// <param name="ActionInProgress">The action state is not idle (loading, result or error on screen).</param>
/// <param name="SpeakActive">Speak is loading or playing (its phase is not idle).</param>
/// <param name="CanReplaySpeak">The "Listen again" button is on screen.</param>
/// <param name="SourceExeName">The foreground app's executable file name (e.g. "notepad.exe"), if known.</param>
/// <param name="IsOwnProcess">The foreground app is PopGuy itself (e.g. its Settings window).</param>
/// <param name="SourceHost">The browser tab's host, read only while ignored domains are on.</param>
public readonly record struct PresentationInput(
    string Text,
    bool IsShowing = false,
    string CurrentText = "",
    bool ActionInProgress = false,
    bool SpeakActive = false,
    bool CanReplaySpeak = false,
    string? SourceExeName = null,
    bool IsOwnProcess = false,
    string? SourceHost = null);

/// <summary>The verdict, plus the source to hand to the toolbar (unset for PopGuy's own process).</summary>
public readonly record struct PresentationResult(PresentationVerdict Verdict, string? SourceExeName, string? SourceHost);

/// <summary>
/// Whether a selection event presents the toolbar, in the order of macOS <c>ToolbarController.handleEvent</c>.
/// </summary>
public static class PresentationGate
{
    public static PresentationResult Evaluate(PresentationInput input, AppSettings settings)
    {
        // PopGuy itself is never the source, so "Ignore this app" can never disable PopGuy.
        var exe = input.IsOwnProcess ? null : input.SourceExeName;
        var host = input.IsOwnProcess ? null : input.SourceHost;
        PresentationResult Result(PresentationVerdict verdict) => new(verdict, exe, host);

        if (input.Text.Length == 0)
            return Result(PresentationVerdict.EmptyText);

        // A trailing same-text event (an accessibility notification, the mouse-up of a toolbar click) must not reset an
        // action on screen or move the panel. Speak never sets the action state, so it counts separately.
        var inProgress = input.ActionInProgress || input.SpeakActive || input.CanReplaySpeak;
        if (input.IsShowing && inProgress && input.Text == input.CurrentText)
            return Result(PresentationVerdict.Reentrant);

        // Both ignore lists fail open on an unknown source (macOS parity): the caller must pass whatever it can read.
        // A blank or null entry (settings.json can hold null in a list) matches nothing.
        if (settings.IgnoredAppsEnabled && IgnoredApps.Contains(settings.IgnoredAppExeNames, exe))
            return Result(PresentationVerdict.IgnoredApp);

        if (host is not null && settings.IgnoredDomainsEnabled && settings.IgnoredDomains.Any(d => HostMatches(host, d)))
            return Result(PresentationVerdict.IgnoredDomain);

        if (ToolbarLayout.EnabledOrdered(settings).Count == 0)
            return Result(PresentationVerdict.NoEnabledAction);

        return Result(PresentationVerdict.Show);
    }

    /// <summary>
    /// True when <paramref name="host"/> is <paramref name="domain"/> or one of its subdomains: "notion.so" also covers
    /// "team.notion.so", never "evilnotion.so". Both sides are normalized first (<see cref="NormalizeDomain"/>); an entry
    /// that normalizes to nothing matches nothing.
    /// </summary>
    public static bool HostMatches(string host, string domain) =>
        NormalizeDomain(host) is { } h && NormalizeDomain(domain) is { } d && (h == d || h.EndsWith("." + d, StringComparison.Ordinal));

    /// <summary>
    /// The host of a browser address-bar value (macOS <c>BrowserURLReader.normalizeHost</c>), normalized by
    /// <see cref="NormalizeDomain"/>; null unless it is a web page. Address bars hide "https://" (Chromium also "www."),
    /// so a value without a scheme counts as a web address; with one, only http and https do ("chrome://newtab",
    /// "edge://settings", "about:blank", "file:///…" and "view-source:…" have no host). "localhost:3000" is a host and a
    /// port. White space (a search being typed) is no address.
    /// </summary>
    public static string? NormalizeHost(string? address)
    {
        var s = address?.Trim() ?? "";
        if (s.Length == 0 || s.Any(char.IsWhiteSpace)) return null;
        var end = s.IndexOfAny(['/', '?', '#']);
        if (s.IndexOf(':') is var colon and >= 0 && (end < 0 || colon < end))
        {
            if (s.AsSpan(colon).StartsWith("://", StringComparison.Ordinal))
            {
                var scheme = s[..colon];
                if (!scheme.Equals("http", StringComparison.OrdinalIgnoreCase) && !scheme.Equals("https", StringComparison.OrdinalIgnoreCase))
                    return null;
            }
            else if (s[(colon + 1)..(end < 0 ? s.Length : end)] is not { Length: > 0 } port || !port.All(char.IsAsciiDigit))
            {
                return null;
            }
        }
        return NormalizeDomain(s);
    }

    /// <summary>
    /// The bare lowercase host of a typed domain or URL (macOS <c>BrowserURLReader.normalizeDomain</c>):
    /// no scheme, user info, port, path, query, leading "." or "www.", trailing "."; null unless it has a dot or is
    /// "localhost", and for white space inside. A Unicode host becomes its punycode "xn--" form (IDNA, as macOS does),
    /// then only ASCII letters, digits, ".", "-" and "_" are kept: the host goes into AI prompts and the settings.
    /// Settings → Ignore stores entries in this form.
    /// </summary>
    public static string? NormalizeDomain(string? raw)
    {
        var s = raw?.Trim().ToLowerInvariant() ?? "";
        if (s.Any(char.IsWhiteSpace))
            return null;
        if (s.IndexOf("://", StringComparison.Ordinal) is var scheme and >= 0)
            s = s[(scheme + 3)..];
        if (s.IndexOfAny(['/', '?', '#']) is var end and >= 0)
            s = s[..end];
        s = s[(s.LastIndexOf('@') + 1)..];
        if (s.IndexOf(':') is var port and >= 0)
            s = s[..port];
        s = s.Trim('.');
        if (s.StartsWith("www.", StringComparison.Ordinal))
            s = s[4..];
        if (!s.All(char.IsAscii))
        {
            try
            {
                s = new IdnMapping().GetAscii(s);
            }
            catch (ArgumentException)
            {
                return null;
            }
        }
        if (!s.All(c => char.IsAsciiLetterLower(c) || char.IsAsciiDigit(c) || c is '.' or '-' or '_'))
            return null;
        return s.Contains('.') || s == "localhost" ? s : null;
    }
}
