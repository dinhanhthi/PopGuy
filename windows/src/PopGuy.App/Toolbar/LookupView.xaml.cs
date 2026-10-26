using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using PopGuy.Core.Actions;
using PopGuy.Core.Dictionaries;
using PopGuy.Core.Toolbar;
using Windows.UI;

namespace PopGuy.Toolbar;

/// <summary>
/// A lookup's result (macOS <c>DictionaryEntryView.swift</c>): the provider tabs (two or more results), "No definition
/// found", or the selected provider's entry, and Listen, which follows the speech state like the Speak button. The tab
/// choice is the view's own; <see cref="ListenRequested"/> carries the entry shown. A plain-text entry (Babylon) shows
/// its text. UNTRUSTED DATA: entry text goes into plain runs, never through a markup parser. UI thread only.
/// </summary>
public sealed partial class LookupView : UserControl
{
    private const string ListenGlyph = "";

    /// <summary>The Listen button's glyph while playing (the Stop button's glyph).</summary>
    private const string StopGlyph = "";

    private IReadOnlyList<DictionaryProviderResult> _results = [];
    private DictionaryProviderKind? _selected;
    private bool _closed;

    public LookupView()
    {
        InitializeComponent();
        ListenButton.Click += OnListenClick;
        ActualThemeChanged += OnThemeChanged;
    }

    /// <summary>Listen was clicked while an entry shows: the entry of the selected tab.</summary>
    public event Action<DictionaryEntry>? ListenRequested;

    private DictionaryEntry? SelectedEntry =>
        (_results.FirstOrDefault(r => r.ProviderKind == _selected) ?? _results.FirstOrDefault())?.Entry;

