using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace PopGuy.Core.Providers.Cli;

/// <summary>
/// A CLI ready to start: <see cref="FileName"/> is always a <c>.exe</c> (the CLI itself, or <c>node.exe</c> for an npm
/// shim), <see cref="LeadingArguments"/> go before the CLI's own arguments (the shim's JS entry), and
/// <see cref="DisplayPath"/> is what the user installed (the <c>.exe</c> or the <c>.cmd</c> shim), for messages.
/// </summary>
public sealed record CliExecutable(string FileName, IReadOnlyList<string> LeadingArguments, string DisplayPath);

/// <summary>
/// The user's PATH, executable lookup and child environment for the subscription CLIs (the Windows side of
/// CLIProcessRunner.swift's environment).
/// The PATH is read from the registry (machine, then user, as Windows builds a new process's PATH), so CLIs installed
/// after PopGuy started are found, plus the known install directories. Resolved once, on first use.
/// <para>
/// Security (BatBadBut): a <c>.cmd</c>/<c>.bat</c> is never started, as Windows would run it through cmd.exe, whose
/// argument parsing lets selected text become commands. An npm <c>.cmd</c> shim is parsed to <c>node.exe</c> plus its
/// JS entry instead; a shim in any other format is refused.
/// </para>
/// </summary>
public sealed partial class ShellEnvironment
{
    public static ShellEnvironment Shared { get; } = new(RegistryPath, Environment.GetEnvironmentVariable);

    /// <summary>Windows' PATH separator, also on the Mac where the tests run.</summary>
    internal const char Separator = ';';

    private readonly Lazy<string> _path;

    /// <param name="basePath">The PATH before the known directories (the registry's on Windows).</param>
    /// <param name="variable">Reads an environment variable of this process.</param>
    internal ShellEnvironment(Func<string> basePath, Func<string, string?> variable)
    {
        Variable = variable;
        _path = new(() => MergedPath(basePath(), KnownDirectories(variable)));
    }

    internal Func<string, string?> Variable { get; }

    /// <summary>The PATH directories, then the known install directories; relative and repeated entries dropped.</summary>
    public string Path => _path.Value;

    /// <summary>
    /// <paramref name="override"/> (a <c>.exe</c> or npm <c>.cmd</c> path from settings, <c>~</c> allowed) when set, else
    /// the first <c>&lt;name&gt;.exe</c> on <see cref="Path"/>, else the first <c>&lt;name&gt;.cmd</c> npm shim on it that
    /// parses. A <c>.exe</c> anywhere on the PATH wins over a shim earlier on it: it needs no parsing. Null when none.
    /// </summary>
    public CliExecutable? Executable(string name, string? @override = null)
    {
        var path = @override?.Trim() ?? "";
        if (path.Length > 0)
        {
            if (path == "~" || path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith("~\\", StringComparison.Ordinal))
                path = (Variable("USERPROFILE") ?? "") + path[1..];
            if (!System.IO.Path.IsPathFullyQualified(path))
                return null;
            return System.IO.Path.GetExtension(path).ToLowerInvariant() switch
            {
                ".exe" => Native(path),
                ".cmd" => Shim(path),
                _ => null,
            };
        }
        var directories = Directories(Path);
        foreach (var directory in directories)
        {
            if (Native(System.IO.Path.Combine(directory, name + ".exe")) is { } native)
                return native;
        }
        foreach (var directory in directories)
        {
            if (Shim(System.IO.Path.Combine(directory, name + ".cmd")) is { } shim)
                return shim;
        }
        return null;
    }

