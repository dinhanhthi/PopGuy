using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using PopGuy.Controls;
using PopGuy.Core.Emojis;
using PopGuy.Platform.Windowing;
using PopGuy.Toolbar;
using CoreVirtualKeyStates = Windows.UI.Core.CoreVirtualKeyStates;
using DrawingPoint = System.Drawing.Point;
using DrawingRectangle = System.Drawing.Rectangle;
using DrawingSize = System.Drawing.Size;
using VirtualKey = Windows.System.VirtualKey;

namespace PopGuy.EmojiPicker;

/// <summary>
/// The emoji picker (macOS EmojiPickerPanel, EmojiPickerView and EmojiGridView): a borderless, topmost tool window of
/// 360 × 333 DIPs on DesktopAcrylic, shown at the caret. It shows <see cref="EmojiPickerModel"/> (section-based; the
/// grid flattens it into rows) and drives it from the search box's keys and the clicks; the controller handles
/// <see cref="EmojiPickerModel.Confirmed"/> and this window's events. Unlike the toolbar, it takes the foreground while
/// shown (the search box needs the keys) and hands it back when it hides. Points and rects are physical screen pixels.
/// UI thread only.
/// </summary>
public sealed partial class EmojiPickerWindow : Window
{
    /// <summary>The content size in DIPs (macOS EmojiPickerPanel.contentSize).</summary>
    private const double ContentWidth = 360;
    private const double ContentHeight = 333;

    /// <summary>The gap between the caret and the picker, in DIPs.</summary>
    private const double CaretGap = 4;

    /// <summary>Row heights in DIPs: a section's title, and a row of 32-tall cells.</summary>
    private const double HeaderRowHeight = 24;
    private const double CellRowHeight = 32;

    /// <summary>Emoji keep their colors (Segoe UI Emoji); symbols are text glyphs in the default font.</summary>
    private const double EmojiFontSize = 21;
    private const double SymbolFontSize = 19;

    /// <summary>The work area when no monitor can be read.</summary>
    private static readonly DrawingRectangle FallbackWorkArea = new(0, 0, 1280, 800);

    /// <summary>VK_PROCESSKEY: the IME took the key (not in <see cref="VirtualKey"/>).</summary>
    private const VirtualKey ProcessKey = (VirtualKey)229;

    /// <summary>
    /// The category icons by section title (macOS sectionSymbols), as Segoe Fluent Icons glyphs; a title without one
    /// shows its first letter.
    /// </summary>
    private static readonly Dictionary<string, string> CategoryGlyphs = new(StringComparer.Ordinal)
    {
        ["Frequently Used"] = "", // Clock
        // Emoji
        ["Smileys & Emotion"] = "", // Emoji2
        ["People & Body"] = "", // Contact
        ["Animals & Nature"] = "", // Leaf
        ["Food & Drink"] = "", // Cafe
        ["Travel & Places"] = "", // Car
        ["Activities"] = "", // Game
        ["Objects"] = "", // Lightbulb
        ["Symbols"] = "", // Heart
        ["Flags"] = "", // Flag
        // Symbols
        ["Keyboard"] = "", // KeyboardClassic
        ["Arrows"] = "", // Forward
        ["Currency"] = "", // PaymentCard
        ["Math"] = "", // CalculatorNegate
        ["Typography"] = "", // Font
        ["Checkboxes"] = "", // CheckboxComposite
    };

    private readonly FontFamily _emojiFont = new("Segoe UI Emoji");
    private readonly FontFamily _symbolIconFont;
    private readonly HashSet<Grid> _realizedRows = [];
    private readonly List<Grid> _categoryItems = [];

    private EmojiPickerModel? _model;
    private SkinTone _tone;
    private bool _closed;
    private bool _closingByCode;
    private XamlRoot? _xamlRoot;

    /// <summary>The rows the grid shows, flattened from <see cref="_sections"/>.</summary>
    private List<EmojiGridRow> _rows = [];

    /// <summary>The model's sections the rows were built from: a new list means a query, tab or reset change.</summary>
    private IReadOnlyList<PickerSection>? _sections;

    /// <summary>Per section, the index of its header row in <see cref="_rows"/>.</summary>
    private int[] _sectionFirstRow = [];

