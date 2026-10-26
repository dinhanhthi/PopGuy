using System.ComponentModel;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
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
using PopGuy.Platform.SystemServices;
using PopGuy.Platform.Windowing;
using CoreVirtualKeyStates = Windows.UI.Core.CoreVirtualKeyStates;
using DrawingPoint = System.Drawing.Point;
using DrawingRectangle = System.Drawing.Rectangle;
using DrawingSize = System.Drawing.Size;
using VirtualKey = Windows.System.VirtualKey;

namespace PopGuy.Toolbar;

/// <summary>
/// The floating toolbar (spec-1 §3.1): a borderless, topmost tool window that never takes the foreground from the
/// source app (the app whose text is selected). Tier 1 of the plan, lifted from the Phase 3 spike: WS_EX_NOACTIVATE
/// plus <c>AllowFocusOnInteraction="False"</c> buttons, a WM_MOUSEACTIVATE → MA_NOACTIVATE subclass on every HWND, and
/// a foreground hand-back after each press. Text input (the prompt, refine and edit boxes) is the one exception: the
/// toolbar is activated for it and gives the foreground back when it ends (see <see cref="EndTextInput"/>). The menus
/// (More actions, the Translate picker) are popup windows that take the foreground while open; it goes back when they
/// close. It shows <see cref="ViewModel"/>; the controller wires the view model's events and calls <see cref="ShowAt"/>
/// and <see cref="Hide"/>. Points and rects are physical screen pixels. UI thread only.
/// </summary>
public sealed partial class ToolbarWindow : Window
{
    /// <summary>The size before the card's first layout (spec-1 §3.1: 280×50 DIP).</summary>
    private const double StartWidth = 280;
    private const double StartHeight = 50;

    /// <summary>The body's minimum width, so a short bar does not wrap the result into a narrow column (spec-1 §3.3).</summary>
    private const double MinBodyWidth = 340;

    /// <summary>The work area when no monitor can be read (spec-1 §3.2).</summary>
    private static readonly DrawingRectangle FallbackWorkArea = new(0, 0, 1280, 800);

    /// <summary>How long Copy shows "Copied" (macOS: the checkmark for 500 ms).</summary>
    private static readonly TimeSpan CopiedInterval = TimeSpan.FromMilliseconds(500);

    /// <summary>How often a drag reads the pointer (the window cannot capture it while it is not the foreground).</summary>
    private static readonly TimeSpan DragPollInterval = TimeSpan.FromMilliseconds(15);

    private static readonly ActionIdentifier TranslateId = ActionIdentifier.Builtin(ActionKind.Translate);

    private readonly DispatcherQueueTimer _dragTimer;
    private readonly DispatcherQueueTimer _copiedTimer;
    private readonly DiffView _diffView;
    private readonly MarkdownView _markdownView;
    private bool _closed;
    private bool _dragging;
    private XamlRoot? _xamlRoot;

    /// <summary>The action row's buttons (the actions and the Translate picker): disabled while an action runs.</summary>
    private readonly List<Button> _rowButtons = [];

    /// <summary>The Translate picker's menu and code, while Translate is on the row.</summary>
    private MenuFlyout? _languageMenu;
    private TextBlock? _languageLabel;

    /// <summary>A menu is open, and when the last one opened and closed (tick count, as the mouse hook's timestamps).</summary>
    private bool _menuOpen;
    private uint _menuOpenedAt;
    private uint _menuClosedAt;

    /// <summary>The window to hand the foreground back to: the source, or the foreground window at the last press.</summary>
    private nint _handBackTo;

    /// <summary>The text box the toolbar is activated for (text input); null when it is not.</summary>
    private TextBox? _textInput;

    /// <summary>The text box whose bounds are the activation region (the last one given text input, while shown).</summary>
    private TextBox? _regionBox;

    /// <summary>Which text boxes show, as last seen (the view model raises every state property on each refresh).</summary>
    private bool _promptShown;
    private bool _refineShown;
    private bool _editorShown;

    /// <summary>The work area the toolbar is kept in: the selection's monitor at show, the window's after a drag.</summary>
    private DrawingRectangle _workArea = FallbackWorkArea;

