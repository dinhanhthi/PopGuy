using System.Runtime.CompilerServices;

namespace PopGuy.Core.Providers.Cli;

/// <summary>
/// The Claude CLI under the user's Anthropic subscription (its own login, no API key; a port of
/// ClaudeCLIProvider.swift).
/// <list type="bullet">
/// <item><c>claude -p --output-format stream-json --include-partial-messages --verbose --tools "" --strict-mcp-config
/// --disallowedTools mcp__* --disable-slash-commands --permission-mode dontAsk --no-session-persistence</c>, then
/// <c>--model</c> when set and <c>--append-system-prompt</c> with the system prompt. <c>--tools ""</c> denies every
/// built-in tool and <c>--strict-mcp-config</c> every user MCP server, whatever the user pre-approved
/// (<c>--allowedTools ""</c> does not deny Bash); <c>--disallowedTools mcp__*</c> also denies any MCP tool,
/// <c>dontAsk</c> refuses whatever would need a permission, and <c>--no-session-persistence</c> keeps the selected
/// text out of the CLI's saved sessions (Windows only; macOS passes none of these four).</item>
/// <item>The selected text, framed as data, goes to stdin (macOS passes it as the positional prompt).</item>
/// <item>Yields <c>delta.text</c> of <c>stream_event</c> lines whose event is a <c>content_block_delta</c> with a
/// <c>text_delta</c>; the aggregate <c>assistant</c> line is skipped (it would double the answer). A <c>result</c> line
/// with <c>is_error</c> (true even with <c>subtype: success</c>, e.g. "Not logged in") throws
/// <see cref="ProviderError.Api"/>; when no delta came, a successful result's text is yielded once.</item>
/// </list>
/// </summary>
public sealed class ClaudeCliProvider(CliRunner runner) : IProvider
{
    private const string Name = "claude";

    public IAsyncEnumerable<string> StreamAsync(
        string? systemPrompt, string input, string model, ProviderOptions options, CancellationToken ct = default) =>
        ParseAsync(
            runner.StreamLinesAsync(Name, options.ExecutablePath, Arguments(systemPrompt, model), CliRunner.DataPrompt(null, input), ct: ct),
            ct);

    /// <summary>
    /// The argv after the executable. The system prompt is PopGuy's instruction, never the selected text; passing it
    /// here (not in the data prompt) keeps it from being sent twice.
    /// </summary>
    internal static IReadOnlyList<string> Arguments(string? systemPrompt, string model)
    {
        List<string> arguments =
        [
            "-p",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--tools", "",
            "--strict-mcp-config",
            "--disallowedTools", "mcp__*",
            "--disable-slash-commands",
            "--permission-mode", "dontAsk",
            "--no-session-persistence",
        ];
        if (CliRunner.SafeModel(model) is { } safe)
            arguments.AddRange(["--model", safe]);
        if (systemPrompt is not null)
            arguments.AddRange(["--append-system-prompt", systemPrompt]);
        return arguments;
    }

    /// <summary>The answer text of <paramref name="lines"/> (the CLI's stdout lines).</summary>
    internal static async IAsyncEnumerable<string> ParseAsync(
        IAsyncEnumerable<string> lines, [EnumeratorCancellation] CancellationToken ct = default)
    {
        var seenDelta = false;
        string? result = null;
        await foreach (var line in lines.WithCancellation(ct))
        {
            switch (ParseLine(line))
            {
                case { IsResult: false } delta:
                    seenDelta = true;
                    yield return delta.Text;
                    break;
                case { IsError: true } error:
                    throw ProviderError.Api(
                        "claude_cli",
                        ProviderHttp.Redact(error.Text.Length > 0 ? error.Text : "Claude CLI reported an error.", apiKey: null));
                case { } success:
                    result = success.Text;
                    break;
            }
        }
        // Fallback for a mode without deltas: the final result's text, once.
        if (!seenDelta && !string.IsNullOrEmpty(result))
            yield return result;
    }

    /// <summary>One stdout line: a text delta, the final result, or null for every other event. Pure, for tests.</summary>
    internal static ClaudeCliLine? ParseLine(string line)
    {
        var json = ProviderJson.Parse(line);
        switch (json.Get("type").String())
        {
            case "stream_event":
                var evt = json.Get("event");
                var delta = evt.Get("delta");
                return evt.Get("type").String() == "content_block_delta" && delta.Get("type").String() == "text_delta"
                       && delta.Get("text").String() is { Length: > 0 } text
                    ? new ClaudeCliLine(text, IsResult: false, IsError: false)
                    : null;
            case "result":
                // Gate on is_error, not subtype.
                return new ClaudeCliLine(
                    json.Get("result").String() ?? "", IsResult: true,
                    IsError: json.Get("is_error") is { ValueKind: System.Text.Json.JsonValueKind.True });
            default:
                // system, assistant (the aggregate), rate_limit_event and any future event.
                return null;
        }
    }
}

/// <summary>A Claude CLI line that matters: a text delta, or the final result (<see cref="IsResult"/>).</summary>
internal readonly record struct ClaudeCliLine(string Text, bool IsResult, bool IsError);
