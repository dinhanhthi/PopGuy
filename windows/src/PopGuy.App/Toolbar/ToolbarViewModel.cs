using System.ComponentModel;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using PopGuy.Core.Actions;
using PopGuy.Core.Diff;
using PopGuy.Core.Dictionaries;
using PopGuy.Core.Icons;
using PopGuy.Core.Settings;
using PopGuy.Core.Speak;
using PopGuy.Core.Toolbar;
using Windows.Graphics.Imaging;

namespace PopGuy.Toolbar;

/// <summary>
/// One action of the inline row or More actions: its title and its icon, either a Segoe Fluent Icons glyph or an emoji
/// (exactly one is set). <paramref name="ShowsLabel"/> (labeledActionIDs): the button shows the title next to the icon,
/// else the icon only with the title as its tooltip.
/// </summary>
public sealed partial record ToolbarActionItem(ActionIdentifier Id, string Label, string? Glyph, string? Emoji, bool ShowsLabel)
{
    /// <summary>Speak or a Speech custom action: its button follows the Speak phase and stays enabled while an action runs.</summary>
    public bool IsSpeech { get; init; }
}

/// <summary>
/// An OCR capture's region for the toolbar's thumbnail: the image source and the bitmap it was made from (BGRA8,
/// premultiplied, physical pixels), kept alive together (whether the source keeps its own copy of the pixels is not
/// documented) and disposed together by <see cref="ToolbarViewModel"/>. UI thread only.
/// </summary>
public sealed class OcrThumbnail(SoftwareBitmapSource source, SoftwareBitmap bitmap) : IDisposable
{
    public SoftwareBitmapSource Source => source;

    public int PixelWidth => bitmap.PixelWidth;

    public int PixelHeight => bitmap.PixelHeight;

    public void Dispose()
    {
        source.Dispose();
        bitmap.Dispose();
    }
}