    /// <summary>The drag's start: the pointer and the window's top-left corner.</summary>
    private DrawingPoint _dragPointer;
    private DrawingPoint _dragOrigin;

    /// <summary>The card's last laid-out size in DIPs; the start size before the first layout.</summary>
    private Windows.Foundation.Size _cardSize = new(StartWidth, StartHeight);

    public ToolbarWindow(ToolbarSession session)
    {
        ViewModel = new ToolbarViewModel(session, DispatcherQueue.GetForCurrentThread());
        InitializeComponent();
        // A Window's x:Bind bindings start on its content's Loading, which this never-activated window did not get
        // (VM QA: every state panel showed at once). Start them now; ShowAt refreshes them again.
        Bindings.Update();

        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(false, false);
            presenter.IsResizable = false;
        }
        Hwnd = Win32Interop.GetWindowFromWindowId(AppWindow.Id);
        // Before the first show: Windows reads WS_EX_TOOLWINDOW (no taskbar button, not in Alt+Tab) at show time.
        ToolbarWindowStyle.Apply(Hwnd);

        if (DesktopAcrylicController.IsSupported())
            SystemBackdrop = new ActiveAcrylicBackdrop();
        else
            RootCanvas.Background = (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"];

        _dragTimer = DispatcherQueue.CreateTimer();
        _dragTimer.Interval = DragPollInterval;
        _dragTimer.IsRepeating = true;
        _dragTimer.Tick += OnDragTick;
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
        MoreMenu.Opening += OnMoreMenuOpening;
        MoreMenu.Closed += OnMenuClosed;
        // The icon-only buttons' titles (the actions get theirs with the row); macOS toolbarTooltip.
        HoverTooltip.SetText(MoreButton, "More actions");
        HoverTooltip.SetText(IgnoreAppButton, "Ignore this app");
        HoverTooltip.SetText(SettingsButton, "Settings");
        HoverTooltip.SetText(CloseButton, "Close");
        HoverTooltip.SetText(RegenerateButton, "Regenerate");
        HoverTooltip.SetText(RefineButton, "Refine");
        HoverTooltip.SetText(DiffToggleRow, "Click a highlighted change to revert or restore it");
        PromptBox.TextChanged += OnPromptTextChanged;
        RefineBox.TextChanged += OnRefineTextChanged;
        EditBox.TextChanged += OnEditTextChanged;
        // Before the text box's own handling: Enter would already be a new line in KeyDown.
        PromptBox.PreviewKeyDown += OnInputPreviewKeyDown;
        RefineBox.PreviewKeyDown += OnInputPreviewKeyDown;
        foreach (var box in TextBoxes) box.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(OnTextBoxPressed), true);
        _diffView = new DiffView(DiffBlock, OnHunkClick);
        _markdownView = new MarkdownView(MarkdownBlock);
        SyncDiffMode();
        ViewModel.PropertyChanged += OnViewModelChanged;

