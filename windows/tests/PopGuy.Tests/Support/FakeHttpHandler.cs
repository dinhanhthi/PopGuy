using System.Net;
using System.Text;

namespace PopGuy.Tests.Support;

/// <summary>A request as the handler saw it, snapshotted before the caller disposes the message.</summary>
public sealed record RecordedRequest(
    HttpMethod Method, Uri? Uri, IReadOnlyDictionary<string, string> Headers, string? Body);

/// <summary>
/// An offline <see cref="HttpMessageHandler"/>: records every request and answers each with the scripted status and
/// body. With <c>chunkSize</c> set, the body is delivered at most that many bytes per read, so a response can split
/// anywhere (between CR and LF, inside a multi-byte UTF-8 sequence).
/// </summary>
public sealed class FakeHttpHandler(HttpStatusCode status, string body, int chunkSize = int.MaxValue) : HttpMessageHandler
{
    public List<RecordedRequest> Requests { get; } = [];

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var headers = request.Headers.Concat(request.Content?.Headers ?? Enumerable.Empty<KeyValuePair<string, IEnumerable<string>>>())
            .ToDictionary(h => h.Key, h => string.Join(", ", h.Value), StringComparer.OrdinalIgnoreCase);
        var requestBody = request.Content is null ? null : await request.Content.ReadAsStringAsync(ct);
        Requests.Add(new RecordedRequest(request.Method, request.RequestUri, headers, requestBody));

        return new HttpResponseMessage(status)
        {
            RequestMessage = request,
            Content = new StreamContent(new ChunkedStream(Encoding.UTF8.GetBytes(body), chunkSize)),
        };
    }

    private sealed class ChunkedStream(byte[] data, int chunkSize) : MemoryStream(data, writable: false)
    {
        public override int Read(byte[] buffer, int offset, int count) => base.Read(buffer, offset, Math.Min(count, chunkSize));

        public override int Read(Span<byte> buffer) => base.Read(buffer[..Math.Min(buffer.Length, chunkSize)]);

        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) =>
            ReadAsync(buffer.AsMemory(offset, count), ct).AsTask();

        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            return ValueTask.FromResult(Read(buffer.Span));
        }
    }
}
