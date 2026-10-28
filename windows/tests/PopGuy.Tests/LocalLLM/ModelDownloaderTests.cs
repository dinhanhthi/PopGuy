using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using PopGuy.LocalLLM;

namespace PopGuy.Tests.LocalLLM;

// Security of the GGUF downloader: only catalog files at their pinned revision, over https, land in the Models folder,
// and only after their size and SHA-256 match. Tests use a small allowlist of their own (the real models are GBs),
// passed through the downloader's internal constructor, and a scripted handler: no network.
public sealed class ModelDownloaderTests : IDisposable
{
    private const string Revision = "0123456789abcdef0123456789abcdef01234567";
    private static readonly byte[] Data = [.. Enumerable.Range(0, 1000).Select(i => (byte)(i * 7))];
    private static readonly GgufModel Model = new(
        "gguf-test", "Test", "unsloth/Test-GGUF", Revision, "Test-Q4_K_M.gguf", Data.Length,
        Convert.ToHexStringLower(SHA256.HashData(Data)), 4096, 1000);

    private readonly string _dir = Path.Combine(Path.GetTempPath(), "PopGuyTests-" + Guid.NewGuid().ToString("N"));
    private readonly ScriptedHandler _hub = new();

    public void Dispose()
    {
        if (Directory.Exists(_dir)) Directory.Delete(_dir, recursive: true);
    }

    private string Final => Path.Combine(_dir, Model.File);

    private string Part => Final + ".part";

    private ModelDownloader Downloader(params GgufModel[] catalog) =>
        new(_dir, new HttpClient(_hub), catalog.Length == 0 ? [Model] : catalog);

    // The pinned resolve URL answers with a redirect to HF's CDN (followed, https), whose body becomes the final file
    // through a single atomic rename: nothing else is left in the folder, and PathFor finds it.
    [Fact]
    public async Task ADownloadFollowsTheHttpsRedirectAndLeavesOnlyTheFinalFile()
    {
        var cdn = new Uri("https://cas-bridge.xethub.hf.co/xet/abc?sig=1");
        _hub.Reply = request => request.RequestUri == cdn ? Body(HttpStatusCode.OK, Data) : Redirect(cdn);
        var downloader = Downloader();
        var progress = new SyncProgress();

        await downloader.DownloadAsync(Model, progress, TestContext.Current.CancellationToken);

        Assert.Equal($"https://huggingface.co/unsloth/Test-GGUF/resolve/{Revision}/Test-Q4_K_M.gguf", _hub.Requests[0].Uri.AbsoluteUri);
        Assert.Equal([Final], Directory.EnumerateFileSystemEntries(_dir));
        Assert.Equal(Data, File.ReadAllBytes(Final));
        Assert.Equal(Final, downloader.PathFor(Model));
        Assert.Equal(new ModelDownloadProgress(Data.Length, Data.Length), progress.Last);
    }

    // A body of the right size but the wrong bytes is deleted: no partial file, no final file.
    [Fact]
    public async Task AShaMismatchDeletesThePartialFile()
    {
        var wrong = Data.ToArray();
        wrong[500] ^= 0xFF;
        _hub.Reply = _ => Body(HttpStatusCode.OK, wrong);
        var downloader = Downloader();

        var error = await Assert.ThrowsAsync<ModelDownloadException>(() =>
            downloader.DownloadAsync(Model, null, TestContext.Current.CancellationToken));

        Assert.Equal(ModelDownloadError.ChecksumMismatch, error.Kind);
        Assert.False(File.Exists(Part));
        Assert.False(File.Exists(Final));
        Assert.Null(downloader.PathFor(Model));
    }

    // A file name that could leave the folder, or an entry missing from the catalog, fails before any request or write;
    // PathFor answers null for it instead of throwing.
    [Theory]
    [InlineData("..\\evil.gguf")]
    [InlineData("../evil.gguf")]
    [InlineData("/tmp/evil.gguf")]
    [InlineData("C:\\evil.gguf")]
    [InlineData("Other-Q4_K_M.gguf")] // Well formed, but not a catalog file.
    public async Task AnUnsafeOrUnknownFileNameIsRejected(string file)
    {
        var hostile = Model with { File = file };
        var downloader = Downloader();

        var error = await Assert.ThrowsAsync<ModelDownloadException>(() =>
            downloader.DownloadAsync(hostile, null, TestContext.Current.CancellationToken));

        Assert.Equal(file.StartsWith("Other", StringComparison.Ordinal) ? ModelDownloadError.UnknownModel : ModelDownloadError.UnsafePath, error.Kind);
        Assert.Empty(_hub.Requests);
        Assert.False(Directory.Exists(_dir) && Directory.EnumerateFileSystemEntries(_dir).Any());
        Assert.Null(downloader.PathFor(hostile));
    }

