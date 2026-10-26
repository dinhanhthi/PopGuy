using System.Text;
using PopGuy.Core.Actions;
using PopGuy.Core.Diff;
using PopGuy.Core.Dictionaries;
using PopGuy.Core.History;
using PopGuy.Core.Json;
using PopGuy.Core.Providers;
using PopGuy.Core.Scripts;
using PopGuy.Core.Settings;
using PopGuy.Core.Speak;

namespace PopGuy.Core.Toolbar;

// The non-UI logic of the toolbar (macOS ToolbarViewModel.swift + ActionEngineHandler.swift, spec-1 §3, spec-2 §2.6-2.8).
// UNTRUSTED DATA: the selection and the streamed output are plain text; the session never interprets them.

/// <summary>The toolbar's action state (macOS <c>ToolbarActionState</c>).</summary>
public abstract record ToolbarState
{
    private ToolbarState() { }

    public static ToolbarState Idle { get; } = new IdleState();

    /// <summary>No action running and nothing to show.</summary>
    public sealed record IdleState : ToolbarState;

    /// <summary>An action is streaming; <paramref name="Progress"/> is the text so far.</summary>
    public sealed record Running(string Progress) : ToolbarState;

    /// <summary>The finished output (wrapping quotes stripped).</summary>
    public sealed record Result(string Text) : ToolbarState;

    /// <summary>A failed run; <paramref name="Message"/> is user-facing (a <see cref="ProviderError"/>'s message verbatim).</summary>
    public sealed record Error(string Message) : ToolbarState;
}

/// <summary>Speech playback, orthogonal to <see cref="ToolbarState"/> (macOS <c>SpeakPhase</c>; wired in Phase 17).</summary>
public enum SpeakPhase { Idle, Loading, Playing }

/// <summary>One run of a provider-backed action on a selection, with the source snapshot taken at dispatch.</summary>
/// <param name="Action">A built-in Improve/Shorten/Proofread/Translate/Prompt, or a custom AI or translation action.</param>
/// <param name="Text">The selected text.</param>
public sealed record ToolbarRun(ActionIdentifier Action, string Text)
{
    /// <summary>The user's typed prompt; required for the built-in Prompt action.</summary>
    public string? PromptText { get; init; }

    /// <summary>The built-in Translate target (BCP-47); null means the settings' default target language.</summary>
    public string? TargetLanguage { get; init; }

    /// <summary>The <c>{{language}}</c> value (macOS: the picker's display name); null means the target language code.</summary>
    public string? LanguageName { get; init; }

    /// <summary>The source app's exe name (history <c>sourceBundleID</c>).</summary>
    public string? SourceExeName { get; init; }

    /// <summary>The source app's display name (<c>{{app}}</c> and history); null falls back to the exe name.</summary>
    public string? SourceAppName { get; init; }

    /// <summary>The browser host (<c>{{domain}}</c>), set only while ignored domains are on.</summary>
    public string? SourceDomain { get; init; }

    /// <summary>The source is an ignored app or domain: the run writes no history (selected text stays off disk).</summary>
    public bool SkipHistory { get; init; }
}

/// <summary>
/// A script action finished (spec-4 §4.4): the App applies <paramref name="AfterRun"/> (close the toolbar, copy or paste
/// <paramref name="Output"/>) while <see cref="ToolbarSession.IsCurrentRun"/> holds for <paramref name="Generation"/>.
/// Show result and Do nothing are already the session's state.
/// </summary>
public sealed record ScriptRunFinished(AfterRunBehavior AfterRun, string? Output, int Generation);

/// <summary>The Listen button's voice for a lookup: the accent, the speech settings and the cloud engine's config.</summary>
public sealed record DictionaryListenVoice(SpeakAccent Accent, SpeakSettings Settings, TtsProviderConfig TtsConfig);

/// <summary>
/// A Speak toggle's voice (the built-in Speak or a Speech custom action): its history name, the accent, the speech
/// settings and the cloud engine's config.
/// </summary>
public sealed record SpeakVoice(string ActionName, SpeakAccent Accent, SpeakSettings Settings, TtsProviderConfig TtsConfig);

