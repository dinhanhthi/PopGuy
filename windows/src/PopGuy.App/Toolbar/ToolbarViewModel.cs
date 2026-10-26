using System.ComponentModel;
using Microsoft.UI.Dispatching;
using PopGuy.Core.Actions;
using PopGuy.Core.Diff;
using PopGuy.Core.Settings;
using PopGuy.Core.Toolbar;

namespace PopGuy.Toolbar;

/// <summary>
/// One button of the inline action row: its visible label and its icon, either a Segoe Fluent Icons glyph or an emoji
/// (exactly one is set).
/// </summary>
public sealed partial record ToolbarActionItem(ActionIdentifier Id, string Label, string? Glyph, string? Emoji);

/// <summary>
/// The toolbar window's state (macOS <c>ToolbarViewModel.swift</c>, the UI half; the logic is Core's
/// <see cref="ToolbarSession"/>). It shows the session's state, plus two app-level messages the session does not own:
/// <see cref="Fail"/> (an error with no run to retry, e.g. the admin-app error) and <see cref="ShowNotice"/> (a note
/// next to a result, e.g. "Copied instead"). The window's clicks become the <c>…Requested</c> / <see cref="ActionInvoked"/>
/// events, which the controller handles; Regenerate, Retry, Refine and Edit go to the session directly. The prompt and
/// refine drafts live here (the controller's Esc and outside-click rules read them). UI thread only, except the
/// session's <c>Changed</c>, which may arrive on any thread and is marshalled here.
/// </summary>
public sealed partial class ToolbarViewModel : INotifyPropertyChanged
{
    /// <summary>The properties that follow the state; raised together on every refresh.</summary>
    private static readonly string[] StateProperties =
    [
        nameof(IsRunning), nameof(IsResult), nameof(IsError), nameof(ShowsBody), nameof(ShowsClose), nameof(ActionsEnabled),
        nameof(ShowsSpinner), nameof(ShowsProgressText), nameof(ProgressText), nameof(ResultText), nameof(ErrorMessage),
        nameof(CanRetry), nameof(ShowsPasteBack), nameof(Notice), nameof(HasNotice), nameof(IsConfirmingClose),
        nameof(IsDiffResult), nameof(ShowDiff), nameof(ShowsDiffView), nameof(ShowsPlainResult), nameof(DiffSegments),
        nameof(RejectedHunks), nameof(ShowsMarkdownResult), nameof(IsPromptInputActive), nameof(IsRefineInputActive),
        nameof(IsEditing), nameof(IsResultEditable), nameof(ShowsEditor), nameof(ShowsEditButton), nameof(ShowsDoneButton),
        nameof(ShowsRegenerate), nameof(ShowsRefine), nameof(RefineEnabled), nameof(ShowsPromptDivider),
        nameof(ShowsReadView),
    ];

    private readonly ToolbarSession _session;
    private readonly DispatcherQueue _dispatcher;
    private ToolbarState _state = ToolbarState.Idle;
    private IReadOnlyList<DiffSegment> _diff = [];
    private IReadOnlySet<int> _rejected = new HashSet<int>();
    private bool _showDiff = true;
    private string? _failMessage;
    private string _notice = "";
    private bool _confirmingClose;
    private IReadOnlyList<ToolbarActionItem> _actions = [];
    private bool _showsLogo = true;
    private bool _isEditable;
    private bool _preserveFormatting;
    private bool _detached;
    private bool _promptInputActive;
    private bool _refineInputActive;
    private bool _editing;
    private bool _resultEditable;
    private bool _canRefine;