    /// <summary>
    /// Shows <paramref name="results"/> (rebuilt only when the snapshot changes; the tab stays on its provider if it is
    /// still there, else the first), or "No definition found".
    /// </summary>
    public void Show(IReadOnlyList<DictionaryProviderResult> results, bool notFound)
    {
        if (_closed) return;
        if (!ReferenceEquals(results, _results))
        {
            _results = results;
            if (!results.Any(r => r.ProviderKind == _selected)) _selected = results.FirstOrDefault()?.ProviderKind;
            BuildTabs();
            Render();
        }
        NotFoundText.Visibility = notFound ? Visibility.Visible : Visibility.Collapsed;
        var hasEntry = !notFound && SelectedEntry is not null;
        EntryPanel.Visibility = hasEntry ? Visibility.Visible : Visibility.Collapsed;
        ListenRow.Visibility = hasEntry ? Visibility.Visible : Visibility.Collapsed;
        ProviderTabs.Visibility = hasEntry && _results.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>
    /// Listen follows the speech (macOS footer): disabled with a spinner while loading, Stop while playing, else Listen,
    /// or "Listen again" once something played.
    /// </summary>
    public void SetSpeakState(SpeakPhase phase, bool canReplay)
    {
        if (_closed) return;
        var title = phase switch
        {
            SpeakPhase.Playing => "Stop",
            SpeakPhase.Idle when canReplay => "Listen again",
            _ => "Listen",
        };
        ListenIcon.Glyph = phase == SpeakPhase.Playing ? StopGlyph : ListenGlyph;
        ListenIcon.Visibility = phase == SpeakPhase.Loading ? Visibility.Collapsed : Visibility.Visible;
        ListenRing.IsActive = phase == SpeakPhase.Loading;
        ListenRing.Visibility = phase == SpeakPhase.Loading ? Visibility.Visible : Visibility.Collapsed;
        ListenButton.IsEnabled = phase != SpeakPhase.Loading;
        ListenLabel.Text = title;
        AutomationProperties.SetName(ListenButton, title);
    }

    /// <summary>Stops the view (its window closed).</summary>
    public void Detach()
    {
        if (_closed) return;
        _closed = true;
        ListenButton.Click -= OnListenClick;
        ActualThemeChanged -= OnThemeChanged;
        ClearTabs();
    }

    private void OnListenClick(object sender, RoutedEventArgs e)
    {
        if (!_closed && SelectedEntry is { } entry) ListenRequested?.Invoke(entry);
    }

    private void OnThemeChanged(FrameworkElement sender, object args)
    {
        if (!_closed) Render();
    }

    // Provider tabs (macOS dictionaryProviderTabs): the short names, in provider order.

    private void BuildTabs()
    {
        ClearTabs();
        foreach (var result in _results)
        {
            var tab = new ToggleButton
            {
                Content = result.ProviderKind.ShortName(),
                Tag = result.ProviderKind,
                AllowFocusOnInteraction = false,
                IsChecked = result.ProviderKind == _selected,
            };
            AutomationProperties.SetName(tab, result.ProviderKind.DisplayName());
            tab.Click += OnTabClick;
            ProviderTabs.Children.Add(tab);
        }
    }

    private void ClearTabs()
    {
        foreach (var child in ProviderTabs.Children)
            if (child is ToggleButton tab) tab.Click -= OnTabClick;
        ProviderTabs.Children.Clear();
    }

    private void OnTabClick(object sender, RoutedEventArgs e)
    {
        if (_closed || sender is not ToggleButton { Tag: DictionaryProviderKind kind }) return;
        _selected = kind;
        // A click toggles a ToggleButton by itself: the checked one is always the selection.
        foreach (var child in ProviderTabs.Children)
            if (child is ToggleButton { Tag: DictionaryProviderKind tabKind } tab) tab.IsChecked = tabKind == kind;
        Render();
    }

    // The entry.

    private void Render()
    {
        PronunciationBlock.Blocks.Clear();
        ContentBlock.Blocks.Clear();
        if (SelectedEntry is not { } entry)
        {
            HeadwordText.Text = "";
            SourceText.Text = "";
            return;
        }
        var dark = ActualTheme == ElementTheme.Dark;
        HeadwordText.Text = entry.Headword;
        SourceText.Text = entry.SourceName;
        RenderPronunciations(entry);
        if (entry.IsPlainTextOnly)
            ContentBlock.Blocks.Add(Lines(entry.RawText!.Split('\n'), Brush("TextFillColorPrimaryBrush")));
        else
            foreach (var (lexical, index) in entry.LexicalEntries.Select((l, i) => (l, i)))
                RenderLexical(lexical, first: index == 0, dark);
    }

    /// <summary>Each pronunciation's IPA and its first tag (macOS pronunciationChip), on one wrapping line.</summary>
    private void RenderPronunciations(DictionaryEntry entry)
    {
        var pronunciations = entry.LexicalEntries.SelectMany(l => l.Pronunciations).ToList();
        PronunciationBlock.Visibility = pronunciations.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (pronunciations.Count == 0) return;
        var paragraph = new Paragraph();
        foreach (var pronunciation in pronunciations)
        {
            if (paragraph.Inlines.Count > 0) paragraph.Inlines.Add(new Run { Text = "    " });
            paragraph.Inlines.Add(new Run { Text = pronunciation.Ipa, FontSize = 12, Foreground = Brush("AccentTextFillColorPrimaryBrush") });
            if (pronunciation.Tags.FirstOrDefault() is { Length: > 0 } tag)
                paragraph.Inlines.Add(new Run { Text = "  " + tag, FontSize = 11, Foreground = Brush("TextFillColorSecondaryBrush") });
        }
        PronunciationBlock.Blocks.Add(paragraph);
    }

    /// <summary>
    /// A part-of-speech group (macOS lexicalSection): its label, then each sense's definition, its examples (the source
    /// line coloured, the translation muted) and its synonyms.
    /// </summary>
    private void RenderLexical(LexicalEntry lexical, bool first, bool dark)
    {
        var groupTop = first ? 0 : 14;
        if (lexical.PartOfSpeech is { Length: > 0 } pos)
        {
            var label = new Paragraph { Margin = new Thickness(0, groupTop, 0, 0) };
            label.Inlines.Add(new Run
            {
                Text = pos,
                FontSize = 12,
                FontWeight = FontWeights.SemiBold,
                Foreground = new SolidColorBrush(dark ? Color.FromArgb(255, 140, 199, 245) : Color.FromArgb(255, 51, 133, 204)),
            });
            ContentBlock.Blocks.Add(label);
            groupTop = 8;
        }
        foreach (var sense in lexical.Senses)
        {
            if (sense.Definition.Length > 0)
            {
                var definition = new Paragraph { Margin = new Thickness(0, groupTop, 0, 0) };
                definition.Inlines.Add(new Run { Text = sense.Definition });
                ContentBlock.Blocks.Add(definition);
            }
            foreach (var example in sense.Examples)
                ContentBlock.Blocks.Add(Example(example, dark));
            if (sense.Synonyms.Count > 0)
            {
                var synonyms = new Paragraph { Margin = new Thickness(0, 4, 0, 0) };
                synonyms.Inlines.Add(new Run
                {
                    Text = "Synonyms: " + string.Join(", ", sense.Synonyms),
                    FontSize = 12,
                    Foreground = Brush("TextFillColorSecondaryBrush"),
                });
                ContentBlock.Blocks.Add(synonyms);
            }
            groupTop = 8;
        }
    }

    /// <summary>An example (macOS exampleBlock): the first line in the example colour, the others muted, indented.</summary>
    private Paragraph Example(string example, bool dark)
    {
        var lines = example.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
        var paragraph = new Paragraph { Margin = new Thickness(10, 4, 0, 0) };
        for (var i = 0; i < lines.Count; i++)
        {
            if (i > 0) paragraph.Inlines.Add(new LineBreak());
            paragraph.Inlines.Add(new Run
            {
                Text = lines[i],
                Foreground = i == 0
                    ? new SolidColorBrush(dark ? Color.FromArgb(255, 237, 143, 133) : Color.FromArgb(255, 179, 56, 46))
                    : Brush("TextFillColorSecondaryBrush"),
            });
        }
        return paragraph;
    }

    /// <summary>Plain text, one line per line (a Run's own line breaks are not kept everywhere).</summary>
    private static Paragraph Lines(IEnumerable<string> lines, Brush foreground)
    {
        var paragraph = new Paragraph();
        foreach (var line in lines)
        {
            if (paragraph.Inlines.Count > 0) paragraph.Inlines.Add(new LineBreak());
            paragraph.Inlines.Add(new Run { Text = line.TrimEnd('\r'), Foreground = foreground });
        }
        return paragraph;
    }

    private static Brush Brush(string key) => (Brush)Application.Current.Resources[key];
}
