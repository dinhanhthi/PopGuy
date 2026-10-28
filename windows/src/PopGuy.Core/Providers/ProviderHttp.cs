using System.Diagnostics;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace PopGuy.Core.Providers;

/// <summary>
/// The HTTP plumbing shared by every HTTP adapter (a port of HTTPClient.swift): one HttpClient, explicit timeouts,
/// non-2xx responses thrown as <see cref="ProviderError.Http"/> with a bounded, redacted body.
/// <para>
/// Timeouts. macOS sets none, so Apple's defaults apply (60 s idle per request, 7-day resource limit); spec-2 §3.0
/// asks a port to pick explicit values. <see cref="IdleTimeout"/> keeps Apple's 60 s and bounds the wait for the
/// response headers and for every body read; <see cref="TotalTimeout"/> bounds the whole call (HttpClient.Timeout stops
/// governing once the headers of a streamed response arrive, so it is disabled and both run on one token source).
/// A timeout throws <c>Transport error: The request timed out.</c>; cancelling the caller's token throws
/// OperationCanceledException as usual.
/// </para>
/// <para>
/// Secrets. Adapters pass the API key in; it is never logged, and every error text built here (HTTP bodies, transport
/// messages) goes through <see cref="Redact"/> first.
/// </para>
/// Each request message is single-use: a retry must build a new one.
/// </summary>
public sealed class ProviderHttp
{
    public static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan IdleTimeout = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan TotalTimeout = TimeSpan.FromMinutes(10);

    /// <summary>At most this much of an error body is read; the message then keeps its first 200 characters.</summary>
    public const int MaxErrorBodyBytes = 4096;

    private const string Redacted = "[redacted]";

    // Credentials an error body or exception message may echo, beyond the exact key passed in.
    private static readonly Regex[] SecretPatterns =
    [
        new(@"(?<=\b(?:Bearer|DeepL-Auth-Key)\s+)[^\s""',;]+", RegexOptions.IgnoreCase),
        new(@"(?<=[?&](?:key|api_key|apikey|auth_key|access_token)=)[^&\s""'#]+", RegexOptions.IgnoreCase),
        new(@"\bsk-[A-Za-z0-9_\-]{8,}"),
        new(@"\bAIza[0-9A-Za-z_\-]{20,}"),
    ];

    /// <summary>The app-wide instance; like macOS's ephemeral session it keeps no cookies or credentials.</summary>
    public static ProviderHttp Shared { get; } = new(CreateSharedHandler());

    // No redirects: one would forward the key (custom headers, the query) and, for 307/308, the POST body to another
    // host. No provider API redirects, so a 3xx surfaces as an HTTP error.
    internal static SocketsHttpHandler CreateSharedHandler() => new()
    {
        ConnectTimeout = ConnectTimeout,
        UseCookies = false,
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        AllowAutoRedirect = false,
    };

    private readonly HttpClient _client;