/// <summary>
/// The toolbar window's state (macOS <c>ToolbarViewModel.swift</c>, the UI half; the logic is Core's
/// <see cref="ToolbarSession"/>). It shows the session's state, plus two app-level messages the session does not own:
/// <see cref="Fail"/> (an error with no run to retry, e.g. the admin-app error) and <see cref="ShowNotice"/> (a note
/// next to a result, e.g. "Copied instead"). The layout (the inline row, More actions, the system buttons, zoom, the
/// result font, the Translate target) is read from the settings on every presentation. The window's clicks become the
/// <c>…Requested</c> / <see cref="ActionInvoked"/> events, which the controller handles; Regenerate, Retry, Refine and
/// Edit go to the session directly. The prompt and refine drafts live here (the controller's Esc and outside-click rules
/// read them), and so does an OCR capture's thumbnail (<see cref="ShowOcrThumbnail"/>). Speak is orthogonal to the
/// session's state (macOS): <see cref="BindSpeak"/> mirrors the coordinator's phase, replay and spoken text, and copies
/// the phase into <see cref="ToolbarSession.SpeakPhase"/>. UI thread only, except the session's and the coordinator's
/// <c>Changed</c>, which may arrive on any thread and are marshalled here.
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
        nameof(ShowsReadView), nameof(IsConfirmingIgnore), nameof(ShowsSystemGroup), nameof(ShowsSpeakDivider),
        nameof(IsDictionaryResult), nameof(DictionaryResults), nameof(IsDictionaryNotFound), nameof(ShowsResultActions),
        nameof(ShowsSpeakArea), nameof(ShowsSpokenText), nameof(ShowsListenAgain), nameof(ShowsSpeakFallback),
    ];

    /// <summary>The properties that follow the speak coordinator; raised together on every speak refresh.</summary>
    private static readonly string[] SpeakProperties =
    [
        nameof(SpeakPhase), nameof(CanReplaySpeak), nameof(SpokenText), nameof(ShowsSpeakArea), nameof(IsSpeakLoading),
        nameof(IsSpeakPlaying), nameof(ShowsSpokenText), nameof(ShowsListenAgain), nameof(ShowsSpeakFallback),
        nameof(ShowsSpeakDivider), nameof(ShowsBody),
    ];

    /// <summary>The properties read from the settings; raised together on every presentation.</summary>
    private static readonly string[] LayoutProperties =
    [
        nameof(Actions), nameof(OverflowActions), nameof(HasOverflow), nameof(ShowsMoreDivider), nameof(ShowsLogo),
        nameof(ShowsIgnoreSite), nameof(ShowsIgnoreSiteDivider), nameof(ShowsIgnoreApp), nameof(CanIgnoreApp),
        nameof(ShowsIgnoreDivider), nameof(ShowsSettingsButton),
        nameof(ShowsSettingsDivider), nameof(ShowsSystemGap), nameof(ShowsSystemGroup), nameof(Zoom),
        nameof(ResultFontSize), nameof(ResultLineHeight), nameof(TargetLanguage),
    ];

    /// <summary>
    /// The OCR thumbnail's box in DIPs (before the zoom): the region is fitted into it, a small one scaled up (macOS:
    /// 460×300). Narrower than macOS's so it never widens the card past the body's minimum width (the window is the
    /// card here; on macOS the thumbnail floats apart from it).
    /// </summary>
    private const double OcrThumbnailMaxWidth = 324;
    private const double OcrThumbnailMaxHeight = 200;

    private static readonly string[] OcrThumbnailProperties =
        [nameof(OcrThumbnailSource), nameof(ShowsOcrThumbnail), nameof(OcrThumbnailWidth), nameof(OcrThumbnailHeight)];

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
    private IReadOnlyList<ToolbarActionItem> _overflow = [];
    private bool _showsLogo = true;
    private bool _showsIgnoreSite;
    private bool _showsIgnoreApp;
    private bool _canIgnoreApp;
    private bool _showsSettingsButton;
    private bool _inlineSystemButtons;
    private bool _confirmingIgnore;
    private double _zoom = ZoomScale(ToolbarZoom.X1);
    private ResultFontSize _resultFontSize = Core.Settings.ResultFontSize.Normal;
    private bool _zoomIncludesFontSize = true;
    private TargetLanguage _targetLanguage = TargetLanguages.English;
    private bool _isEditable;
    private bool _preserveFormatting;
    private bool _detached;
    private bool _promptInputActive;
    private bool _refineInputActive;
    private bool _editing;
    private bool _resultEditable;
    private bool _canRefine;
    private SpeakCoordinator? _speak;
    private SpeakPhase _speakPhase;
    private bool _canReplaySpeak;
    private string? _spokenText;
    private bool _speakFellBack;
    private bool _isLookup;
    private IReadOnlyList<DictionaryProviderResult> _lookupResults = [];
    private bool _lookupNotFound;
    private OcrThumbnail? _ocrThumbnail;
    private double _ocrThumbnailWidth;
    private double _ocrThumbnailHeight;

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

    /// <summary>"Ignore App" in the ignore confirmation: the controller adds the source app to the ignored apps and closes.</summary>
    public event Action? IgnoreAppRequested;

    /// <summary>"Ignore this site" (macOS: no confirmation): the controller adds the tab's host to the ignored domains and closes.</summary>
    public event Action? IgnoreSiteRequested;

    /// <summary>The Settings button (macOS: opens Settings and closes the toolbar).</summary>
    public event Action? SettingsRequested;

    /// <summary>"Listen again" was clicked (macOS replaySpeak: the cached audio, no new request, no history).</summary>
    public event Action? ReplayRequested;

    /// <summary>A lookup's Listen was clicked; the argument is the entry of the provider tab shown.</summary>
    public event Action<DictionaryEntry>? ListenRequested;

    /// <summary>The inline row (<see cref="ToolbarLayout.PrincipalOrdered"/>), in order.</summary>
    public IReadOnlyList<ToolbarActionItem> Actions => _actions;

    /// <summary>More actions (<see cref="ToolbarLayout.OverflowOrdered"/>), in order.</summary>
    public IReadOnlyList<ToolbarActionItem> OverflowActions => _overflow;

    /// <summary>The More actions button shows when at least one action is in it.</summary>
    public bool HasOverflow => _overflow.Count > 0;

    /// <summary>A divider between the last inline action and More actions (macOS: none before the first control).</summary>
    public bool ShowsMoreDivider => HasOverflow && _actions.Count > 0;

    public bool ShowsLogo => _showsLogo;

    /// <summary>"Ignore this site": the selection is in a browser tab whose host was read (macOS sourceDomain != nil).</summary>
    public bool ShowsIgnoreSite => _showsIgnoreSite;

    /// <summary>"Ignore this app" (ignoredAppsEnabled).</summary>
    public bool ShowsIgnoreApp => _showsIgnoreApp;

    /// <summary>The source app is known (its exe name): "Ignore this app" can add it, else the button is disabled.</summary>
    public bool CanIgnoreApp => _canIgnoreApp;

    /// <summary>The Settings button (showToolbarSettingsButton).</summary>
    public bool ShowsSettingsButton => _showsSettingsButton;

    /// <summary>
    /// The system buttons sit after a gap at the bar's right edge (macOS Spacer, only when one shows), or inline after a
    /// divider each (inlineToolbarSystemButtons). Close always ends the bar.
    /// </summary>
    public bool ShowsSystemGap => (_showsIgnoreSite || _showsIgnoreApp || _showsSettingsButton) && !_inlineSystemButtons;

    public bool ShowsIgnoreSiteDivider => _inlineSystemButtons && _showsIgnoreSite && HasActionControls;

    public bool ShowsIgnoreDivider => _inlineSystemButtons && _showsIgnoreApp && (HasActionControls || _showsIgnoreSite);

    public bool ShowsSettingsDivider =>
        _inlineSystemButtons && _showsSettingsButton && (HasActionControls || _showsIgnoreSite || _showsIgnoreApp);

    /// <summary>The system buttons or Close show (an empty group would add its margin to the bar).</summary>
    public bool ShowsSystemGroup => _showsIgnoreSite || _showsIgnoreApp || _showsSettingsButton || ShowsClose;

    /// <summary>The toolbar zoom (toolbarZoom): the whole card scales, and the window with it.</summary>
    public double Zoom => _zoom;

    /// <summary>The scale of a zoom level: 1× is 0.9 of the card's layout size, 1.2× its layout size, 1.3× 1.2.</summary>
    internal static double ZoomScale(ToolbarZoom zoom) => zoom switch
    {
        ToolbarZoom.X1_2 => 1.0,
        ToolbarZoom.X1_3 => 1.2,
        _ => 0.9,
    };

    /// <summary>
    /// The result text's font size (resultFontSize: the Caption, Body and Body Large sizes). With zoomIncludesFontSize
    /// off it stays at that size whatever the zoom: the card's scaling is undone.
    /// </summary>
    public double ResultFontSize => ResultFontScale * _resultFontSize switch
    {
        Core.Settings.ResultFontSize.Small => 12,
        Core.Settings.ResultFontSize.Big => 18,
        _ => 14,
    };

    /// <summary>The line height that goes with <see cref="ResultFontSize"/> (the same type ramp entries).</summary>
    public double ResultLineHeight => ResultFontScale * _resultFontSize switch
    {
        Core.Settings.ResultFontSize.Small => 16,
        Core.Settings.ResultFontSize.Big => 24,
        _ => 20,
    };

    /// <summary>The Translate picker's target, from the settings' default on each presentation (macOS: in-session only).</summary>
    public TargetLanguage TargetLanguage => _targetLanguage;

    private double ResultFontScale => _zoomIncludesFontSize ? 1 : 1 / _zoom;

    private bool HasActionControls => _actions.Count > 0 || HasOverflow;

    /// <summary>
    /// The OCR capture's region (macOS ocrPreviewImage), above the action bar: set only on the OCR path, after
    /// <see cref="Present"/>; every presentation and hide clears it.
    /// </summary>
    public ImageSource? OcrThumbnailSource => _ocrThumbnail?.Source;

    public bool ShowsOcrThumbnail => _ocrThumbnail is not null;

    /// <summary>The thumbnail's size in DIPs (its aspect-fit into the box); 0 without one.</summary>
    public double OcrThumbnailWidth => _ocrThumbnailWidth;

    public double OcrThumbnailHeight => _ocrThumbnailHeight;

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

    /// <summary>
    /// Anything below the action row (the prompt input, running, result, error, Speak or the ignore confirmation).
    /// </summary>
    public bool ShowsBody => IsPromptInputActive || IsRunning || IsResult || IsError || ShowsSpeakArea || IsConfirmingIgnore;

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

    public bool ShowsPlainResult => IsResult && !ShowsDiffView && !ShowsMarkdownResult && !IsEditing && !IsDictionaryResult;

    /// <summary>
    /// The result rendered as Markdown ("Preserve &amp; render formatting", macOS MarkdownResultView). Never for an
    /// Improve or Proofread result: its Text mode stays plain, as on macOS. Copy and Paste back keep the raw Markdown.
    /// </summary>
    public bool ShowsMarkdownResult => IsResult && !IsDiffResult && _preserveFormatting && !IsEditing && !IsDictionaryResult;

    /// <summary>The result's diff segments (computed once by the session when the run finished).</summary>
    public IReadOnlyList<DiffSegment> DiffSegments => _diff;

    /// <summary>The diff hunks the user rejected.</summary>
    public IReadOnlySet<int> RejectedHunks => _rejected;

    public string ErrorMessage => _failMessage ?? (_state is ToolbarState.Error error ? error.Message : "");

    /// <summary>A failed run can run again; an app-level error (<see cref="Fail"/>) cannot.</summary>
    public bool CanRetry => _failMessage is null && _state is ToolbarState.Error;

    public bool ShowsPasteBack => IsResult && IsEditable && !IsDictionaryResult;

    /// <summary>
    /// A lookup's result (Look up or a Dictionary custom action): the definitions show instead of the text, with Listen
    /// and no Copy, Paste back, Edit, Regenerate or Refine (macOS).
    /// </summary>
    public bool IsDictionaryResult => IsResult && _isLookup;

    /// <summary>The lookup's definitions, one per provider that found one (a tab each when there are several).</summary>
    public IReadOnlyList<DictionaryProviderResult> DictionaryResults => _lookupResults;

    /// <summary>The lookup found nothing: "No definition found" shows.</summary>
    public bool IsDictionaryNotFound => IsDictionaryResult && _lookupNotFound;

    /// <summary>The result's button row (Copy, Paste back, Edit, Regenerate, Refine); a lookup has none.</summary>
    public bool ShowsResultActions => !IsDictionaryResult;

    public string Notice => _notice;

    public bool HasNotice => _notice.Length > 0;

    /// <summary>"Close without using the result?" shows below the result (spec-1 §3.8; inline, the toolbar never activates).</summary>
    public bool IsConfirmingClose => _confirmingClose && IsResult;

    /// <summary>"Ignore this app?" shows below the bar (macOS: a confirmation dialog; inline, the toolbar never activates).</summary>
    public bool IsConfirmingIgnore => _confirmingIgnore;

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
    public bool ShowsReadView => !IsEditing && !IsDictionaryResult;

    public bool ShowsEditButton => IsResultEditable && !IsEditing;

    public bool ShowsDoneButton => IsEditing;

    /// <summary>Regenerate and Refine hide while editing, as on macOS.</summary>
    public bool ShowsRegenerate => IsResult && !IsEditing && !IsDictionaryResult;

    public bool ShowsRefine => IsResult && _canRefine && !IsEditing;

    /// <summary>Refine is disabled while its input is open.</summary>
    public bool RefineEnabled => !IsRefineInputActive;

    /// <summary>The Speak phase (macOS speakPhase): the Speak button is Speak when idle, else Stop.</summary>
    public SpeakPhase SpeakPhase => _speakPhase;

    /// <summary>"Listen again" is available (macOS canReplaySpeak); it keeps the Speak area, and feeds the gate.</summary>
    public bool CanReplaySpeak => _canReplaySpeak;

    /// <summary>The text last spoken (macOS lastSpokenText), shown once playback ends.</summary>
    public string SpokenText => _spokenText ?? "";

    /// <summary>
    /// The Speak area below the bar (macOS: speakPhase != idle || canReplaySpeak), never with a lookup: its Listen
    /// button shows the speech state instead.
    /// </summary>
    public bool ShowsSpeakArea => (_speakPhase != SpeakPhase.Idle || _canReplaySpeak) && !_isLookup;

    public bool IsSpeakLoading => _speakPhase == SpeakPhase.Loading;

    public bool IsSpeakPlaying => _speakPhase == SpeakPhase.Playing;

    public bool ShowsSpokenText => ShowsSpeakArea && _speakPhase == SpeakPhase.Idle && _spokenText is not null;

    public bool ShowsListenAgain => ShowsSpokenText && _canReplaySpeak;

    /// <summary>A cloud engine was selected but the system voice played.</summary>
    public bool ShowsSpeakFallback => ShowsSpeakArea && _speakFellBack;

    /// <summary>A divider between the panel above (prompt, running, result or error) and the Speak area.</summary>
    public bool ShowsSpeakDivider => ShowsSpeakArea && (IsPromptInputActive || IsRunning || IsResult || IsError);

    /// <summary>The prompt input's text, as typed.</summary>
    public string PromptDraft { get; set; } = "";

    /// <summary>The refine input's text, as typed.</summary>
    public string RefineDraft { get; set; } = "";

    /// <summary>A non-empty prompt or refine draft is open: an outside click or Esc keeps the toolbar (macOS).</summary>
    public bool HasOpenDraft =>
        (IsPromptInputActive && PromptDraft.Trim().Length > 0) || (IsRefineInputActive && RefineDraft.Trim().Length > 0);

    // Controller → view model.

    /// <summary>
    /// A new presentation: stops any run, clears the messages and reads the layout and the Markdown rendering from
    /// <paramref name="settings"/> (settings apply at the next presentation, spec-1 §3.7, macOS ToolbarController).
    /// </summary>
    /// <param name="canIgnoreApp">The source app's exe name is known, so "Ignore this app" can add it.</param>
    /// <param name="sourceHost">The browser tab's host, if read: "Ignore this site" shows (never in the Settings preview).</param>
    public void Present(AppSettings settings, bool isEditable, bool canIgnoreApp, string? sourceHost = null)
    {
        _session.Stop();
        // Only the OCR path shows a thumbnail, after this (macOS update).
        ClearOcrThumbnail();
        PromptDraft = "";
        RefineDraft = "";
        _actions = Items(settings, ToolbarLayout.PrincipalOrdered(settings));
        _overflow = Items(settings, ToolbarLayout.OverflowOrdered(settings));
        _showsLogo = !settings.HideToolbarLogo;
        _showsIgnoreSite = sourceHost is not null;
        _showsIgnoreApp = settings.IgnoredAppsEnabled;
        _canIgnoreApp = canIgnoreApp;
        _showsSettingsButton = settings.ShowToolbarSettingsButton;
        _inlineSystemButtons = settings.InlineToolbarSystemButtons;
        _zoom = ZoomScale(settings.ToolbarZoom);
        _resultFontSize = settings.ResultFontSize;
        _zoomIncludesFontSize = settings.ZoomIncludesFontSize;
        _targetLanguage = TargetLanguages.FromCode(settings.DefaultTargetLanguage);
        foreach (var name in LayoutProperties) Raise(name);
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

    /// <summary>
    /// Shows <paramref name="thumbnail"/> above the action bar (macOS handleOCRCapture), aspect-fitted into the box; the
    /// view model owns it from here and disposes it when it clears. Call it after <see cref="Present"/>, before the show.
    /// </summary>
    public void ShowOcrThumbnail(OcrThumbnail thumbnail)
    {
        ClearOcrThumbnail();
        var ratio = thumbnail.PixelWidth > 0 && thumbnail.PixelHeight > 0
            ? (double)thumbnail.PixelWidth / thumbnail.PixelHeight
            : 16.0 / 9.0;
        var width = OcrThumbnailMaxWidth;
        var height = width / ratio;
        if (height > OcrThumbnailMaxHeight)
        {
            height = OcrThumbnailMaxHeight;
            width = height * ratio;
        }
        _ocrThumbnail = thumbnail;
        _ocrThumbnailWidth = Math.Round(width);
        _ocrThumbnailHeight = Math.Round(height);
        foreach (var name in OcrThumbnailProperties) Raise(name);
    }

    /// <summary>Cancels any run and returns to idle (every hide calls it).</summary>
    public void Stop()
    {
        _session.Stop();
        ClearOcrThumbnail();
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

    /// <summary>
    /// Follows <paramref name="speak"/> (macOS bindSpeakCoordinator). Once, before the toolbar shows; the Settings
    /// preview never binds (its Speak button stays idle).
    /// </summary>
    public void BindSpeak(SpeakCoordinator speak)
    {
        _speak = speak;
        speak.Changed += OnSpeakChanged;
        RefreshSpeak();
    }

    /// <summary>The coordinator's state changed (any thread, media threads too): refreshed on the UI thread.</summary>
    private void OnSpeakChanged()
    {
        if (_dispatcher.HasThreadAccess) RefreshSpeak();
        else _dispatcher.TryEnqueue(RefreshSpeak);
    }

    /// <summary>The window closed: stops following the session and stops any run (no refresh: the window is gone).</summary>
    public void Detach()
    {
        _detached = true;
        _session.Changed -= OnSessionChanged;
        if (_speak is not null) _speak.Changed -= OnSpeakChanged;
        _session.Stop();
        _ocrThumbnail?.Dispose();
        _ocrThumbnail = null;
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

    /// <summary>"Ignore this app": asks first (macOS confirmation dialog).</summary>
    public void RequestIgnoreApp()
    {
        _confirmingIgnore = true;
        Refresh();
    }

    /// <summary>"Ignore App" in the confirmation.</summary>
    public void ConfirmIgnoreApp() => IgnoreAppRequested?.Invoke();

    /// <summary>"Cancel" in the ignore confirmation: it goes, the toolbar stays.</summary>
    public void CancelIgnoreApp()
    {
        _confirmingIgnore = false;
        Refresh();
    }

    public void RequestIgnoreSite() => IgnoreSiteRequested?.Invoke();

    public void RequestSettings() => SettingsRequested?.Invoke();

    public void RequestReplay() => ReplayRequested?.Invoke();

    public void RequestListen(DictionaryEntry entry) => ListenRequested?.Invoke(entry);

    /// <summary>A pick in the Translate picker: the next Translate uses it (it does not run; macOS parity).</summary>
    public void SetTargetLanguage(TargetLanguage language)
    {
        _targetLanguage = language;
        Raise(nameof(TargetLanguage));
    }

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

    /// <summary>The view lets go of the thumbnail first (the raise), then it is disposed.</summary>
    private void ClearOcrThumbnail()
    {
        if (_ocrThumbnail is not { } old) return;
        _ocrThumbnail = null;
        _ocrThumbnailWidth = 0;
        _ocrThumbnailHeight = 0;
        foreach (var name in OcrThumbnailProperties) Raise(name);
        old.Dispose();
    }

    private void ClearMessages()
    {
        _failMessage = null;
        _notice = "";
        _confirmingClose = false;
        _confirmingIgnore = false;
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
        _isLookup = _session.DictionaryAction is not null;
        _lookupResults = _session.DictionaryResults;
        _lookupNotFound = _session.IsDictionaryNotFound;
        foreach (var name in StateProperties) Raise(name);
    }

    /// <summary>Reads the coordinator's state once (a queued refresh shows the latest) and mirrors the phase.</summary>
    private void RefreshSpeak()
    {
        if (_detached || _speak is null) return;
        _speakPhase = _speak.Phase;
        _canReplaySpeak = _speak.CanReplay;
        _spokenText = _speak.LastSpokenText;
        _speakFellBack = _speak.DidFallBackToSystem;
        _session.SpeakPhase = _speakPhase;
        foreach (var name in SpeakProperties) Raise(name);
    }

    private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    // The row's labels and icons (macOS ToolbarView.actionControl).

    private static IReadOnlyList<ToolbarActionItem> Items(AppSettings settings, IReadOnlyList<ActionIdentifier> ids) =>
        [.. ids.Select(id => ItemFor(settings, id, settings.LabeledActionIds.Contains(id))).OfType<ToolbarActionItem>()];

    private static ToolbarActionItem? ItemFor(AppSettings settings, ActionIdentifier id, bool showsLabel)
    {
        switch (id.Type)
        {
            case ActionIdentifierType.Builtin:
                return id.BuiltinKind switch
                {
                    ActionKind.Improve => Builtin(id, "Improve", "wand.and.stars", showsLabel),
                    ActionKind.Shorten => Builtin(id, "Shorten", "text.badge.minus", showsLabel),
                    ActionKind.Proofread => Builtin(id, "Proofread", "checkmark.bubble", showsLabel),
                    ActionKind.Prompt => Builtin(id, "Prompt", "bubble.and.pencil", showsLabel),
                    ActionKind.Translate => Builtin(id, "Translate", "character.bubble", showsLabel),
                    _ => null,
                };
            case ActionIdentifierType.Speak:
                // The view shows Stop instead while Speak is loading or playing.
                return Builtin(id, "Speak", "speaker.wave.2", showsLabel) with { IsSpeech = true };
            case ActionIdentifierType.Dictionary:
                return Builtin(id, "Look up", "character.book.closed", showsLabel);
            default:
                var custom = settings.CustomActions.FirstOrDefault(a => a.Id == id.CustomId);
                if (custom is null) return null;
                // A Speech action reads Stop like Speak while speech is loading or playing (macOS).
                var isSpeech = custom.Type == CustomActionType.Speech;
                return custom.Icon.Type == ActionIconType.Emoji
                    ? new ToolbarActionItem(id, custom.Title, null, custom.Icon.Value, showsLabel) { IsSpeech = isSpeech }
                    : new ToolbarActionItem(id, custom.Title, SymbolMap.Glyph(custom.Icon.Value), null, showsLabel) { IsSpeech = isSpeech };
        }
    }

    private static ToolbarActionItem Builtin(ActionIdentifier id, string label, string sfSymbol, bool showsLabel) =>
        new(id, label, SymbolMap.Glyph(sfSymbol), null, showsLabel);
}
