using System.Runtime.CompilerServices;

namespace PopGuy.Core.Providers.Cli;

/// <summary>
/// The Codex CLI under the user's OpenAI subscription (its own login file, no API key; a port of
/// CodexCLIProvider.swift).
/// <list type="bullet">
/// <item><c>codex exec --json --sandbox read-only --skip-git-repo-check --ephemeral -c model_reasoning_effort=low</c>,
/// then <c>-m</c> when set, then <c>-</c>: Codex reads the prompt from stdin. Low reasoning effort avoids the slow
/// default loop; the git check is skipped because the working directory is an empty temp folder.</item>
/// <item>Codex has no system role: the system prompt and the selected text, framed as data, are one prompt.</item>
/// <item>Yields the text of each <c>item.completed</c> line whose item is an <c>agent_message</c> (one whole message,
/// no token deltas). A <c>turn.failed</c> line throws <see cref="ProviderError.Api"/> (Windows only; macOS relies on
/// the exit code). <c>error</c> lines are skipped: Codex also sends them for retries it recovers from, and a fatal one
/// ends in <c>turn.failed</c> or a failed exit.</item>
/// </list>
/// </summary>
public sealed class CodexCliProvider(CliRunner runner) : IProvider
{
    private const string Name = "codex";

    public IAsyncEnumerable<string> StreamAsync(
        string? systemPrompt, string input, string model, ProviderOptions options, CancellationToken ct = default) =>
        ParseAsync(
            runner.StreamLinesAsync(Name, options.ExecutablePath, Arguments(model), CliRunner.DataPrompt(systemPrompt, input), ct),
            ct);

    /// <summary>The argv after the executable.</summary>
    internal static IReadOnlyList<string> Arguments(string model)
    {
        List<string> arguments =
        [
            "exec",
            "--json",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--ephemeral",
            "-c", "model_reasoning_effort=low",
        ];
        if (CliRunner.SafeModel(model) is { } safe)
            arguments.AddRange(["-m", safe]);
        arguments.Add("-");
        return arguments;
    }

    /// <summary>The answer text of <paramref name="lines"/> (the CLI's stdout lines).</summary>
    internal static async IAsyncEnumerable<string> ParseAsync(
        IAsyncEnumerable<string> lines, [EnumeratorCancellation] CancellationToken ct = default)
    {
        await foreach (var line in lines.WithCancellation(ct))
        {
            if (ParseLine(line) is { } text)
                yield return text;
        }
    }

    /// <summary>
    /// The agent message of one stdout line, or null for every other event (thread/turn control, reasoning, commands).
    /// Throws on <c>turn.failed</c>. Pure, for tests.
    /// </summary>
    internal static string? ParseLine(string line)
    {
        var json = ProviderJson.Parse(line);
        var item = json.Get("item");
        return json.Get("type").String() switch
        {
            "item.completed" when item.Get("type").String() == "agent_message" => item.Get("text").String(),
            "turn.failed" => throw Error(json.Get("error").Get("message").String()),
            _ => null,
        };
    }

    private static ProviderError Error(string? message) =>
        ProviderError.Api("codex_cli", ProviderHttp.Redact(message is { Length: > 0 } ? message : "Codex CLI failed.", apiKey: null));
}
