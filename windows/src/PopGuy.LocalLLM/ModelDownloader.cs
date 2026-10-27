using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using PopGuy.Core;

namespace PopGuy.LocalLLM;

public enum ModelDownloadError
{
    UnknownModel,
    UnsafePath,
    HttpStatus,
    InsecureRedirect,
    SizeMismatch,
    ChecksumMismatch,
    Incomplete,
}

public sealed class ModelDownloadException(ModelDownloadError kind, string message) : Exception(message)
{
    public ModelDownloadError Kind { get; } = kind;
}

/// <summary>Download progress of one model file, in bytes.</summary>
public readonly record struct ModelDownloadProgress(long CompletedBytes, long TotalBytes)
{
    public double Fraction => TotalBytes > 0 ? Math.Min(1, (double)CompletedBytes / TotalBytes) : 0;
}

/// <summary>
/// Opt-in downloads of <see cref="GgufCatalog"/> models into one folder (<see cref="DefaultFolder"/>). Only catalog
/// entries are fetched, from <c>huggingface.co/&lt;repo&gt;/resolve/&lt;pinned revision&gt;/&lt;file&gt;</c> over https
/// (HF's redirect to its CDN is followed only to https), and the file name comes from the catalog, never from the
/// server. The body goes to <c>&lt;file&gt;.part</c>, which a later call resumes with an HTTP Range request; the file
/// is renamed to its final name only once its size and SHA-256 match the catalog.
/// </summary>
/// <remarks>
/// Failures: a size or SHA-256 mismatch deletes the partial file. Cancellation, a dropped connection or an HTTP error
/// keeps it, so the next download resumes (models are GBs); <see cref="DeleteAsync"/> removes it. The injected
/// <see cref="HttpClient"/> should have <c>Timeout = InfiniteTimeSpan</c>: the cancellation token stops a download.
/// Downloads and deletes of one entry through one downloader run one after the other. llama.cpp maps a loaded model
/// into memory, which Windows will not delete nor replace: unload the provider before a delete or a new download.
/// </remarks>
public sealed class ModelDownloader
{
    private const string HubHost = "huggingface.co";
    private const string PartSuffix = ".part";
    private const int BufferSize = 1 << 20;
    private const int MaxRedirects = 5;

    private readonly HttpClient _http;
    private readonly IReadOnlyList<GgufModel> _catalog;
    private readonly ConcurrentDictionary<string, SemaphoreSlim> _gates = new();

    /// <param name="folder">Where the models go: <see cref="DefaultFolder"/> in the app.</param>
    public ModelDownloader(string folder, HttpClient http) : this(folder, http, GgufCatalog.All) { }

    /// <param name="catalog">The entries allowed to download (tests use small files of their own).</param>
    internal ModelDownloader(string folder, HttpClient http, IReadOnlyList<GgufModel> catalog)
    {
        Folder = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
        _http = http;
        _catalog = catalog;
    }

    public string Folder { get; }

    /// <summary><c>%LOCALAPPDATA%\PopGuyData\Models</c> (<c>&lt;root&gt;\Cache\Models</c> under <c>POPGUY_DATA_ROOT</c>).</summary>
    public static string DefaultFolder(AppPaths paths) => Path.Combine(paths.CacheDirectory, "Models");

    /// <summary>
    /// The final file is there with the catalog's size. Its SHA-256 was checked before it got that name, so it is not
    /// hashed again. Never throws: false for an entry that is not a safe catalog entry.
    /// </summary>
    public bool IsDownloaded(GgufModel entry) => PathFor(entry) is not null;

