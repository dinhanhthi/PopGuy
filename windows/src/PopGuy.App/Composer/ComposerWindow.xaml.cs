using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PopGuy.Controls;
using PopGuy.Core.Composer;
using PopGuy.Platform.Capture;
using PopGuy.Platform.Windowing;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Color = Windows.UI.Color;
using CoreVirtualKeyStates = Windows.UI.Core.CoreVirtualKeyStates;
using VirtualKey = Windows.System.VirtualKey;

namespace PopGuy.Composer;

/// <summary>
/// The Terminal Composer window (macOS ComposerWindow.swift, ComposerView.swift, ComposerTextView.swift): a resizable
/// editor window on the solid base background, centered on the monitor with the pointer. The editor is a plain-text
/// <see cref="RichEditBox"/> (paste and copy are plain text) with simple Markdown highlighting from
/// <see cref="MarkdownHighlighter"/>: a heading line bold at the base size, code monospace on a subtle background,
/// bold and italic as their traits, list markers and fence lines dimmed. Keys: Ctrl+Enter Done, Ctrl+Shift+Enter Done
/// &amp; Submit, Esc Cancel (closes the find bar first), Ctrl+F find. Unlike the toolbar, the composer takes the
/// foreground. One window per session: the controller makes it, answers its requests and closes it with
/// <see cref="CloseComposer"/>. The text is never logged. UI thread only.
/// </summary>
public sealed partial class ComposerWindow : Window
{
    private const double DefaultWidth = 720;
    private const double DefaultHeight = 480;
    private const double MinWidth = 520;
    private const double MinHeight = 260;

    /// <summary>Highlighting waits for a pause in typing, so a burst of keys is one undo step and one format pass.</summary>
    private static readonly TimeSpan HighlightDelay = TimeSpan.FromMilliseconds(120);

    /// <summary>The editor's font (the XAML FontFamily): highlighting resets text to it.</summary>
    private const string BaseFontName = "Segoe UI";

    /// <summary>Inbox on every Windows.</summary>
    private const string CodeFontName = "Consolas";

    private readonly DispatcherQueueTimer _highlightTimer;

    /// <summary>The document's text ends with a paragraph mark the user never typed (measured once, at start).</summary>
    private readonly bool _hasFinalMark;

    /// <summary>The raw text the formats match: a TextChanged with this text is a format change, not an edit.</summary>
    private string _highlighted = "";

    /// <summary>A format pass is running: its own TextChanged events are ignored.</summary>
    private bool _formatting;

    private string? _sourceAppName;
    private string? _noTargetHint;
    private bool _composeMode;
    private bool _canSubmit = true;
    private bool _sessionEnded;
    private bool _draftAvailable;
    private bool _placed;
    private bool _closingByCode;
    private bool _closed;

    public ComposerWindow()
    {
        InitializeComponent();
        Hwnd = Win32Interop.GetWindowFromWindowId(AppWindow.Id);
        // The title bar's icon (an unpackaged app's windows have none of their own).
        AppWindow.SetIcon(App.IconPath);

        _highlightTimer = DispatcherQueue.CreateTimer();
        _highlightTimer.Interval = HighlightDelay;
        _highlightTimer.IsRepeating = false;
        _highlightTimer.Tick += OnHighlightTick;

        // RichEdit's text ends with a final paragraph mark ("x" reads "x\r"): measured, then left out of the text.
        Editor.TextDocument.SetText(TextSetOptions.None, "x");
        Editor.TextDocument.GetText(TextGetOptions.None, out var probe);
        _hasFinalMark = probe == "x\r";
        Editor.TextDocument.SetText(TextSetOptions.None, "");
        Editor.TextDocument.ClearUndoRedoHistory();

        HoverTooltip.SetText(CancelButton, "Cancel (Esc)");
        HoverTooltip.SetText(DoneSubmitButton, "Done & Submit (Ctrl+Shift+Enter)");
        HoverTooltip.SetText(RestoreDraftButton, "Restore the last saved draft");
        SetIconButton(FindPreviousButton, "Previous match (Shift+Enter)");
        SetIconButton(FindNextButton, "Next match (Enter)");
        SetIconButton(FindCloseButton, "Close (Esc)");

        CancelButton.Click += OnCancelClick;
        DoneButton.Click += OnDoneClick;
        DoneSubmitButton.Click += OnDoneSubmitClick;
        RestoreDraftButton.Click += OnRestoreDraftClick;
        FindPreviousButton.Click += OnFindPreviousClick;
        FindNextButton.Click += OnFindNextClick;
        FindCloseButton.Click += OnFindCloseClick;
        FindBox.PreviewKeyDown += OnFindBoxPreviewKeyDown;
        FindBox.TextChanged += OnFindBoxTextChanged;
        Editor.TextChanged += OnEditorTextChanged;
        Editor.Paste += OnEditorPaste;
        Editor.PreviewKeyDown += OnEditorPreviewKeyDown;
        Editor.Loaded += OnEditorLoaded;
        RootGrid.PreviewKeyDown += OnRootPreviewKeyDown;
        RootGrid.ActualThemeChanged += OnActualThemeChanged;
        AppWindow.Closing += OnAppWindowClosing;
        Closed += OnClosed;

        UpdateFooter();
    }