    public ToolbarViewModel(ToolbarSession session, DispatcherQueue dispatcher)
    {
        _session = session;
        _dispatcher = dispatcher;
        _session.Changed += OnSessionChanged;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>An action button was clicked: the controller builds the <see cref="ToolbarRun"/> and calls <see cref="Run"/>.</summary>
    public event Action<ActionIdentifier>? ActionInvoked;

    /// <summary>Stop was clicked while running (macOS: Stop dismisses the toolbar, which cancels the stream).</summary>
    public event Action? StopRequested;

    /// <summary>Copy was clicked; the argument is the text to put on the clipboard.</summary>
    public event Action<string>? CopyRequested;

    /// <summary>Paste back was clicked; the argument is the text to paste into the source.</summary>
    public event Action<string>? PasteBackRequested;

    /// <summary>The prompt was submitted (Run or Enter); the argument is the trimmed, non-empty prompt.</summary>
    public event Action<string>? PromptSubmitted;

    /// <summary>The prompt input's Cancel: closes the toolbar at once (macOS: a deliberate Cancel skips the draft guard).</summary>
    public event Action? PromptCancelRequested;

    /// <summary>Close was clicked: a dismiss request (the controller applies the close confirmation).</summary>
    public event Action? CloseRequested;

    /// <summary>Esc in the activated toolbar: a dismiss request like an outside click (a non-empty draft keeps it open).</summary>
    public event Action? EscapeRequested;

    /// <summary>"Close Anyway" in the close confirmation.</summary>
    public event Action? CloseAnywayRequested;

    /// <summary>"Turn This Setting Off" in the close confirmation: the controller turns confirmCloseAfterResult off and closes.</summary>
    public event Action? DisableCloseConfirmationRequested;

    /// <summary>The inline row (<see cref="ToolbarLayout.PrincipalOrdered"/>), in order.</summary>
    public IReadOnlyList<ToolbarActionItem> Actions
    {
        get => _actions;
        private set
        {
            _actions = value;
            Raise(nameof(Actions));
        }
    }

    public bool ShowsLogo
    {
        get => _showsLogo;
        private set
        {
            _showsLogo = value;
            Raise(nameof(ShowsLogo));
        }
    }

    /// <summary>The selection is in an editable field: Paste back is offered (spec-1 §2.5).</summary>
    public bool IsEditable
    {
        get => _isEditable;
        private set
        {
            _isEditable = value;
            Raise(nameof(IsEditable));
            Raise(nameof(ShowsPasteBack));
        }
    }

    public bool IsRunning => _failMessage is null && _state is ToolbarState.Running;

    public bool IsResult => _failMessage is null && _state is ToolbarState.Result;

    public bool IsError => _failMessage is not null || _state is ToolbarState.Error;

    /// <summary>Anything below the action row (the prompt input, running, result or error).</summary>
    public bool ShowsBody => IsPromptInputActive || IsRunning || IsResult || IsError;

    /// <summary>Close is hidden while running: Stop is the explicit exit then (spec-1 §3.5).</summary>
    public bool ShowsClose => !IsRunning;

    /// <summary>The action buttons are disabled while an action runs.</summary>
    public bool ActionsEnabled => !IsRunning;

    public bool ShowsSpinner => IsRunning && ProgressText.Length == 0;

    public bool ShowsProgressText => IsRunning && ProgressText.Length > 0;

    public string ProgressText => _state is ToolbarState.Running running ? running.Progress : "";

    /// <summary>The result as text: for a diff, the merged text (what Copy and Paste back use, macOS displayedResult).</summary>
    public string ResultText => IsResult ? _session.CopyText() : "";

    /// <summary>An Improve or Proofread result: it has a diff, and the Diff/Text toggle shows.</summary>
    public bool IsDiffResult => IsResult && _diff.Count > 0;

    /// <summary>
    /// The Diff/Text toggle's choice (macOS showImproveDiff): the inline diff, or the merged text. Never reset by a
    /// presentation, so the choice sticks for the app session; the diff is the default.
    /// </summary>
    public bool ShowDiff => _showDiff;

    public bool ShowsDiffView => IsDiffResult && _showDiff;

    public bool ShowsPlainResult => IsResult && !ShowsDiffView && !ShowsMarkdownResult && !IsEditing;

    /// <summary>
    /// The result rendered as Markdown ("Preserve &amp; render formatting", macOS MarkdownResultView). Never for an
    /// Improve or Proofread result: its Text mode stays plain, as on macOS. Copy and Paste back keep the raw Markdown.
    /// </summary>
    public bool ShowsMarkdownResult => IsResult && !IsDiffResult && _preserveFormatting && !IsEditing;

    /// <summary>The result's diff segments (computed once by the session when the run finished).</summary>
    public IReadOnlyList<DiffSegment> DiffSegments => _diff;

    /// <summary>The diff hunks the user rejected.</summary>
    public IReadOnlySet<int> RejectedHunks => _rejected;

    public string ErrorMessage => _failMessage ?? (_state is ToolbarState.Error error ? error.Message : "");

    /// <summary>A failed run can run again; an app-level error (<see cref="Fail"/>) cannot.</summary>
    public bool CanRetry => _failMessage is null && _state is ToolbarState.Error;

    public bool ShowsPasteBack => IsResult && IsEditable;

    public string Notice => _notice;

    public bool HasNotice => _notice.Length > 0;

    /// <summary>"Close without using the result?" shows below the result (spec-1 §3.8; inline, the toolbar never activates).</summary>
    public bool IsConfirmingClose => _confirmingClose && IsResult;

    /// <summary>The prompt input shows below the action row.</summary>
    public bool IsPromptInputActive => _promptInputActive;

    /// <summary>A divider between the prompt input and the running, result or error panel below it.</summary>
    public bool ShowsPromptDivider => IsPromptInputActive && (IsRunning || IsResult || IsError);

    /// <summary>The refine input shows below the result.</summary>
    public bool IsRefineInputActive => IsResult && _refineInputActive;

    /// <summary>The result is being edited.</summary>
    public bool IsEditing => IsResult && _editing;

    /// <summary>The result can be edited (every result but a diff, as on macOS).</summary>
    public bool IsResultEditable => IsResult && _resultEditable;

    /// <summary>The editor replaces the result text while editing.</summary>
    public bool ShowsEditor => IsEditing;

    /// <summary>The read view (text, diff or Markdown); collapsed while editing.</summary>
    public bool ShowsReadView => !IsEditing;

    public bool ShowsEditButton => IsResultEditable && !IsEditing;

    public bool ShowsDoneButton => IsEditing;

    /// <summary>Regenerate and Refine hide while editing, as on macOS.</summary>
    public bool ShowsRegenerate => IsResult && !IsEditing;

    public bool ShowsRefine => IsResult && _canRefine && !IsEditing;

    /// <summary>Refine is disabled while its input is open.</summary>
    public bool RefineEnabled => !IsRefineInputActive;

    /// <summary>The prompt input's text, as typed.</summary>
    public string PromptDraft { get; set; } = "";

    /// <summary>The refine input's text, as typed.</summary>
    public string RefineDraft { get; set; } = "";

    /// <summary>A non-empty prompt or refine draft is open: an outside click or Esc keeps the toolbar (macOS).</summary>
    public bool HasOpenDraft =>
        (IsPromptInputActive && PromptDraft.Trim().Length > 0) || (IsRefineInputActive && RefineDraft.Trim().Length > 0);

    // Controller → view model.

    /// <summary>
    /// A new presentation: stops any run, clears the messages and reads the inline row, the logo and the Markdown
    /// rendering from <paramref name="settings"/> (settings apply at the next presentation, spec-1 §3.7).
    /// </summary>
    public void Present(AppSettings settings, bool isEditable)
    {
        _session.Stop();
        PromptDraft = "";
        RefineDraft = "";
        Actions = [.. ToolbarLayout.PrincipalOrdered(settings).Select(id => ItemFor(settings, id)).OfType<ToolbarActionItem>()];
        ShowsLogo = !settings.HideToolbarLogo;
        _preserveFormatting = settings.PreserveFormatting;
        IsEditable = isEditable;
        ClearMessages();
        Refresh();
    }

    /// <summary>Streams <paramref name="run"/>; actions that are not provider-backed change nothing (see the session).</summary>
    public void Run(ToolbarRun run)
    {
        ClearMessages();
        _ = _session.RunAsync(run);
        Refresh();
    }

    /// <summary>Cancels any run and returns to idle (every hide calls it).</summary>
    public void Stop()
    {
        _session.Stop();
        PromptDraft = "";
        RefineDraft = "";
        ClearMessages();
        Refresh();
    }

    /// <summary>Shows <paramref name="message"/> as the error, without Retry (an app-level error, not a failed run).</summary>
    public void Fail(string message)
    {
        _session.Stop();
        _failMessage = message;
        Refresh();
    }

    /// <summary>Shows <paramref name="message"/> as a note below the result (e.g. "Copied instead").</summary>
    public void ShowNotice(string message)
    {
        _notice = message;
        Refresh();
    }

    /// <summary>Shows the close confirmation below the result (the controller calls it for a dismiss request on a result).</summary>
    public void ShowCloseConfirmation()
    {
        _confirmingClose = true;
        Refresh();
    }

    /// <summary>The session's state changed: refresh now on the UI thread (click reacts first), else on the next tick.</summary>
    private void OnSessionChanged()
    {
        if (_dispatcher.HasThreadAccess) Refresh();
        else _dispatcher.TryEnqueue(Refresh);
    }

    /// <summary>The window closed: stops following the session and stops any run (no refresh: the window is gone).</summary>
    public void Detach()
    {
        _detached = true;
        _session.Changed -= OnSessionChanged;
        _session.Stop();
    }

    // Window → view model (the clicks).

    public void Invoke(ActionIdentifier id) => ActionInvoked?.Invoke(id);

    public void RequestStop() => StopRequested?.Invoke();

    public void RequestCopy() => CopyRequested?.Invoke(_session.CopyText());

    public void RequestPasteBack() => PasteBackRequested?.Invoke(_session.CopyText());

    /// <summary>The Prompt button or hotkey (macOS triggerPromptInput): opens the prompt input, or cancels it when open.</summary>
    public void TogglePromptInput()
    {
        if (_session.IsPromptInputActive) CancelPromptInput();
        else _session.OpenPromptInput();
    }

    /// <summary>Closes the prompt input and discards the draft.</summary>
    public void CancelPromptInput()
    {
        PromptDraft = "";
        _session.CancelPromptInput();
    }

    /// <summary>Run or Enter in the prompt input: a blank draft does nothing; else the controller runs it.</summary>
    public void SubmitPrompt()
    {
        var prompt = PromptDraft.Trim();
        if (prompt.Length == 0) return;
        PromptDraft = "";
        PromptSubmitted?.Invoke(prompt);
    }

    public void RequestPromptCancel() => PromptCancelRequested?.Invoke();

    /// <summary>Refine (macOS openRefineInput): opens the refine input below the result, if the result can be refined.</summary>
    public void OpenRefineInput() => _session.OpenRefineInput();

    /// <summary>The refine input's Cancel: closes the input only, the result stays.</summary>
    public void CancelRefineInput()
    {
        RefineDraft = "";
        _session.CancelRefineInput();
    }

    /// <summary>Run or Enter in the refine input: a blank draft does nothing; else the result is revised.</summary>
    public void SubmitRefine()
    {
        var instruction = RefineDraft.Trim();
        if (instruction.Length == 0) return;
        RefineDraft = "";
        ClearMessages();
        _ = _session.RefineAsync(instruction);
        Refresh();
    }

    /// <summary>Edit: the editor replaces the result text, seeded with <see cref="ResultText"/>.</summary>
    public void BeginEditing() => _session.BeginEditing();

    /// <summary>Done: the edited text stays the result (Copy and Paste back use it).</summary>
    public void EndEditing() => _session.EndEditing();

    /// <summary>The editor's text changed (no refresh: the editor already shows it).</summary>
    public void SetEditText(string text) => _session.SetEditText(text);

    public void RequestClose() => CloseRequested?.Invoke();

    public void RequestEscape() => EscapeRequested?.Invoke();

    public void RequestCloseAnyway() => CloseAnywayRequested?.Invoke();

    public void RequestDisableCloseConfirmation() => DisableCloseConfirmationRequested?.Invoke();

    /// <summary>The Diff/Text toggle: shows the inline diff (<paramref name="show"/>) or the merged text.</summary>
    public void SetShowDiff(bool show)
    {
        _showDiff = show;
        Refresh();
    }

    /// <summary>A click on a diff hunk: accepts it if rejected, else rejects it (Copy then keeps its original text).</summary>
    public void ToggleHunk(int index) => _session.ToggleHunk(index);

    /// <summary>"Keep Open": the confirmation goes, the toolbar and its result stay.</summary>
    public void KeepOpen()
    {
        _confirmingClose = false;
        Refresh();
    }

    /// <summary>Regenerate (on a result) and Retry (on a failed run): the same selection and action again.</summary>
    public void Regenerate()
    {
        RefineDraft = "";
        ClearMessages();
        _ = _session.RegenerateAsync();
        Refresh();
    }

    private void ClearMessages()
    {
        _failMessage = null;
        _notice = "";
        _confirmingClose = false;
    }

    private void Refresh()
    {
        if (_detached) return; // a refresh queued before the window closed
        _state = _session.State;
        _diff = _session.DiffSegments;
        _rejected = _session.RejectedHunks;
        _promptInputActive = _session.IsPromptInputActive;
        _refineInputActive = _session.IsRefineInputActive;
        _editing = _session.IsEditing;
        _resultEditable = _session.IsResultEditable;
        _canRefine = _session.CanRefine;
        foreach (var name in StateProperties) Raise(name);
    }

    private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    // The row's labels and icons (macOS ToolbarView.actionControl).

    private static ToolbarActionItem? ItemFor(AppSettings settings, ActionIdentifier id)
    {
        switch (id.Type)
        {
            case ActionIdentifierType.Builtin:
                return id.BuiltinKind switch
                {
                    ActionKind.Improve => Builtin(id, "Improve", "wand.and.stars"),
                    ActionKind.Shorten => Builtin(id, "Shorten", "text.badge.minus"),
                    ActionKind.Proofread => Builtin(id, "Proofread", "checkmark.bubble"),
                    ActionKind.Prompt => Builtin(id, "Prompt", "bubble.and.pencil"),
                    ActionKind.Translate => Builtin(id, "Translate", "character.bubble"),
                    _ => null,
                };
            case ActionIdentifierType.Speak or ActionIdentifierType.Dictionary:
                // Not on the row until Speak (Phase 17) and Look up (Phase 18) exist: a button would do nothing.
                return null;
            default:
                var custom = settings.CustomActions.FirstOrDefault(a => a.Id == id.CustomId);
                if (custom is null) return null;
                return custom.Icon.Type == ActionIconType.Emoji
                    ? new ToolbarActionItem(id, custom.Title, null, custom.Icon.Value)
                    : new ToolbarActionItem(id, custom.Title, Glyph(custom.Icon.Value), null);
        }
    }

    private static ToolbarActionItem Builtin(ActionIdentifier id, string label, string sfSymbol) => new(id, label, Glyph(sfSymbol), null);

    /// <summary>
    /// The Segoe Fluent Icons glyph for an SF Symbol name: the built-ins' symbols and a few common ones; anything else
    /// gets the star (the default custom icon is "sparkles").
    /// </summary>
    internal static string Glyph(string sfSymbol) => sfSymbol switch
    {
        "wand.and.stars" => "\uE70F", // Edit
        "text.badge.minus" => "\uE738", // Remove
        "checkmark.bubble" or "checkmark" => "\uE73E", // CheckMark
        "bubble.and.pencil" or "text.bubble" => "\uE8F2", // ChatBubbles
        "character.bubble" or "globe" => "\uE774", // Globe
        "character.book.closed" or "book" => "\uE82D", // Dictionary
        "speaker.wave.2" => "\uE767", // Volume
        "doc.on.doc" => "\uE8C8", // Copy
        "pencil" => "\uE70F", // Edit
        _ => "\uE734", // FavoriteStar (sparkles, star and unknown names)
    };
}