    /// <summary>The downloaded file of <paramref name="entry"/>, or null when it is missing. Never throws.</summary>
    public string? PathFor(GgufModel entry)
    {
        try
        {
            var path = FinalPath(entry);
            return new FileInfo(path) is { Exists: true } file && file.Length == entry.Bytes ? path : null;
        }
        catch (Exception e) when (e is ModelDownloadException or IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    /// <summary>The <c>LlamaProvider</c> resolver: an action's model id (<see cref="GgufCatalog.Resolve"/>) to its file, or null.</summary>
    public string? ResolvePath(string? modelId) => PathFor(GgufCatalog.Resolve(modelId));

    /// <summary>
    /// Downloads <paramref name="entry"/>, resuming its partial file, and verifies it before the final rename. Throws
    /// <see cref="ModelDownloadException"/>, HttpRequestException or IOException (network and disk failures), and
    /// OperationCanceledException when cancelled; the last three keep the partial file.
    /// </summary>
    public async Task DownloadAsync(
        GgufModel entry, IProgress<ModelDownloadProgress>? progress = null, CancellationToken ct = default)
    {
        var final = FinalPath(entry);
        var gate = Gate(entry);
        await gate.WaitAsync(ct);
        try
        {
            await Fetch(entry, final, final + PartSuffix, progress, ct);
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>Deletes the downloaded file and any partial download; waits for a download of the entry to end.</summary>
    public async Task DeleteAsync(GgufModel entry, CancellationToken ct = default)
    {
        var final = FinalPath(entry);
        var gate = Gate(entry);
        await gate.WaitAsync(ct);
        try
        {
            foreach (var path in new[] { final + PartSuffix, final })
            {
                if (File.Exists(path)) File.Delete(path);
            }
        }
        finally
        {
            gate.Release();
        }
    }

    private SemaphoreSlim Gate(GgufModel entry) => _gates.GetOrAdd(entry.Id, _ => new SemaphoreSlim(1, 1));

    private async Task Fetch(
        GgufModel entry, string final, string part, IProgress<ModelDownloadProgress>? progress, CancellationToken ct)
    {
        Directory.CreateDirectory(Folder);
        var existing = File.Exists(part) ? new FileInfo(part).Length : 0;
        if (existing > entry.Bytes)
        {
            File.Delete(part);
            existing = 0;
        }
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var written = existing;
        if (existing < entry.Bytes)
        {
            using var response = await Send(ResolveUrl(entry), existing, ct);
            var from = Resumed(response, existing, part);
            if (from > 0) await HashPrefix(part, from, hash, ct);
            written = from;
            progress?.Report(new(written, entry.Bytes));

            var tooLong = false;
            await using (var input = await response.Content.ReadAsStreamAsync(ct))
            await using (var output = new FileStream(
                part, from > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, BufferSize, useAsync: true))
            {
                var buffer = new byte[BufferSize];
                int read;
                while ((read = await input.ReadAsync(buffer, ct)) > 0)
                {
                    // The catalog's size, not the server's Content-Length, bounds what is written.
                    if (written + read > entry.Bytes)
                    {
                        tooLong = true;
                        break;
                    }
                    hash.AppendData(buffer, 0, read);
                    await output.WriteAsync(buffer.AsMemory(0, read), ct);
                    written += read;
                    progress?.Report(new(written, entry.Bytes));
                }
            }
            if (tooLong) throw Rejected(part, ModelDownloadError.SizeMismatch, $"Size mismatch for {entry.File}.");
            if (written < entry.Bytes)
            {
                throw new ModelDownloadException(ModelDownloadError.Incomplete, $"The download of {entry.File} stopped early.");
            }
        }
        else
        {
            // A partial file of the full size (a run stopped before its check): verify it without a request.
            await HashPrefix(part, existing, hash, ct);
        }

        if (!string.Equals(Convert.ToHexString(hash.GetHashAndReset()), entry.Sha256, StringComparison.OrdinalIgnoreCase))
        {
            throw Rejected(part, ModelDownloadError.ChecksumMismatch, $"SHA-256 mismatch for {entry.File}.");
        }
        File.Move(part, final, overwrite: true);
        progress?.Report(new(entry.Bytes, entry.Bytes));
    }

    /// <summary>
    /// Where the body starts: <paramref name="existing"/> for a 206 that resumes there, 0 for a 200 (the server ignored
    /// the Range). Any other answer fails; a refused range (416) or a 206 elsewhere also deletes the partial file.
    /// </summary>
    private static long Resumed(HttpResponseMessage response, long existing, string part)
    {
        var status = (int)response.StatusCode;
        if (response.StatusCode == HttpStatusCode.OK) return 0;
        if (response.StatusCode == HttpStatusCode.PartialContent)
        {
            if (existing > 0 && response.Content.Headers.ContentRange?.From == existing) return existing;
            throw Rejected(part, ModelDownloadError.HttpStatus, $"HTTP {status}: the server resumed at another byte.");
        }
        if (response.StatusCode == HttpStatusCode.RequestedRangeNotSatisfiable)
        {
            throw Rejected(part, ModelDownloadError.HttpStatus, $"HTTP {status}: the partial download could not be resumed.");
        }
        throw new ModelDownloadException(ModelDownloadError.HttpStatus, $"HTTP {status} while downloading the model.");
    }

    /// <summary>
    /// GETs <paramref name="url"/> (with a Range from <paramref name="from"/> when resuming), following redirects only to
    /// https. Redirects the client follows itself are checked by where the response came from.
    /// </summary>
    private async Task<HttpResponseMessage> Send(Uri url, long from, CancellationToken ct)
    {
        for (var hops = 0; ; hops++)
        {
            var request = new HttpRequestMessage(HttpMethod.Get, url);
            if (from > 0) request.Headers.Range = new RangeHeaderValue(from, null);
            var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
            var source = response.RequestMessage?.RequestUri ?? url;
            if (source.Scheme != Uri.UriSchemeHttps)
            {
                response.Dispose();
                throw Insecure(source);
            }
            if ((int)response.StatusCode is not (301 or 302 or 303 or 307 or 308)) return response;

            var location = response.Headers.Location;
            response.Dispose();
            if (location is null) throw new ModelDownloadException(ModelDownloadError.HttpStatus, "A redirect without a target.");
            url = location.IsAbsoluteUri ? location : new Uri(source, location);
            if (url.Scheme != Uri.UriSchemeHttps) throw Insecure(url);
            if (hops >= MaxRedirects) throw new ModelDownloadException(ModelDownloadError.HttpStatus, "Too many redirects.");
        }
    }

    private static async Task HashPrefix(string part, long length, IncrementalHash hash, CancellationToken ct)
    {
        await using var input = new FileStream(part, FileMode.Open, FileAccess.Read, FileShare.Read, BufferSize, useAsync: true);
        var buffer = new byte[BufferSize];
        var left = length;
        while (left > 0)
        {
            var read = await input.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, left)), ct);
            if (read == 0) throw new ModelDownloadException(ModelDownloadError.Incomplete, "The partial download changed while reading it.");
            hash.AppendData(buffer, 0, read);
            left -= read;
        }
    }

    // Paths

    private static Uri ResolveUrl(GgufModel entry) => new(
        $"https://{HubHost}/{string.Join('/', entry.Repo.Split('/').Select(Uri.EscapeDataString))}"
        + $"/resolve/{entry.Revision}/{Uri.EscapeDataString(entry.File)}");

    /// <summary>
    /// The final path of a catalog entry in <see cref="Folder"/>. The file name is checked by its characters first (a
    /// backslash is no separator on the Mac, so resolving alone would miss <c>..\</c>), then the entry must be one of
    /// the catalog's, pinned to a full commit SHA, and the path must resolve directly in the folder.
    /// </summary>
    private string FinalPath(GgufModel entry)
    {
        if (!IsSafeName(entry.File)) throw Unsafe(entry.File);
        if (!_catalog.Contains(entry) || !IsCommitSha(entry.Revision))
        {
            throw new ModelDownloadException(ModelDownloadError.UnknownModel, $"{entry.Id} is not a downloadable model.");
        }
        var path = Path.GetFullPath(Path.Combine(Folder, entry.File));
        return string.Equals(Path.GetDirectoryName(path), Folder, StringComparison.Ordinal) ? path : throw Unsafe(entry.File);
    }

    /// <summary>A plain <c>.gguf</c> file name: no separator, colon or NUL, not dotted at either end, no trailing space.</summary>
    private static bool IsSafeName(string name) =>
        name.Length > 0 && name.IndexOfAny(['/', '\\', ':', '\0']) < 0 && !Path.IsPathRooted(name)
        && !name.StartsWith('.') && !name.EndsWith(' ') && name.EndsWith(".gguf", StringComparison.OrdinalIgnoreCase);

    private static bool IsCommitSha(string revision) => revision.Length == 40 && revision.All(char.IsAsciiHexDigitLower);

    /// <summary>Deletes the partial file (best effort) and returns the error to throw.</summary>
    private static ModelDownloadException Rejected(string part, ModelDownloadError kind, string message)
    {
        try
        {
            File.Delete(part);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return new(kind, message);
    }

    private static ModelDownloadException Unsafe(string name) =>
        new(ModelDownloadError.UnsafePath, $"Refusing unsafe model file name {name}.");

    private static ModelDownloadException Insecure(Uri url) =>
        new(ModelDownloadError.InsecureRedirect, $"Refusing a download that is not over https ({url.Host}).");
}