    // Requests to the controller.

    /// <summary>
    /// Done (false) or Done &amp; Submit (true, only while <see cref="CanSubmit"/>). Not raised while the text is too large,
    /// the session ended, or Compose has no target.
    /// </summary>
    public event Action<bool>? DoneRequested;

    /// <summary>Cancel, Esc, or the window's close button (the window stays open: the controller closes it).</summary>
    public event Action? CancelRequested;

    /// <summary>After the session ended, or in Compose without a target: the text was put on the clipboard.</summary>
    public event Action? CopyAndCloseRequested;

    /// <summary>"Restore draft": the controller sets <see cref="Text"/> from the draft.</summary>
    public event Action? RestoreDraftRequested;

    /// <summary>The text changed: raised after a pause in typing (not per key), for the draft autosave.</summary>
    public event Action? TextEdited;

    // State from the controller.

    public nint Hwnd { get; }

    /// <summary>The foreground window when <see cref="ShowAndActivate"/> was called (not this one); 0 when none.</summary>
    public nint PreviousForeground { get; private set; }

    /// <summary>The editor's plain text with "\n" line breaks. Setting it loads the text with an empty undo history.</summary>
    public string Text
    {
        get => ComposerFileRules.NormalizeLineEndings(RawText().Replace('\v', '\n'));
        set
        {
            _highlightTimer.Stop();
            Editor.TextDocument.SetText(TextSetOptions.None, value.Replace("\r\n", "\r").Replace('\n', '\r'));
            Highlight();
            Editor.TextDocument.ClearUndoRedoHistory();
            // The caret at the end, to go on writing.
            Editor.TextDocument.Selection.SetRange(_highlighted.Length, _highlighted.Length);
        }
    }

    /// <summary>
    /// The app the text is edited for ("Editing for …"), or in <see cref="ComposeMode"/> the app Done pastes into
    /// ("Pasting into …"). Null or empty: none; in Compose mode Done then becomes Copy &amp; Close.
    /// </summary>
    public string? SourceAppName
    {
        get => _sourceAppName;
        set
        {
            _sourceAppName = value;
            UpdateFooter();
        }
    }

    /// <summary>
    /// The footer of a <see cref="ComposeMode"/> composer without a target, saying why there is none; null: the default
    /// ("no target").
    /// </summary>
    public string? NoTargetHint
    {
        get => _noTargetHint;
        set
        {
            _noTargetHint = value;
            UpdateFooter();
        }
    }

    /// <summary>A Compose composer (no CLI session): Done pastes into <see cref="SourceAppName"/>.</summary>
    public bool ComposeMode
    {
        get => _composeMode;
        set
        {
            _composeMode = value;
            UpdateFooter();
        }
    }

