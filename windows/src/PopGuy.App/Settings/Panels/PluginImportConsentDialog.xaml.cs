using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using PopGuy.Core.Actions;
using PopGuy.Core.Plugins;
using PopGuy.Settings.ViewModels;

namespace PopGuy.Settings.Panels;

/// <summary>
/// The import consent panel (macOS PluginImportConsentView, spec-3 §5.3.4), the trust boundary of every import path:
/// the security note, then each action with a checkbox (all checked), its icon, title, type, Windows note, its URL,
/// script or system prompt in full (monospace, selectable, scrolling), After run and the visibility regex; then the
/// items not imported with their reasons. Add to PopGuy (enabled while one is checked) adds the checked actions through
/// <see cref="ActionsViewModel.AddImported"/>; Cancel, Esc or a click beside the panel add nothing. Pure presentation:
/// nothing is run or opened. UI thread only.
/// </summary>
public sealed partial class PluginImportConsentDialog : UserControl
{
    private const string SecurityNote =
        "Imported scripts run only when you click the action. Review them below — only add plugins you trust.";

    private readonly List<(CheckBox Box, CustomAction Action)> _rows = [];
    private ActionsViewModel _model = null!;
    private SlideOverPanel _panel = null!;
    private HyperlinkButton? _selectAll;

    public PluginImportConsentDialog()
    {
        InitializeComponent();
        HeaderBar.Padding = SlideOverPanel.HeaderPadding;
        CancelButton.Click += (_, _) => _panel.Close();
        AddButton.Click += (_, _) => Add();
    }

    /// <summary>The checked actions were added: the page then reports the provider refusals, as macOS does after confirm.</summary>
    internal bool Added { get; private set; }

    /// <summary>Builds the panel for <paramref name="consent"/>. Once, before it shows.</summary>
    internal void Initialize(ActionsViewModel model, ImportConsent consent, SlideOverPanel panel)
    {
        _model = model;
        _panel = panel;
        SourceText.Text = consent.SourceName;
        BodyPanel.Children.Add(Note());
        if (consent.Actions.Count > 0) ActionsSection(consent.Actions);
        if (consent.Skipped.Count > 0) SkippedSection(consent.Skipped);
        SkippedCountText.Text = consent.Skipped.Count == 1 ? "1 item skipped" : $"{consent.Skipped.Count} items skipped";
        SkippedCountText.Visibility = Shown(consent.Skipped.Count > 0);
        RefreshSelection();
    }

    /// <summary>A failed write keeps the panel open with the error; Add stays off so nothing is added twice.</summary>
    private void Add()
    {
        var selected = _rows.Where(r => r.Box.IsChecked == true).Select(r => r.Action).ToList();
        if (selected.Count == 0) return;
        if (!_model.AddImported(selected))
        {
            SaveErrorText.Visibility = Visibility.Visible;
            AddButton.IsEnabled = false;
            return;
        }
        Added = true;
        _panel.Close();
    }

    /// <summary>The counter, Select All / Deselect All and Add follow the checkboxes (macOS selectedIDs).</summary>
    private void RefreshSelection()
    {
        var total = _rows.Count;
        var selected = _rows.Count(r => r.Box.IsChecked == true);
        AddCountText.Text = selected == total
            ? (total == 1 ? "1 action to add" : $"{total} actions to add")
            : $"{selected} of {total} selected";
        AddCountText.Visibility = Shown(total > 0);
        if (_selectAll is not null) _selectAll.Content = selected == total ? "Deselect All" : "Select All";
        if (SaveErrorText.Visibility == Visibility.Collapsed) AddButton.IsEnabled = selected > 0;
    }

    // Body.

    private Border Note()
    {
        var line = new Grid { ColumnSpacing = 8 };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.Children.Add(new FontIcon { Glyph = "", Style = PanelStyle("SecondaryIconStyle"), VerticalAlignment = VerticalAlignment.Top });
        var text = new TextBlock { Text = SecurityNote, Style = PanelStyle("CaptionStyle") };
        Grid.SetColumn(text, 1);
        line.Children.Add(text);
        return new Border { Style = PanelStyle("CardStyle"), Child = line };
    }

