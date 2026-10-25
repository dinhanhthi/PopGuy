using System.Globalization;

namespace PopGuy.Core.Providers;

// The provider contract of the macOS app (spec-2 §2.9, §3.0). Swift sources: Provider.swift, ProviderTypes.swift.

/// <summary>A pluggable AI or translation provider; callers never know which one is in use.</summary>
public interface IProvider
{
    /// <summary>
    /// Streams token deltas. Non-streaming providers yield their single result once. Throws <see cref="ProviderError"/>
    /// on transport, HTTP, decoding or API failures; cancelling <paramref name="ct"/> stops the request.
    /// </summary>
    /// <param name="systemPrompt">Optional system prompt; translation providers ignore it.</param>
    /// <param name="input">The user text to process.</param>
    /// <param name="model">The model id configured for the action.</param>
    IAsyncEnumerable<string> StreamAsync(
        string? systemPrompt, string input, string model, ProviderOptions options, CancellationToken ct = default);
}

/// <summary>Per-call options; each adapter reads only the fields its API uses.</summary>
public sealed record ProviderOptions
{
    /// <summary>Target language for translation (DeepL expects uppercase codes, Google lowercase BCP-47).</summary>
    public string? TargetLanguage { get; init; }

    /// <summary>Source language hint for translation; null lets the provider auto-detect.</summary>
    public string? SourceLanguage { get; init; }

    /// <summary>
    /// Endpoint override, honoured by Ollama, the OpenAI adapter for GLM, OpenRouter and Custom, and Gemini. Null: the
    /// adapter's own base URL.
    /// </summary>
    public Uri? BaseUrl { get; init; }

    /// <summary>Completion token cap (Anthropic requires max_tokens).</summary>
    public int MaxTokens { get; init; } = 4096;

    /// <summary>Path of a local CLI binary, for the CLI providers.</summary>
    public string? ExecutablePath { get; init; }

    /// <summary>DeepL formality ("prefer_more" or "prefer_less"), from the action's tone; DeepL only.</summary>
    public string? Formality { get; init; }
}

/// <summary>The case of a <see cref="ProviderError"/>.</summary>
public enum ProviderErrorKind
{
    Transport,
    Http,
    DecodingFailed,
    MissingOption,
    UnexpectedResponse,
    Api,
}

/// <summary>
/// A provider failure. <see cref="Exception.Message"/> is the user-facing text shown in the toolbar and stored in
/// history, verbatim from the macOS app. It never carries an inner exception, so <see cref="Exception.ToString"/>
/// prints nothing beyond the (redacted) message and the stack.
/// </summary>
public sealed class ProviderError : Exception
{
    /// <summary>The number of text elements of an HTTP error body kept in the message.</summary>
    public const int HttpBodySnippetLength = 200;

    private ProviderError(ProviderErrorKind kind, string message, int? statusCode = null) : base(message)
    {
        Kind = kind;
        StatusCode = statusCode;
    }

    public ProviderErrorKind Kind { get; }

    /// <summary>The HTTP status (or a CLI's exit code) of an <see cref="ProviderErrorKind.Http"/> error.</summary>
    public int? StatusCode { get; }

    /// <summary>A network failure, timeout or invalid endpoint.</summary>
    public static ProviderError Transport(string message) => new(ProviderErrorKind.Transport, $"Transport error: {message}");

    /// <summary>A non-2xx response (or a CLI's non-zero exit). The body must already be redacted.</summary>
    public static ProviderError Http(int statusCode, string? body)
    {
        var snippet = string.IsNullOrEmpty(body) ? "(no body)" : Prefix(body, HttpBodySnippetLength);
        return new(ProviderErrorKind.Http, $"HTTP {statusCode}: {snippet}", statusCode);
    }

    public static ProviderError DecodingFailed(string message) =>
        new(ProviderErrorKind.DecodingFailed, $"Decoding failed: {message}");

    public static ProviderError MissingOption(string message) =>
        new(ProviderErrorKind.MissingOption, $"Missing option: {message}");

    public static ProviderError UnexpectedResponse(string message) =>
        new(ProviderErrorKind.UnexpectedResponse, $"Unexpected response: {message}");

    /// <summary>An in-stream error event after a 2xx response (Anthropic, Gemini, Claude CLI).</summary>
    public static ProviderError Api(string kind, string message) =>
        new(ProviderErrorKind.Api, $"API error ({kind}): {message}");

    // Swift's prefix(200) counts characters (grapheme clusters), so a cut never splits a surrogate pair or an emoji.
    private static string Prefix(string text, int length)
    {
        var info = new StringInfo(text);
        return info.LengthInTextElements <= length ? text : info.SubstringByTextElements(0, length);
    }
}