    /// <summary>Done &amp; Submit (and Ctrl+Shift+Enter) is offered; false: Done only, no Enter.</summary>
    public bool CanSubmit
    {
        get => _canSubmit;
        set
        {
            _canSubmit = value;
            UpdateFooter();
        }
    }

    /// <summary>Done copies the text and closes: the session ended, or Compose has no target.</summary>
    private bool CopyOnly => _sessionEnded || _composeMode && string.IsNullOrEmpty(_sourceAppName);

    /// <summary>The CLI went away: Done becomes Copy &amp; Close and Done &amp; Submit hides.</summary>
    public bool SessionEnded
    {
        get => _sessionEnded;
        set
        {
            _sessionEnded = value;
            UpdateFooter();
        }
    }

    /// <summary>An older draft exists: shows "Restore draft".</summary>
    public bool DraftAvailable
    {
        get => _draftAvailable;
        set
        {
            _draftAvailable = value;
            RestoreDraftButton.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    // Show and close.

    /// <summary>
    /// Shows the window (centered on the monitor with the pointer the first time) and activates it with the keyboard
    /// focus in the editor. <paramref name="fromPipe"/>: opened by a popguy-edit request, so PopGuy got no input event
    /// and Windows would only flash its taskbar button; the input queue is then attached to the foreground thread
    /// around <c>SetForegroundWindow</c>.
    /// </summary>
    public void ShowAndActivate(bool fromPipe)
    {
        if (_closed) return;
        var foreground = ToolbarWindowStyle.ForegroundWindow();
        if (foreground != 0 && foreground != Hwnd) PreviousForeground = foreground;
        if (!_placed)
        {
            _placed = true;
            Place();
        }
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter)
            presenter.Restore();
        Activate();
        if (fromPipe && ToolbarWindowStyle.ForegroundWindow() != Hwnd) ForceForeground();
        Editor.Focus(FocusState.Programmatic);
    }

    /// <summary>Closes the window without raising <see cref="CancelRequested"/>.</summary>
    public void CloseComposer()
    {
        if (_closed) return;
        _closingByCode = true;
        Close();
    }

    /// <summary>
    /// The close button and Alt+F4 are Cancel: the window stays until the controller closes it, on the next dispatcher
    /// turn (not from inside the Closing event).
    /// </summary>
    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_closingByCode || _closed) return;
        args.Cancel = true;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_closed && !_closingByCode) CancelRequested?.Invoke();
        });
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _closed = true;
        _highlightTimer.Stop();
        _highlightTimer.Tick -= OnHighlightTick;
        Editor.TextChanged -= OnEditorTextChanged;
        Editor.Paste -= OnEditorPaste;
        Editor.PreviewKeyDown -= OnEditorPreviewKeyDown;
        Editor.Loaded -= OnEditorLoaded;
        FindBox.PreviewKeyDown -= OnFindBoxPreviewKeyDown;
        FindBox.TextChanged -= OnFindBoxTextChanged;
        RootGrid.PreviewKeyDown -= OnRootPreviewKeyDown;
        RootGrid.ActualThemeChanged -= OnActualThemeChanged;
        AppWindow.Closing -= OnAppWindowClosing;
        Closed -= OnClosed;
    }

    /// <summary>The default size (in DIPs at that monitor's scale) centered on the work area of the monitor with the pointer.</summary>
    private void Place()
    {
        var pointer = ToolbarWindowStyle.CursorPosition();
        var work = DisplayArea.GetFromPoint(new PointInt32(pointer.X, pointer.Y), DisplayAreaFallback.Nearest).WorkArea;
        var scale = MonitorInfo.Scale(pointer);
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = Px(MinWidth, scale);
            presenter.PreferredMinimumHeight = Px(MinHeight, scale);
        }
        var width = Math.Min(Px(DefaultWidth, scale), work.Width);
        var height = Math.Min(Px(DefaultHeight, scale), work.Height);
        AppWindow.MoveAndResize(new RectInt32(
            work.X + (work.Width - width) / 2, work.Y + (work.Height - height) / 2, width, height));
    }

    private static int Px(double dips, double scale) => (int)Math.Round(dips * scale);

    /// <summary>
    /// The foreground-unlock lever: with this thread's input attached to the foreground window's thread, Windows lets
    /// <c>SetForegroundWindow</c> through. Detached right after.
    /// </summary>
    private void ForceForeground()
    {
        var foreground = ToolbarWindowStyle.ForegroundWindow();
        var foregroundThread = foreground == 0 ? 0 : GetWindowThreadProcessId(foreground, 0);
        var thread = GetCurrentThreadId();
        var attached = foregroundThread != 0 && foregroundThread != thread && AttachThreadInput(thread, foregroundThread, true);
        try
        {
            ToolbarWindowStyle.SetForeground(Hwnd);
        }
        finally
        {
            if (attached) AttachThreadInput(thread, foregroundThread, false);
        }
    }

    /// <summary>
    /// The toolbar's Paste back (in-process): the editor's selection becomes <paramref name="text"/> as plain text, with
    /// the caret after it, as a paste does.
    /// </summary>
    public void ReplaceSelection(string text)
    {
        if (_closed) return;
        var selection = Editor.TextDocument.Selection;
        selection.SetText(TextSetOptions.None, text.Replace("\r\n", "\r").Replace('\n', '\r'));
        selection.Collapse(false);
        Editor.Focus(FocusState.Programmatic);
    }

    private void OnEditorLoaded(object sender, RoutedEventArgs e) => Editor.Focus(FocusState.Programmatic);

    // Footer.

    private void UpdateFooter()
    {
        var text = Text;
        var tooLarge = Encoding.UTF8.GetByteCount(text) > ComposerMessage.MaxTextBytes;
        var copyOnly = CopyOnly;
        var named = !string.IsNullOrEmpty(_sourceAppName);
        SourceHint.Text = _composeMode
            ? (named ? $"Pasting into {_sourceAppName}" : _noTargetHint ?? "Compose (no target: Copy & Close copies the text)")
            : (named ? $"Editing for {_sourceAppName}" : "Compose");
        // The target can be long enough to be trimmed.
        HoverTooltip.SetText(SourceHint, SourceHint.Text);
        SessionEndedNotice.Visibility = _sessionEnded ? Visibility.Visible : Visibility.Collapsed;
        TooLargeNotice.Visibility = tooLarge && !copyOnly ? Visibility.Visible : Visibility.Collapsed;
        DoneSubmitButton.Visibility = copyOnly || !_canSubmit ? Visibility.Collapsed : Visibility.Visible;
        if (copyOnly)
        {
            DoneButton.Content = "Copy & Close";
            DoneButton.IsEnabled = text.Length > 0;
            SetTooltip(DoneButton, "Copy & Close (Ctrl+Enter)");
        }
        else
        {
            DoneButton.Content = "Done";
            DoneButton.IsEnabled = !tooLarge;
            SetTooltip(DoneButton, "Done (Ctrl+Enter)");
        }
        DoneSubmitButton.IsEnabled = !tooLarge;
    }

    private static void SetTooltip(Button button, string text)
    {
        HoverTooltip.SetText(button, text);
        AutomationProperties.SetHelpText(button, text);
    }

    private static void SetIconButton(Button button, string text)
    {
        AutomationProperties.SetName(button, text);
        HoverTooltip.SetText(button, text);
    }

    private void OnCancelClick(object sender, RoutedEventArgs e) => CancelRequested?.Invoke();

    private void OnDoneClick(object sender, RoutedEventArgs e) => Done();

    private void OnDoneSubmitClick(object sender, RoutedEventArgs e) => DoneAndSubmit();

    private void OnRestoreDraftClick(object sender, RoutedEventArgs e) => RestoreDraftRequested?.Invoke();

    /// <summary>
    /// Done, or Copy &amp; Close once the session ended or when Compose has no target (the clipboard write is the user's
    /// own action).
    /// </summary>
    private void Done()
    {
        var text = Text;
        if (CopyOnly)
        {
            // A failed write keeps the window open, so the text is not lost.
            if (text.Length > 0 && ClipboardGuard.WriteText(text, excludeFromHistory: false)) CopyAndCloseRequested?.Invoke();
            return;
        }
        if (Encoding.UTF8.GetByteCount(text) > ComposerMessage.MaxTextBytes)
        {
            UpdateFooter();
            return;
        }
        DoneRequested?.Invoke(false);
    }

    private void DoneAndSubmit()
    {
        if (CopyOnly || !_canSubmit) return;
        if (Encoding.UTF8.GetByteCount(Text) > ComposerMessage.MaxTextBytes)
        {
            UpdateFooter();
            return;
        }
        DoneRequested?.Invoke(true);
    }

    // Keys.

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    /// <summary>The window's key map, before the focused control sees the key.</summary>
    private void OnRootPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = IsDown(VirtualKey.Control);
        var shift = IsDown(VirtualKey.Shift);
        if (e.Key == VirtualKey.Enter && control)
        {
            e.Handled = true;
            if (shift) DoneAndSubmit();
            else Done();
        }
        else if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            if (FindBar.Visibility == Visibility.Visible) CloseFind();
            else CancelRequested?.Invoke();
        }
        else if (e.Key == VirtualKey.F && control && !shift)
        {
            e.Handled = true;
            OpenFind();
        }
    }

    /// <summary>
    /// Enter and Backspace continue and end Markdown lists. Undo and redo step over the format passes (they leave the
    /// text as it was), so one key is one edit.
    /// </summary>
    private void OnEditorPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var shift = IsDown(VirtualKey.Shift);
        if (!IsDown(VirtualKey.Control))
        {
            if (!shift && !IsDown(VirtualKey.Menu) && e.Key is VirtualKey.Enter or VirtualKey.Back
                && ApplyListEdit(enter: e.Key == VirtualKey.Enter))
            {
                e.Handled = true;
            }
            return;
        }
        if (e.Key == VirtualKey.Z)
        {
            e.Handled = true;
            StepHistory(redo: shift);
        }
        else if (e.Key == VirtualKey.Y && !shift)
        {
            e.Handled = true;
            StepHistory(redo: true);
        }
    }

    /// <summary>
    /// The <see cref="ListContinuation"/> edit for Enter or Backspace at a caret (no selection), as one undoable edit
    /// with the caret after it; false: the key does its own thing.
    /// </summary>
    private bool ApplyListEdit(bool enter)
    {
        var document = Editor.TextDocument;
        var selection = document.Selection;
        if (selection.StartPosition != selection.EndPosition) return false;
        var text = RawText();
        var caret = selection.StartPosition;
        if ((enter ? ListContinuation.ReturnEdit(text, caret) : ListContinuation.BackspaceEdit(text, caret)) is not { } edit)
            return false;
        var range = document.GetRange(edit.Start, edit.Start + edit.Length);
        range.SetText(TextSetOptions.None, edit.Replacement.Replace('\n', '\r'));
        selection.SetRange(range.EndPosition, range.EndPosition);
        return true;
    }

    /// <summary>
    /// RichEdit records format changes as undo steps and has no way to leave them out, so each format pass is grouped
    /// into one step and undo/redo skip the steps that do not change the text. An undone edit brings its formats back
    /// with it; a redone edit is followed by its format pass when that is the next step.
    /// </summary>
    private void StepHistory(bool redo)
    {
        var document = Editor.TextDocument;
        _highlightTimer.Stop();
        var before = RawText();
        var current = before;
        while (redo ? document.CanRedo() : document.CanUndo())
        {
            if (redo) document.Redo();
            else document.Undo();
            current = RawText();
            if (current != before) break;
        }
        if (redo && current != before && document.CanRedo())
        {
            document.Redo();
            if (RawText() != current) document.Undo();
        }
        _highlighted = RawText();
        UpdateFooter();
    }

    // Paste: plain text only.

    private async void OnEditorPaste(object sender, TextControlPasteEventArgs e)
    {
        e.Handled = true;
        string text;
        try
        {
            var content = Clipboard.GetContent();
            if (!content.Contains(StandardDataFormats.Text)) return;
            text = await content.GetTextAsync();
        }
        catch (Exception exception) when (exception is COMException or UnauthorizedAccessException)
        {
            return;
        }
        if (_closed) return;
        var selection = Editor.TextDocument.Selection;
        selection.SetText(TextSetOptions.None, text.Replace("\r\n", "\r").Replace('\n', '\r'));
        selection.Collapse(false);
    }

    // Highlighting.

    /// <summary>The document's text with "\r" line breaks, without the final paragraph mark; its indices are the editor's.</summary>
    private string RawText()
    {
        Editor.TextDocument.GetText(TextGetOptions.None, out var text);
        return _hasFinalMark && text.EndsWith('\r') ? text[..^1] : text;
    }

    private void OnEditorTextChanged(object sender, RoutedEventArgs e)
    {
        if (_formatting || _closed) return;
        _highlightTimer.Stop();
        _highlightTimer.Start();
    }

    private void OnHighlightTick(DispatcherQueueTimer sender, object args)
    {
        sender.Stop();
        if (_closed) return;
        if (RawText() != _highlighted) Highlight();
        UpdateFooter();
        TextEdited?.Invoke();
    }

    /// <summary>Theme colors are set on the text itself: a theme switch formats it again.</summary>
    private void OnActualThemeChanged(FrameworkElement sender, object args)
    {
        if (!_closed) DispatcherQueue.TryEnqueue(Highlight);
    }

    /// <summary>
    /// One format pass over the whole text (up to <see cref="MarkdownHighlighter.FullDocumentLimit"/>; a longer text
    /// keeps its formats): the base format first, then the runs. One undo step, one repaint.
    /// </summary>
    private void Highlight()
    {
        if (_closed || _formatting) return;
        var raw = RawText();
        _highlighted = raw;
        if (raw.Length > MarkdownHighlighter.FullDocumentLimit) return;

        var theme = RootGrid.ActualTheme;
        var background = ThemeColor("SolidBackgroundFillColorBase", theme);
        var text = Over(ThemeColor("TextFillColorPrimary", theme), background);
        var dimmed = Over(ThemeColor("TextFillColorSecondary", theme), background);
        var code = Over(ThemeColor("SubtleFillColorSecondary", theme), background);

        var document = Editor.TextDocument;
        _formatting = true;
        document.BatchDisplayUpdates();
        document.BeginUndoGroup();
        try
        {
            var all = document.GetRange(0, raw.Length).CharacterFormat;
            all.Bold = FormatEffect.Off;
            all.Italic = FormatEffect.Off;
            all.Underline = UnderlineType.None;
            all.Name = BaseFontName;
            all.ForegroundColor = text;
            all.BackgroundColor = background;
            // "\v" is a soft line break (Shift+Enter): a line end for the highlighter, at the same index.
            foreach (var run in MarkdownHighlighter.Runs(raw.Replace('\v', '\r')))
            {
                var format = document.GetRange(run.Start, run.Start + run.Length).CharacterFormat;
                switch (run.Kind)
                {
                    case HighlightKind.Heading:
                    case HighlightKind.Bold:
                        format.Bold = FormatEffect.On;
                        break;
                    case HighlightKind.Italic:
                        format.Italic = FormatEffect.On;
                        break;
                    case HighlightKind.ListMarker:
                        format.ForegroundColor = dimmed;
                        break;
                    case HighlightKind.InlineCode:
                    case HighlightKind.CodeBlock:
                        format.Name = CodeFontName;
                        format.BackgroundColor = code;
                        break;
                    case HighlightKind.CodeFence:
                        format.Name = CodeFontName;
                        format.BackgroundColor = code;
                        format.ForegroundColor = dimmed;
                        break;
                }
            }
        }
        finally
        {
            document.EndUndoGroup();
            document.ApplyDisplayUpdates();
            _formatting = false;
        }
    }

    /// <summary>
    /// <paramref name="key"/>'s color in the theme dictionary of <paramref name="theme"/> (WinUI keeps Dark under
    /// "Default"), as SettingsWindow reads its caption colors.
    /// </summary>
    private static Color ThemeColor(string key, ElementTheme theme)
    {
        string[] names = theme == ElementTheme.Light ? ["Light"] : ["Dark", "Default"];
        if (FindThemeValue(Application.Current.Resources, key, names) is Color color) return color;
        return (Color)Application.Current.Resources[key];
    }

    private static object? FindThemeValue(ResourceDictionary dictionary, string key, string[] names)
    {
        foreach (var name in names)
        {
            if (dictionary.ThemeDictionaries.TryGetValue(name, out var found)
                && found is ResourceDictionary themed
                && themed.TryGetValue(key, out var value))
            {
                return value;
            }
        }
        foreach (var merged in dictionary.MergedDictionaries)
        {
            if (FindThemeValue(merged, key, names) is { } value) return value;
        }
        return null;
    }

    /// <summary>
    /// <paramref name="top"/> blended over <paramref name="bottom"/>, opaque: RichEdit drops a color's alpha, and the
    /// Fluent text and fill colors are translucent.
    /// </summary>
    private static Color Over(Color top, Color bottom)
    {
        byte Mix(byte up, byte down) => (byte)Math.Round((up * top.A + down * (255 - top.A)) / 255.0);
        return Color.FromArgb(255, Mix(top.R, bottom.R), Mix(top.G, bottom.G), Mix(top.B, bottom.B));
    }

    // Find: case-insensitive, wraps around, selects the match.

    private void OpenFind()
    {
        FindBar.Visibility = Visibility.Visible;
        FindStatus.Visibility = Visibility.Collapsed;
        FindBox.Focus(FocusState.Programmatic);
        FindBox.SelectAll();
    }

    private void CloseFind()
    {
        FindBar.Visibility = Visibility.Collapsed;
        Editor.Focus(FocusState.Programmatic);
    }

    private void OnFindBoxPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter || IsDown(VirtualKey.Control)) return;
        e.Handled = true;
        Find(forward: !IsDown(VirtualKey.Shift));
    }

    private void OnFindBoxTextChanged(object sender, TextChangedEventArgs e) => FindStatus.Visibility = Visibility.Collapsed;

    private void OnFindPreviousClick(object sender, RoutedEventArgs e) => Find(forward: false);

    private void OnFindNextClick(object sender, RoutedEventArgs e) => Find(forward: true);

    private void OnFindCloseClick(object sender, RoutedEventArgs e) => CloseFind();

    private void Find(bool forward)
    {
        var query = FindBox.Text.Replace("\r\n", "\r").Replace('\n', '\r');
        var text = RawText();
        if (query.Length == 0 || text.Length == 0) return;
        var selection = Editor.TextDocument.Selection;
        int index;
        if (forward)
        {
            var from = Math.Min(selection.EndPosition, text.Length);
            index = text.IndexOf(query, from, StringComparison.OrdinalIgnoreCase);
            if (index < 0) index = text.IndexOf(query, StringComparison.OrdinalIgnoreCase);
        }
        else
        {
            // A match that starts before the selection (it may end inside it).
            var last = selection.StartPosition + query.Length - 2;
            index = selection.StartPosition > 0
                ? text.LastIndexOf(query, Math.Min(last, text.Length - 1), StringComparison.OrdinalIgnoreCase)
                : -1;
            if (index < 0) index = text.LastIndexOf(query, StringComparison.OrdinalIgnoreCase);
        }
        FindStatus.Visibility = index < 0 ? Visibility.Visible : Visibility.Collapsed;
        if (index < 0) return;
        selection.SetRange(index, index + query.Length);
        selection.ScrollIntoView(PointOptions.None);
    }

    // Win32: the foreground-unlock lever (not in PopGuy.Platform's CsWin32 set).

    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern uint GetWindowThreadProcessId(nint hwnd, nint processId);

    [DllImport("user32.dll", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachThreadInput(uint attach, uint attachTo, [MarshalAs(UnmanagedType.Bool)] bool doAttach);

    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern uint GetCurrentThreadId();
}
