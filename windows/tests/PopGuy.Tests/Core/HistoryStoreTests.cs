using PopGuy.Core;
using PopGuy.Core.Actions;
using PopGuy.Core.History;

namespace PopGuy.Tests.Core;

// Contract: history.json (spec-3 §4): a JSON array of HistoryRecord, newest first, ISO-8601 dates, the newest 500 kept.
public sealed class HistoryStoreTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "PopGuyTests-" + Guid.NewGuid().ToString("N"));
    private readonly AppPaths _paths;

    public HistoryStoreTests() => _paths = AppPaths.Resolve(_root);

    public void Dispose()
    {
        if (Directory.Exists(_root))
            Directory.Delete(_root, recursive: true);
    }

    private static HistoryRecord Run(string input) => new()
    {
        ActionName = "Improve",
        ProviderKind = ProviderKind.OpenAi,
        Model = "gpt-6.1-sol",
        SourceAppName = "Notepad",
        DurationMs = 120,
        Success = true,
        Input = input,
        Output = "out",
    };

    [Fact]
    public async Task CapKeepsTheNewest500()
    {
        var store = new HistoryStore(_paths);
        for (var i = 0; i <= HistoryStore.MaxEntries; i++)
            store.Record(Run($"run {i}"), storeFullText: true);
        await store.FlushAsync();

        var reloaded = new HistoryStore(_paths).Records;

        Assert.Equal(500, reloaded.Count);
        Assert.Equal("run 500", reloaded[0].Input);
        Assert.Equal("run 1", reloaded[^1].Input);
    }

    [Fact]
    public async Task RoundTripReadsBackWithIsoDatesAndPreviewOnlyText()
    {
        var store = new HistoryStore(_paths);
        var longInput = string.Join(" ", Enumerable.Range(1, 30).Select(i => $"w{i}"));
        store.Record(Run(longInput), storeFullText: false);
        await store.FlushAsync();

        var json = File.ReadAllText(_paths.HistoryFile);
        Assert.Matches("""
            "timestamp": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"
            """, json);
        var reloaded = Assert.Single(new HistoryStore(_paths).Records);
        Assert.Equal(store.Records[0], reloaded);
        Assert.True(reloaded.Truncated);
        Assert.Equal("w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 … w19 w20 w21 w22 w23 w24 w25 w26 w27 w28 w29 w30", reloaded.Input);
    }
}
