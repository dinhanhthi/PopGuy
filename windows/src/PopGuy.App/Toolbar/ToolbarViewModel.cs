using System.ComponentModel;
using Microsoft.UI.Dispatching;
using PopGuy.Core.Actions;
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
/// events, which the controller handles; Regenerate and Retry re-run the session's last run directly. UI thread only,
/// except the session's <c>Changed</c>, which may arrive on any thread and is marshalled here.
/// </summary>
public sealed partial class ToolbarViewModel : INotifyPropertyChanged
{
    /// <summary>The properties that follow the state; raised together on every refresh.</summary>
    private static readonly string[] StateProperties =
    [
        nameof(IsRunning), nameof(IsResult), nameof(IsError), nameof(ShowsBody), nameof(ShowsClose), nameof(ActionsEnabled),
        nameof(ShowsSpinner), nameof(ShowsProgressText), nameof(ProgressText), nameof(ResultText), nameof(ErrorMessage),
        nameof(CanRetry), nameof(ShowsPasteBack), nameof(Notice), nameof(HasNotice),
    ];

    private readonly ToolbarSession _session;
    private readonly DispatcherQueue _dispatcher;
    private ToolbarState _state = ToolbarState.Idle;
    private string? _failMessage;
    private string _notice = "";
    private IReadOnlyList<ToolbarActionItem> _actions = [];
    private bool _showsLogo = true;
    private bool _isEditable;
    private bool _detached;

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

    /// <summary>Close was clicked: a dismiss request (the controller applies the close confirmation).</summary>
    public event Action? CloseRequested;

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

    /// <summary>Anything below the action row (running, result or error).</summary>
    public bool ShowsBody => IsRunning || IsResult || IsError;

    /// <summary>Close is hidden while running: Stop is the explicit exit then (spec-1 §3.5).</summary>
    public bool ShowsClose => !IsRunning;

    /// <summary>The action buttons are disabled while an action runs.</summary>
    public bool ActionsEnabled => !IsRunning;

    public bool ShowsSpinner => IsRunning && ProgressText.Length == 0;

    public bool ShowsProgressText => IsRunning && ProgressText.Length > 0;

    public string ProgressText => _state is ToolbarState.Running running ? running.Progress : "";

    public string ResultText => _state is ToolbarState.Result result ? result.Text : "";

    public string ErrorMessage => _failMessage ?? (_state is ToolbarState.Error error ? error.Message : "");

    /// <summary>A failed run can run again; an app-level error (<see cref="Fail"/>) cannot.</summary>
    public bool CanRetry => _failMessage is null && _state is ToolbarState.Error;

    public bool ShowsPasteBack => IsResult && IsEditable;

    public string Notice => _notice;

    public bool HasNotice => _notice.Length > 0;

    // Controller → view model.

    /// <summary>
    /// A new presentation: stops any run, clears the messages and reads the inline row and the logo from
    /// <paramref name="settings"/> (settings apply at the next presentation, spec-1 §3.7).
    /// </summary>
    public void Present(AppSettings settings, bool isEditable)
    {
        _session.Stop();
        Actions = [.. ToolbarLayout.PrincipalOrdered(settings).Select(id => ItemFor(settings, id)).OfType<ToolbarActionItem>()];
        ShowsLogo = !settings.HideToolbarLogo;
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

    public void RequestClose() => CloseRequested?.Invoke();

    /// <summary>Regenerate (on a result) and Retry (on a failed run): the same selection and action again.</summary>
    public void Regenerate()
    {
        ClearMessages();
        _ = _session.RegenerateAsync();
        Refresh();
    }

    private void ClearMessages()
    {
        _failMessage = null;
        _notice = "";
    }

    private void Refresh()
    {
        if (_detached) return; // a refresh queued before the window closed
        _state = _session.State;
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
