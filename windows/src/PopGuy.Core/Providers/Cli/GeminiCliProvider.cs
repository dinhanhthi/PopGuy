using System.Runtime.CompilerServices;

namespace PopGuy.Core.Providers.Cli;

/// <summary>
/// The Gemini CLI under the user's Google subscription (its own login file, no API key; a port of
/// GeminiCLIProvider.swift).
/// <list type="bullet">
/// <item><c>gemini -p "" --approval-mode plan --output-format stream-json</c>, then <c>--model</c> when set.
/// <c>--approval-mode plan</c> keeps tools read-only. macOS passes the prompt as the <c>-p</c> value; here it goes to
/// stdin, which the CLI puts before the (empty) <c>-p</c> value. The CLI waits only 500 ms for piped input, and
/// <see cref="CliRunner"/> writes it right after the start.</item>
/// <item>The system prompt and the selected text, framed as data, are one prompt.</item>
/// <item>Yields <c>content</c> of <c>message</c> lines from the assistant with <c>delta: true</c> (a non-delta message
/// is the aggregate and would double the answer). Text before the first <c>{</c> of a line is dropped: the CLI can glue
/// a notice such as "MCP issues detected." to the first JSON object. An <c>error</c> line (except a warning, such as
/// "Loop detected") and an error <c>result</c> throw <see cref="ProviderError.Api"/> (Windows only; macOS relies on the
/// exit code).</item>
/// </list>
/// </summary>
public sealed class GeminiCliProvider(CliRunner runner) : IProvider
{
    private const string Name = "gemini";

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
            "-p", "",
            "--approval-mode", "plan",
            "--output-format", "stream-json",
        ];
        if (CliRunner.SafeModel(model) is { } safe)
            arguments.AddRange(["--model", safe]);
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
    /// The assistant delta of one stdout line, or null for every other event (init, the user echo, a successful
    /// result). Throws on an error event. Pure, for tests.
    /// </summary>
    internal static string? ParseLine(string line)
    {
        var brace = line.IndexOf('{');
        if (brace < 0)
            return null;
        var json = ProviderJson.Parse(line[brace..]);
        return json.Get("type").String() switch
        {
            "message" when json.Get("role").String() == "assistant"
                           && json.Get("delta") is { ValueKind: System.Text.Json.JsonValueKind.True }
                           && json.Get("content").String() is { Length: > 0 } content => content,
            "error" when json.Get("severity").String() != "warning" => throw Error(json.Get("message").String()),
            "result" when json.Get("status").String() == "error" => throw Error(json.Get("error").Get("message").String()),
            _ => null,
        };
    }

    private static ProviderError Error(string? message) =>
        ProviderError.Api("gemini_cli", ProviderHttp.Redact(message is { Length: > 0 } ? message : "Gemini CLI failed.", apiKey: null));
}