        // Every press and release, the buttons' (handled) too: the foreground hand-back.
        Card.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(OnAnyPointerPressed), true);
        Card.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(OnAnyPointerReleased), true);
        // Drag: presses outside the buttons and the selectable text reach these (those controls handle theirs).
        Card.PointerPressed += OnBackgroundPressed;
        Card.PointerMoved += OnPointerMoved;
        Card.PointerReleased += OnPointerReleased;
        Card.PointerCaptureLost += OnPointerCaptureLost;
        // Esc reaches the toolbar only while it is activated (text input): the focus is in one of the text boxes.
        Card.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnCardKeyDown), true);
        Activated += OnActivated;

        Bar.SizeChanged += OnBarSizeChanged;
        Card.SizeChanged += OnCardSizeChanged;
        Card.Loaded += OnCardLoaded;
        Closed += OnClosed;
        RebuildActionRow();
    }

    public ToolbarViewModel ViewModel { get; }

    /// <summary>The toolbar's window handle.</summary>
    public nint Hwnd { get; }

    /// <summary>The toolbar is on screen.</summary>
    public bool IsShown { get; private set; }

    /// <summary>The user dragged the toolbar since the last show (the controller stops repositioning it then).</summary>
    public bool UserDragged { get; private set; }

    /// <summary>
    /// Shows the toolbar for <paramref name="source"/> without activating it, placed by
    /// <see cref="PanelPositioning.PanelOrigin"/> (spec-1 §3.2) in the work area of the monitor holding the selection.
    /// Call <see cref="ToolbarViewModel.Present"/> first, so the toolbar is sized for the new content. Also re-presents
    /// a toolbar that is already showing: the position is recomputed, unless the user dragged the toolbar since it was
    /// shown (a drag disables auto-reposition until the next show; the size still follows the content).
    /// </summary>
    /// <param name="pointer">The gesture's release point; null for the chord and the hotkeys (placed below the selection).</param>
    /// <param name="grewDownward">The drag direction; null when unknown.</param>
    /// <param name="selection">The selection's screen rect; an empty one means a zero-size rect at the pointer (or the cursor).</param>
    public void ShowAt(DrawingPoint? pointer, bool? grewDownward, DrawingRectangle selection, ForegroundApp source)
    {
        if (_closed) return;
        StopDrag();
        _handBackTo = source.Hwnd;
        if (IsShown && UserDragged)
        {
            // Where the user put it, in the work area of the monitor it was dropped on; FitToCard resizes it.
            AppWindow.Show(activateWindow: false);
            return;
        }
        UserDragged = false;

        var selectionRect = selection.Width > 0 && selection.Height > 0
            ? selection
            : new DrawingRectangle(pointer ?? ToolbarWindowStyle.CursorPosition(), DrawingSize.Empty);
        var midpoint = new DrawingPoint(selectionRect.Left + selectionRect.Width / 2, selectionRect.Top + selectionRect.Height / 2);
        var work = MonitorInfo.WorkArea(midpoint);
        _workArea = work.IsEmpty ? FallbackWorkArea : work;

        // The new content's size now, not after the show (layout runs on this thread).
        Bindings.Update();
        Card.UpdateLayout();
        if (Card.ActualWidth > 0 && Card.ActualHeight > 0) _cardSize = new(Card.ActualWidth, Card.ActualHeight);
        var scale = MonitorInfo.Scale(midpoint);
        var frame = ToolbarWindowStyle.FrameExtent(Hwnd);
        var size = new DrawingSize(
            Pixels(_cardSize.Width * ViewModel.Zoom, scale) + frame.Width, Pixels(_cardSize.Height * ViewModel.Zoom, scale) + frame.Height);
        var origin = PanelPositioning.PanelOrigin(size, selectionRect, _workArea, pointer, grewDownward);
        ToolbarWindowStyle.SetBounds(Hwnd, new DrawingRectangle(origin, size));

        // Never Activate(): it would take the foreground from the source app.
        AppWindow.Show(activateWindow: false);
        IsShown = true;

        // The XAML input-site windows exist only once the window is shown; windows already subclassed are skipped.
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_closed) return;
            try
            {
                ToolbarWindowStyle.SubclassNoActivate(Hwnd, null);
            }
            catch (Exception)
            {
                // Tier 1 goes on without the subclass lever (WS_EX_NOACTIVATE and the hand-back still hold).
            }
        });
    }

    /// <summary>
    /// Hides the toolbar and stops any run (Phase 8 → 8.3: every hide stops the session). The foreground goes back to
    /// the source only if the toolbar has it (after a click elsewhere, the clicked window keeps it).
    /// </summary>
    public void Hide()
    {
        if (_closed || !IsShown) return;
        StopDrag();
        EndTextInput(handBack: false);
        MoreMenu.Hide();
        _languageMenu?.Hide();
        HoverTooltip.Dismiss();
        ToolbarWindowStyle.HandBackForeground(Hwnd, _handBackTo);
        AppWindow.Hide();
        IsShown = false;
        UserDragged = false;
        ViewModel.Stop();
    }

    /// <summary>The point is on the toolbar's window (the outside-click check).</summary>
    public bool Contains(DrawingPoint point) => ToolbarWindowStyle.WindowRect(Hwnd).Contains(point);

    /// <summary>
    /// A menu was open at <paramref name="timestamp"/> (the mouse hook's tick count): the press was on the menu, or
    /// closed it, and is not an outside click (macOS: a click outside an open menu only closes the menu). By time, since
    /// the hook's press may be handled after the menu closed.
    /// </summary>
    public bool WasMenuOpenAt(uint timestamp) =>
        (int)(timestamp - _menuOpenedAt) >= 0 && (_menuOpen || (int)(_menuClosedAt - timestamp) >= 0);

    // Text input: the only time the toolbar is activated on purpose (spike 3.5: the activation region answers
    // MA_ACTIVATE for a click in the box, and SetForegroundWindow right after the user's click or hotkey is the second
    // lever). It ends (activation off) on Enter, Cancel, a press anywhere but the box, the box closing, deactivation
    // (another window took the foreground) and hide.

    private IEnumerable<TextBox> TextBoxes => [PromptBox, RefineBox, EditBox];

    /// <summary>
    /// Activates the toolbar for <paramref name="box"/> and focuses it. When Windows refuses the foreground, text input
    /// ends at once (typing would go to the source); the box stays, and a click in it activates the toolbar.
    /// </summary>
    private void BeginTextInput(TextBox box)
    {
        if (_closed || !IsShown) return;
        var foreground = ToolbarWindowStyle.RememberForeground(Hwnd);
        if (foreground != 0) _handBackTo = foreground;
        _textInput = box;
        _regionBox = box;
        UpdateActivationRegion();
        ToolbarWindowStyle.AllowActivation(Hwnd, true);
        if (!ToolbarWindowStyle.IsToolbarOrOwnedForeground(Hwnd)) ToolbarWindowStyle.SetForeground(Hwnd);
        if (!ToolbarWindowStyle.IsToolbarOrOwnedForeground(Hwnd))
        {
            EndTextInput(handBack: false);
            return;
        }
        // Once the window is active (a press or a just-shown box is still being handled now).
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_closed && _textInput == box) box.Focus(FocusState.Programmatic);
        });
    }

    /// <summary>
    /// Ends text input: clicks stop activating the toolbar (WS_EX_NOACTIVATE back on) and, with
    /// <paramref name="handBack"/>, the source gets the foreground back if the toolbar has it. Also when only the
    /// subclass turned activation on (a click in the region whose press never reached the box). The controller calls it
    /// before a paste.
    /// </summary>
    public void EndTextInput(bool handBack)
    {
        if (_closed || (_textInput is null && !ToolbarWindowStyle.IsActivationAllowed(Hwnd))) return;
        _textInput = null;
        ToolbarWindowStyle.AllowActivation(Hwnd, false);
        if (handBack) ToolbarWindowStyle.HandBackForeground(Hwnd, _handBackTo);
    }

    /// <summary>A text box opened: text input starts in it. It closed: text input in it ends, and it is no longer the region.</summary>
    private void OnTextBoxShown(TextBox box, bool shown)
    {
        if (shown)
        {
            BeginTextInput(box);
            return;
        }
        if (_regionBox == box)
        {
            _regionBox = null;
            UpdateActivationRegion();
        }
        if (_textInput == box) EndTextInput(handBack: true);
    }

    private bool IsBoxShown(TextBox box) =>
        box == PromptBox ? ViewModel.IsPromptInputActive : box == RefineBox ? ViewModel.IsRefineInputActive : ViewModel.ShowsEditor;

    /// <summary>The region box's bounds in client pixels become the activation region (empty when it is not shown).</summary>
    private void UpdateActivationRegion()
    {
        if (_closed) return;
        var region = DrawingRectangle.Empty;
        var scale = _xamlRoot?.RasterizationScale ?? 0;
        if (_regionBox is { } box && IsBoxShown(box) && box.ActualWidth > 0 && box.ActualHeight > 0
            && scale > 0 && double.IsFinite(scale))
        {
            var bounds = box.TransformToVisual(RootCanvas)
                .TransformBounds(new Windows.Foundation.Rect(0, 0, box.ActualWidth, box.ActualHeight));
            region = DrawingRectangle.FromLTRB(
                (int)Math.Floor(bounds.Left * scale), (int)Math.Floor(bounds.Top * scale),
                (int)Math.Ceiling(bounds.Right * scale), (int)Math.Ceiling(bounds.Bottom * scale));
        }
        ToolbarWindowStyle.SetActivationRegion(Hwnd, region);
    }

    /// <summary>The press is on <paramref name="box"/> or inside it.</summary>
    private static bool IsWithin(object? source, TextBox box)
    {
        for (var element = source as DependencyObject; element is not null; element = VisualTreeHelper.GetParent(element))
        {
            if (element == box) return true;
        }
        return false;
    }

    /// <summary>A click in a text box (one already open): text input in it (the click itself focuses it).</summary>
    private void OnTextBoxPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!_closed && sender is TextBox box && _textInput != box) BeginTextInput(box);
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

    /// <summary>Another window took the foreground (a click elsewhere): it keeps it, only activation goes off.</summary>
    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (!_closed && args.WindowActivationState == WindowActivationState.Deactivated) EndTextInput(handBack: false);
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
        FrameworkElement content = Icon(item);
        if (item.ShowsLabel)
        {
            var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            panel.Children.Add(content);
            panel.Children.Add(new TextBlock { Text = item.Label, VerticalAlignment = VerticalAlignment.Center });
            content = panel;
        }
        var button = new Button
        {
            Content = content,
            Tag = item,
            AllowFocusOnInteraction = false,
            VerticalAlignment = VerticalAlignment.Stretch,
            IsEnabled = ViewModel.ActionsEnabled,
        };
        AutomationProperties.SetName(button, item.Label);
        if (!item.ShowsLabel) HoverTooltip.SetText(button, item.Label);
        button.Click += OnActionClick;
        _rowButtons.Add(button);
        return button;
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

    private static FrameworkElement Icon(ToolbarActionItem item) => item.Emoji is { } emoji
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

    // The menus: built when they open, so they show the current actions and target. While one is open, presses are not
    // outside clicks (WasMenuOpenAt) and the press hand-back waits; the foreground goes back when it closes.

    private void OnMoreMenuOpening(object? sender, object e)
    {
        if (_closed) return;
        OnMenuOpening();
        ClearMenu(MoreMenu);
        foreach (var item in ViewModel.OverflowActions)
        {
            var entry = new MenuFlyoutItem
            {
                Text = item.Label,
                Tag = item,
                Icon = item.Emoji is { } emoji
                    ? new FontIcon { FontFamily = new FontFamily("Segoe UI Emoji"), Glyph = emoji }
                    : new FontIcon { FontFamily = SymbolFont, Glyph = item.Glyph ?? "" },
                IsEnabled = ViewModel.ActionsEnabled,
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
        _menuOpen = true;
        _menuOpenedAt = (uint)Environment.TickCount;
        HoverTooltip.Dismiss();
    }

    private void OnMenuClosed(object? sender, object e)
    {
        _menuOpen = false;
        _menuClosedAt = (uint)Environment.TickCount;
        if (_closed) return;
        // After the item's click (Prompt opens its box and keeps the foreground for typing).
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_closed && !_menuOpen && !_dragging && _textInput is null) ToolbarWindowStyle.HandBackForeground(Hwnd, _handBackTo);
        });
    }

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
        switch (e.PropertyName)
        {
            case nameof(ToolbarViewModel.Actions):
                RebuildActionRow();
                break;
            case nameof(ToolbarViewModel.ActionsEnabled):
                foreach (var button in _rowButtons) button.IsEnabled = ViewModel.ActionsEnabled;
                break;
            case nameof(ToolbarViewModel.TargetLanguage):
                if (_languageLabel is not null) _languageLabel.Text = ViewModel.TargetLanguage.Code;
                break;
            case nameof(ToolbarViewModel.Zoom):
                CardScale.ScaleX = ViewModel.Zoom;
                CardScale.ScaleY = ViewModel.Zoom;
                FitToCard();
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
                OnTextBoxShown(PromptBox, ViewModel.IsPromptInputActive);
                break;
            case nameof(ToolbarViewModel.IsRefineInputActive):
                if (ViewModel.IsRefineInputActive == _refineShown) break;
                _refineShown = ViewModel.IsRefineInputActive;
                if (!ViewModel.IsRefineInputActive) RefineBox.Text = "";
                OnTextBoxShown(RefineBox, ViewModel.IsRefineInputActive);
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
                OnTextBoxShown(EditBox, ViewModel.ShowsEditor);
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
        CopyIcon.Glyph = "\uE73E";
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
        CopyIcon.Glyph = "\uE8C8";
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

    // The foreground hand-back: WS_EX_NOACTIVATE does not hold for every press, so after each one the source gets the
    // foreground back if the toolbar took it.

    private void OnAnyPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_closed) return;
        // The window to hand back to: the foreground now, unless it is the toolbar (then the one from before).
        var foreground = ToolbarWindowStyle.RememberForeground(Hwnd);
        if (foreground != 0) _handBackTo = foreground;
        // A press anywhere but the text box ends text input: the toolbar must not stay the foreground. Runs after the
        // box's own press handler, so a press in another box has already moved text input there.
        if (_textInput is not { } box || !IsWithin(e.OriginalSource, box)) EndTextInput(handBack: true);
    }

    private void OnAnyPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_closed) return;
        // After the click handlers (a paste must run while PopGuy may still set the foreground). Not during text input
        // (a click that opened a box): the toolbar keeps the foreground on purpose; nor while a menu the click opened is
        // up (it hands back when it closes).
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_closed && !_dragging && !_menuOpen && _textInput is null) ToolbarWindowStyle.HandBackForeground(Hwnd, _handBackTo);
        });
    }

    // Drag: no title bar, so a press on the card's background (Transparent, so it hit-tests) moves the window by how far
    // the pointer moved since the press. A window that is not the foreground cannot really capture the pointer, so the
    // drag also reads the pointer and the button every 15 ms and ends when the button is up.

    private void OnBackgroundPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_closed || _dragging || !e.GetCurrentPoint(Card).Properties.IsLeftButtonPressed) return;
        Card.CapturePointer(e.Pointer);
        _dragPointer = ToolbarWindowStyle.CursorPosition();
        _dragOrigin = ToolbarWindowStyle.WindowRect(Hwnd).Location;
        _dragging = true;
        _dragTimer.Start();
        e.Handled = true;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging || _closed) return;
        DragToPointer();
        e.Handled = true;
    }

    private void OnDragTick(DispatcherQueueTimer sender, object args)
    {
        if (!_dragging || _closed)
        {
            sender.Stop();
            return;
        }
        if (!ToolbarWindowStyle.IsPrimaryButtonDown())
        {
            // Released where the window did not see it (outside it, without a capture).
            EndDrag();
            return;
        }
        DragToPointer();
    }

    /// <summary>The window's top-left corner follows the pointer from where the drag started.</summary>
    private void DragToPointer()
    {
        var pointer = ToolbarWindowStyle.CursorPosition();
        var x = _dragOrigin.X + pointer.X - _dragPointer.X;
        var y = _dragOrigin.Y + pointer.Y - _dragPointer.Y;
        var frame = ToolbarWindowStyle.WindowRect(Hwnd);
        if (frame.IsEmpty || (frame.X == x && frame.Y == y)) return;
        if (ToolbarWindowStyle.Move(Hwnd, x, y)) UserDragged = true;
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging) return;
        DragToPointer();
        if (!_closed) Card.ReleasePointerCapture(e.Pointer);
        e.Handled = true;
        EndDrag();
    }

    private void OnPointerCaptureLost(object sender, PointerRoutedEventArgs e)
    {
        // Without a real capture, the capture goes as soon as the pointer leaves: the poll goes on until the button is up.
        if (_dragging && !ToolbarWindowStyle.IsPrimaryButtonDown()) EndDrag();
    }

    /// <summary>The drag is over: later resizes keep the toolbar in the work area of the monitor it was dropped on.</summary>
    private void EndDrag()
    {
        StopDrag();
        if (_closed) return;
        var frame = ToolbarWindowStyle.WindowRect(Hwnd);
        if (!frame.IsEmpty)
        {
            var work = MonitorInfo.WorkArea(new DrawingPoint(frame.Left + frame.Width / 2, frame.Top + frame.Height / 2));
            if (!work.IsEmpty) _workArea = work;
        }
        ToolbarWindowStyle.HandBackForeground(Hwnd, _handBackTo);
    }

    private void StopDrag()
    {
        _dragging = false;
        _dragTimer.Stop();
    }

    // Size: the window follows the card, its top edge fixed, then clamped into the work area (spec-1 §3.1-3.2).

    private void OnCardLoaded(object sender, RoutedEventArgs e)
    {
        if (_closed || _xamlRoot is not null || Card.XamlRoot is not { } root) return;
        _xamlRoot = root;
        root.Changed += OnXamlRootChanged;
        FitToCard();
    }

    /// <summary>A move to a monitor of another DPI: the same DIPs are another number of pixels.</summary>
    private void OnXamlRootChanged(XamlRoot sender, XamlRootChangedEventArgs args)
    {
        if (_closed) return;
        FitToCard();
        UpdateActivationRegion();
    }

    /// <summary>The body is as wide as the bar, and at least <see cref="MinBodyWidth"/>, so its text wraps (spec-1 §3.3).</summary>
    private void OnBarSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!_closed) Body.Width = Math.Max(Bar.ActualWidth, MinBodyWidth);
    }

    private void OnCardSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_closed) return;
        FitToCard();
        // The boxes move with the content above them.
        UpdateActivationRegion();
    }

    private void FitToCard()
    {
        if (_xamlRoot is null || Card.ActualWidth <= 0 || Card.ActualHeight <= 0) return;
        var scale = _xamlRoot.RasterizationScale;
        if (scale <= 0 || !double.IsFinite(scale)) return;
        _cardSize = new(Card.ActualWidth, Card.ActualHeight);
        // The window is the zoomed card (a render scale: the layout size is unscaled) plus the frame Windows keeps around
        // the client area.
        var extent = ToolbarWindowStyle.FrameExtent(Hwnd);
        var width = Pixels(_cardSize.Width * ViewModel.Zoom, scale) + extent.Width;
        var height = Pixels(_cardSize.Height * ViewModel.Zoom, scale) + extent.Height;
        var frame = ToolbarWindowStyle.WindowRect(Hwnd);
        if (frame.IsEmpty || (frame.Width == width && frame.Height == height)) return;

        // Keep the top-left, then clamp; wider or taller than the work area pins to its left or top edge (Max last).
        var inset = PanelPositioning.PanelEdgeInset;
        var x = Math.Max(Math.Min(frame.X, _workArea.Right - width - inset), _workArea.Left + inset);
        var y = Math.Max(Math.Min(frame.Y, _workArea.Bottom - height - inset), _workArea.Top + inset);
        ToolbarWindowStyle.SetBounds(Hwnd, new DrawingRectangle(x, y, width, height));
    }

    /// <summary>Layout rounding leaves whole pixels; the tolerance keeps a rounding error from adding one.</summary>
    private static int Pixels(double dips, double scale) => (int)Math.Ceiling(dips * scale - 0.01);

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _closed = true;
        IsShown = false;
        StopDrag();
        _dragTimer.Tick -= OnDragTick;
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
        MoreMenu.Opening -= OnMoreMenuOpening;
        MoreMenu.Closed -= OnMenuClosed;
        ClearMenu(MoreMenu);
        HoverTooltip.Dismiss();
        PromptBox.TextChanged -= OnPromptTextChanged;
        RefineBox.TextChanged -= OnRefineTextChanged;
        EditBox.TextChanged -= OnEditTextChanged;
        PromptBox.PreviewKeyDown -= OnInputPreviewKeyDown;
        RefineBox.PreviewKeyDown -= OnInputPreviewKeyDown;
        Activated -= OnActivated;
        foreach (var button in _rowButtons) button.Click -= OnActionClick;
        if (_languageMenu is not null)
        {
            _languageMenu.Opening -= OnLanguageMenuOpening;
            _languageMenu.Closed -= OnMenuClosed;
            ClearMenu(_languageMenu);
        }
        ViewModel.PropertyChanged -= OnViewModelChanged;
        ViewModel.Detach();
        Card.PointerPressed -= OnBackgroundPressed;
        Card.PointerMoved -= OnPointerMoved;
        Card.PointerReleased -= OnPointerReleased;
        Card.PointerCaptureLost -= OnPointerCaptureLost;
        Bar.SizeChanged -= OnBarSizeChanged;
        Card.SizeChanged -= OnCardSizeChanged;
        Card.Loaded -= OnCardLoaded;
        if (_xamlRoot is not null) _xamlRoot.Changed -= OnXamlRootChanged;
        _xamlRoot = null;
    }
}
