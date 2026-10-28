using System.Runtime.CompilerServices;
using System.Text;

namespace PopGuy.Core.Providers;

/// <summary>
/// Decodes a Server-Sent Events body into its data payloads (spec-2 §3.0, a port of SSEDecoder.swift). Neutral: each
/// adapter parses its own JSON from the payloads.
/// <list type="bullet">
/// <item>Only <c>data:</c> lines count; the prefix and at most one following space are dropped.</item>
/// <item>The payload <c>[DONE]</c> ends the stream and is not yielded.</item>
/// <item><c>event:</c>, <c>id:</c>, <c>retry:</c>, comment and blank lines are skipped.</item>
/// <item>Multi-line data events are not joined: each <c>data:</c> line is its own payload, as on macOS.</item>
/// </list>
/// Lines end at LF, CRLF or CR. Reads may split anywhere, including inside a UTF-8 sequence: the reader's decoder
/// keeps partial sequences across reads.
/// </summary>
public static class SseDecoder
{
    private const string DataPrefix = "data:";

    public static async IAsyncEnumerable<string> DecodeAsync(Stream body, [EnumeratorCancellation] CancellationToken ct = default)
    {
        using var reader = new StreamReader(body, new UTF8Encoding(false), detectEncodingFromByteOrderMarks: false);
        while (await reader.ReadLineAsync(ct) is { } line)
        {
            if (!line.StartsWith(DataPrefix, StringComparison.Ordinal))
                continue;
            var payload = line[DataPrefix.Length..];
            if (payload.StartsWith(' '))
                payload = payload[1..];
            if (payload == "[DONE]")
                yield break;
            yield return payload;
        }
    }
}