    // A redirect to plain http is refused, and nothing is written.
    [Fact]
    public async Task ARedirectToHttpIsRefused()
    {
        _hub.Reply = _ => Redirect(new Uri("http://cdn.example.com/model.gguf"));

        var error = await Assert.ThrowsAsync<ModelDownloadException>(() =>
            Downloader().DownloadAsync(Model, null, TestContext.Current.CancellationToken));

        Assert.Equal(ModelDownloadError.InsecureRedirect, error.Kind);
        Assert.Single(_hub.Requests);
        Assert.False(File.Exists(Part));
        Assert.False(File.Exists(Final));
    }

    // An existing partial file is resumed with a Range request, the rest appended, and the whole file verified.
    [Fact]
    public async Task APartialFileIsResumedWithARangeRequest()
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllBytes(Part, Data[..400]);
        _hub.Reply = request =>
        {
            var response = Body(HttpStatusCode.PartialContent, Data[400..]);
            response.Content.Headers.ContentRange = new ContentRangeHeaderValue(400, Data.Length - 1, Data.Length);
            return response;
        };

        await Downloader().DownloadAsync(Model, null, TestContext.Current.CancellationToken);

        Assert.Equal("bytes=400-", _hub.Requests[0].Range);
        Assert.Equal(Data, File.ReadAllBytes(Final));
        Assert.False(File.Exists(Part));
    }

    // Cancelling keeps what was downloaded for a later resume; Delete removes it with any final file.
    [Fact]
    public async Task CancellingKeepsThePartialFileAndDeleteRemovesIt()
    {
        _hub.Reply = _ => Body(HttpStatusCode.OK, Data, chunkSize: 100);
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var progress = new SyncProgress(p => { if (p.CompletedBytes >= 300) cancel.Cancel(); });
        var downloader = Downloader();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => downloader.DownloadAsync(Model, progress, cancel.Token));

        Assert.Equal(Data[..300], File.ReadAllBytes(Part));
        Assert.False(File.Exists(Final));
        Assert.False(downloader.IsDownloaded(Model));

        File.WriteAllBytes(Final, Data);
        await downloader.DeleteAsync(Model, TestContext.Current.CancellationToken);

        Assert.Empty(Directory.EnumerateFileSystemEntries(_dir));
    }

    // Settings may hold a GGUF id, a macOS MLX catalog id or MLX repo id (exported actions), or anything else: the
    // models with a GGUF twin map to it, every other id to the default model.
    [Theory]
    [InlineData("gguf-qwen3.5-2b", "gguf-qwen3.5-2b")]
    [InlineData("qwen3.5-2b", "gguf-qwen3.5-2b")]
    [InlineData("gemma-4-e4b", "gguf-gemma-4-e4b")]
    [InlineData("mlx-community/gemma-4-e2b-it-4bit", "gguf-gemma-4-e2b")]
    [InlineData("qwen3.5-9b", "gguf-qwen3.5-4b")] // No GGUF twin in this catalog.
    [InlineData("unknown-model", "gguf-qwen3.5-4b")]
    [InlineData("", "gguf-qwen3.5-4b")]
    [InlineData(null, "gguf-qwen3.5-4b")]
    public void AModelIdResolvesToACatalogEntry(string? id, string expected) =>
        Assert.Equal(expected, GgufCatalog.Resolve(id).Id);

    private static HttpResponseMessage Body(HttpStatusCode status, byte[] body, int chunkSize = int.MaxValue) =>
        new(status) { Content = new StreamContent(new ChunkedStream(body, chunkSize)) };

    private static HttpResponseMessage Redirect(Uri location) =>
        new(HttpStatusCode.Found) { Headers = { Location = location } };

    private sealed record Request(Uri Uri, string? Range);

    /// <summary>Answers each request with <see cref="Reply"/> and records its URL and Range header.</summary>
    private sealed class ScriptedHandler : HttpMessageHandler
    {
        public Func<HttpRequestMessage, HttpResponseMessage> Reply { get; set; } = _ => new(HttpStatusCode.NotFound);

        public List<Request> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Requests.Add(new(request.RequestUri!, request.Headers.Range?.ToString()));
            var response = Reply(request);
            response.RequestMessage = request;
            return Task.FromResult(response);
        }
    }

    /// <summary>Reports on the caller's thread (<see cref="Progress{T}"/> posts later).</summary>
    private sealed class SyncProgress(Action<ModelDownloadProgress>? onReport = null) : IProgress<ModelDownloadProgress>
    {
        public ModelDownloadProgress Last { get; private set; }

        public void Report(ModelDownloadProgress value)
        {
            Last = value;
            onReport?.Invoke(value);
        }
    }

    /// <summary>A body read at most <c>chunkSize</c> bytes at a time, honouring cancellation between reads.</summary>
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