    /// <summary>Tests inject a fake handler; the app uses <see cref="Shared"/>.</summary>
    public ProviderHttp(HttpMessageHandler handler) =>
        _client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };

    /// <summary>Sends a streaming request and yields its SSE data payloads (see <see cref="SseDecoder"/>).</summary>
    public async IAsyncEnumerable<string> StreamSseAsync(
        HttpRequestMessage request, string? apiKey, [EnumeratorCancellation] CancellationToken ct = default)
    {
        using var ownedRequest = request;
        using var deadline = new Deadline(ct);
        using var response = await SendCheckedAsync(request, apiKey, deadline);
        await using var payloads = SseDecoder.DecodeAsync(await OpenBodyAsync(response, deadline), deadline.Token)
            .GetAsyncEnumerator();
        while (true)
        {
            try
            {
                if (!await payloads.MoveNextAsync())
                    yield break;
            }
            catch (Exception ex) when (Translate(ex, ct, apiKey) is { } error)
            {
                throw error;
            }
            yield return payloads.Current;
        }
    }

    /// <summary>Sends a plain request and returns its whole body (the non-streaming translation providers).</summary>
    public async Task<string> SendAsync(HttpRequestMessage request, string? apiKey, CancellationToken ct = default)
    {
        using var ownedRequest = request;
        using var deadline = new Deadline(ct);
        using var response = await SendCheckedAsync(request, apiKey, deadline);
        try
        {
            using var reader = new StreamReader(await OpenBodyAsync(response, deadline), Encoding.UTF8);
            return await reader.ReadToEndAsync(deadline.Token);
        }
        catch (Exception ex) when (Translate(ex, ct, apiKey) is { } error)
        {
            throw error;
        }
    }

    /// <summary>
    /// Sends a plain request and returns its whole body as bytes (cloud TTS and dictionary audio). A body over
    /// <paramref name="maxBytes"/> throws <see cref="ProviderErrorKind.UnexpectedResponse"/> once the cap is passed.
    /// </summary>
    public async Task<byte[]> SendBytesAsync(
        HttpRequestMessage request, string? apiKey, CancellationToken ct = default, int maxBytes = int.MaxValue)
    {
        using var ownedRequest = request;
        using var deadline = new Deadline(ct);
        using var response = await SendCheckedAsync(request, apiKey, deadline);
        try
        {
            await using var body = await OpenBodyAsync(response, deadline);
            using var buffer = new MemoryStream();
            var chunk = new byte[81920];
            int read;
            while ((read = await body.ReadAsync(chunk, deadline.Token)) > 0)
            {
                if (buffer.Length + read > maxBytes)
                    throw ProviderError.UnexpectedResponse("The response is too large.");
                buffer.Write(chunk, 0, read);
            }
            return buffer.ToArray();
        }
        catch (Exception ex) when (Translate(ex, ct, apiKey) is { } error)
        {
            throw error;
        }
    }

    /// <summary>Replaces the exact key (raw or percent-encoded) and common credential shapes with a placeholder.</summary>
    public static string Redact(string text, string? apiKey)
    {
        if (!string.IsNullOrEmpty(apiKey))
        {
            var escaped = Uri.EscapeDataString(apiKey);
            if (escaped != apiKey)
                text = text.Replace(escaped, Redacted, StringComparison.Ordinal);
            text = text.Replace(apiKey, Redacted, StringComparison.Ordinal);
        }
        foreach (var pattern in SecretPatterns)
            text = pattern.Replace(text, Redacted);
        return text;
    }

    /// <summary>Drops the <c>user:password@</c> part of a URL echoed in an error, even when the string does not parse.</summary>
    internal static string StripUserInfo(string url)
    {
        var start = url.IndexOf("://", StringComparison.Ordinal);
        if (start < 0)
            return url;
        start += 3;
        var end = url.IndexOfAny(['/', '?', '#'], start);
        if (end < 0)
            end = url.Length;
        var at = url.LastIndexOf('@', end - 1, end - start);
        return at < 0 ? url : url[..start] + url[(at + 1)..];
    }

    private async Task<HttpResponseMessage> SendCheckedAsync(HttpRequestMessage request, string? apiKey, Deadline deadline)
    {
        HttpResponseMessage? response = null;
        try
        {
            deadline.Touch();
            response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            if (response.IsSuccessStatusCode)
                return response;

            var status = (int)response.StatusCode;
            var body = await ReadCappedAsync(await OpenBodyAsync(response, deadline), deadline.Token);
            throw ProviderError.Http(status, Redact(body, apiKey));
        }
        catch (Exception ex) when (Translate(ex, deadline.CallerToken, apiKey) is { } error)
        {
            response?.Dispose();
            throw error;
        }
        catch
        {
            response?.Dispose();
            throw;
        }
    }

    private static async Task<Stream> OpenBodyAsync(HttpResponseMessage response, Deadline deadline) =>
        new IdleTimeoutStream(await response.Content.ReadAsStreamAsync(deadline.Token), deadline);

    private static async Task<string> ReadCappedAsync(Stream body, CancellationToken ct)
    {
        var buffer = new byte[MaxErrorBodyBytes];
        int length = 0, read;
        while (length < buffer.Length && (read = await body.ReadAsync(buffer.AsMemory(length), ct)) > 0)
            length += read;
        return Encoding.UTF8.GetString(buffer, 0, length);
    }

    // Maps a failure to the error the user sees; null passes it through (ProviderError, or the caller's cancellation).
    private static ProviderError? Translate(Exception ex, CancellationToken callerToken, string? apiKey) => ex switch
    {
        ProviderError => null,
        OperationCanceledException when callerToken.IsCancellationRequested => null,
        OperationCanceledException => ProviderError.Transport("The request timed out."),
        HttpRequestException or IOException => ProviderError.Transport(Redact(ex.Message, apiKey)),
        _ => null,
    };

    /// <summary>One token for a call: the caller's cancellation, the idle timeout (re-armed per read) and the total.</summary>
    private sealed class Deadline(CancellationToken callerToken) : IDisposable
    {
        private readonly CancellationTokenSource _source = CancellationTokenSource.CreateLinkedTokenSource(callerToken);
        private readonly Stopwatch _elapsed = Stopwatch.StartNew();

        public CancellationToken CallerToken => callerToken;

        public CancellationToken Token => _source.Token;

        /// <summary>Re-arms the timer before an await on the network: the idle timeout, capped by the time left.</summary>
        public void Touch()
        {
            var left = TotalTimeout - _elapsed.Elapsed;
            if (left <= TimeSpan.Zero)
                _source.Cancel();
            else
                _source.CancelAfter(left < IdleTimeout ? left : IdleTimeout);
        }

        public void Dispose() => _source.Dispose();
    }

    /// <summary>
    /// A read-only body stream that re-arms the deadline before every read and always reads with its token, whatever
    /// token the reader above passes down.
    /// </summary>
    private sealed class IdleTimeoutStream(Stream inner, Deadline deadline) : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }

        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
        {
            deadline.Touch();
            return inner.ReadAsync(buffer, deadline.Token);
        }

        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) =>
            ReadAsync(buffer.AsMemory(offset, count), ct).AsTask();

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        protected override void Dispose(bool disposing)
        {
            if (disposing)
                inner.Dispose();
            base.Dispose(disposing);
        }
    }
}

