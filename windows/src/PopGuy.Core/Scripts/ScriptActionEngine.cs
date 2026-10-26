using System.ComponentModel;
using System.Diagnostics;
using PopGuy.Core.Actions;
using PopGuy.Core.Providers;
using PopGuy.Core.Providers.Cli;

namespace PopGuy.Core.Scripts;

/// <summary>A script action's output: null when it has none (an opened URL, an empty or blank stdout).</summary>
public sealed record ScriptActionResult(string? Text);

/// <summary>A script action that could not run or failed; <see cref="Exception.Message"/> is user-facing.</summary>
public sealed class ScriptActionError(string message) : Exception(message);

/// <summary>Runs a scriptable custom action (macOS <c>ScriptActionRunning</c>): the toolbar session's seam.</summary>
public interface IScriptActionRunner
{
    /// <param name="text">The trimmed selection: the <c>{text}</c> value and <c>POPGUY_TEXT</c>.</param>
    /// <param name="fullText">The untrimmed selection: <c>POPGUY_FULL_TEXT</c>.</param>
    /// <exception cref="ScriptActionError">The action cannot run here, or it failed.</exception>
    Task<ScriptActionResult> RunAsync(CustomAction action, string text, string fullText, CancellationToken ct = default);
}

/// <summary>
/// Runs Open URL and PowerShell shell-script actions (a port of <c>ScriptActionEngine.swift</c>, spec-4 §4.2). They
/// bypass the providers. AppleScript, Shortcuts and shell scripts without <c>shell: "powershell"</c> (macOS zsh) are
/// refused with <see cref="MadeForMacMessage"/>.
/// <para>
/// Security. The selection is untrusted. An Open URL template gets it percent-encoded
/// (<see cref="PlaceholderExpander.ExpandUrl"/>), and only an absolute http(s) URL is opened: ShellExecute would hand
/// any other scheme (file:, ms-msdt:, search-ms:...) to its handler. A script gets it only as the
/// <c>POPGUY_TEXT</c>/<c>POPGUY_FULL_TEXT</c> environment values, never in its source or argv. The script goes to
/// PowerShell's stdin through <see cref="CliRunner"/>: started directly (no cmd.exe), with the CliRunner allowlisted
/// environment (no API keys) plus <c>ComSpec</c> and <c>PATHEXT</c>, in a fresh temp folder. A run is stopped after
/// <see cref="RunTimeout"/>, its whole process tree killed, and its output capped at <see cref="OutputLimit"/>.
/// </para>
/// </summary>
public sealed class ScriptActionEngine : IScriptActionRunner
{
    public const string MadeForMacMessage = "This action was made for macOS and can't run on Windows.";

    /// <summary>The longest a script may run (macOS has no limit; a hung script would hold the toolbar).</summary>
    public static readonly TimeSpan RunTimeout = TimeSpan.FromMinutes(2);

    /// <summary>The most stdout a script may print, in characters (1 MB of ASCII); more fails the run.</summary>
    internal const int OutputLimit = 1024 * 1024;

    private const string InvalidUrlMessage = "The URL template did not produce a valid URL.";
    private const string UrlSchemeMessage = "Only http and https URLs can be opened on Windows.";
    private const string PowerShellMissingMessage =
        "PowerShell was not found. Shell script actions need Windows PowerShell or PowerShell 7.";
    private const string TimedOutMessage = "The script didn't finish within 2 minutes and was stopped.";
    private const string OutputTooLargeMessage = "The script printed more than 1 MB of output and was stopped.";

    /// <summary>
    /// The PowerShell command line: constant, no user data. Not <c>-Command -</c>: PowerShell then runs stdin one
    /// statement at a time, as if typed, so a multi-line <c>if</c>/<c>else</c> silently never runs (measured on Windows
    /// PowerShell 5.1); and 5.1 reads stdin and writes stdout in the console code page. This reads the whole script
    /// from stdin as UTF-8, runs it as one script block (its <c>exit</c> code is the process's) and writes UTF-8 (when
    /// the console code page can be set; the script runs either way).
    /// </summary>
    internal static readonly IReadOnlyList<string> PowerShellArguments =
    [
        "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command",
        "try{[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)}catch{}; & ([ScriptBlock]::Create(" +
        "[IO.StreamReader]::new([Console]::OpenStandardInput(),[Text.UTF8Encoding]::new($false)).ReadToEnd()))",
    ];

    private readonly Func<Uri, bool> _openUrl;
    private readonly ShellEnvironment _shell = ShellEnvironment.Shared;
    private readonly CliRunner _runner;

