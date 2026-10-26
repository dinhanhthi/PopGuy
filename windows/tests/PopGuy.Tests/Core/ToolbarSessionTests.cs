using System.Runtime.CompilerServices;
using PopGuy.Core;
using PopGuy.Core.Actions;
using PopGuy.Core.History;
using PopGuy.Core.Providers;
using PopGuy.Core.Scripts;
using PopGuy.Core.Settings;
using PopGuy.Core.Toolbar;

namespace PopGuy.Tests.Core;

// Key feature: the toolbar state machine (ToolbarViewModel.swift + ActionEngineHandler.swift): a run streams to a
// result with throttled notifications, a provider failure shows its message verbatim, and each run writes one history
// record with its success flag, only while history is on. Refine revises the shown result through the same action;
// Regenerate re-runs the plain action; Copy takes the edited result.
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
        /// <summary>The system prompt and input of every call, in order.</summary>
        public List<(string? SystemPrompt, string Input)> Calls { get; } = [];

        public async IAsyncEnumerable<string> StreamAsync(
            string? systemPrompt, string input, string model, ProviderOptions options,
            [EnumeratorCancellation] CancellationToken ct = default)
        {
            Calls.Add((systemPrompt, input));
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

    /// <param name="hold">Holds the run until it completes; with <paramref name="honoursCancellation"/> a cancelled
    /// run throws instead of finishing.</param>
    private sealed class FakeScripts(
        string? output, Exception? error = null, Task? hold = null, bool honoursCancellation = false) : IScriptActionRunner
    {
        public (string Text, string FullText)? Call { get; private set; }

        public async Task<ScriptActionResult> RunAsync(
            CustomAction action, string text, string fullText, CancellationToken ct = default)
        {
            Call = (text, fullText);
            if (hold is not null)
                await (honoursCancellation ? hold.WaitAsync(ct) : hold);
            await Task.Yield();
            if (error is not null)
                throw error;
            return new ScriptActionResult(output);
        }
    }

    private static readonly CustomAction Script = new()
    {
        Title = "Upper",
        SystemPrompt = "",
        Type = CustomActionType.ShellScript,
        Shell = "powershell",
        ScriptSource = "$env:POPGUY_TEXT.ToUpper()",
    };

    private ToolbarSession ScriptSession(FakeScripts scripts, AfterRunBehavior afterRun)
    {
        var settings = new AppSettings { HistoryEnabled = true, CustomActions = [Script with { AfterRun = afterRun }] };
        return new ToolbarSession(
            new ActionEngine(new ProviderFactory(), _ => null), _history, () => settings, new FrozenClock(), scripts);
    }

    private static readonly ToolbarRun ScriptRun = new(ActionIdentifier.Custom(Script.Id), "  teh fox \n");

    private static readonly ToolbarRun Improve = new(ActionIdentifier.Builtin(ActionKind.Improve), "teh fox");
    private static readonly ToolbarRun Shorten = new(ActionIdentifier.Builtin(ActionKind.Shorten), "the quick brown fox");

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

    // macOS recordSpeak: one record at trigger time with the selected engine and accent, no output; none for an
    // ignored source.
    [Fact]
    public void SpeakRecordsTheEngineAndAccent()
    {
        var session = Session(new FakeProvider([]));
        var run = new ToolbarRun(ActionIdentifier.Speak, "Bonjour") { SourceExeName = "notepad.exe" };

        session.RecordSpeak(run, SpeakEngineSelection.Cloud(TtsProviderKind.AzureTts), SpeakAccent.French);
        session.RecordSpeak(run with { SkipHistory = true }, SpeakEngineSelection.System, SpeakAccent.UsEnglish);

        var record = Assert.Single(_history.Records);
        Assert.Equal(("Speak", "Azure Speech", "French"), (record.ActionName, record.ProviderLabel, record.Model));
        Assert.Equal(("Bonjour", "", true), (record.Input, record.Output, record.Success));
        Assert.Equal("notepad.exe", record.SourceAppName);
        Assert.Null(record.ProviderKind);
        Assert.Equal(ToolbarState.Idle, session.State);
    }

    [Fact]
    public async Task HistoryOffWritesNothing()
    {
        await Session(new FakeProvider(["ok"]), historyEnabled: false).RunAsync(Improve);

        Assert.Empty(_history.Records);
    }

    [Fact]
    public async Task RefineSendsThePreviousResultAndTheInstructionThroughTheSameAction()
    {
        var provider = new FakeProvider(["a fox"]);
        var session = Session(provider);
        await session.RunAsync(Shorten);

        await session.RefineAsync("  more formal ");

        Assert.Equal(2, provider.Calls.Count);
        var (system, input) = provider.Calls[1];
        Assert.StartsWith(provider.Calls[0].SystemPrompt!, system); // Shorten's prompt, then the refine directive
        Assert.EndsWith(ActionEngine.RefineDirective + "\n\nInstruction: more formal", system);
        Assert.Equal("Original text:\nthe quick brown fox\n\nPrevious result:\na fox", input);
    }

    [Fact]
    public async Task RegenerateAfterARefineRerunsThePlainAction()
    {
        var provider = new FakeProvider(["a fox"]);
        var session = Session(provider);
        await session.RunAsync(Shorten);
        await session.RefineAsync("more formal");

        await session.RegenerateAsync();

        Assert.Equal(3, provider.Calls.Count);
        Assert.Equal(provider.Calls[0], provider.Calls[2]);
    }

    [Fact]
    public async Task CopyTextReturnsTheEditedResult()
    {
        var session = Session(new FakeProvider(["a fox"]));
        await session.RunAsync(Shorten);

        session.BeginEditing();
        session.SetEditText("a quick fox");
        session.EndEditing();

        Assert.Equal("a quick fox", session.CopyText());
    }

    // spec-4 §4.4: a script gets the trimmed and the full selection, records one history entry, and hands its output
    // to the App per afterRun (Show result is the session's own result state).
    [Fact]
    public async Task ScriptShowResultShowsTheOutputAndRecordsIt()
    {
        var scripts = new FakeScripts("TEH FOX");
        var session = ScriptSession(scripts, AfterRunBehavior.ShowResult);
        ScriptRunFinished? finished = null;
        session.ScriptFinished += f => finished = f;

        await session.RunAsync(ScriptRun);

        Assert.Equal(("teh fox", "  teh fox \n"), scripts.Call);
        Assert.Equal(new ToolbarState.Result("TEH FOX"), session.State);
        Assert.Equal(AfterRunBehavior.ShowResult, finished?.AfterRun);
        var record = Assert.Single(_history.Records);
        Assert.True(record.Success);
        Assert.Equal(("Upper", "Shell Script", "teh fox", "TEH FOX"), (record.ActionName, record.ProviderLabel, record.Input, record.Output));
    }

    [Fact]
    public async Task ScriptCloseToolbarGoesIdleAndHandsTheOutputToTheApp()
    {
        var session = ScriptSession(new FakeScripts("TEH FOX"), AfterRunBehavior.CloseToolbar);
        ScriptRunFinished? finished = null;
        session.ScriptFinished += f => finished = f;

        await session.RunAsync(ScriptRun);

        Assert.Equal(ToolbarState.Idle, session.State);
        Assert.NotNull(finished);
        Assert.Equal((AfterRunBehavior.CloseToolbar, "TEH FOX"), (finished.AfterRun, finished.Output));
        Assert.True(session.IsCurrentRun(finished.Generation));
    }

    [Fact]
    public async Task ScriptFailureShowsItsMessageAndHandsNothingToTheApp()
    {
        var session = ScriptSession(new FakeScripts(null, new ScriptActionError("Script exited with status 1: boom")), AfterRunBehavior.PasteResult);
        var finished = false;
        session.ScriptFinished += _ => finished = true;

        await session.RunAsync(ScriptRun);

        Assert.Equal(new ToolbarState.Error("Script exited with status 1: boom"), session.State);
        Assert.False(finished);
        var record = Assert.Single(_history.Records);
        Assert.False(record.Success);
    }

    // A stopped script writes nothing when it ends: no state, no history, and no ScriptFinished (the App would copy or
    // paste its output), whether it ends cancelled or finishes anyway.
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task StoppedScriptChangesNothingWhenItEnds(bool honoursCancellation)
    {
        var hold = new TaskCompletionSource();
        var session = ScriptSession(
            new FakeScripts("TEH FOX", hold: hold.Task, honoursCancellation: honoursCancellation), AfterRunBehavior.PasteResult);
        var finished = false;
        session.ScriptFinished += _ => finished = true;

        var run = session.RunAsync(ScriptRun);
        Assert.Equal(new ToolbarState.Running(""), session.State);
        session.Stop();
        hold.SetResult();
        await run;

        Assert.Equal(ToolbarState.Idle, session.State);
        Assert.False(finished);
        Assert.Empty(_history.Records);
    }
}
