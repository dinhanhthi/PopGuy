using PopGuy.Core.Providers;
using PopGuy.Core.Providers.Cli;

namespace PopGuy.Tests.Core;

// Security: how a subscription CLI is started. An npm .cmd shim runs as node.exe + its JS entry, never through cmd.exe
// (BatBadBut); the child environment is the allowlist only, so no API key reaches the CLI.
public sealed class CliProviderTests : IDisposable
{
    private readonly string _folder = Path.Combine(Path.GetTempPath(), "PopGuyTests-cli-" + Guid.NewGuid().ToString("N"));

    public CliProviderTests() => Directory.CreateDirectory(_folder);

    public void Dispose() => Directory.Delete(_folder, recursive: true);

    // The shim npm 7+ (cmd-shim 4+) writes for @anthropic-ai/claude-code.
    private const string NpmShim =
        "@ECHO off\r\n" +
        "GOTO start\r\n" +
        ":find_dp0\r\n" +
        "SET dp0=%~dp0\r\n" +
        "EXIT /b\r\n" +
        ":start\r\n" +
        "SETLOCAL\r\n" +
        "CALL :find_dp0\r\n" +
        "\r\n" +
        "IF EXIST \"%dp0%\\node.exe\" (\r\n" +
        "  SET \"_prog=%dp0%\\node.exe\"\r\n" +
        ") ELSE (\r\n" +
        "  SET \"_prog=node\"\r\n" +
        "  SET PATHEXT=%PATHEXT:;.JS;=;%\r\n" +
        ")\r\n" +
        "\r\n" +
        "endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & \"%_prog%\"  \"%dp0%\\node_modules\\@anthropic-ai\\claude-code\\cli.js\" %*\r\n";

    private static ShellEnvironment Shell(string path, Func<string, string?>? variable = null) =>
        new(() => path, variable ?? (_ => null));

    private string WriteFile(string relative, string text = "")
    {
        var path = Path.Combine(_folder, relative);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
        return path;
    }

    [Fact]
    public void NpmShimResolvesToNodeAndScriptNeverCmd()
    {
        var node = WriteFile("node.exe");
        var script = WriteFile(Path.Combine("node_modules", "@anthropic-ai", "claude-code", "cli.js"));
        var shim = WriteFile("claude.cmd", NpmShim);

        var executable = Shell(_folder).Executable("claude");

        Assert.NotNull(executable);
        Assert.Equal(node, executable.FileName);
        Assert.Equal([script], executable.LeadingArguments);
        Assert.Equal(shim, executable.DisplayPath);
    }

    [Fact]
    public void ShimRunningAnotherProgramIsRefusedAndCmdIsNeverStarted()
    {
        WriteFile("node.exe");
        WriteFile("cli.js");
        WriteFile("claude.cmd", "@ECHO off\r\ncmd.exe /c \"%~dp0\\cli.js\" %*\r\n");

        Assert.Null(Shell(_folder).Executable("claude"));
        var cmd = new CliExecutable(Path.Combine(_folder, "cmd.exe"), [], "cmd.exe");
        Assert.Throws<ProviderError>(() => ShellEnvironment.StartInfo(cmd, [], new Dictionary<string, string>(), _folder));
    }

    [Fact]
    public void ChildEnvironmentIsTheAllowlistOnlyWithHomeFromUserProfile()
    {
        // A variable of this process must not leak through ProcessStartInfo's inherited environment either.
        const string inherited = "POPGUY_TEST_INHERITED_SECRET";
        Environment.SetEnvironmentVariable(inherited, "sk-inherited-0123456789");
        try
        {
            var values = new Dictionary<string, string>
            {
                ["USERPROFILE"] = @"C:\Users\thi",
                ["APPDATA"] = @"C:\Users\thi\AppData\Roaming",
                ["LOCALAPPDATA"] = @"C:\Users\thi\AppData\Local",
                ["SystemRoot"] = @"C:\Windows",
                ["TEMP"] = @"C:\Users\thi\AppData\Local\Temp",
                ["TMP"] = @"C:\Users\thi\AppData\Local\Temp",
                ["USERNAME"] = "thi",
                ["HOME"] = @"C:\elsewhere",
                ["ANTHROPIC_API_KEY"] = "sk-ant-0123456789",
                ["OPENAI_API_KEY"] = "sk-0123456789",
                ["NODE_OPTIONS"] = "--require evil.js",
            };
            var environment = ShellEnvironment.BaseEnvironment(@"C:\npm", name => values.GetValueOrDefault(name));
            var info = ShellEnvironment.StartInfo(
                new CliExecutable(Path.Combine(_folder, "claude.exe"), [], "claude.exe"), [], environment, _folder);

            Assert.Equal(
                ["APPDATA", "HOME", "LOCALAPPDATA", "PATH", "SystemRoot", "TEMP", "TMP", "USERNAME", "USERPROFILE"],
                info.Environment.Keys.Order(StringComparer.Ordinal));
            Assert.Equal(@"C:\Users\thi", info.Environment["HOME"]);
            Assert.Equal(@"C:\npm", info.Environment["PATH"]);
        }
        finally
        {
            Environment.SetEnvironmentVariable(inherited, null);
        }
    }
}