    /// <param name="openUrl">Opens an http(s) URL, false when it could not; ShellExecute (the default browser) by default.</param>
    /// <param name="onStarted">Called with PowerShell's process right after it starts (see <see cref="CliRunner"/>).</param>
    public ScriptActionEngine(Func<Uri, bool>? openUrl = null, Action<Process>? onStarted = null)
    {
        _openUrl = openUrl ?? ShellOpen;
        // The engine applies its own timeout, with its own message.
        _runner = new CliRunner(Timeout.InfiniteTimeSpan, onStarted, _shell);
    }

    public async Task<ScriptActionResult> RunAsync(
        CustomAction action, string text, string fullText, CancellationToken ct = default)
    {
        switch (action.Type)
        {
            case CustomActionType.OpenUrl:
                return OpenUrl(action.ScriptSource, text);
            case CustomActionType.ShellScript when action.Shell == CustomActionEditing.PowerShell:
                return await RunPowerShellAsync(action.ScriptSource, text, fullText, ct);
            case CustomActionType.ShellScript or CustomActionType.AppleScript or CustomActionType.RunShortcut:
                throw new ScriptActionError(MadeForMacMessage);
            default:
                throw new ScriptActionError(
                    $"Action type '{action.Type.DisplayName()}' is not a scriptable type and cannot be run by ScriptActionEngine.");
        }
    }

    private ScriptActionResult OpenUrl(string template, string text)
    {
        if (!Uri.TryCreate(PlaceholderExpander.ExpandUrl(template, text), UriKind.Absolute, out var url))
            throw new ScriptActionError(InvalidUrlMessage);
        if (url.Scheme != Uri.UriSchemeHttp && url.Scheme != Uri.UriSchemeHttps)
            throw new ScriptActionError(UrlSchemeMessage);
        if (!_openUrl(url))
            throw new ScriptActionError(InvalidUrlMessage);
        return new ScriptActionResult(null);
    }

    // The escaped form: Uri.ToString() would decode the encoded selection.
    private static bool ShellOpen(Uri url)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true });
            return true;
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException)
        {
            return false;
        }
    }

    private async Task<ScriptActionResult> RunPowerShellAsync(string script, string text, string fullText, CancellationToken ct)
    {
        var executable = PowerShellPath() ?? throw new ScriptActionError(PowerShellMissingMessage);
        var environment = PlaceholderExpander.ScriptEnvironment(text, fullText, _shell.Variable("USERPROFILE") ?? "");
        foreach (var name in (string[])["ComSpec", "PATHEXT"])
        {
            if (_shell.Variable(name) is { Length: > 0 } value)
                environment[name] = value;
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(RunTimeout);
        var lines = new List<string>();
        var length = 0;
        try
        {
            // Leaving the loop early (the cap) stops PowerShell and kills its process tree.
            await foreach (var line in _runner.StreamLinesAsync(
                               "PowerShell", executable, PowerShellArguments, script,
                               extraEnvironment: environment, keepEmptyLines: true, ct: timeout.Token))
            {
                // PowerShell ends its lines with CRLF.
                var bare = line.EndsWith('\r') ? line[..^1] : line;
                length += bare.Length + 1;
                if (length > OutputLimit)
                    throw new ScriptActionError(OutputTooLargeMessage);
                lines.Add(bare);
            }
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested && !ct.IsCancellationRequested)
        {
            throw new ScriptActionError(TimedOutMessage);
        }
        catch (ProviderError error)
        {
            throw ProcessFailed(error);
        }
        var output = string.Join('\n', lines).Trim();
        return new ScriptActionResult(output.Length == 0 ? null : output);
    }

    /// <summary>pwsh.exe on the PATH (PowerShell 7), else Windows PowerShell 5.1, which every Windows has; null when neither is there.</summary>
    private string? PowerShellPath()
    {
        if (_shell.Executable("pwsh") is { LeadingArguments.Count: 0 } pwsh)
            return pwsh.FileName;
        if (_shell.Variable("SystemRoot") is not { Length: > 0 } root)
            return null;
        var path = Path.Combine(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        return File.Exists(path) ? path : null;
    }

    // macOS processFailed: a non-zero exit with stderr's cause (CliRunner's redacted snippet), anything else as -1.
    private static ScriptActionError ProcessFailed(ProviderError error)
    {
        var status = -1;
        var stderr = error.Message;
        if (error is { Kind: ProviderErrorKind.Http, StatusCode: { } code })
        {
            status = code;
            var prefix = $"HTTP {code}: ";
            stderr = stderr.StartsWith(prefix, StringComparison.Ordinal) ? stderr[prefix.Length..] : stderr;
            if (stderr == "(no body)")
                stderr = "";
        }
        return new ScriptActionError($"Script exited with status {status}: {(stderr.Length == 0 ? "(no output)" : stderr)}");
    }
}
