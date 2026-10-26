using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.Library;
using PopGuy.Settings.ViewModels;

namespace PopGuy.Settings.Panels;

/// <summary>
/// The Action Library panel (macOS ActionLibraryView): one section per category with a card per preset (icon, title,
/// description, type badge, Install, and the script behind a chevron for a script preset). The search box filters by
/// title and description and hides the sections left empty. Install adds the preset through
/// <see cref="ActionsViewModel.InstallPreset"/>, and its card flips to Installed. The click opens the panel at once; the
/// sections are built once it is in the tree, each preset made once. Done, Esc or a click beside the panel close it. UI
/// thread only.
/// </summary>
public sealed partial class ActionLibraryPanel : UserControl
{
    /// <summary>The panel's minimum width (macOS ActionLibraryView minWidth).</summary>
    internal const double SheetMinWidth = 560;

    private const string CheckMark = "";
    private const string ChevronRight = "";
    private const string ChevronDown = "";

    private readonly List<(StackPanel Section, List<(Border Card, CustomAction Action)> Cards)> _sections = [];
    private ActionsViewModel _model = null!;

    public ActionLibraryPanel()
    {
        InitializeComponent();
        HeaderBar.Padding = SlideOverPanel.HeaderPadding;
        SearchBox.TextChanged += (_, _) => ApplyFilter();
        SearchBox.Loaded += (_, _) => AttachClearTooltip();
    }

    /// <summary>The search box takes the focus when the panel opens.</summary>
    internal UIElement InitialFocus => SearchBox;

