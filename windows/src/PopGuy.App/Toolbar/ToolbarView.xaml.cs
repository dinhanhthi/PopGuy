using System.ComponentModel;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.Text;
using PopGuy.Core.Toolbar;
using CoreVirtualKeyStates = Windows.UI.Core.CoreVirtualKeyStates;
using VirtualKey = Windows.System.VirtualKey;

namespace PopGuy.Toolbar;

/// <summary>
/// The toolbar's content (macOS <c>ToolbarView.swift</c>): the action bar and the body, bound to
/// <see cref="ViewModel"/>; its clicks go to the view model. No window code: <see cref="ToolbarWindow"/> hosts it (size,
/// position, activation, drag, the foreground hand-back), and the Settings window can show it as a preview. The window
/// follows the text boxes (<see cref="TextBoxes"/>, <see cref="TextBoxShown"/>) and the menus
/// (<see cref="MenuOpened"/>, <see cref="MenuClosed"/>). UI thread only.
/// </summary>
public sealed partial class ToolbarView : UserControl
{
    /// <summary>The body's minimum width, so a short bar does not wrap the result into a narrow column (spec-1 §3.3).</summary>
    private const double MinBodyWidth = 340;

    /// <summary>The result panel's left and right padding together (12 + 12 DIP in the XAML).</summary>
    private const double ResultHorizontalPadding = 24;

    /// <summary>How long Copy shows "Copied" (macOS: the checkmark for 500 ms).</summary>
    private static readonly TimeSpan CopiedInterval = TimeSpan.FromMilliseconds(500);

    private static readonly ActionIdentifier TranslateId = ActionIdentifier.Builtin(ActionKind.Translate);

    /// <summary>The Speak button's glyph while playing (macOS stop.fill; the Stop button's glyph).</summary>
    private const string StopGlyph = "\uE71A";

    private readonly DispatcherQueueTimer _copiedTimer;
    private readonly DiffView _diffView;
    private readonly MarkdownView _markdownView;
    private ToolbarViewModel _viewModel = null!;
    private bool _closed;

    /// <summary>The action row's buttons (the actions and the Translate picker): disabled while an action runs.</summary>
    private readonly List<Button> _rowButtons = [];

    /// <summary>
    /// The Speak button's parts, while Speak is on the row: it follows the Speak phase (Speak, then Stop with a spinner
    /// while loading and the stop glyph while playing), and stays enabled while an action runs (macOS).
    /// </summary>
    private Button? _speakButton;
    private FontIcon? _speakIcon;
    private ProgressRing? _speakRing;
    private TextBlock? _speakLabel;

    /// <summary>The Translate picker's menu and code, while Translate is on the row.</summary>
    private MenuFlyout? _languageMenu;
    private TextBlock? _languageLabel;

    /// <summary>Which text boxes show, as last seen (the view model raises every state property on each refresh).</summary>
    private bool _promptShown;
    private bool _refineShown;
    private bool _editorShown;

    /// <summary>A body fit is queued for after the current bindings (<see cref="QueueFitBodyWidth"/>).</summary>
    private bool _bodyFitQueued;