/// <summary>
/// JSON helpers shared by the adapters. Lookups are lenient, as macOS's optional casts: a missing key or a value of
/// another shape reads as null, so a payload that does not match is skipped rather than thrown.
/// </summary>
internal static class ProviderJson
{
    /// <summary>A request body sent as <c>Content-Type: application/json</c> (no charset, as on macOS).</summary>
    public static StringContent Content(JsonObject body) =>
        new(body.ToJsonString(), new MediaTypeHeaderValue("application/json"));

    /// <summary>The root of <paramref name="payload"/>, or null when it is not JSON.</summary>
    public static JsonElement? Parse(string payload)
    {
        try
        {
            using var doc = JsonDocument.Parse(payload);
            return doc.RootElement.Clone();
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static JsonElement? Get(this JsonElement? element, string key) =>
        element is { ValueKind: JsonValueKind.Object } obj && obj.TryGetProperty(key, out var value) ? value : null;

    public static JsonElement? First(this JsonElement? element) =>
        element is { ValueKind: JsonValueKind.Array } array && array.GetArrayLength() > 0 ? array[0] : null;

    public static IEnumerable<JsonElement> Items(this JsonElement? element) =>
        element is { ValueKind: JsonValueKind.Array } array ? array.EnumerateArray() : [];

    public static string? String(this JsonElement? element) =>
        element is { ValueKind: JsonValueKind.String } value ? value.GetString() : null;
}
