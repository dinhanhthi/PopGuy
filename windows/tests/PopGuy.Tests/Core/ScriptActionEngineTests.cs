using PopGuy.Core.Actions;
using PopGuy.Core.Scripts;

namespace PopGuy.Tests.Core;

// Security: an Open URL action launches only an absolute http(s) URL, and only a PowerShell script runs; macOS-only
// actions are refused before anything starts. The selected text reaches a script only as an environment value.
public sealed class ScriptActionEngineTests
{
    private readonly List<Uri> _launched = [];

    private ScriptActionEngine Engine() => new(openUrl: uri =>
    {
        _launched.Add(uri);
        return true;
    });

    private static CustomAction Action(CustomActionType type, string source, string? shell = null) => new()
    {
        Title = "Script",
        SystemPrompt = "",
        Type = type,
        ScriptSource = source,
        Shell = shell,
    };

    [Fact]
    public async Task OpenUrlLaunchesTheEncodedUrl()
    {
        var result = await Engine().RunAsync(
            Action(CustomActionType.OpenUrl, "https://www.google.com/search?q={text}"), "a&b c/../d", "a&b c/../d",
            TestContext.Current.CancellationToken);

        Assert.Null(result.Text);
        Assert.Equal("https://www.google.com/search?q=a%26b%20c%2F..%2Fd", Assert.Single(_launched).AbsoluteUri);
    }

    [Theory]
    [InlineData("file:///C:/{text}")]
    [InlineData("ms-msdt:/id PCWDiagnostic {text}")]
    [InlineData("search-ms:query={text}")]
    [InlineData("javascript:alert({text})")]
    [InlineData("{text}")]
    public async Task OpenUrlRefusesEveryOtherScheme(string template)
    {
        var error = await Assert.ThrowsAsync<ScriptActionError>(
            () => Engine().RunAsync(
                Action(CustomActionType.OpenUrl, template), "https://evil.test", "https://evil.test",
                TestContext.Current.CancellationToken));

        Assert.Empty(_launched);
        Assert.NotEmpty(error.Message);
    }

    [Theory]
    [InlineData(CustomActionType.AppleScript, null)]
    [InlineData(CustomActionType.RunShortcut, null)]
    [InlineData(CustomActionType.ShellScript, null)]
    [InlineData(CustomActionType.ShellScript, "zsh")]
    public async Task MacOSActionsAreRefused(CustomActionType type, string? shell)
    {
        var error = await Assert.ThrowsAsync<ScriptActionError>(
            () => Engine().RunAsync(
                Action(type, "Write-Output $env:POPGUY_TEXT", shell), "text", "text", TestContext.Current.CancellationToken));

        Assert.Equal("This action was made for macOS and can't run on Windows.", error.Message);
    }

    [Fact]
    public async Task PowerShellGetsTheSelectionOnlyAsAnEnvironmentValue()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("PowerShell scripts run on Windows only.");
        // Multi-line on purpose: `else` on its own line runs only when the whole script is parsed as one block.
        const string script = "if ($true) {\n  Write-Output $env:POPGUY_TEXT\n}\nelse {\n  Write-Output 'no'\n}\n";
        const string text = "\"; $(calc) é";

        var result = await new ScriptActionEngine().RunAsync(
            Action(CustomActionType.ShellScript, script, "powershell"), text, text, TestContext.Current.CancellationToken);

        Assert.Equal(text, result.Text);
    }

    // Security: a NUL in the selection must not end POPGUY_TEXT and start a variable of its own.
    [Fact]
    public async Task NulInTheSelectionAddsNoEnvironmentVariable()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("PowerShell scripts run on Windows only.");
        const string text = "a\0POPGUY_INJECTED=1";

        var result = await new ScriptActionEngine().RunAsync(
            Action(CustomActionType.ShellScript, "Write-Output \"[$env:POPGUY_INJECTED]\"", "powershell"), text, text,
            TestContext.Current.CancellationToken);

        Assert.Equal("[]", result.Text);
    }

    // The output cap: a script that prints without stopping fails instead of growing PopGuy's memory. Many lines hit
    // the engine's 1 MB cap; one line over CliRunner's 4 MB line limit gets the same message.
    [Theory]
    [InlineData("$line = 'x' * 1024; 1..1100 | ForEach-Object { $line }")]
    [InlineData("'x' * 5MB")]
    public async Task PowerShellOutputOver1MBFailsTheRun(string script)
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("PowerShell scripts run on Windows only.");

        var error = await Assert.ThrowsAsync<ScriptActionError>(
            () => new ScriptActionEngine().RunAsync(
                Action(CustomActionType.ShellScript, script, "powershell"), "text", "text",
                TestContext.Current.CancellationToken));

        Assert.Equal("The script printed more than 1 MB of output and was stopped.", error.Message);
    }
}
