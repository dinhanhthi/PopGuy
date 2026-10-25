using System.Runtime.CompilerServices;
using PopGuy.Core;
using PopGuy.Core.Actions;
using PopGuy.Core.History;
using PopGuy.Core.Providers;
using PopGuy.Core.Settings;
using PopGuy.Core.Toolbar;

namespace PopGuy.Tests.Core;

// Key feature: the toolbar state machine (ToolbarViewModel.swift + ActionEngineHandler.swift): a run streams to a
// result with throttled notifications, a provider failure shows its message verbatim, and each run writes one history
// record with its success flag, only while history is on.
public sealed class ToolbarSessionTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "PopGuyTests-" + Guid.NewGuid().ToString("N"));
    private readonly HistoryStore _history;

    public ToolbarSessionTests() => _history = new HistoryStore(AppPaths.Resolve(_root));

    public void Dispose()
    {
        _history.FlushAsync().Wait();
        if (Directory.Exists(_root))
            Directory.Delete(_root, recursive: true);
    }

    private sealed class FakeProvider(IReadOnlyList<string> chunks, Exception? error = null) : IProvider
    {
        public async IAsyncEnumerable<string> StreamAsync(
            string? systemPrompt, string input, string model, ProviderOptions options,
            [EnumeratorCancellation] CancellationToken ct = default)
        {
            await Task.Yield();
            if (error is not null)
                throw error;
            foreach (var chunk in chunks)
                yield return chunk;
        }
    }

    // A frozen clock: every chunk arrives inside one throttle interval.
    private sealed class FrozenClock : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => new(2026, 10, 25, 12, 0, 0, TimeSpan.Zero);
    }

    private ToolbarSession Session(IProvider provider, bool historyEnabled = true)
    {
        var factory = new ProviderFactory();
        factory.Register(ProviderKind.OpenAi, _ => provider);
        var settings = new AppSettings { HistoryEnabled = historyEnabled };
        return new ToolbarSession(new ActionEngine(factory, _ => "pg-test-key"), _history, () => settings, new FrozenClock());
    }

    private static readonly ToolbarRun Improve = new(ActionIdentifier.Builtin(ActionKind.Improve), "teh fox");

    [Fact]
    public async Task RunStreamsToTheResultAndRecordsOneSuccess()
    {
        var session = Session(new FakeProvider(["\"The", " quick", " brown", " fox", "\""]));
        var changes = 0;
        session.Changed += () => changes++;

        await session.RunAsync(Improve);

        Assert.Equal(new ToolbarState.Result("The quick brown fox"), session.State);
        Assert.Equal(2, changes); // running + result: the five chunks are coalesced
        var record = Assert.Single(_history.Records);
        Assert.True(record.Success);
        Assert.Equal("The quick brown fox", record.Output);
    }

    [Fact]
    public async Task ProviderErrorShowsItsMessageAndRecordsOneFailure()
    {
        var session = Session(new FakeProvider([], ProviderError.Http(401, "invalid key")));

        await session.RunAsync(Improve);

        Assert.Equal(new ToolbarState.Error("HTTP 401: invalid key"), session.State);
        var record = Assert.Single(_history.Records);
        Assert.False(record.Success);
        Assert.Equal("HTTP 401: invalid key", record.ErrorMessage);
    }

    [Fact]
    public async Task HistoryOffWritesNothing()
    {
        await Session(new FakeProvider(["ok"]), historyEnabled: false).RunAsync(Improve);

        Assert.Empty(_history.Records);
    }
}