    /// <summary>Sets the panel up. Once, before it shows; the sections follow once it is loaded.</summary>
    internal void Initialize(ActionsViewModel model, SlideOverPanel panel)
    {
        _model = model;
        DoneButton.Click += (_, _) => panel.Close();
        RoutedEventHandler? loaded = null;
        loaded = (_, _) =>
        {
            Loaded -= loaded;
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, BuildSections);
        };
        Loaded += loaded;
    }

    /// <summary>One section per category, its presets' cards in catalog order; a query typed meanwhile applies.</summary>
    private void BuildSections()
    {
        var installed = _model.Current.CustomActions;
        foreach (var category in ActionLibrary.Categories)
        {
            var section = new StackPanel { Spacing = 8 };
            section.Children.Add(new TextBlock { Text = category.DisplayName(), Style = PanelStyle("CategoryHeaderStyle") });
            var cards = new List<(Border, CustomAction)>();
            foreach (var preset in ActionLibrary.Presets(category))
            {
                var action = preset.Make();
                var card = Card(preset, action, ActionLibrary.IsInstalled(preset, installed));
                section.Children.Add(card);
                cards.Add((card, action));
            }
            if (cards.Count == 0) continue;
            BodyPanel.Children.Add(section);
            _sections.Add((section, cards));
        }
        ApplyFilter();
    }

    /// <summary>Shows the cards whose title or description holds the trimmed query (macOS filteredRows), and the sections that keep one.</summary>
    private void ApplyFilter()
    {
        var query = SearchBox.Text.Trim();
        foreach (var (section, cards) in _sections)
        {
            var any = false;
            foreach (var (card, action) in cards)
            {
                var shown = query.Length == 0
                    || action.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase)
                    || action.ActionDescription.Contains(query, StringComparison.CurrentCultureIgnoreCase);
                card.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
                any |= shown;
            }
            section.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    // Cards (macOS LibraryPresetRow).

    /// <summary>Icon, title and description, the type badge, Install or Installed, then the script chevron when there is one.</summary>
    private Border Card(LibraryPreset preset, CustomAction action, bool installed)
    {
        var header = new Grid { ColumnSpacing = 10 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var icon = new FontIcon { FontSize = 16, Width = 22, Style = PanelStyle("SecondaryIconStyle"), VerticalAlignment = VerticalAlignment.Center };
        CustomActionEditPanel.SetIcon(icon, action.Icon);
        header.Children.Add(icon);

        var titles = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(new TextBlock { Text = action.Title, TextWrapping = TextWrapping.Wrap });
        if (action.ActionDescription.Length > 0) titles.Children.Add(Caption(action.ActionDescription));
        Place(header, titles, 1);

        var badge = new Border { Style = PanelStyle("BadgeStyle"), Child = Caption(CustomActionEditPanel.TypeName(action.Type)) };
        Place(header, badge, 2);
        Place(header, InstallControl(preset, action.Title, installed), 3);

        var body = new StackPanel { Spacing = 12 };
        body.Children.Add(header);
        // Shell scripts and AppleScript only (macOS isScriptableWithBody): what runs is shown; a URL template reads from its title.
        if ((action.Type is CustomActionType.ShellScript or CustomActionType.AppleScript) && action.ScriptSource.Length > 0)
        {
            var script = Code(ScriptLabel(action.Type), action.ScriptSource);
            script.Visibility = Visibility.Collapsed;
            body.Children.Add(script);
            Place(header, Disclosure(script), 4);
        }
        return new Border { Style = PanelStyle("CardStyle"), Child = body };
    }

    /// <summary>
    /// Install (accent), or the Installed state: a disabled button with a checkmark. A click turns the button off at once,
    /// so a second click cannot add the preset twice; a failed install turns it back on and shows the error.
    /// </summary>
    private Button InstallControl(LibraryPreset preset, string title, bool installed)
    {
        var button = new Button { VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(button, $"Install {title}");
        if (installed)
        {
            ShowInstalled(button, title);
            return button;
        }
        button.Content = "Install";
        button.Style = AppStyle("AccentButtonStyle");
        button.Click += (_, _) =>
        {
            button.IsEnabled = false;
            if (_model.InstallPreset(preset))
            {
                SaveErrorText.Visibility = Visibility.Collapsed;
                ShowInstalled(button, title);
            }
            else
            {
                SaveErrorText.Visibility = Visibility.Visible;
                button.IsEnabled = true;
            }
        };
        return button;
    }

    private static void ShowInstalled(Button button, string title)
    {
        AutomationProperties.SetName(button, $"{title} installed");
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        content.Children.Add(new FontIcon { Glyph = CheckMark, FontSize = 12 });
        content.Children.Add(new TextBlock { Text = "Installed" });
        button.Style = AppStyle("DefaultButtonStyle");
        button.Content = content;
        button.IsEnabled = false;
    }

    /// <summary>The chevron that shows and hides <paramref name="script"/>, with its tooltip following.</summary>
    private static Button Disclosure(FrameworkElement script)
    {
        var glyph = new FontIcon { Glyph = ChevronRight, FontSize = 12 };
        var button = new Button { Content = glyph, Style = AppStyle("SubtleButtonStyle"), VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(button, "Show script");
        HoverTooltip.SetText(button, "Show script");
        button.Click += (_, _) =>
        {
            var expand = script.Visibility == Visibility.Collapsed;
            script.Visibility = expand ? Visibility.Visible : Visibility.Collapsed;
            glyph.Glyph = expand ? ChevronDown : ChevronRight;
            var label = expand ? "Hide script" : "Show script";
            AutomationProperties.SetName(button, label);
            HoverTooltip.SetText(button, label);
        };
        return button;
    }

    /// <summary><paramref name="text"/> under <paramref name="label"/>: monospace, selectable, its lines kept, scrolling past 160.</summary>
    private StackPanel Code(string label, string text)
    {
        var block = new TextBlock
        {
            Text = text,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 12,
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.NoWrap,
            Margin = new Thickness(8),
        };
        AutomationProperties.SetName(block, label);
        var scroller = new ScrollViewer
        {
            Content = block,
            MaxHeight = 160,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Enabled,
        };
        var panel = new StackPanel { Spacing = 4 };
        panel.Children.Add(Caption(label));
        panel.Children.Add(new Border { Style = PanelStyle("CodeStyle"), Child = scroller });
        return panel;
    }

    private static string ScriptLabel(CustomActionType type) =>
        type == CustomActionType.AppleScript ? "AppleScript" : "Shell script";

    // Helpers.

    private static void Place(Grid grid, FrameworkElement element, int column)
    {
        Grid.SetColumn(element, column);
        grid.Children.Add(element);
    }

    /// <summary>The search box's own clear button gets the fast tooltip once its template is applied (as on the Actions page).</summary>
    private void AttachClearTooltip()
    {
        if (FindNamed(SearchBox, "DeleteButton") is { } clear && HoverTooltip.GetText(clear) is null)
            HoverTooltip.SetText(clear, "Clear search");
    }

    private static FrameworkElement? FindNamed(DependencyObject parent, string name)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is FrameworkElement element && element.Name == name) return element;
            if (FindNamed(child, name) is { } found) return found;
        }
        return null;
    }

    private Style PanelStyle(string key) => (Style)Resources[key];

    private static Style AppStyle(string key) => (Style)Application.Current.Resources[key];

    private TextBlock Caption(string text) => new() { Text = text, Style = PanelStyle("CaptionStyle") };
}
