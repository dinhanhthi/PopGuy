using System.Text;
using PopGuy.Core.Actions;
using PopGuy.Core.Diff;
using PopGuy.Core.History;
using PopGuy.Core.Providers;
using PopGuy.Core.Settings;

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
/// Runs one provider action at a time and holds the toolbar state. <see cref="Changed"/> is raised on any thread (the
/// App marshals to its UI thread): on every state transition, and while streaming at most once per
/// <see cref="ProgressInterval"/>. A run that is stopped or replaced leaves no trace: no state change, no history
/// (macOS generation guard, spec-2 §2.7). There is no automatic retry (spec-2 §2.8): Retry and Regenerate run again.
/// </summary>
public sealed class ToolbarSession(ActionEngine engine, HistoryStore history, Func<AppSettings> settings, TimeProvider? clock = null)
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
    private ToolbarRun? _lastRun;

    // The result's diff (Improve and Proofread only), computed once when the run finishes, and the hunks the user
    // rejected; both reset with every new result. Replaced, never mutated, so a read under the lock is a snapshot.
    private IReadOnlyList<DiffSegment> _diff = [];
    private IReadOnlySet<int> _rejected = new HashSet<int>();

    public event Action? Changed;

    public ToolbarState State
    {
        get
        {
            lock (_gate)
                return _state;
        }
    }

    /// <summary>Set by the speak coordinator (Phase 17); feeds <see cref="PresentationInput.SpeakActive"/>.</summary>
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
    /// The text Copy and Paste back use: for a diff, the merged text (accepted hunks, the original text of rejected
    /// ones); else the result; "" without a result.
    /// </summary>
    public string CopyText()
    {
        lock (_gate)
        {
            if (_state is not ToolbarState.Result result) return "";
            return _diff.Count == 0 ? result.Text : DiffHunks.Merged(_diff, _rejected);
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
    /// Cancels any run in flight and streams <paramref name="run"/>. The task completes when the run ends; the App need
    /// not await it. Actions that are not provider-backed (Speak, Look up, script types, a missing custom action, Prompt
    /// without text) change nothing.
    /// </summary>
    public Task RunAsync(ToolbarRun run)
    {
        var s = settings();
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
            _state = new ToolbarState.Running("");
        }
        Changed?.Invoke();
        return Stream(run, resolved, s, generation, ct);
    }

    /// <summary>Re-runs the last run on the same selection (Regenerate on a result, Retry on an error).</summary>
    public Task RegenerateAsync()
    {
        ToolbarRun? run;
        lock (_gate)
            run = _state is ToolbarState.Result or ToolbarState.Error ? _lastRun : null;
        return run is null ? Task.CompletedTask : RunAsync(run);
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
            if (_state is ToolbarState.IdleState)
                return;
            _state = ToolbarState.Idle;
            ClearDiffLocked();
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
            _state = new ToolbarState.Result(text);
            ClearDiffLocked();
        }
        Changed?.Invoke();
    }
#endif

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

    private async Task Stream(ToolbarRun run, Resolved resolved, AppSettings s, int generation, CancellationToken ct)
    {
        var startedAt = _clock.GetUtcNow();
        var request = new ActionRequest(resolved.Action, run.Text, resolved.Kind, resolved.Model)
        {
            BaseUrl = ProviderFactory.ResolveBaseUrl(resolved.Kind, s),
            PreserveFormatting = s.PreserveFormatting,
            GlobalPrompt = s.GlobalPrompt,
            Context = new PromptContext(
                run.SourceAppName ?? "", run.SourceDomain ?? "",
                PromptContext.DateString(startedAt, _clock.LocalTimeZone), resolved.Language),
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

    private void ClearDiffLocked()
    {
        _diff = [];
        _rejected = new HashSet<int>();
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