    /// <summary>The selection the grid last drew.</summary>
    private PickerSelection? _drawnSelection;

    /// <summary>The search box is composing (IME): the arrows, Enter and Esc are the IME's.</summary>
    private bool _composing;

    /// <summary>A category click is jumping: it scrolls the section's header to the top itself.</summary>
    private bool _jumping;

    /// <summary>The window was activated since the last show: only then does a deactivation close it.</summary>
    private bool _activatedSinceShow;

    /// <summary>The window to hand the foreground back to: the foreground window when the picker was shown.</summary>
    private nint _handBackTo;

    public EmojiPickerWindow()
    {
        InitializeComponent();
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
            RootGrid.Background = (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"];

        _symbolIconFont = Application.Current.Resources.TryGetValue("SymbolThemeFontFamily", out var found) && found is FontFamily family
            ? family
            : new FontFamily("Segoe Fluent Icons");

        SearchBox.TextChanged += OnSearchTextChanged;
        SearchBox.PreviewKeyDown += OnSearchPreviewKeyDown;
        SearchBox.TextCompositionStarted += OnTextCompositionStarted;
        SearchBox.TextCompositionEnded += OnTextCompositionEnded;
        SettingsButton.Click += OnSettingsClick;
        EmojiTabButton.Click += OnEmojiTabClick;
        SymbolsTabButton.Click += OnSymbolsTabClick;
        RowsRepeater.ElementPrepared += OnElementPrepared;
        RowsRepeater.ElementClearing += OnElementClearing;
        RowsRepeater.ElementIndexChanged += OnElementIndexChanged;
        RootGrid.Loaded += OnRootLoaded;
        Activated += OnActivated;
        AppWindow.Closing += OnAppWindowClosing;
        Closed += OnClosed;
    }

    /// <summary>The gear was clicked: the controller hides the picker and opens Settings.</summary>
    public event Action? SettingsRequested;

    /// <summary>Esc in the search box, or Alt+F4 (the window stays open): the controller hides the picker.</summary>
    public event Action? Cancelled;

    /// <summary>The picker's window handle.</summary>
    public nint Hwnd { get; }

    /// <summary>The picker is on screen.</summary>
    public bool IsShown { get; private set; }

    /// <summary>
    /// Shows <paramref name="model"/> below <paramref name="caret"/> (above when there is no room), clamped to the work
    /// area of the caret's monitor, and takes the foreground with the keyboard focus in the search box. Call
    /// <see cref="EmojiPickerModel.Reset"/> first (each open). The window to hand the foreground back to is the
    /// foreground window now (the source app).
    /// </summary>
    /// <param name="caret">The caret's screen rect; a zero-size rect at the pointer when the caret is unknown.</param>
    public void ShowAt(DrawingRectangle caret, EmojiPickerModel model, SkinTone tone)
    {
        if (_closed) return;
        Attach(model);
        _tone = tone;
        // Set on every opening, also to 0: the foreground never goes back to a window of an earlier opening.
        _handBackTo = ToolbarWindowStyle.RememberForeground(Hwnd);

        // Everything from the model, as on a reset (rows, tabs, categories, footer), at the top.
        _sections = null;
        SyncFromModel();

        var anchor = caret.Location;
        var work = MonitorInfo.WorkArea(anchor);
        if (work.IsEmpty) work = FallbackWorkArea;
        var scale = MonitorInfo.Scale(anchor);
        var size = WindowSize(scale);
        var origin = Origin(size, caret, work, Pixels(CaretGap, scale));
        ToolbarWindowStyle.SetBounds(Hwnd, new DrawingRectangle(origin, size));
        // A click anywhere in the picker activates it (when Windows refused the foreground at show).
        ToolbarWindowStyle.SetActivationRegion(Hwnd, new DrawingRectangle(DrawingPoint.Empty, size));

        _activatedSinceShow = false;
        AppWindow.Show(activateWindow: false);
        IsShown = true;
        TakeForeground();

        // The XAML input-site windows exist only once the window is shown; windows already subclassed are skipped.
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_closed || !IsShown) return;
            try
            {
                ToolbarWindowStyle.SubclassNoActivate(Hwnd, null);
            }
            catch (Exception)
            {
                // The picker goes on without the subclass lever (it already has the foreground or a click gives it).
            }
            SearchBox.Focus(FocusState.Programmatic);
            ScrollToTop();
        });
    }

    /// <summary>
    /// Hides the picker; the foreground goes back to the source only if the picker has it (after a click elsewhere,
    /// the clicked window keeps it).
    /// </summary>
    public void HidePicker()
    {
        if (_closed || !IsShown) return;
        IsShown = false;
        _activatedSinceShow = false;
        HoverTooltip.Dismiss();
        ToolbarWindowStyle.AllowActivation(Hwnd, false);
        ToolbarWindowStyle.HandBackForeground(Hwnd, _handBackTo);
        AppWindow.Hide();
    }

    /// <summary>
    /// Activation on (WS_EX_NOACTIVATE off), then the foreground: right after the user's hotkey Windows normally allows
    /// it; when it refused, the thread-attach lever. If both fail, the picker stays and a click in it activates it.
    /// </summary>
    private void TakeForeground()
    {
        ToolbarWindowStyle.AllowActivation(Hwnd, true);
        ToolbarWindowStyle.SetForeground(Hwnd);
        if (!ToolbarWindowStyle.IsToolbarOrOwnedForeground(Hwnd)) ToolbarWindowStyle.ForceForeground(Hwnd);
    }

    /// <summary>Another window took the foreground after the picker had it: the picker hides.</summary>
    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (_closed || !IsShown) return;
        if (args.WindowActivationState != WindowActivationState.Deactivated)
        {
            _activatedSinceShow = true;
            return;
        }
        if (!_activatedSinceShow) return;
        // Once the foreground has moved (a popup the picker owns, e.g. a tooltip, does not count).
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_closed || !IsShown || ToolbarWindowStyle.IsToolbarOrOwnedForeground(Hwnd)) return;
            HidePicker();
        });
    }

    // Model.

    private void Attach(EmojiPickerModel model)
    {
        if (ReferenceEquals(_model, model)) return;
        if (_model is not null) _model.Changed -= OnModelChanged;
        _model = model;
        _model.Changed += OnModelChanged;
    }

    private void OnModelChanged()
    {
        if (!_closed) SyncFromModel();
    }

    /// <summary>
    /// The view follows the model. The sections list is replaced only on a query, tab or reset change: then the rows
    /// are rebuilt and the grid goes back to the top; otherwise only the selection moved, and it is scrolled into view.
    /// </summary>
    private void SyncFromModel()
    {
        if (_model is not { } model) return;
        if (SearchBox.Text != model.Query) SearchBox.Text = model.Query;

        var browsing = model.Query.Length == 0;
        var empty = model.Sections.Count == 0;
        Navigation.Visibility = browsing && !empty ? Visibility.Visible : Visibility.Collapsed;
        NavigationDivider.Visibility = Navigation.Visibility;
        GridScroller.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        EmptyState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        SyncTabs(model.Tab);
        FooterText.Text = model.SelectedEmoji is { } emoji ? CapitalizedFirst(emoji.Description) : "No results";

        if (!ReferenceEquals(_sections, model.Sections))
        {
            RebuildRows(model.Sections);
            RebuildCategories(browsing ? model.Sections : []);
            _drawnSelection = model.Selection;
            SyncCategoryUnderline();
            ScrollToTop();
            return;
        }

        if (_drawnSelection == model.Selection) return;
        var previous = _drawnSelection;
        _drawnSelection = model.Selection;
        RefreshRowOf(previous);
        RefreshRowOf(model.Selection);
        SyncCategoryUnderline();
        if (!_jumping) ScrollSelectionIntoView();
    }

    private void SyncTabs(PickerTab tab)
    {
        var selected = (Style)RootGrid.Resources["TabSelectedButtonStyle"];
        var normal = (Style)RootGrid.Resources["TabButtonStyle"];
        var emojiStyle = tab == PickerTab.Emoji ? selected : normal;
        var symbolsStyle = tab == PickerTab.Symbols ? selected : normal;
        if (!ReferenceEquals(EmojiTabButton.Style, emojiStyle)) EmojiTabButton.Style = emojiStyle;
        if (!ReferenceEquals(SymbolsTabButton.Style, symbolsStyle)) SymbolsTabButton.Style = symbolsStyle;
    }

    // Grid rows: a section's header, then its cells by rows of the section's column count (9).

    private void RebuildRows(IReadOnlyList<PickerSection> sections)
    {
        _sections = sections;
        var rows = new List<EmojiGridRow>();
        _sectionFirstRow = new int[sections.Count];
        for (var s = 0; s < sections.Count; s++)
        {
            _sectionFirstRow[s] = rows.Count;
            rows.Add(new EmojiGridRow(s, 0, isHeader: true));
            var section = sections[s];
            for (var start = 0; start < section.Emojis.Count; start += section.Columns)
                rows.Add(new EmojiGridRow(s, start, isHeader: false));
        }
        _rows = rows;
        _realizedRows.Clear();
        RowsRepeater.ItemsSource = rows;
    }

    /// <summary>The row holding <paramref name="selection"/>'s cell; -1 when none.</summary>
    private int RowIndexOf(PickerSelection? selection)
    {
        if (selection is not { } s || _sections is null || s.Section < 0 || s.Section >= _sectionFirstRow.Length) return -1;
        var row = _sectionFirstRow[s.Section] + 1 + s.Index / _sections[s.Section].Columns;
        return row < _rows.Count ? row : -1;
    }

    private void OnElementPrepared(ItemsRepeater sender, ItemsRepeaterElementPreparedEventArgs args)
    {
        if (args.Element is not Grid grid) return;
        if (grid.Children.Count == 0) BuildRow(grid);
        _realizedRows.Add(grid);
        ConfigureRow(grid, args.Index);
    }

    private void OnElementClearing(ItemsRepeater sender, ItemsRepeaterElementClearingEventArgs args)
    {
        if (args.Element is Grid grid) _realizedRows.Remove(grid);
    }

    private void OnElementIndexChanged(ItemsRepeater sender, ItemsRepeaterElementIndexChangedEventArgs args)
    {
        if (args.Element is Grid grid) ConfigureRow(grid, args.NewIndex);
    }

    /// <summary>
    /// A row element's children, made once per element (elements are recycled between header and cell rows): the
    /// header text, then one cell per column, each a hit target holding the highlight and the glyph.
    /// </summary>
    private void BuildRow(Grid grid)
    {
        var columns = PickerTab.Emoji.Columns();
        for (var c = 0; c < columns; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var header = new TextBlock { Style = (Style)RootGrid.Resources["SectionHeaderTextStyle"] };
        Grid.SetColumnSpan(header, columns);
        grid.Children.Add(header);

        var highlightStyle = (Style)RootGrid.Resources["CellHighlightStyle"];
        var textStyle = (Style)RootGrid.Resources["CellTextStyle"];
        for (var c = 0; c < columns; c++)
        {
            var cell = new Grid { Background = new SolidColorBrush(Colors.Transparent), Tag = c };
            cell.Children.Add(new Rectangle { Style = highlightStyle, Visibility = Visibility.Collapsed });
            cell.Children.Add(new TextBlock { Style = textStyle });
            cell.Tapped += OnCellTapped;
            Grid.SetColumn(cell, c);
            grid.Children.Add(cell);
        }
    }

    /// <summary>Shows row <paramref name="rowIndex"/> in <paramref name="grid"/>: its header, or its cells with the selection.</summary>
    private void ConfigureRow(Grid grid, int rowIndex)
    {
        grid.Tag = rowIndex;
        if (_sections is null || rowIndex < 0 || rowIndex >= _rows.Count || grid.Children.Count == 0) return;
        var row = _rows[rowIndex];
        var section = _sections[row.Section];
        var header = (TextBlock)grid.Children[0];
        if (row.IsHeader)
        {
            grid.Height = HeaderRowHeight;
            header.Text = section.Title;
            header.Visibility = Visibility.Visible;
            for (var c = 1; c < grid.Children.Count; c++) grid.Children[c].Visibility = Visibility.Collapsed;
            return;
        }

        grid.Height = CellRowHeight;
        header.Visibility = Visibility.Collapsed;
        var selection = _model?.Selection;
        for (var c = 1; c < grid.Children.Count; c++)
        {
            var cell = (Grid)grid.Children[c];
            var index = row.Start + c - 1;
            if (index >= section.Emojis.Count || index >= row.Start + section.Columns)
            {
                cell.Visibility = Visibility.Collapsed;
                continue;
            }
            var emoji = section.Emojis[index];
            cell.Visibility = Visibility.Visible;
            cell.Children[0].Visibility = selection == new PickerSelection(row.Section, index) ? Visibility.Visible : Visibility.Collapsed;
            var label = (TextBlock)cell.Children[1];
            if (emoji.Kind is null)
            {
                label.Text = emoji.Toned(_tone);
                label.FontSize = EmojiFontSize;
                label.FontFamily = _emojiFont;
            }
            else
            {
                label.Text = emoji.Glyph;
                label.FontSize = SymbolFontSize;
                label.ClearValue(TextBlock.FontFamilyProperty);
            }
            AutomationProperties.SetName(cell, emoji.Description);
        }
    }

    private void RefreshRowOf(PickerSelection? selection)
    {
        var rowIndex = RowIndexOf(selection);
        if (rowIndex < 0) return;
        foreach (var grid in _realizedRows)
        {
            if (grid.Tag is int index && index == rowIndex) ConfigureRow(grid, index);
        }
    }

    /// <summary>A click on a cell selects it and confirms it (the controller then hides the picker and types it).</summary>
    private void OnCellTapped(object sender, TappedRoutedEventArgs e)
    {
        if (_closed || _model is not { } model || _sections is null) return;
        if (sender is not Grid { Tag: int column, Parent: Grid { Tag: int rowIndex } } || rowIndex < 0 || rowIndex >= _rows.Count) return;
        var row = _rows[rowIndex];
        if (row.IsHeader) return;
        var section = _sections[row.Section];
        var index = row.Start + column;
        if (index >= section.Emojis.Count) return;
        e.Handled = true;
        model.Select(section.Emojis[index], row.Section);
        model.Confirm();
    }

    // Scrolling.

    private void ScrollToTop() => GridScroller.ChangeView(null, 0, null, disableAnimation: true);

    /// <summary>The selected cell's row into view, with as little scrolling as it takes.</summary>
    private void ScrollSelectionIntoView()
    {
        var rowIndex = RowIndexOf(_model?.Selection);
        if (rowIndex >= 0) BringRowIntoView(rowIndex, alignTop: false);
    }

    private void BringRowIntoView(int rowIndex, bool alignTop)
    {
        if (rowIndex < 0 || rowIndex >= _rows.Count) return;
        var element = RowsRepeater.GetOrCreateElement(rowIndex);
        element.UpdateLayout();
        var options = new BringIntoViewOptions { AnimationDesired = false };
        if (alignTop) options.VerticalAlignmentRatio = 0;
        element.StartBringIntoView(options);
    }

    // Navigation: the tabs and the category icons.

    private void OnEmojiTabClick(object sender, RoutedEventArgs e)
    {
        if (_model is { } model) model.Tab = PickerTab.Emoji;
    }

    private void OnSymbolsTabClick(object sender, RoutedEventArgs e)
    {
        if (_model is { } model) model.Tab = PickerTab.Symbols;
    }

    /// <summary>One icon per section (its glyph, else its first letter), with the section's title as its tooltip.</summary>
    private void RebuildCategories(IReadOnlyList<PickerSection> sections)
    {
        foreach (var item in _categoryItems)
        {
            if (item.Children.Count > 0 && item.Children[0] is Button button)
            {
                button.Click -= OnCategoryClick;
                HoverTooltip.SetText(button, null);
            }
        }
        _categoryItems.Clear();
        CategoryRow.Children.Clear();

        var buttonStyle = (Style)RootGrid.Resources["CategoryButtonStyle"];
        var underlineStyle = (Style)RootGrid.Resources["CategoryUnderlineStyle"];
        for (var s = 0; s < sections.Count; s++)
        {
            var title = sections[s].Title;
            var button = new Button { Style = buttonStyle, Tag = s, Content = CategoryIcon(title) };
            AutomationProperties.SetName(button, title);
            HoverTooltip.SetText(button, title);
            button.Click += OnCategoryClick;
            var item = new Grid { Height = 28 };
            item.Children.Add(button);
            item.Children.Add(new Rectangle { Style = underlineStyle, Visibility = Visibility.Collapsed });
            _categoryItems.Add(item);
            CategoryRow.Children.Add(item);
        }
    }

    private UIElement CategoryIcon(string title) => CategoryGlyphs.TryGetValue(title, out var glyph)
        ? new FontIcon { Glyph = glyph, FontSize = 14, FontFamily = _symbolIconFont }
        : new TextBlock
        {
            Text = title.Length > 0 ? title[..1] : "?",
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };

    /// <summary>The underline and the primary color go to the category holding the selection.</summary>
    private void SyncCategoryUnderline()
    {
        var selected = _model?.Selection?.Section ?? -1;
        var buttonStyle = (Style)RootGrid.Resources["CategoryButtonStyle"];
        var selectedStyle = (Style)RootGrid.Resources["CategorySelectedButtonStyle"];
        for (var s = 0; s < _categoryItems.Count; s++)
        {
            var item = _categoryItems[s];
            if (item.Children.Count < 2 || item.Children[0] is not Button button) continue;
            var style = s == selected ? selectedStyle : buttonStyle;
            if (!ReferenceEquals(button.Style, style)) button.Style = style;
            item.Children[1].Visibility = s == selected ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    /// <summary>Selects the section's first cell and scrolls its header to the top (also when it was already selected).</summary>
    private void OnCategoryClick(object sender, RoutedEventArgs e)
    {
        if (_closed || _model is not { } model || sender is not Button { Tag: int section }) return;
        _jumping = true;
        try
        {
            model.Jump(section);
        }
        finally
        {
            _jumping = false;
        }
        if (section < _sectionFirstRow.Length) BringRowIntoView(_sectionFirstRow[section], alignTop: true);
    }

    // Search box: the query, and the keys that drive the grid.

    private void OnSearchTextChanged(object sender, TextChangedEventArgs e)
    {
        // The model ignores the same value (its own reset writing the box back).
        if (!_closed && _model is { } model) model.Query = SearchBox.Text;
    }

    private void OnTextCompositionStarted(TextBox sender, TextCompositionStartedEventArgs args) => _composing = true;

    private void OnTextCompositionEnded(TextBox sender, TextCompositionEndedEventArgs args) => _composing = false;

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    /// <summary>
    /// Arrows move the selection, Enter confirms, Esc cancels. Not while the IME composes (it owns these keys until it
    /// commits), and not with Ctrl, Alt or Shift (Shift+arrows keep selecting text).
    /// </summary>
    private void OnSearchPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_closed || _model is not { } model || _composing || e.Key == ProcessKey) return;
        if (IsDown(VirtualKey.Control) || IsDown(VirtualKey.Menu) || IsDown(VirtualKey.Shift)) return;
        switch (e.Key)
        {
            case VirtualKey.Left:
                model.Move(MoveDirection.Left);
                break;
            case VirtualKey.Right:
                model.Move(MoveDirection.Right);
                break;
            case VirtualKey.Up:
                model.Move(MoveDirection.Up);
                break;
            case VirtualKey.Down:
                model.Move(MoveDirection.Down);
                break;
            case VirtualKey.Enter:
                model.Confirm();
                break;
            case VirtualKey.Escape:
                Cancelled?.Invoke();
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    private void OnSettingsClick(object sender, RoutedEventArgs e) => SettingsRequested?.Invoke();

    // Size and position.

    /// <summary>The window's size at <paramref name="scale"/>: the content plus the frame Windows keeps around the client area.</summary>
    private DrawingSize WindowSize(double scale)
    {
        var frame = ToolbarWindowStyle.FrameExtent(Hwnd);
        return new DrawingSize(Pixels(ContentWidth, scale) + frame.Width, Pixels(ContentHeight, scale) + frame.Height);
    }

    /// <summary>
    /// The top-left (macOS EmojiPickerPanel): at the caret's left edge, <paramref name="gap"/> below it, or above it when
    /// the bottom would leave the work area; then clamped into the work area (Min then Max: a picker larger than the
    /// work area keeps its top/left edge).
    /// </summary>
    private static DrawingPoint Origin(DrawingSize size, DrawingRectangle caret, DrawingRectangle work, int gap)
    {
        var y = caret.Bottom + gap;
        if (y + size.Height > work.Bottom) y = caret.Top - gap - size.Height;
        var x = Math.Max(Math.Min(caret.Left, work.Right - size.Width), work.Left);
        y = Math.Max(Math.Min(y, work.Bottom - size.Height), work.Top);
        return new DrawingPoint(x, y);
    }

    private void OnRootLoaded(object sender, RoutedEventArgs e)
    {
        if (_closed || _xamlRoot is not null || RootGrid.XamlRoot is not { } root) return;
        _xamlRoot = root;
        root.Changed += OnXamlRootChanged;
    }

    /// <summary>A move to a monitor of another DPI: the same DIPs are another number of pixels (top-left kept).</summary>
    private void OnXamlRootChanged(XamlRoot sender, XamlRootChangedEventArgs args)
    {
        if (_closed || !IsShown) return;
        var scale = sender.RasterizationScale;
        if (scale <= 0 || !double.IsFinite(scale)) return;
        var size = WindowSize(scale);
        var frame = ToolbarWindowStyle.WindowRect(Hwnd);
        if (frame.IsEmpty || frame.Size == size) return;
        ToolbarWindowStyle.Resize(Hwnd, size.Width, size.Height);
        ToolbarWindowStyle.SetActivationRegion(Hwnd, new DrawingRectangle(DrawingPoint.Empty, size));
    }

    /// <summary>Layout rounding leaves whole pixels; the tolerance keeps a rounding error from adding one.</summary>
    private static int Pixels(double dips, double scale) => (int)Math.Ceiling(dips * scale - 0.01);

    /// <summary>Uppercases only the first letter, so acronyms ("OK hand", "ZZZ") are kept.</summary>
    private static string CapitalizedFirst(string text) =>
        text.Length == 0 ? text : string.Concat(text[..1].ToUpperInvariant(), text.AsSpan(1));

    /// <summary>Closes the window for good (the feature was turned off, or the app exits); Alt+F4 does not.</summary>
    public void ClosePicker()
    {
        if (_closed) return;
        _closingByCode = true;
        Close();
    }

    /// <summary>
    /// Alt+F4 is Esc: the window stays (a closed picker could never show again) and the controller hides it, on the
    /// next dispatcher turn (not from inside the Closing event).
    /// </summary>
    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_closingByCode || _closed) return;
        args.Cancel = true;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_closed && !_closingByCode) Cancelled?.Invoke();
        });
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _closed = true;
        IsShown = false;
        HoverTooltip.Dismiss();
        if (_model is not null) _model.Changed -= OnModelChanged;
        _model = null;
        SearchBox.TextChanged -= OnSearchTextChanged;
        SearchBox.PreviewKeyDown -= OnSearchPreviewKeyDown;
        SearchBox.TextCompositionStarted -= OnTextCompositionStarted;
        SearchBox.TextCompositionEnded -= OnTextCompositionEnded;
        SettingsButton.Click -= OnSettingsClick;
        EmojiTabButton.Click -= OnEmojiTabClick;
        SymbolsTabButton.Click -= OnSymbolsTabClick;
        RowsRepeater.ElementPrepared -= OnElementPrepared;
        RowsRepeater.ElementClearing -= OnElementClearing;
        RowsRepeater.ElementIndexChanged -= OnElementIndexChanged;
        RootGrid.Loaded -= OnRootLoaded;
        Activated -= OnActivated;
        AppWindow.Closing -= OnAppWindowClosing;
        Closed -= OnClosed;
        if (_xamlRoot is not null) _xamlRoot.Changed -= OnXamlRootChanged;
        _xamlRoot = null;
    }
}

/// <summary>One row of the picker's grid: a section's header, or up to a row of its cells from <see cref="Start"/>.</summary>
internal sealed partial class EmojiGridRow(int section, int start, bool isHeader)
{
    /// <summary>The section's index in the model's sections.</summary>
    public int Section { get; } = section;

    /// <summary>The index of the row's first cell in the section (0 for a header).</summary>
    public int Start { get; } = start;

    public bool IsHeader { get; } = isHeader;
}