    /// <summary>
    /// How every CLI process starts: the program directly (never through cmd.exe or the shell), arguments as a list
    /// (never a joined string), only <paramref name="environment"/>, stdin/stdout/stderr redirected, no console window.
    /// </summary>
    internal static ProcessStartInfo StartInfo(
        CliExecutable executable, IEnumerable<string> arguments, IReadOnlyDictionary<string, string> environment,
        string workingDirectory)
    {
        // Process.Start would hand a .cmd/.bat to cmd.exe (BatBadBut); a resolved CLI is always a .exe.
        if (!IsLaunchable(executable.FileName))
            throw ProviderError.Transport($"{executable.DisplayPath} cannot be started: only a .exe is run, never through cmd.exe.");
        var info = new ProcessStartInfo(executable.FileName)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = workingDirectory,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            // Never the console code page; no BOM.
            StandardInputEncoding = new UTF8Encoding(false),
        };
        foreach (var argument in executable.LeadingArguments.Concat(arguments))
            info.ArgumentList.Add(argument);
        // ProcessStartInfo starts from this process's environment; only the allowlist may reach the CLI.
        info.Environment.Clear();
        foreach (var (name, value) in environment)
            info.Environment[name] = value;
        return info;
    }

    /// <summary>A new empty folder only this run uses, <c>%TEMP%\PopGuy-cli-&lt;GUID&gt;</c>, as a CLI's working directory.</summary>
    internal static string CreateWorkDirectory()
    {
        var workDirectory = System.IO.Path.Combine(
            System.IO.Path.GetTempPath(), "PopGuy-cli-" + Guid.NewGuid().ToString("D").ToUpperInvariant());
        Directory.CreateDirectory(workDirectory);
        return workDirectory;
    }

    /// <summary>Deletes a <see cref="CreateWorkDirectory"/> folder; one still in use is left for the system to clean.</summary>
    internal static void DeleteWorkDirectory(string workDirectory)
    {
        try
        {
            Directory.Delete(workDirectory, recursive: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // A grandchild still holds it; the temp folder is cleaned by the system.
        }
    }

    /// <summary>
    /// The environment every CLI gets: PATH, the user's folders and name, HOME (= USERPROFILE), and nothing else from
    /// PopGuy (no API keys, no NODE_OPTIONS), so the CLIs use the subscription login. Variables this process lacks are
    /// left out.
    /// </summary>
    internal static Dictionary<string, string> BaseEnvironment(string path, Func<string, string?> variable)
    {
        var environment = new Dictionary<string, string> { ["PATH"] = path };
        foreach (var name in (string[])["USERPROFILE", "APPDATA", "LOCALAPPDATA", "SystemRoot", "TEMP", "TMP", "USERNAME"])
        {
            if (variable(name) is { Length: > 0 } value)
                environment[name] = value;
        }
        if (environment.TryGetValue("USERPROFILE", out var home))
            environment["HOME"] = home;
        return environment;
    }

    /// <summary><c>%APPDATA%\npm</c>, <c>%USERPROFILE%\.local\bin</c>, <c>%USERPROFILE%\scoop\shims</c>, <c>%LOCALAPPDATA%\Programs</c>.</summary>
    internal static List<string> KnownDirectories(Func<string, string?> variable)
    {
        var directories = new List<string>();
        void Add(string name, string relative)
        {
            if (variable(name) is { Length: > 0 } root)
                directories.Add(System.IO.Path.Combine(root, relative));
        }
        Add("APPDATA", "npm");
        Add("USERPROFILE", System.IO.Path.Combine(".local", "bin"));
        Add("USERPROFILE", System.IO.Path.Combine("scoop", "shims"));
        Add("LOCALAPPDATA", "Programs");
        return directories;
    }

    /// <summary><paramref name="basePath"/> then <paramref name="extra"/>, joined with <c>;</c>; relative and repeated entries dropped.</summary>
    internal static string MergedPath(string basePath, IEnumerable<string> extra) =>
        string.Join(Separator, Directories(string.Join(Separator, basePath.Split(Separator).Concat(extra))));

    /// <summary>The fully qualified entries of a PATH, deduplicated (case-insensitive, like Windows paths).</summary>
    internal static List<string> Directories(string path) =>
        path.Split(Separator)
            .Select(entry => entry.Trim().Trim('"'))
            .Where(entry => entry.Length > 0 && System.IO.Path.IsPathFullyQualified(entry))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

    /// <summary>
    /// Machine PATH, then user PATH (REG_EXPAND_SZ expanded); this process's PATH when the registry has none or is
    /// not there (the Mac test run).
    /// </summary>
    private static string RegistryPath()
    {
        var parts = new List<string>();
        if (OperatingSystem.IsWindows())
        {
            foreach (var (root, key) in new[]
                     {
                         (Registry.LocalMachine, @"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"),
                         (Registry.CurrentUser, "Environment"),
                     })
            {
                try
                {
                    using var subKey = root.OpenSubKey(key);
                    if (subKey?.GetValue("Path") is string value && value.Length > 0)
                        parts.Add(value);
                }
                catch (Exception error) when (error is System.Security.SecurityException or IOException or UnauthorizedAccessException)
                {
                    // Unreadable: fall back below.
                }
            }
        }
        return parts.Count > 0 ? string.Join(Separator, parts) : Environment.GetEnvironmentVariable("PATH") ?? "";
    }

    private static CliExecutable? Native(string path) =>
        IsLaunchable(path) && File.Exists(path) ? new(path, [], path) : null;

    /// <summary>A <c>.exe</c> that is not cmd.exe.</summary>
    private static bool IsLaunchable(string path)
    {
        var name = System.IO.Path.GetFileName(path);
        return name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) && !name.Equals("cmd.exe", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// The npm shim at <paramref name="shimPath"/> as <c>node.exe &lt;script&gt;</c>: <c>node.exe</c> next to the shim
    /// when there is one (the shim's own rule), else the first <c>node.exe</c> on <see cref="Path"/>. Null when the shim,
    /// its script or node is missing, or the shim is not in a known format.
    /// </summary>
    private CliExecutable? Shim(string shimPath)
    {
        string text;
        try
        {
            var info = new FileInfo(shimPath);
            // A real shim is under 1 KB.
            if (!info.Exists || info.Length > 16 * 1024)
                return null;
            text = File.ReadAllText(shimPath);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
        if (ShimScript(text) is not { } script)
            return null;
        var directory = System.IO.Path.GetFullPath(System.IO.Path.GetDirectoryName(shimPath)!);
        var scriptPath = System.IO.Path.GetFullPath(
            System.IO.Path.Combine(directory, script.Replace('\\', System.IO.Path.DirectorySeparatorChar)));
        // The script must stay inside the shim's folder (no `..` out of it); the separator keeps C:\npm2 out of C:\npm. A
        // drive or share root already ends with one (C:\), so it is not doubled.
        var inside = System.IO.Path.EndsInDirectorySeparator(directory) ? directory : directory + System.IO.Path.DirectorySeparatorChar;
        if (!scriptPath.StartsWith(inside, StringComparison.OrdinalIgnoreCase) || !File.Exists(scriptPath))
            return null;
        var node = Native(System.IO.Path.Combine(directory, "node.exe"))
                   ?? Directories(Path).Select(entry => Native(System.IO.Path.Combine(entry, "node.exe"))).FirstOrDefault(found => found is not null);
        return node is null ? null : new(node.FileName, [scriptPath], shimPath);
    }

    /// <summary>
    /// The JS entry (relative to the shim's folder, as written in it) of an npm <c>.cmd</c> shim, in one of the formats
    /// npm's cmd-shim writes for a <c>#!/usr/bin/env node</c> script without arguments:
    /// <list type="bullet">
    /// <item>cmd-shim 2-3 (also pnpm): <c>"%~dp0\node.exe"  "%~dp0\&lt;script&gt;" %*</c>.</item>
    /// <item>cmd-shim 4+ (npm 7+): <c>SET "_prog=%dp0%\node.exe"</c> / <c>SET "_prog=node"</c>, then
    /// <c>... &amp; "%_prog%"  "%dp0%\&lt;script&gt;" %*</c>.</item>
    /// </list>
    /// Null for anything else: another program (a bash or pwsh shebang), shebang arguments, text after <c>%*</c>, more
    /// than one script, a script path with cmd metacharacters, or a rooted, drive or UNC script path. Nothing in the
    /// shim is ever run.
    /// </summary>
    internal static string? ShimScript(string text)
    {
        var scripts = OldShimLine().Matches(text).Select(match => match.Groups["script"].Value).ToList();
        var newLines = NewShimLine().Matches(text);
        if (newLines.Count > 0)
        {
            // The program must be node: exactly the two _prog assignments of a node shim.
            var programs = ProgAssignment().Matches(text).Select(match => match.Groups["program"].Value).ToList();
            if (programs.Count != 2 || !programs.Contains(@"%dp0%\node.exe") || !programs.Contains("node"))
                return null;
            scripts.AddRange(newLines.Select(match => match.Groups["script"].Value));
        }
        if (scripts.Count == 0 || scripts.Distinct(StringComparer.Ordinal).Count() != 1)
            return null;
        var script = scripts[0];
        if (script.Length == 0 || script.Any(c => char.IsControl(c) || "\"%!^&|<>".Contains(c)))
            return null;
        // Path.Combine would drop the shim's folder for a drive-rooted, rooted or UNC script (an NTLM leak for UNC).
        if (script.Contains(':') || script[0] is '\\' or '/')
            return null;
        return script;
    }

    [GeneratedRegex("""^[ \t]*"%~dp0\\node\.exe"[ \t]+"%~dp0\\(?<script>[^"\r\n]*)"[ \t]+%\*[ \t]*\r?$""", RegexOptions.Multiline)]
    private static partial Regex OldShimLine();

    [GeneratedRegex("""^endLocal & goto #_undefined_# 2>NUL \|\| title %COMSPEC% & "%_prog%"[ \t]+"%dp0%\\(?<script>[^"\r\n]*)"[ \t]+%\*[ \t]*\r?$""", RegexOptions.Multiline | RegexOptions.IgnoreCase)]
    private static partial Regex NewShimLine();

    [GeneratedRegex("""_prog=(?<program>[^"\r\n]*)""", RegexOptions.IgnoreCase)]
    private static partial Regex ProgAssignment();
}
