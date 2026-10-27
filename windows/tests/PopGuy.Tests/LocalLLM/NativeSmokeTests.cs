using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using LLama;
using LLama.Common;
using PopGuy.Core.Providers;
using PopGuy.LocalLLM;

namespace PopGuy.Tests.LocalLLM;

// LlamaProvider on the real llama.cpp natives (CI's native-smoke job, on x64 and ARM64; Windows only, where the natives
// ship). The pinned smoke model is downloaded through ModelDownloader (size and SHA-256 checked) into
// POPGUY_TEST_MODELS, which CI caches between runs; without that folder the tests skip.
[Trait("Category", "NativeLLM")]
public sealed class NativeSmokeTests
{
    // Test-only entry, never in the catalog: the smallest Qwen3 chat model (about 640 MB), the one EchoDiar pins.
    private static readonly GgufModel Qwen3Small = new(
        "gguf-qwen3-0.6b-test", "Qwen3 0.6B",
        "Qwen/Qwen3-0.6B-GGUF", "23749fefcc72300e3a2ad315e1317431b06b590a",
        "Qwen3-0.6B-Q8_0.gguf", 639_446_688,
        "9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031", 40_960, 1500);

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    private static void Log(string line) => TestContext.Current.TestOutputHelper?.WriteLine("NativeSmoke: " + line);

    private static void SkipUnlessWindows() =>
        Assert.SkipUnless(OperatingSystem.IsWindows(), "The llama.cpp natives are tested on Windows only.");

    private static string ModelsRoot()
    {
        var root = Environment.GetEnvironmentVariable("POPGUY_TEST_MODELS");
        Assert.SkipWhen(string.IsNullOrEmpty(root), "Set POPGUY_TEST_MODELS to a folder for the test models.");
        return root!;
    }

    private static HttpClient Http() => new() { Timeout = Timeout.InfiniteTimeSpan };

    [Fact]
    public async Task LlamaProviderStreamsAnImproveAnswer()
    {
        SkipUnlessWindows();
        using var http = Http();
        var downloader = new ModelDownloader(ModelsRoot(), http, [Qwen3Small]);
        // DownloadAsync fetches again even when the final file is there: only download a missing model.
        if (!downloader.IsDownloaded(Qwen3Small)) await downloader.DownloadAsync(Qwen3Small, ct: Token);

        var provider = new LlamaProvider(id => id == Qwen3Small.Id ? downloader.PathFor(Qwen3Small) : null);
        var pieces = 0;
        var text = new StringBuilder();
        var clock = Stopwatch.StartNew();
        try
        {
            await foreach (var piece in provider.StreamAsync(
                "Improve the writing of the user's text. Reply with the improved text only.",
                "i has went to the store yesterday", Qwen3Small.Id, new ProviderOptions { MaxTokens = 32 }, Token))
            {
                pieces++;
                text.Append(piece);
            }
        }
        finally
        {
            await provider.UnloadAsync(CancellationToken.None);
        }

        Log($"qwen3-0.6b ({RuntimeInformation.ProcessArchitecture}): {pieces} pieces in {clock.Elapsed.TotalSeconds:0.0} s: "
            + text.ToString().ReplaceLineEndings(" "));
        Assert.True(pieces >= 1, "No token was generated.");
        Assert.False(string.IsNullOrWhiteSpace(text.ToString()), "The answer is empty.");
    }

    // Opt-in: about 12 GB of downloads. Each catalog GGUF in turn is downloaded into a temp folder (never the cached test
    // models), opened vocabulary only (header, metadata and tokenizer: llama.cpp knows the architecture), its chat
    // template applied to a short chat as LlamaProvider does, then deleted before the next, so at most one model is on
    // disk.
    [Fact]
    public async Task EveryCatalogGgufLoads()
    {
        SkipUnlessWindows();
        Assert.SkipUnless(Environment.GetEnvironmentVariable("POPGUY_TEST_GGUF_ALL") == "1",
            "Set POPGUY_TEST_GGUF_ALL=1 to download and open every catalog GGUF (about 12 GB, one at a time).");
        var root = Path.Combine(Path.GetTempPath(), "PopGuyGguf-" + Guid.NewGuid().ToString("N"));
        using var http = Http();
        var downloader = new ModelDownloader(root, http);
        var failures = new List<string>();
        try
        {
            foreach (var entry in GgufCatalog.All)
            {
                var clock = Stopwatch.StartNew();
                try
                {
                    await downloader.DownloadAsync(entry, ct: Token);
                    var download = clock.Elapsed;
                    var path = downloader.PathFor(entry) ?? throw new InvalidOperationException("Downloaded, but not found.");
                    using (var weights = LLamaWeights.LoadFromFile(new ModelParams(path) { VocabOnly = true }))
                    {
                        var arch = weights.Metadata.GetValueOrDefault("general.architecture") ?? "?";
                        var prompt = new LlamaPrompt(weights).Tokens(
                            [new ChatMessage("system", "You are concise."), new ChatMessage("user", "Reply with the word hello.")]);
                        Log($"gguf {entry.Id}: download {download.TotalSeconds:0} s, load OK ({arch}, "
                            + $"{weights.Vocab.Count} tokens, prompt {prompt.Count} tokens)");
                    }
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    Log($"gguf {entry.Id}: FAILED after {clock.Elapsed.TotalSeconds:0} s: {error.GetType().Name}: {error.Message}");
                    failures.Add($"{entry.Id}: {error.GetType().Name}: {error.Message}");
                }
                finally
                {
                    // The mapped file is released before it is deleted (Windows will not delete a mapped file).
                    GC.Collect();
                    GC.WaitForPendingFinalizers();
                    // Throws (ending the loop) rather than leave a model behind for the next download.
                    await downloader.DeleteAsync(entry, CancellationToken.None);
                }
            }
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
        Assert.Empty(failures);
    }
}