/// <summary>
/// Runs one provider action at a time and holds the toolbar state. <see cref="Changed"/> is raised on any thread (the
/// App marshals to its UI thread): on every state transition, and while streaming at most once per
/// <see cref="ProgressInterval"/>. A run that is stopped or replaced leaves no trace: no state change, no history
/// (macOS generation guard, spec-2 §2.7). There is no automatic retry (spec-2 §2.8): Retry and Regenerate run again.
/// It also holds the text inputs' state: the prompt input, the refine input and the editable result. A scriptable
/// custom action runs through <paramref name="scripts"/> (none: it changes nothing) under the same rules, and so do
/// Look up and a Dictionary custom action through <paramref name="dictionary"/>: their result is the providers'
/// entries (<see cref="DictionaryResults"/>), not text.
/// </summary>
public sealed class ToolbarSession(
    ActionEngine engine, HistoryStore history, Func<AppSettings> settings, TimeProvider? clock = null,
    IScriptActionRunner? scripts = null, DictionaryEngine? dictionary = null)
{
    /// <summary>
    /// The minimum time between two progress notifications. macOS appends per token and lets SwiftUI coalesce; WinUI
    /// re-layouts per notification, so the session throttles (~20 updates a second). A pause mid-stream shows the
    /// buffered tail with the next token or at the end.
    /// </summary>
    public static readonly TimeSpan ProgressInterval = TimeSpan.FromMilliseconds(50);

    private readonly TimeProvider _clock = clock ?? TimeProvider.System;
    private readonly Lock _gate = new();
    private ToolbarState _state = ToolbarState.Idle;
    private int _generation;
    private CancellationTokenSource? _cts;

    // The last run as the user started it (a refine keeps its action, so Regenerate re-runs the plain action, as on
    // macOS) and the provider it resolved to (DeepL and Google Translate cannot follow a refine instruction).
    private ToolbarRun? _lastRun;
    private ProviderKind? _lastKind;

    // The text inputs (macOS isPromptInputActive, isRefineInputActive, isEditing). The drafts are the App's.
    private bool _promptInputActive;
    private bool _refineInputActive;
    private bool _editing;

    // The edit buffer of a non-diff result (macOS editedResult): seeded with every result, changed only while editing.
    private string _edited = "";

    // The result's diff (Improve and Proofread only), computed once when the run finishes, and the hunks the user
    // rejected; both reset with every new result. Replaced, never mutated, so a read under the lock is a snapshot.
    private IReadOnlyList<DiffSegment> _diff = [];
    private IReadOnlySet<int> _rejected = new HashSet<int>();

    // The lookup shown or running (macOS isDictionaryAction, dictionaryEntries, isDictionaryNotFound). The results are
    // replaced, never mutated, like the diff.
    private ActionIdentifier? _lookupAction;
    private IReadOnlyList<DictionaryProviderResult> _lookupResults = [];
    private bool _lookupNotFound;

    public event Action? Changed;

    /// <summary>A script run ended without an error and was not stopped or replaced. Raised on any thread.</summary>
    public event Action<ScriptRunFinished>? ScriptFinished;

    public ToolbarState State
    {
        get
        {
            lock (_gate)
                return _state;
        }
    }

    /// <summary>The speak coordinator's phase, mirrored by the App on its UI thread; feeds <see cref="PresentationInput.SpeakActive"/>.</summary>
    public SpeakPhase SpeakPhase { get; set; }

    /// <summary>The result's word diff against the selection (Improve and Proofread); empty for every other result.</summary>
    public IReadOnlyList<DiffSegment> DiffSegments
    {
        get
        {
            lock (_gate)
                return _diff;
        }
    }

    /// <summary>The diff hunks the user rejected (their original text is kept); empty means every hunk is accepted.</summary>
    public IReadOnlySet<int> RejectedHunks
    {
        get
        {
            lock (_gate)
                return _rejected;
        }
    }

    /// <summary>
    /// The text Copy, Paste back and a refine use: for a diff, the merged text (accepted hunks, the original text of
    /// rejected ones); else the edit buffer (the result, as the user edited it); "" without a result.
    /// </summary>
    public string CopyText()
    {
        lock (_gate)
            return CopyTextLocked();
    }

    /// <summary>
    /// The action of the lookup running or shown (Look up or a Dictionary custom action), from its start until another
    /// run or Stop (macOS isDictionaryAction); else null.
    /// </summary>
    public ActionIdentifier? DictionaryAction
    {
        get
        {
            lock (_gate)
                return _lookupAction;
        }
    }

    /// <summary>The lookup's definitions, one per provider that found one, in provider order; empty otherwise.</summary>
    public IReadOnlyList<DictionaryProviderResult> DictionaryResults
    {
        get
        {
            lock (_gate)
                return _lookupResults;
        }
    }

    /// <summary>The lookup finished without a definition (a Result with no text, as on macOS).</summary>
    public bool IsDictionaryNotFound
    {
        get
        {
            lock (_gate)
                return _lookupNotFound;
        }
    }

    /// <summary>The prompt input is open (macOS: it shows below the action row, also before any run).</summary>
    public bool IsPromptInputActive
    {
        get
        {
            lock (_gate)
                return _promptInputActive;
        }
    }

    /// <summary>The refine input is open below the result.</summary>
    public bool IsRefineInputActive
    {
        get
        {
            lock (_gate)
                return _refineInputActive;
        }
    }

    /// <summary>The result is being edited (<see cref="BeginEditing"/>).</summary>
    public bool IsEditing
    {
        get
        {
            lock (_gate)
                return _editing;
        }
    }

    /// <summary>The result can be edited: every result but a diff (Improve and Proofread), as on macOS.</summary>
    public bool IsResultEditable
    {
        get
        {
            lock (_gate)
                return IsResultEditableLocked();
        }
    }

    /// <summary>
    /// The result can be revised with an instruction: it came from a run, through a provider that takes a model (DeepL
    /// and Google Translate cannot follow an instruction).
    /// </summary>
    public bool CanRefine
    {
        get
        {
            lock (_gate)
                return CanRefineLocked();
        }
    }

    /// <summary>Opens the prompt input (the App checks the selection first).</summary>
    public void OpenPromptInput() => SetFlag(ref _promptInputActive, true);

    /// <summary>Closes the prompt input; the App discards its draft.</summary>
    public void CancelPromptInput() => SetFlag(ref _promptInputActive, false);

    /// <summary>Opens the refine input below the result; changes nothing when the result cannot be refined.</summary>
    public void OpenRefineInput()
    {
        lock (_gate)
        {
            if (_refineInputActive || !CanRefineLocked()) return;
            _refineInputActive = true;
        }
        Changed?.Invoke();
    }

    /// <summary>Closes the refine input (the result stays); the App discards its draft.</summary>
    public void CancelRefineInput() => SetFlag(ref _refineInputActive, false);

    /// <summary>Starts editing the result; changes nothing for a diff result or without a result.</summary>
    public void BeginEditing()
    {
        lock (_gate)
        {
            if (_editing || !IsResultEditableLocked()) return;
            _editing = true;
        }
        Changed?.Invoke();
    }

    /// <summary>Ends editing; the edit buffer stays (Copy and Paste back use it).</summary>
    public void EndEditing() => SetFlag(ref _editing, false);

    /// <summary>
    /// The editor's text, while editing. Raises no <see cref="Changed"/>: the editor already shows it, and a refresh
    /// per keystroke would re-layout the toolbar.
    /// </summary>
    public void SetEditText(string text)
    {
        lock (_gate)
        {
            if (_editing && IsResultEditableLocked()) _edited = text;
        }
    }

    /// <summary>Accepts a rejected diff hunk or rejects an accepted one; an index that names no hunk changes nothing.</summary>
    public void ToggleHunk(int index)
    {
        lock (_gate)
        {
            if (_state is not ToolbarState.Result || index < 0 || index >= DiffHunks.HunkRanges(_diff).Count) return;
            var rejected = new HashSet<int>(_rejected);
            if (!rejected.Remove(index)) rejected.Add(index);
            _rejected = rejected;
        }
        Changed?.Invoke();
    }

    /// <summary>
    /// Cancels any run in flight and streams <paramref name="run"/> (or runs its script or lookup). The task completes
    /// when the run ends; the App need not await it. Speak, a missing custom action, Prompt without text, and a lookup
    /// without a dictionary engine change nothing.
    /// </summary>
    public Task RunAsync(ToolbarRun run) => Start(run, followUp: null);

    /// <summary>
    /// Refine: revises the result (as Copy would take it, <see cref="CopyText"/>) per <paramref name="instruction"/>,
    /// through the same action on the same selection (<see cref="ActionRequest.FollowUp"/>). A blank instruction, or a
    /// result that cannot be refined (<see cref="CanRefine"/>), changes nothing.
    /// </summary>
    public Task RefineAsync(string instruction)
    {
        var trimmed = instruction.Trim();
        ToolbarRun? run;
        string previous;
        lock (_gate)
        {
            if (trimmed.Length == 0 || !CanRefineLocked()) return Task.CompletedTask;
            run = _lastRun!;
            previous = CopyTextLocked();
        }
        return Start(run, new FollowUp(previous, trimmed));
    }

    /// <summary>
    /// Re-runs the last run on the same selection (Regenerate on a result, Retry on an error). After a refine, the plain
    /// action runs again without the instruction, as on macOS.
    /// </summary>
    public Task RegenerateAsync()
    {
        ToolbarRun? run;
        lock (_gate)
            run = _state is ToolbarState.Result or ToolbarState.Error ? _lastRun : null;
        return run is null ? Task.CompletedTask : RunAsync(run);
    }

    /// <summary>
    /// Records a Speak in history when it starts (macOS <c>recordSpeak</c>), while history is on and the source is not
    /// ignored: the engine selected (not a fallback that played) and the accent, with the selection as the input and no
    /// output. Speak playback itself never touches the session's state.
    /// </summary>
    /// <param name="run">The selection and its source (<see cref="ToolbarRun.Action"/> is not read).</param>
    /// <param name="actionName">The history name: "Speak", or a Speech custom action's title (<see cref="SpeakVoice"/>).</param>
    public void RecordSpeak(ToolbarRun run, SpeakEngineSelection engine, SpeakAccent accent, string actionName = "Speak")
    {
        var s = settings();
        if (!s.HistoryEnabled || run.SkipHistory)
            return;
        history.Record(new HistoryRecord
        {
            ActionName = actionName,
            ProviderLabel = engine.DisplayName(),
            Model = accent.DisplayName(),
            SourceBundleId = run.SourceExeName,
            SourceAppName = run.SourceAppName ?? run.SourceExeName,
            DurationMs = 0,
            Success = true,
            Input = run.Text,
            Output = "",
        }, s.HistoryStoreFullText);
    }

    /// <summary>
    /// Stop (and toolbar dismissal): cancels the stream and returns to idle. The partial text is discarded and nothing is
    /// recorded, as on macOS, where Stop dismisses the toolbar.
    /// </summary>
    public void Stop()
    {
        lock (_gate)
        {
            CancelLocked();
            if (_state is ToolbarState.IdleState && !_promptInputActive && !_refineInputActive && !_editing)
                return;
            _state = ToolbarState.Idle;
            ClearDiffLocked();
            ClearLookupLocked();
            _edited = "";
            _promptInputActive = false;
            _refineInputActive = false;
            _editing = false;
        }
        Changed?.Invoke();
    }

#if DEBUG
    /// <summary>
    /// DEBUG only, for the App's <c>--selftest-toolbar</c>: shows <paramref name="text"/> as a result without a run (no
    /// provider, no history). Regenerate does nothing afterwards (there is no last run).
    /// </summary>
    public void ShowCanned(string text)
    {
        lock (_gate)
        {
            CancelLocked();
            _lastRun = null;
            _lastKind = null;
            _state = new ToolbarState.Result(text);
            ClearDiffLocked();
            ClearLookupLocked();
            _edited = text;
            _editing = false;
            _refineInputActive = false;
        }
        Changed?.Invoke();
    }
#endif

    /// <summary>
    /// No run started and no Stop since the script run that raised <see cref="ScriptFinished"/> with
    /// <paramref name="generation"/>.
    /// </summary>
    public bool IsCurrentRun(int generation)
    {
        lock (_gate)
            return generation == _generation;
    }

    // A new run (or a refine) replaces the one in flight; editing and the refine input end, and a Prompt run closes
    // the prompt input (macOS startPrompt). Every other run leaves the prompt input as it is, as on macOS.
    private Task Start(ToolbarRun run, FollowUp? followUp)
    {
        var s = settings();
        if (followUp is null && ScriptAction(run, s) is { } script)
            return scripts is null ? Task.CompletedTask : StartScript(run, script, s);
        if (followUp is null && ResolveLookup(run, s) is { } lookup)
            return dictionary is null ? Task.CompletedTask : StartLookup(run, lookup, s);
        if (Resolve(run, s) is not { } resolved)
            return Task.CompletedTask;

        int generation;
        CancellationToken ct;
        lock (_gate)
        {
            CancelLocked();
            generation = _generation;
            _cts = new CancellationTokenSource();
            ct = _cts.Token;
            _lastRun = run;
            _lastKind = resolved.Kind;
            _state = new ToolbarState.Running("");
            _editing = false;
            _refineInputActive = false;
            ClearLookupLocked();
            if (run.Action == ActionIdentifier.Builtin(ActionKind.Prompt))
                _promptInputActive = false;
        }
        Changed?.Invoke();
        return Stream(run, resolved, s, followUp, generation, ct);
    }

    private static CustomAction? ScriptAction(ToolbarRun run, AppSettings s) =>
        run.Action.Type == ActionIdentifierType.Custom
            ? s.CustomActions.FirstOrDefault(a => a.Id == run.Action.CustomId && a.IsScriptable)
            : null;

    // macOS ToolbarViewModel's scriptable branch (spec-4 §4.4). No refine (no provider), no diff.
    private Task StartScript(ToolbarRun run, CustomAction action, AppSettings s)
    {
        int generation;
        CancellationToken ct;
        lock (_gate)
        {
            CancelLocked();
            generation = _generation;
            _cts = new CancellationTokenSource();
            ct = _cts.Token;
            _lastRun = run;
            _lastKind = null;
            _state = new ToolbarState.Running("");
            _editing = false;
            _refineInputActive = false;
            ClearLookupLocked();
        }
        Changed?.Invoke();
        return RunScript(run, action, s, generation, ct);
    }

    private async Task RunScript(ToolbarRun run, CustomAction action, AppSettings s, int generation, CancellationToken ct)
    {
        var startedAt = _clock.GetUtcNow();
        var text = run.Text.Trim();
        string? output = null;
        string? error = null;
        try
        {
            output = (await scripts!.RunAsync(action, text, run.Text, ct)).Text;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            return; // Stopped or replaced: the newer generation owns the state.
        }
        catch (Exception e)
        {
            error = e.Message;
        }

        var shown = error is null && action.AfterRun == AfterRunBehavior.ShowResult && !string.IsNullOrEmpty(output);
        ToolbarState final = error is not null ? new ToolbarState.Error(error)
            : shown ? new ToolbarState.Result(output!)
            : ToolbarState.Idle;
        lock (_gate)
        {
            if (generation != _generation)
                return;
            _state = final;
            ClearDiffLocked();
            _edited = shown ? output! : "";
            _cts?.Dispose();
            _cts = null;
        }
        Changed?.Invoke();

        if (s.HistoryEnabled && !run.SkipHistory)
        {
            history.Record(new HistoryRecord
            {
                ActionName = action.Title,
                ProviderLabel = action.Type.DisplayName(),
                Model = "",
                SourceBundleId = run.SourceExeName,
                SourceAppName = run.SourceAppName ?? run.SourceExeName,
                DurationMs = (int)(_clock.GetUtcNow() - startedAt).TotalMilliseconds,
                Success = error is null,
                ErrorMessage = error,
                Input = text,
                Output = output ?? "",
            }, s.HistoryStoreFullText);
        }
        if (error is null)
            ScriptFinished?.Invoke(new ScriptRunFinished(action.AfterRun, output, generation));
    }

    private sealed record Lookup(string ActionName, DictionaryConfig Config, bool AllProviders, string MissLabel);

    // macOS ActionEngineHandler.dictionary: Look up asks every provider with the global config, a Dictionary custom
    // action only its own provider. The run's TargetLanguage (the Translate picker) is not the definition language.
    private static Lookup? ResolveLookup(ToolbarRun run, AppSettings s)
    {
        if (run.Action.Type == ActionIdentifierType.Dictionary)
            return new("Look up", s.DictionaryConfig, AllProviders: true, "All dictionary providers");
        if (run.Action.Type != ActionIdentifierType.Custom)
            return null;
        var custom = s.CustomActions.FirstOrDefault(a => a.Id == run.Action.CustomId && a.Type == CustomActionType.Dictionary);
        if (custom is null)
            return null;
        var name = custom.Title.Trim().Length == 0 ? "Dictionary" : custom.Title;
        return new(name, custom.DictionaryConfig, AllProviders: false, custom.DictionaryConfig.Provider.DisplayName());
    }

    // The lookup shows the running state at once (click reacts first); no refine, no diff, no edit.
    private Task StartLookup(ToolbarRun run, Lookup lookup, AppSettings s)
    {
        int generation;
        CancellationToken ct;
        lock (_gate)
        {
            CancelLocked();
            generation = _generation;
            _cts = new CancellationTokenSource();
            ct = _cts.Token;
            _lastRun = run;
            _lastKind = null;
            _state = new ToolbarState.Running("");
            _editing = false;
            _refineInputActive = false;
            _lookupAction = run.Action;
            _lookupResults = [];
            _lookupNotFound = false;
        }
        Changed?.Invoke();
        return RunLookup(run, lookup, s, generation, ct);
    }

    private async Task RunLookup(ToolbarRun run, Lookup lookup, AppSettings s, int generation, CancellationToken ct)
    {
        var startedAt = _clock.GetUtcNow();
        var term = run.Text.Trim();
        IReadOnlyList<DictionaryProviderResult> results = [];
        string? error = null;

        async Task<IReadOnlyList<DictionaryProviderResult>> Fetch()
        {
            if (lookup.AllProviders)
                return await dictionary!.LookupAllAsync(term, lookup.Config, ct);
            if (term.Length == 0)
                throw DictionaryLookupException.NotFound();
            return [new DictionaryProviderResult(lookup.Config.Provider, await dictionary!.LookupAsync(term, lookup.Config, ct))];
        }

        try
        {
            // Off the caller's thread: a Babylon lookup reads and indexes its files before its first await.
            results = await Task.Run(Fetch, ct);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            return; // Stopped or replaced: the newer generation owns the state.
        }
        catch (DictionaryLookupException e) when (e.Kind == DictionaryLookupErrorKind.NotFound)
        {
        }
        catch (DictionaryLookupException e)
        {
            error = e.Message;
        }
        catch (Exception e)
        {
            error = DictionaryLookupException.Network(e.Message).Message;
        }

        var found = error is null && results.Count > 0;
        var preview = found ? LookupPreview(results[0].Entry) : "";
        ToolbarState final = error is not null ? new ToolbarState.Error(error) : new ToolbarState.Result(preview);
        lock (_gate)
        {
            if (generation != _generation)
                return;
            _state = final;
            ClearDiffLocked();
            _edited = preview;
            _lookupResults = found ? results : [];
            _lookupNotFound = error is null && !found;
            _cts?.Dispose();
            _cts = null;
        }
        Changed?.Invoke();

        // macOS runDictionary: a miss is a failure, so history never counts "No definition found" as a result.
        if (s.HistoryEnabled && !run.SkipHistory)
        {
            history.Record(new HistoryRecord
            {
                ActionName = lookup.ActionName,
                ProviderLabel = found ? string.Join(", ", results.Select(r => r.ProviderKind.DisplayName())) : lookup.MissLabel,
                Model = lookup.Config.DefinitionLanguage,
                SourceBundleId = run.SourceExeName,
                SourceAppName = run.SourceAppName ?? run.SourceExeName,
                DurationMs = (int)(_clock.GetUtcNow() - startedAt).TotalMilliseconds,
                Success = found,
                ErrorMessage = found ? null : error ?? DictionaryLookupException.NotFound().Message,
                Input = run.Text,
                Output = found ? string.Join("\n\n", results.Select(r => LookupPreview(r.Entry))) : "",
            }, s.HistoryStoreFullText);
        }
    }

    /// <summary>An entry's one-line summary (macOS dictionaryPreview): its first definition, else its text, else the headword.</summary>
    private static string LookupPreview(DictionaryEntry entry) =>
        entry.LexicalEntries.FirstOrDefault()?.Senses.FirstOrDefault()?.Definition ?? entry.RawText ?? entry.Headword;

    /// <summary>
    /// The Listen button's voice for a lookup by <paramref name="action"/> (macOS triggerDictionaryListen): a Dictionary
    /// custom action's own accent, speech settings and cloud config (none for the system voice); else Look up's, with
    /// the selected cloud engine's config from the settings.
    /// </summary>
    public static DictionaryListenVoice ListenVoice(AppSettings s, ActionIdentifier action)
    {
        var custom = action.Type == ActionIdentifierType.Custom
            ? s.CustomActions.FirstOrDefault(a => a.Id == action.CustomId && a.Type == CustomActionType.Dictionary)
            : null;
        if (custom is not null)
        {
            var own = custom.DictionaryConfig;
            return new(own.Accent, own.SpeakSettings,
                own.SpeakSettings.SelectedEngine.CloudProvider is null ? new TtsProviderConfig() : custom.TtsConfig);
        }
        var config = s.DictionaryConfig;
        var tts = config.SpeakSettings.SelectedEngine.CloudProvider is { } kind
            ? s.TtsProviderConfigs.GetValueOrDefault(RawValueEnumConverter<TtsProviderKind>.ToRaw(kind)) ?? new TtsProviderConfig()
            : new TtsProviderConfig();
        return new(config.Accent, config.SpeakSettings, tts);
    }

    /// <summary>
    /// The voice a Speak toggle by <paramref name="action"/> speaks with (macOS triggerSpeak, triggerCustomAction's
    /// speech branch): the built-in Speak uses the Speak settings, their default accent and the selected cloud engine's
    /// config from the settings; a Speech custom action its own speech settings, their default accent and its own cloud
    /// config; history names both "Speak" (macOS recordSpeak). Null for every other action: it does not speak.
    /// </summary>
    public static SpeakVoice? SpeakVoiceFor(AppSettings s, ActionIdentifier action)
    {
        if (action.Type == ActionIdentifierType.Speak)
        {
            var speak = s.SpeakSettings;
            var tts = speak.SelectedEngine.CloudProvider is { } kind
                ? s.TtsProviderConfigs.GetValueOrDefault(RawValueEnumConverter<TtsProviderKind>.ToRaw(kind)) ?? new TtsProviderConfig()
                : new TtsProviderConfig();
            return new("Speak", speak.DefaultAccent, speak, tts);
        }
        if (action.Type != ActionIdentifierType.Custom)
            return null;
        var custom = s.CustomActions.FirstOrDefault(a => a.Id == action.CustomId && a.Type == CustomActionType.Speech);
        if (custom is null)
            return null;
        return new("Speak", custom.SpeakSettings.DefaultAccent, custom.SpeakSettings, custom.TtsConfig);
    }

    private sealed record Resolved(EngineAction Action, string ActionName, ProviderKind Kind, string Model, string Language);

    // The EngineAction mapping of macOS ActionEngineHandler (Phase 6 → 8 follow-up).
    private static Resolved? Resolve(ToolbarRun run, AppSettings s)
    {
        var target = run.TargetLanguage ?? s.DefaultTargetLanguage;
        var language = run.LanguageName ?? target;
        Resolved Builtin(ActionConfig c, EngineAction action, string name) => new(action, name, c.ProviderKind, c.Model, language);

        switch (run.Action.Type)
        {
            case ActionIdentifierType.Builtin:
                return run.Action.BuiltinKind switch
                {
                    ActionKind.Improve => Builtin(s.ImproveConfig,
                        new EngineAction.Improve(s.ImproveConfig.CustomPrompt, s.ImproveConfig.Tone ?? TranslateTone.Neutral), "Improve"),
                    ActionKind.Shorten => Builtin(s.ShortenConfig,
                        new EngineAction.Shorten(s.ShortenConfig.CustomPrompt, s.ShortenConfig.Tone ?? TranslateTone.Neutral), "Shorten"),
                    ActionKind.Proofread => Builtin(s.ProofreadConfig,
                        new EngineAction.Proofread(s.ProofreadConfig.CustomPrompt), "Proofread"),
                    ActionKind.Translate => Builtin(s.TranslateConfig,
                        new EngineAction.Translate(target, s.TranslateConfig.CustomPrompt, s.TranslateConfig.Tone ?? TranslateTone.Neutral),
                        "Translate"),
                    ActionKind.Prompt when !string.IsNullOrWhiteSpace(run.PromptText) =>
                        Builtin(s.PromptConfig, new EngineAction.Custom(run.PromptText), "Prompt"),
                    _ => null,
                };
            case ActionIdentifierType.Custom:
                var custom = s.CustomActions.FirstOrDefault(a => a.Id == run.Action.CustomId);
                return custom?.Type switch
                {
                    CustomActionType.Ai => new(new EngineAction.Custom(custom.SystemPrompt), custom.Title,
                        custom.ProviderKind, custom.Model, language),
                    CustomActionType.Translation => new(
                        new EngineAction.Translate(custom.TargetLanguage,
                            custom.SystemPrompt.Length == 0 ? null : custom.SystemPrompt, custom.Tone),
                        custom.Title, custom.ProviderKind, custom.Model, custom.TargetLanguage),
                    _ => null,
                };
            default:
                return null;
        }
    }

    private async Task Stream(
        ToolbarRun run, Resolved resolved, AppSettings s, FollowUp? followUp, int generation, CancellationToken ct)
    {
        var startedAt = _clock.GetUtcNow();
        var request = new ActionRequest(resolved.Action, run.Text, resolved.Kind, resolved.Model)
        {
            BaseUrl = ProviderFactory.ResolveBaseUrl(resolved.Kind, s),
            ExecutablePath = ProviderFactory.ResolveExecutablePath(resolved.Kind, s),
            PreserveFormatting = s.PreserveFormatting,
            GlobalPrompt = s.GlobalPrompt,
            Context = new PromptContext(
                run.SourceAppName ?? "", run.SourceDomain ?? "",
                PromptContext.DateString(startedAt, _clock.LocalTimeZone), resolved.Language),
            FollowUp = followUp,
        };

        var buffer = new StringBuilder();
        var lastRaised = startedAt;
        ToolbarState final;
        IReadOnlyList<DiffSegment> diff = [];
        string? error = null;
        try
        {
            // Every engine failure surfaces on the first MoveNextAsync, so one try covers the whole enumeration.
            await foreach (var token in engine.StreamAsync(request, ct))
            {
                buffer.Append(token);
                var now = _clock.GetUtcNow();
                if (now - lastRaised < ProgressInterval)
                    continue;
                lastRaised = now;
                if (!TrySet(generation, new ToolbarState.Running(buffer.ToString())))
                    return;
                Changed?.Invoke();
            }
            var text = ActionEngine.StripWrappingQuotes(buffer.ToString(), run.Text);
            final = new ToolbarState.Result(text);
            // Improve and Proofread show what changed (their output mirrors the input); custom actions never do.
            if (run.Action is { Type: ActionIdentifierType.Builtin, BuiltinKind: ActionKind.Improve or ActionKind.Proofread })
                diff = DiffAlgorithm.Diff(run.Text, text);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            return; // Stopped or replaced: the newer generation owns the state.
        }
        catch (Exception e)
        {
            error = e.Message;
            final = new ToolbarState.Error(error);
        }

        lock (_gate)
        {
            if (generation != _generation)
                return;
            _state = final;
            _diff = diff;
            _rejected = new HashSet<int>();
            _edited = final is ToolbarState.Result finished ? finished.Text : "";
            _cts?.Dispose();
            _cts = null;
        }
        Changed?.Invoke();

        if (s.HistoryEnabled && !run.SkipHistory)
        {
            history.Record(new HistoryRecord
            {
                ActionName = resolved.ActionName,
                ProviderKind = resolved.Kind,
                Model = resolved.Model,
                SourceBundleId = run.SourceExeName,
                SourceAppName = run.SourceAppName ?? run.SourceExeName,
                DurationMs = (int)(_clock.GetUtcNow() - startedAt).TotalMilliseconds,
                Success = error is null,
                ErrorMessage = error,
                Input = run.Text,
                Output = final is ToolbarState.Result result ? result.Text : "",
            }, s.HistoryStoreFullText);
        }
    }

    private bool TrySet(int generation, ToolbarState state)
    {
        lock (_gate)
        {
            if (generation != _generation)
                return false;
            _state = state;
            return true;
        }
    }

    private string CopyTextLocked()
    {
        if (_state is not ToolbarState.Result) return "";
        return _diff.Count == 0 ? _edited : DiffHunks.Merged(_diff, _rejected);
    }

    private bool IsResultEditableLocked() => _state is ToolbarState.Result && _diff.Count == 0 && _lookupAction is null;

    private bool CanRefineLocked() =>
        _state is ToolbarState.Result && _lastRun is not null
        && _lastKind is not (null or ProviderKind.DeepL or ProviderKind.GoogleTranslate);

    /// <summary>Sets a text-input flag; raises <see cref="Changed"/> only when it changed.</summary>
    private void SetFlag(ref bool flag, bool value)
    {
        lock (_gate)
        {
            if (flag == value) return;
            flag = value;
        }
        Changed?.Invoke();
    }

    private void ClearDiffLocked()
    {
        _diff = [];
        _rejected = new HashSet<int>();
    }

    private void ClearLookupLocked()
    {
        _lookupAction = null;
        _lookupResults = [];
        _lookupNotFound = false;
    }

    // Bump the generation first so the old run's late tokens and completion are discarded (spec-2 §2.7). The cancelled
    // source is not disposed: its stream may still register on the token while it unwinds.
    private void CancelLocked()
    {
        _generation++;
        _cts?.Cancel();
        _cts = null;
    }
}
