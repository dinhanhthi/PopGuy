using System.Net;
using PopGuy.Core.Providers;
using PopGuy.Tests.Support;

namespace PopGuy.Tests.Core;

// Contract: the shared HTTP plumbing and SSE decoder of every streaming adapter (spec-2 §2.9, §3.0).
public sealed class ProviderStreamTests
{
    private static async Task<List<string>> Payloads(FakeHttpHandler handler, string? apiKey = null)
    {
        var http = new ProviderHttp(handler);
        var request = new HttpRequestMessage(HttpMethod.Post, "https://api.example.test/v1/chat/completions");
        var payloads = new List<string>();
        await foreach (var payload in http.StreamSseAsync(request, apiKey, TestContext.Current.CancellationToken))
            payloads.Add(payload);
        return payloads;
    }

    [Fact]
    public async Task SseYieldsDataLinesAndStopsAtDone()
    {
        const string body =
            ": keep-alive\r\nevent: delta\r\nid: 7\r\nretry: 3000\r\ndata: {\"a\":1}\r\n\r\ndata:no-space\n\n" +
            "data:  two spaces\n\ndata: [DONE]\n\ndata: after done\n\n";

        var payloads = await Payloads(new FakeHttpHandler(HttpStatusCode.OK, body));

        Assert.Equal(["{\"a\":1}", "no-space", " two spaces"], payloads);
    }

    [Fact]
    public async Task SseSurvivesChunksSplitAtEveryByte()
    {
        // One byte per read splits CR from LF and every multi-byte UTF-8 sequence (é is 2 bytes, the emoji 4).
        const string body = "data: héllo 😀 wörld\r\n\r\ndata: 日本語\n\ndata: [DONE]\n\n";

        var payloads = await Payloads(new FakeHttpHandler(HttpStatusCode.OK, body, chunkSize: 1));

        Assert.Equal(["héllo 😀 wörld", "日本語"], payloads);
    }

    [Fact]
    public async Task ErrorBodyEchoingTheApiKeyIsRedacted()
    {
        // The key matches none of the generic patterns, so only the exact-key rule can remove it.
        const string apiKey = "pg-test-7f3a9c1e5b2d";
        var body = $$$"""{"error":{"message":"Incorrect API key provided: {{{apiKey}}}","header":"Bearer other-secret-token"}}""";
        var handler = new FakeHttpHandler(HttpStatusCode.Unauthorized, body);

        var error = await Assert.ThrowsAsync<ProviderError>(() => Payloads(handler, apiKey));

        Assert.Equal(ProviderErrorKind.Http, error.Kind);
        Assert.Equal(401, error.StatusCode);
        Assert.StartsWith("HTTP 401: {\"error\":{\"message\":\"Incorrect API key provided: ", error.Message);
        Assert.DoesNotContain(apiKey, error.ToString());
        Assert.DoesNotContain("other-secret-token", error.ToString());
    }
}