    public ToolbarView()
    {
        InitializeComponent();

        _copiedTimer = DispatcherQueue.CreateTimer();
        _copiedTimer.Interval = CopiedInterval;
        _copiedTimer.IsRepeating = false;
        _copiedTimer.Tick += OnCopiedTick;

        CloseButton.Click += OnCloseClick;
        StopButton.Click += OnStopClick;
        CopyButton.Click += OnCopyClick;
        PasteBackButton.Click += OnPasteBackClick;
        RegenerateButton.Click += OnRegenerateClick;
        RetryButton.Click += OnRegenerateClick;
        CloseAnywayButton.Click += OnCloseAnywayClick;
        DisableConfirmButton.Click += OnDisableConfirmClick;
        KeepOpenButton.Click += OnKeepOpenClick;
        DiffModeButton.Click += OnDiffModeClick;
        TextModeButton.Click += OnTextModeClick;
        EditButton.Click += OnEditClick;
        DoneButton.Click += OnDoneClick;
        RefineButton.Click += OnRefineClick;
        PromptRunButton.Click += OnPromptRunClick;
        PromptCancelButton.Click += OnPromptCancelClick;
        RefineRunButton.Click += OnRefineRunClick;
        RefineCancelButton.Click += OnRefineCancelClick;
        SettingsButton.Click += OnSettingsClick;
        IgnoreAppButton.Click += OnIgnoreAppClick;
        IgnoreConfirmButton.Click += OnIgnoreConfirmClick;
        IgnoreCancelButton.Click += OnIgnoreCancelClick;
        ListenAgainButton.Click += OnListenAgainClick;
        MoreMenu.Opening += OnMoreMenuOpening;
        MoreMenu.Closed += OnMenuClosed;
        // The icon-only buttons' titles (the actions get theirs with the row); macOS toolbarTooltip.
        HoverTooltip.SetText(MoreButton, "More actions");
        HoverTooltip.SetText(IgnoreAppButton, "Ignore this app");
        HoverTooltip.SetText(SettingsButton, "Settings");
        HoverTooltip.SetText(CloseButton, "Close");
        HoverTooltip.SetText(RegenerateButton, "Regenerate");
        HoverTooltip.SetText(RefineButton, "Refine");
        HoverTooltip.SetText(ListenAgainButton, "Listen again");
        HoverTooltip.SetText(DiffToggleRow, "Click a highlighted change to revert or restore it");
        PromptBox.TextChanged += OnPromptTextChanged;
        RefineBox.TextChanged += OnRefineTextChanged;
        EditBox.TextChanged += OnEditTextChanged;
        // Before the text box's own handling: Enter would already be a new line in KeyDown.
        PromptBox.PreviewKeyDown += OnInputPreviewKeyDown;
        RefineBox.PreviewKeyDown += OnInputPreviewKeyDown;
        _diffView = new DiffView(DiffBlock, OnHunkClick);
        _markdownView = new MarkdownView(MarkdownBlock);

        // Esc reaches the toolbar only while it is activated (text input): the focus is in one of the text boxes.
        Card.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnCardKeyDown), true);
        Bar.SizeChanged += OnBarSizeChanged;
    }

    /// <summary>The state shown. Set it once, before the view is shown; the bindings start at once.</summary>
    public ToolbarViewModel ViewModel
    {
        get => _viewModel;
        set
        {
            if (_closed || ReferenceEquals(_viewModel, value)) return;
            if (_viewModel is not null) _viewModel.PropertyChanged -= OnViewModelChanged;
            _viewModel = value;
            _viewModel.PropertyChanged += OnViewModelChanged;
            SyncDiffMode();
            RebuildActionRow();
            UpdateBindings();
        }
    }

    /// <summary>The text boxes that take focus (prompt, refine, edit): the window's text input.</summary>
    public IReadOnlyList<TextBox> TextBoxes => [PromptBox, RefineBox, EditBox];

    /// <summary>The inline actions' buttons, in row order: the Settings layout editor hit-tests them.</summary>
    internal IEnumerable<(ActionIdentifier Id, FrameworkElement Button)> ActionButtons =>
        _rowButtons.Where(b => b.Tag is ToolbarActionItem).Select(b => (((ToolbarActionItem)b.Tag).Id, (FrameworkElement)b));

    /// <summary>A text box opened (true) or closed (false), after its text was reset or seeded.</summary>
    public event Action<TextBox, bool>? TextBoxShown;

    /// <summary>More actions or the Translate picker is opening (popup windows that take the foreground while open).</summary>
    public event Action? MenuOpened;

    /// <summary>The menu that was open closed.</summary>
    public event Action? MenuClosed;

    /// <summary>
    /// Updates the bindings now. x:Bind bindings start on Loading, which the content of a never-activated window does
    /// not get (VM QA: every state panel showed at once); the window calls this before it reads the size.
    /// </summary>
    public void UpdateBindings() => Bindings.Update();

    /// <summary><paramref name="box"/> (one of <see cref="TextBoxes"/>) shows.</summary>
    public bool IsTextBoxShown(TextBox box) =>
        box == PromptBox ? ViewModel.IsPromptInputActive : box == RefineBox ? ViewModel.IsRefineInputActive : ViewModel.ShowsEditor;

    /// <summary>Closes More actions and the Translate picker.</summary>
    public void CloseMenus()
    {
        MoreMenu.Hide();
        _languageMenu?.Hide();
    }

    /// <summary>Stops the view (its window closed): it no longer follows the view model or handles its controls.</summary>
    public void Detach()
    {
        if (_closed) return;
        _closed = true;
        _copiedTimer.Stop();
        _copiedTimer.Tick -= OnCopiedTick;
        CloseButton.Click -= OnCloseClick;
        StopButton.Click -= OnStopClick;
        CopyButton.Click -= OnCopyClick;
        PasteBackButton.Click -= OnPasteBackClick;
        RegenerateButton.Click -= OnRegenerateClick;
        RetryButton.Click -= OnRegenerateClick;
        CloseAnywayButton.Click -= OnCloseAnywayClick;
        DisableConfirmButton.Click -= OnDisableConfirmClick;
        KeepOpenButton.Click -= OnKeepOpenClick;
        DiffModeButton.Click -= OnDiffModeClick;
        TextModeButton.Click -= OnTextModeClick;
        EditButton.Click -= OnEditClick;
        DoneButton.Click -= OnDoneClick;
        RefineButton.Click -= OnRefineClick;
        PromptRunButton.Click -= OnPromptRunClick;
        PromptCancelButton.Click -= OnPromptCancelClick;
        RefineRunButton.Click -= OnRefineRunClick;
        RefineCancelButton.Click -= OnRefineCancelClick;
        SettingsButton.Click -= OnSettingsClick;
        IgnoreAppButton.Click -= OnIgnoreAppClick;
        IgnoreConfirmButton.Click -= OnIgnoreConfirmClick;
        IgnoreCancelButton.Click -= OnIgnoreCancelClick;
        ListenAgainButton.Click -= OnListenAgainClick;
        MoreMenu.Opening -= OnMoreMenuOpening;
        MoreMenu.Closed -= OnMenuClosed;
        ClearMenu(MoreMenu);
        PromptBox.TextChanged -= OnPromptTextChanged;
        RefineBox.TextChanged -= OnRefineTextChanged;
        EditBox.TextChanged -= OnEditTextChanged;
        PromptBox.PreviewKeyDown -= OnInputPreviewKeyDown;
        RefineBox.PreviewKeyDown -= OnInputPreviewKeyDown;
        foreach (var button in _rowButtons) button.Click -= OnActionClick;
        if (_languageMenu is not null)
        {
            _languageMenu.Opening -= OnLanguageMenuOpening;
            _languageMenu.Closed -= OnMenuClosed;
            ClearMenu(_languageMenu);
        }
        if (_viewModel is not null) _viewModel.PropertyChanged -= OnViewModelChanged;
        Bar.SizeChanged -= OnBarSizeChanged;
    }

    /// <summary>Enter runs the prompt or the refine; Shift+Enter falls through as a new line (the editor keeps Enter).</summary>
    private void OnInputPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_closed || e.Key != VirtualKey.Enter) return;
        if (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down)) return;
        e.Handled = true;
        if (ReferenceEquals(sender, PromptBox)) ViewModel.SubmitPrompt();
        else ViewModel.SubmitRefine();
    }

    private void OnCardKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_closed || e.Key != VirtualKey.Escape) return;
        e.Handled = true;
        ViewModel.RequestEscape();
    }

    // The boxes' text: drafts and the edit buffer keep "\n" line breaks (a WinUI TextBox returns a bare "\r").

    private void OnPromptTextChanged(object sender, TextChangedEventArgs e)
    {
        if (_closed) return;
        ViewModel.PromptDraft = LineEndings.ToLf(PromptBox.Text);
        PromptRunButton.IsEnabled = ViewModel.PromptDraft.Trim().Length > 0;
    }

    private void OnRefineTextChanged(object sender, TextChangedEventArgs e)
    {
        if (_closed) return;
        ViewModel.RefineDraft = LineEndings.ToLf(RefineBox.Text);
        RefineRunButton.IsEnabled = ViewModel.RefineDraft.Trim().Length > 0;
    }

    private void OnEditTextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_closed && ViewModel.IsEditing) ViewModel.SetEditText(LineEndings.ToLf(EditBox.Text));
    }

    // The action row: built from the view model's items (the row is dynamic, from the settings). A divider goes between
    // two actions, and Translate carries its target-language picker (macOS actionBar).

    private void RebuildActionRow()
    {
        foreach (var button in _rowButtons) button.Click -= OnActionClick;
        _rowButtons.Clear();
        (_speakButton, _speakIcon, _speakRing, _speakLabel) = (null, null, null, null);
        if (_languageMenu is not null)
        {
            _languageMenu.Opening -= OnLanguageMenuOpening;
            _languageMenu.Closed -= OnMenuClosed;
            ClearMenu(_languageMenu);
            _languageMenu = null;
            _languageLabel = null;
        }
        ActionRow.Children.Clear();
        foreach (var item in ViewModel.Actions)
        {
            if (ActionRow.Children.Count > 0) ActionRow.Children.Add(Divider());
            var button = ActionButton(item);
            if (item.Id != TranslateId)
            {
                ActionRow.Children.Add(button);
                continue;
            }
            var group = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
            group.Children.Add(button);
            group.Children.Add(LanguagePicker());
            ActionRow.Children.Add(group);
        }
    }

    /// <summary>An action's button: the icon and the title (labeledActionIDs), else the icon with the title as its tooltip.</summary>
    private Button ActionButton(ToolbarActionItem item)
    {
        var isSpeak = item.Id.Type == ActionIdentifierType.Speak;
        FrameworkElement content = Icon(item);
        if (isSpeak)
        {
            // The icon and a spinner in one cell: the spinner replaces the icon while loading.
            _speakIcon = (FontIcon)content;
            _speakRing = new ProgressRing { Width = 14, Height = 14, IsActive = false, Visibility = Visibility.Collapsed };
            var cell = new Grid();
            cell.Children.Add(content);
            cell.Children.Add(_speakRing);
            content = cell;
        }
        if (item.ShowsLabel)
        {
            var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var label = new TextBlock { Text = item.Label, VerticalAlignment = VerticalAlignment.Center };
            panel.Children.Add(content);
            panel.Children.Add(label);
            content = panel;
            if (isSpeak) _speakLabel = label;
        }
        var button = new Button
        {
            Content = content,
            Tag = item,
            AllowFocusOnInteraction = false,
            VerticalAlignment = VerticalAlignment.Stretch,
            IsEnabled = isSpeak || ViewModel.ActionsEnabled,
        };
        AutomationProperties.SetName(button, item.Label);
        if (!item.ShowsLabel) HoverTooltip.SetText(button, item.Label);
        button.Click += OnActionClick;
        _rowButtons.Add(button);
        if (isSpeak)
        {
            _speakButton = button;
            SyncSpeakButton();
        }
        return button;
    }

    /// <summary>The Speak button follows the phase (macOS): Speak when idle, else Stop (a spinner while loading).</summary>
    private void SyncSpeakButton()
    {
        if (_speakButton is not { Tag: ToolbarActionItem item } button || _speakIcon is null || _speakRing is null) return;
        var phase = ViewModel.SpeakPhase;
        var title = phase == SpeakPhase.Idle ? item.Label : "Stop";
        _speakIcon.Glyph = phase == SpeakPhase.Playing ? StopGlyph : item.Glyph ?? "";
        _speakIcon.Visibility = phase == SpeakPhase.Loading ? Visibility.Collapsed : Visibility.Visible;
        _speakRing.IsActive = phase == SpeakPhase.Loading;
        _speakRing.Visibility = phase == SpeakPhase.Loading ? Visibility.Visible : Visibility.Collapsed;
        if (_speakLabel is not null) _speakLabel.Text = title;
        else HoverTooltip.SetText(button, title);
        AutomationProperties.SetName(button, title);
    }

    /// <summary>The Translate picker (macOS LanguagePicker): the target's code; picking a language does not run Translate.</summary>
    private Button LanguagePicker()
    {
        _languageLabel = new TextBlock { Text = ViewModel.TargetLanguage.Code, VerticalAlignment = VerticalAlignment.Center };
        _languageMenu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft, ShouldConstrainToRootBounds = false };
        _languageMenu.Opening += OnLanguageMenuOpening;
        _languageMenu.Closed += OnMenuClosed;
        var picker = new Button
        {
            Content = _languageLabel,
            Flyout = _languageMenu,
            AllowFocusOnInteraction = false,
            VerticalAlignment = VerticalAlignment.Stretch,
            IsEnabled = ViewModel.ActionsEnabled,
        };
        AutomationProperties.SetName(picker, "Target language");
        _rowButtons.Add(picker);
        return picker;
    }

    /// <summary>An action's icon as on its button (the layout editor's More actions chips use it too).</summary>
    internal static FrameworkElement Icon(ToolbarActionItem item) => item.Emoji is { } emoji
        ? new TextBlock { Text = emoji, VerticalAlignment = VerticalAlignment.Center }
        : new FontIcon { FontFamily = SymbolFont, FontSize = 14, Glyph = item.Glyph ?? "" };

    private static FontFamily SymbolFont =>
        Application.Current.Resources.TryGetValue("SymbolThemeFontFamily", out var found) && found is FontFamily family
            ? family
            : new FontFamily("Segoe Fluent Icons");

    private static Rectangle Divider() => new()
    {
        Width = 1,
        Height = 16,
        Margin = new Thickness(2, 0, 2, 0),
        VerticalAlignment = VerticalAlignment.Center,
        Fill = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"],
    };

    // The menus: built when they open, so they show the current actions and target. The window follows them
    // (MenuOpened, MenuClosed).

    private void OnMoreMenuOpening(object? sender, object e)
    {
        if (_closed) return;
        OnMenuOpening();
        ClearMenu(MoreMenu);
        foreach (var item in ViewModel.OverflowActions)
        {
            // Speak is never disabled and reads Stop while loading or playing (macOS overflowMenuTitleAndSymbol).
            var isSpeak = item.Id.Type == ActionIdentifierType.Speak;
            var phase = isSpeak ? ViewModel.SpeakPhase : SpeakPhase.Idle;
            var entry = new MenuFlyoutItem
            {
                Text = phase == SpeakPhase.Idle ? item.Label : "Stop",
                Tag = item,
                Icon = item.Emoji is { } emoji
                    ? new FontIcon { FontFamily = new FontFamily("Segoe UI Emoji"), Glyph = emoji }
                    : new FontIcon { FontFamily = SymbolFont, Glyph = phase == SpeakPhase.Playing ? StopGlyph : item.Glyph ?? "" },
                IsEnabled = isSpeak || ViewModel.ActionsEnabled,
                AllowFocusOnInteraction = false,
            };
            entry.Click += OnActionClick;
            MoreMenu.Items.Add(entry);
        }
    }

    private void OnLanguageMenuOpening(object? sender, object e)
    {
        if (_closed || _languageMenu is not { } menu) return;
        OnMenuOpening();
        ClearMenu(menu);
        foreach (var language in TargetLanguages.All)
        {
            var entry = new ToggleMenuFlyoutItem
            {
                Text = language.Name,
                Tag = language,
                IsChecked = language == ViewModel.TargetLanguage,
                AllowFocusOnInteraction = false,
            };
            entry.Click += OnLanguageClick;
            menu.Items.Add(entry);
        }
    }

    private void OnMenuOpening()
    {
        MenuOpened?.Invoke();
        HoverTooltip.Dismiss();
    }

    private void OnMenuClosed(object? sender, object e) => MenuClosed?.Invoke();

    private void ClearMenu(MenuFlyout menu)
    {
        foreach (var entry in menu.Items)
        {
            if (entry is not MenuFlyoutItem item) continue;
            item.Click -= OnActionClick;
            item.Click -= OnLanguageClick;
        }
        menu.Items.Clear();
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (_closed) return;
        QueueFitBodyWidth();
        switch (e.PropertyName)
        {
            case nameof(ToolbarViewModel.Actions):
                RebuildActionRow();
                break;
            case nameof(ToolbarViewModel.ActionsEnabled):
                foreach (var button in _rowButtons) button.IsEnabled = button == _speakButton || ViewModel.ActionsEnabled;
                break;
            case nameof(ToolbarViewModel.SpeakPhase):
                SyncSpeakButton();
                break;
            case nameof(ToolbarViewModel.TargetLanguage):
                if (_languageLabel is not null) _languageLabel.Text = ViewModel.TargetLanguage.Code;
                break;
            case nameof(ToolbarViewModel.Zoom):
                CardScale.ScaleX = ViewModel.Zoom;
                CardScale.ScaleY = ViewModel.Zoom;
                break;
            case nameof(ToolbarViewModel.ShowsSystemGap):
                // The gap takes the bar's spare width only before the system buttons (inline ones stay with the actions).
                GapColumn.Width = ViewModel.ShowsSystemGap ? new GridLength(1, GridUnitType.Star) : GridLength.Auto;
                break;
            case nameof(ToolbarViewModel.ShowsBody):
                // macOS: while a body shows, the bar is at least its minimum width, so the gap reaches the card's edge.
                Bar.MinWidth = ViewModel.ShowsBody ? MinBodyWidth : 0;
                break;
            case nameof(ToolbarViewModel.IsResult):
                if (!ViewModel.IsResult) ResetCopyButton();
                break;
            case nameof(ToolbarViewModel.ShowDiff):
                SyncDiffMode();
                break;
            case nameof(ToolbarViewModel.ShowsDiffView):
                // Rebuilt only when the diff or the rejected hunks change (DiffView compares the snapshots).
                if (ViewModel.ShowsDiffView) _diffView.Show(ViewModel.DiffSegments, ViewModel.RejectedHunks);
                break;
            case nameof(ToolbarViewModel.ShowsMarkdownResult):
                // Rebuilt only when the text changes (MarkdownView compares it).
                if (ViewModel.ShowsMarkdownResult) _markdownView.Show(ViewModel.ResultText);
                break;
            case nameof(ToolbarViewModel.IsPromptInputActive):
                if (ViewModel.IsPromptInputActive == _promptShown) break;
                _promptShown = ViewModel.IsPromptInputActive;
                // A closed input drops its draft.
                if (!ViewModel.IsPromptInputActive) PromptBox.Text = "";
                TextBoxShown?.Invoke(PromptBox, ViewModel.IsPromptInputActive);
                break;
            case nameof(ToolbarViewModel.IsRefineInputActive):
                if (ViewModel.IsRefineInputActive == _refineShown) break;
                _refineShown = ViewModel.IsRefineInputActive;
                if (!ViewModel.IsRefineInputActive) RefineBox.Text = "";
                TextBoxShown?.Invoke(RefineBox, ViewModel.IsRefineInputActive);
                break;
            case nameof(ToolbarViewModel.ShowsEditor):
                if (ViewModel.ShowsEditor == _editorShown) break;
                _editorShown = ViewModel.ShowsEditor;
                // Seeded with the result as shown (the edit buffer), the caret at the end.
                if (ViewModel.ShowsEditor)
                {
                    EditBox.Text = ViewModel.ResultText;
                    EditBox.Select(EditBox.Text.Length, 0);
                }
                TextBoxShown?.Invoke(EditBox, ViewModel.ShowsEditor);
                break;
        }
    }

    /// <summary>The Diff/Text toggle shows the view model's choice (a click toggles a ToggleButton by itself).</summary>
    private void SyncDiffMode()
    {
        DiffModeButton.IsChecked = ViewModel.ShowDiff;
        TextModeButton.IsChecked = !ViewModel.ShowDiff;
    }

    // Clicks.

    private void OnActionClick(object sender, RoutedEventArgs e)
    {
        if (!_closed && sender is FrameworkElement { Tag: ToolbarActionItem item }) ViewModel.Invoke(item.Id);
    }

    private void OnLanguageClick(object sender, RoutedEventArgs e)
    {
        if (!_closed && sender is FrameworkElement { Tag: TargetLanguage language }) ViewModel.SetTargetLanguage(language);
    }

    private void OnSettingsClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.RequestSettings();
    }

    private void OnIgnoreAppClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.RequestIgnoreApp();
    }

    private void OnIgnoreConfirmClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.ConfirmIgnoreApp();
    }

    private void OnIgnoreCancelClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.CancelIgnoreApp();
    }

    private void OnListenAgainClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.RequestReplay();
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.RequestClose();
    }

    private void OnStopClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.RequestStop();
    }

    private void OnCopyClick(object sender, RoutedEventArgs e)
    {
        if (_closed) return;
        ViewModel.RequestCopy();
        // The confirmation shows at once (click reacts first): the checkmark and "Copied" for 500 ms.
        CopyIcon.Glyph = "";
        CopyLabel.Text = "Copied";
        _copiedTimer.Stop();
        _copiedTimer.Start();
    }

    private void OnCopiedTick(DispatcherQueueTimer sender, object args)
    {
        sender.Stop();
        if (!_closed) ResetCopyButton();
    }

    private void ResetCopyButton()
    {
        _copiedTimer.Stop();
        CopyIcon.Glyph = "";
        CopyLabel.Text = "Copy";
    }

    private void OnPasteBackClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.RequestPasteBack();
    }

    private void OnRegenerateClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.Regenerate();
    }

    private void OnCloseAnywayClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.RequestCloseAnyway();
    }

    private void OnDisableConfirmClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.RequestDisableCloseConfirmation();
    }

    private void OnKeepOpenClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.KeepOpen();
    }

    private void OnDiffModeClick(object sender, RoutedEventArgs e)
    {
        if (_closed) return;
        ViewModel.SetShowDiff(true);
        SyncDiffMode();
    }

    private void OnTextModeClick(object sender, RoutedEventArgs e)
    {
        if (_closed) return;
        ViewModel.SetShowDiff(false);
        SyncDiffMode();
    }

    private void OnEditClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.BeginEditing();
    }

    private void OnDoneClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.EndEditing();
    }

    private void OnRefineClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.OpenRefineInput();
    }

    private void OnPromptRunClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.SubmitPrompt();
    }

    private void OnPromptCancelClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.RequestPromptCancel();
    }

    private void OnRefineRunClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.SubmitRefine();
    }

    private void OnRefineCancelClick(object sender, RoutedEventArgs e)
    {
        if (!_closed) ViewModel.CancelRefineInput();
    }

    private void OnHunkClick(int hunk)
    {
        if (!_closed) ViewModel.ToggleHunk(hunk);
    }

    // Width: the body follows the bar (the window follows the card's size).

    private void OnBarSizeChanged(object sender, SizeChangedEventArgs e) => FitBodyWidth();

    /// <summary>
    /// The body is as wide as the bar, at least <see cref="MinBodyWidth"/>, so its text wraps (spec-1 §3.3), and wide
    /// enough for the result buttons, which never wrap (VM QA: Refine was cut off at the minimum width).
    /// </summary>
    private void FitBodyWidth()
    {
        if (_closed) return;
        ResultActions.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        Body.Width = Math.Max(Math.Max(Bar.ActualWidth, MinBodyWidth), ResultActions.DesiredSize.Width + ResultHorizontalPadding);
    }

    /// <summary>Fits the body once this change's bindings have run, so the result row holds its new buttons.</summary>
    private void QueueFitBodyWidth()
    {
        if (_bodyFitQueued) return;
        _bodyFitQueued = true;
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            _bodyFitQueued = false;
            FitBodyWidth();
        });
    }
}