    private void ActionsSection(IReadOnlyList<ConsentAction> actions)
    {
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(Section("Actions to add"));
        _selectAll = new HyperlinkButton { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 20, 0, 0) };
        _selectAll.Click += (_, _) =>
        {
            var check = _rows.Any(r => r.Box.IsChecked != true);
            foreach (var (box, _) in _rows) box.IsChecked = check;
        };
        Grid.SetColumn(_selectAll, 1);
        header.Children.Add(_selectAll);
        BodyPanel.Children.Add(header);
        foreach (var entry in actions) BodyPanel.Children.Add(ActionRow(entry));
    }

    /// <summary>A checkbox beside the action's card (macOS ImportedActionCard).</summary>
    private Grid ActionRow(ConsentAction entry)
    {
        var action = entry.Imported.Action;
        var title = action.Title.Length == 0 ? "(untitled)" : action.Title;
        var box = new CheckBox { IsChecked = true, MinWidth = 0, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 8, 0, 0) };
        AutomationProperties.SetName(box, $"Add {title}");
        box.Checked += (_, _) => RefreshSelection();
        box.Unchecked += (_, _) => RefreshSelection();
        _rows.Add((box, action));

        var body = new StackPanel { Spacing = 8 };
        body.Children.Add(CardHeader(action, title));
        if (entry.WindowsNote is { } note) body.Children.Add(CautionLine(note));
        if (action.ScriptSource.Length > 0)
            body.Children.Add(Code(ExecutableLabel(action.Type), action.ScriptSource, 180, wrap: false));
        else if (action.Type == CustomActionType.Ai)
            body.Children.Add(Code("System prompt", action.SystemPrompt.Length == 0 ? "(empty)" : action.SystemPrompt, 120, wrap: true));
        if (action.IsScriptable)
        {
            body.Children.Add(Metadata("After run", CustomActionEditPanel.AfterRunName(action.AfterRun), monospace: false));
            if (action.AppliesWhenRegex.Length > 0) body.Children.Add(Metadata("Shown when matches", action.AppliesWhenRegex, monospace: true));
        }

        var row = new Grid { ColumnSpacing = 4 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var card = new Border { Style = PanelStyle("CardStyle"), Child = body };
        Grid.SetColumn(card, 1);
        row.Children.Add(box);
        row.Children.Add(card);
        return row;
    }

    /// <summary>Icon, title and description, then the type badge.</summary>
    private Grid CardHeader(CustomAction action, string title)
    {
        var header = new Grid { ColumnSpacing = 10 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = new FontIcon { FontSize = 16, Width = 20, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) };
        CustomActionEditPanel.SetIcon(icon, action.Icon);
        header.Children.Add(icon);
        var titles = new StackPanel { Spacing = 2 };
        titles.Children.Add(new TextBlock { Text = title, Style = AppStyle("BodyStrongTextBlockStyle"), TextWrapping = TextWrapping.Wrap });
        if (action.ActionDescription.Length > 0) titles.Children.Add(Caption(action.ActionDescription));
        Grid.SetColumn(titles, 1);
        header.Children.Add(titles);
        var badge = new Border { Style = PanelStyle("BadgeStyle"), Child = Caption(CustomActionEditPanel.TypeName(action.Type)) };
        Grid.SetColumn(badge, 2);
        header.Children.Add(badge);
        return header;
    }

    /// <summary>
    /// <paramref name="text"/> in full under <paramref name="label"/>: plain selectable text (never a link), scrolling past
    /// <paramref name="maxHeight"/>; a script keeps its lines and scrolls sideways.
    /// </summary>
    private StackPanel Code(string label, string text, double maxHeight, bool wrap)
    {
        var block = new TextBlock
        {
            Text = text,
            FontFamily = Monospace,
            FontSize = 12,
            IsTextSelectionEnabled = true,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            Margin = new Thickness(8),
        };
        AutomationProperties.SetName(block, label);
        var scroller = new ScrollViewer
        {
            Content = block,
            MaxHeight = maxHeight,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = wrap ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Auto,
            HorizontalScrollMode = wrap ? ScrollMode.Disabled : ScrollMode.Enabled,
        };
        var panel = new StackPanel { Spacing = 4 };
        panel.Children.Add(Caption(label));
        panel.Children.Add(new Border { Style = PanelStyle("CodeStyle"), Child = scroller });
        return panel;
    }

    /// <summary>A label column, then the value (macOS MetadataRow).</summary>
    private Grid Metadata(string label, string value, bool monospace)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(Caption(label));
        var text = new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        if (monospace) text.FontFamily = Monospace;
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        return row;
    }

    /// <summary>"Not imported": each item's label and reason, in one card with dividers (macOS SkippedItemRow).</summary>
    private void SkippedSection(IReadOnlyList<SkippedItem> skipped)
    {
        BodyPanel.Children.Add(Section("Not imported"));
        var list = new StackPanel { Spacing = 8 };
        for (var i = 0; i < skipped.Count; i++)
        {
            if (i > 0) list.Children.Add(new Rectangle { Style = PanelStyle("DividerStyle") });
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(new FontIcon
            {
                Glyph = "",
                Style = PanelStyle("CautionIconStyle"),
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 2, 0, 0),
            });
            var text = new StackPanel { Spacing = 2 };
            text.Children.Add(new TextBlock { Text = skipped[i].Label, TextWrapping = TextWrapping.Wrap });
            text.Children.Add(Caption(skipped[i].Reason));
            Grid.SetColumn(text, 1);
            row.Children.Add(text);
            list.Children.Add(row);
        }
        BodyPanel.Children.Add(new Border { Style = PanelStyle("CardStyle"), Child = list });
    }

    // Helpers.

    /// <summary>A caution icon, then <paramref name="text"/> wrapping.</summary>
    private Grid CautionLine(string text)
    {
        var line = new Grid { ColumnSpacing = 6 };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var icon = new FontIcon { Glyph = "", Style = PanelStyle("CautionIconStyle"), VerticalAlignment = VerticalAlignment.Top };
        icon.FontSize = 12;
        icon.Margin = new Thickness(0, 2, 0, 0);
        line.Children.Add(icon);
        var caption = Caption(text);
        Grid.SetColumn(caption, 1);
        line.Children.Add(caption);
        return line;
    }

    private static string ExecutableLabel(CustomActionType type) => type switch
    {
        CustomActionType.OpenUrl => "URL template",
        CustomActionType.RunShortcut => "Shortcut name",
        CustomActionType.AppleScript => "AppleScript",
        CustomActionType.ShellScript => "Shell script",
        _ => "Script",
    };

    private Style PanelStyle(string key) => (Style)Resources[key];

    private static Style AppStyle(string key) => (Style)Application.Current.Resources[key];

    private TextBlock Section(string title) => new() { Text = title, Style = PanelStyle("SectionHeaderStyle") };

    private TextBlock Caption(string text) => new() { Text = text, Style = PanelStyle("CaptionStyle") };

    private static FontFamily Monospace => new("Cascadia Mono, Consolas");

    private static Visibility Shown(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;
}
