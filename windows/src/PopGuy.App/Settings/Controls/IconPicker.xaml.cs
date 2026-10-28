using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PopGuy.Core.Actions;
using PopGuy.Core.Icons;

namespace PopGuy.Settings.Controls;

/// <summary>
/// The custom action icon picker (macOS IconPickerView): the SF Symbol tab (macOS's curated names, filtered by the search,
/// each drawn through <see cref="SymbolMap"/>) and the Emoji tab (a box keeping its last emoji, then the quick picks). A
/// pick stores the SF Symbol name or the emoji in <see cref="ActionIcon"/>, never a glyph, so settings stay portable. It
/// opens on the tab of the current icon. UI thread only.
/// </summary>
public sealed partial class IconPicker : UserControl
{
    private readonly List<(ActionIcon Icon, Border Chip, FontIcon? Glyph)> _cells = [];
    private readonly Dictionary<string, Button> _symbolButtons = new(StringComparer.Ordinal);

    /// <summary>The emoji box's text as last set from the selection: TextBox raises TextChanged later, so a change to it is not the user's.</summary>
    private string _shownText = "";

    public IconPicker()
    {
        InitializeComponent();
        ModeBar.SelectionChanged += (_, _) => ShowMode();
        SearchBox.TextChanged += (_, _) => FillSymbols();
        EmojiBox.TextChanged += (_, _) =>
        {
            if (EmojiBox.Text != _shownText) Select(IconCatalog.EmojiFromInput(EmojiBox.Text));
        };
    }

    /// <summary>The picked icon.</summary>
    public ActionIcon Selection { get; private set; } = ActionIcon.Default;

    /// <summary>The user picked an icon.</summary>
    public event Action<ActionIcon>? SelectionChanged;

    /// <summary>The symbol font of the app's glyphs (a FontIcon's own, put back after an emoji).</summary>
    internal static FontFamily SymbolFont =>
        Application.Current.Resources.TryGetValue("SymbolThemeFontFamily", out var found) && found is FontFamily family
            ? family
            : new FontFamily("Segoe Fluent Icons");

    /// <summary>Builds the cells for <paramref name="current"/> and opens its tab. Once, before it shows.</summary>
    internal void Initialize(ActionIcon current)
    {
        Selection = current;
        foreach (var name in IconCatalog.Symbols) _symbolButtons[name] = SymbolCell(name);
        foreach (var emoji in IconCatalog.Emoji) EmojiGrid.Children.Add(EmojiCell(emoji));
        FillSymbols();
        ModeBar.SelectedItem = ModeBar.Items[current.Type == ActionIconType.Emoji ? 1 : 0];
        ShowMode();
        Refresh();
    }

    private void ShowMode()
    {
        var emoji = ModeBar.Items.IndexOf(ModeBar.SelectedItem) == 1;
        SymbolPanel.Visibility = emoji ? Visibility.Collapsed : Visibility.Visible;
        EmojiPanel.Visibility = emoji ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>The symbol grid holds the names matching the search; "No results" stands in for an empty one.</summary>
    private void FillSymbols()
    {
        var names = IconCatalog.Search(SearchBox.Text);
        SymbolGrid.Children.Clear();
        foreach (var name in names) SymbolGrid.Children.Add(_symbolButtons[name]);
        NoResultsText.Visibility = names.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        SymbolScroller.Visibility = names.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Select(ActionIcon icon)
    {
        if (icon == Selection) return;
        Selection = icon;
        Refresh();
        SelectionChanged?.Invoke(icon);
    }

    /// <summary>The cells mark the selection; the emoji box shows the selected emoji (macOS: its binding's getter).</summary>
    private void Refresh()
    {
        foreach (var (icon, chip, glyph) in _cells)
        {
            var selected = icon == Selection;
            chip.Style = CellStyle(selected ? (glyph is null ? "SelectedEmojiCellStyle" : "SelectedSymbolCellStyle") : "CellStyle");
            if (glyph is not null) glyph.Style = CellStyle(selected ? "SelectedGlyphStyle" : "GlyphStyle");
        }
        var text = Selection.Type == ActionIconType.Emoji ? Selection.Value : "";
        _shownText = text;
        if (EmojiBox.Text == text) return;
        EmojiBox.Text = text;
        EmojiBox.SelectionStart = text.Length;
    }

    private Button SymbolCell(string name)
    {
        var glyph = new FontIcon { FontFamily = SymbolFont, Glyph = SymbolMap.Glyph(name) };
        return Cell(ActionIcon.SfSymbol(name), glyph, glyph, name);
    }

    private Button EmojiCell(string emoji)
    {
        var text = new TextBlock
        {
            Text = emoji,
            FontSize = 20,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        return Cell(ActionIcon.Emoji(emoji), text, null, emoji);
    }

    /// <summary>A 36-point chip in a flat button (keyboard and screen reader reach it); a click picks its icon.</summary>
    private Button Cell(ActionIcon icon, FrameworkElement content, FontIcon? glyph, string name)
    {
        content.HorizontalAlignment = HorizontalAlignment.Center;
        content.VerticalAlignment = VerticalAlignment.Center;
        var chip = new Border { Child = content };
        var button = new Button { Content = chip, Style = CellStyle("CellButtonStyle") };
        AutomationProperties.SetName(button, name);
        button.Click += (_, _) => Select(icon);
        _cells.Add((icon, chip, glyph));
        return button;
    }

    private Style CellStyle(string key) => (Style)Resources[key];
}
