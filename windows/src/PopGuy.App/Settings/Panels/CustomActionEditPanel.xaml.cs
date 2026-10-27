using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.Icons;
using PopGuy.Core.Plugins;
using PopGuy.Core.Settings;
using PopGuy.Settings.Controls;
using PopGuy.Settings.ViewModels;

namespace PopGuy.Settings.Panels;

/// <summary>
/// The Add/Edit action panel (macOS CustomActionEditSheet, spec-3 §5.3.2): the type, the identity (on/off, locked while
/// it is the only active action; name, description, icon), then the cards of the type: AI system prompt, provider and
/// model; translation provider, model, target language, tone, additional prompt; speech engine, accent, speed, pitch;
/// dictionary provider and language; Open URL template; shell script (PowerShell); the macOS-only Shortcut and
/// AppleScript, offered only when the action already is one; and the visibility regex of the scriptable types. It edits
/// a draft: Save (enabled while <see cref="CustomAction.IsSaveable"/>) adds or updates the action through
/// <see cref="ActionsViewModel"/>, Cancel, Esc or a click beside the panel discard it. UI thread only.
/// </summary>
public sealed partial class CustomActionEditPanel : UserControl
{
    private const string TextToken = "{text}";
    private const string PromptCaption =
        "Use {{text}} for the selected text. Also available: {{app}}, {{date}}, {{language}}, {{domain}} (only when Ignored Domains is on).";
    private const string ActivateTooltip = "Turn this action on or off";
    private const string LockedTooltip =
        "Disabled because this is the only active action. The toolbar needs at least one. Turn on another action first.";

    /// <summary>The types Windows runs, in picker order; AppleScript and Shortcuts join only for an action that is one.</summary>
    private static readonly CustomActionType[] WindowsTypes =
    [
        CustomActionType.Ai, CustomActionType.Translation, CustomActionType.Speech, CustomActionType.Dictionary,
        CustomActionType.OpenUrl, CustomActionType.ShellScript,
    ];

    private static readonly SpeakEngineSelection[] Engines =
    [
        SpeakEngineSelection.System,
        SpeakEngineSelection.Cloud(TtsProviderKind.OpenAiTts),
        SpeakEngineSelection.Cloud(TtsProviderKind.GoogleCloudTts),
        SpeakEngineSelection.Cloud(TtsProviderKind.AzureTts),
    ];

    /// <summary>Each type row's refresh from the draft, in row order.</summary>
    private readonly List<Action> _updates = [];
    private readonly StackPanel _typeRows = new() { Spacing = 4 };
    private ActionsViewModel _model = null!;
    private SlideOverPanel _panel = null!;
    private CustomAction? _original;
    private CustomAction _draft = null!;
    private ModelField? _modelField;

    /// <summary>The controls are being set from the draft: their change events are not the user's.</summary>
    private bool _syncing;

    public CustomActionEditPanel()
    {
        InitializeComponent();
        HeaderBar.Padding = SlideOverPanel.HeaderPadding;
        CancelButton.Click += (_, _) => _panel.Close();
        SaveButton.Click += (_, _) => Save();
    }

    /// <summary>The Name box: it takes the focus when the panel opens.</summary>
    internal UIElement? InitialFocus { get; private set; }

    /// <summary>Builds the panel for <paramref name="action"/> (a new one when its id is not saved). Once, before it shows.</summary>
    internal void Initialize(ActionsViewModel model, CustomAction action, SlideOverPanel panel)
    {
        _model = model;
        _panel = panel;
        _original = model.Current.CustomActions.FirstOrDefault(a => a.Id == action.Id);
        _draft = action;
        TypeRow();
        IdentityRows();
        BodyPanel.Children.Add(_typeRows);
        BuildTypeRows();
        RefreshHeader();
    }

    private void Save()
    {
        if (!_draft.IsSaveable) return;
        // The model box saves on a timer: take what is typed now.
        _modelField?.Flush();
        if (!_model.SaveCustomAction(CustomActionEditing.ForSave(_original, _draft)))
        {
            SaveErrorText.Visibility = Visibility.Visible;
            return;
        }
        _panel.Close();
    }

    /// <summary>The draft changed: the type rows follow it, then the header.</summary>
    private void Changed(Func<CustomAction, CustomAction> change)
    {
        if (_syncing) return;
        _draft = change(_draft);
        _syncing = true;
        foreach (var update in _updates) update();
        _syncing = false;
        RefreshHeader();
    }

    private void RefreshHeader()
    {
        SetIcon(HeaderIcon, _draft.Icon);
        HeaderTitle.Text = _draft.Title.Length == 0 ? "New Action" : _draft.Title;
        SaveButton.IsEnabled = _draft.IsSaveable;
    }

    // Type and identity.

    private void TypeRow()
    {
        var types = Enum.GetValues<CustomActionType>().Where(t => WindowsTypes.Contains(t) || t == _draft.Type).ToList();
        var box = new ComboBox { MinWidth = 180 };
        AutomationProperties.SetName(box, "Type");
        foreach (var type in types) box.Items.Add(TypeName(type));
        box.SelectedIndex = types.IndexOf(_draft.Type);
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedIndex < 0 || types[box.SelectedIndex] == _draft.Type) return;
            _draft = CustomActionEditing.WithType(_draft, types[box.SelectedIndex]);
            BuildTypeRows();
            RefreshHeader();
        };
        BodyPanel.Children.Add(new SettingsCard { Header = "Type", Content = box, Margin = new Thickness(0, 20, 0, 0) });
    }

    private void IdentityRows()
    {
        BodyPanel.Children.Add(Section("Identity"));

        // Locked while this is the only active action; the transparent host keeps the tooltip while locked.
        var locked = ToolbarLayout.IsLastEnabledAction(_model.Current, ActionIdentifier.Custom(_draft.Id));
        var toggle = new ToggleSwitch { IsOn = _draft.IsEnabled, IsEnabled = !locked };
        AutomationProperties.SetName(toggle, "Activate");
        toggle.Toggled += (_, _) => Changed(a => a with { IsEnabled = toggle.IsOn });
        var host = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        host.Children.Add(toggle);
        HoverTooltip.SetText(host, locked ? LockedTooltip : ActivateTooltip);
        BodyPanel.Children.Add(new SettingsCard { Header = "Activate", Content = host });

        var name = TextField(_draft.Title, "e.g. Summarise", "Name");
        name.TextChanged += (_, _) => Changed(a => a with { Title = name.Text });
        InitialFocus = name;
        BodyPanel.Children.Add(new SettingsCard { Header = "Name", Content = name });

        var description = TextField(_draft.ActionDescription, "Optional — short description", "Description");
        description.TextChanged += (_, _) => Changed(a => a with { ActionDescription = description.Text });
        BodyPanel.Children.Add(new SettingsCard { Header = "Description", Content = description });

        // Collapsed by default (macOS): the current icon and Add open the picker in a flyout below.
        var icon = new FontIcon { FontSize = 16, VerticalAlignment = VerticalAlignment.Center };
        SetIcon(icon, _draft.Icon);
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        label.Children.Add(icon);
        label.Children.Add(new TextBlock { Text = "Add", VerticalAlignment = VerticalAlignment.Center });
        var picker = new IconPicker();
        picker.Initialize(_draft.Icon);
        picker.SelectionChanged += picked =>
        {
            Changed(a => a with { Icon = picked });
            SetIcon(icon, _draft.Icon);
        };
        var iconButton = new Button
        {
            Content = label,
            Flyout = new Flyout { Content = picker, Placement = FlyoutPlacementMode.Bottom },
        };
        AutomationProperties.SetName(iconButton, "Icon");
        BodyPanel.Children.Add(new SettingsCard { Header = "Icon", Content = iconButton });
    }

    // Rows by type (macOS aiFields, translationFields, speechFields, dictionaryFields, openURLFields, ...).

    private void BuildTypeRows()
    {
        _modelField?.Release();
        _modelField = null;
        _updates.Clear();
        _typeRows.Children.Clear();
        switch (_draft.Type)
        {
            case CustomActionType.Ai:
                AiRows();
                break;
            case CustomActionType.Translation:
                TranslationRows();
                break;
            case CustomActionType.Speech:
                SpeechRows();
                break;
            case CustomActionType.Dictionary:
                DictionaryRows();
                break;
            case CustomActionType.OpenUrl:
                OpenUrlRows();
                break;
            case CustomActionType.RunShortcut:
                RunShortcutRows();
                break;
            case CustomActionType.AppleScript:
                AppleScriptRows();
                break;
            default:
                ShellScriptRows();
                break;
        }
        if (_draft.IsScriptable) VisibilityRows();
        _syncing = true;
        foreach (var update in _updates) update();
        _syncing = false;
    }

    private void AiRows()
    {
        var prompt = MultiLine(_draft.SystemPrompt, "Required — system prompt for this action", "System Prompt", 100, monospace: false);
        prompt.TextChanged += (_, _) => Changed(a => a with { SystemPrompt = prompt.Text });
        AddRow(VerticalCard("System Prompt", prompt, Caption(PromptCaption)));
        AddRow(Section("Provider"));
        ProviderRow(ProviderKindExtensions.AllowedProviders(CustomActionType.Ai));
        ModelRow();
    }

    private void TranslationRows()
    {
        AddRow(Section("Provider"));
        ProviderRow(ProviderKindExtensions.AllowedProviders(CustomActionType.Translation));
        ModelRow();
        LanguageRow("Default Target Language", () => _draft.TargetLanguage, code => a => a with { TargetLanguage = code });

        // Tone: AI providers and DeepL (its formality); the additional prompt: AI providers only.
        var tones = Enum.GetValues<TranslateTone>();
        var toneBox = new ComboBox { MinWidth = 160 };
        AutomationProperties.SetName(toneBox, "Tone");
        // The enum names are the macOS display names.
        foreach (var tone in tones) toneBox.Items.Add(tone.ToString());
        toneBox.SelectionChanged += (_, _) =>
        {
            if (toneBox.SelectedIndex >= 0) Changed(a => a with { Tone = tones[toneBox.SelectedIndex] });
        };
        var toneCard = new SettingsCard { Header = "Tone", Content = toneBox };
        _updates.Add(() =>
        {
            toneCard.Visibility = Shown(_draft.ProviderKind.UsesModel() || _draft.ProviderKind == ProviderKind.DeepL);
            toneBox.SelectedIndex = Array.IndexOf(tones, _draft.Tone);
        });
        AddRow(toneCard);

        var extra = MultiLine(
            _draft.SystemPrompt, "Optional — extra instructions layered on top of translation", "Additional prompt", 64, monospace: false);
        extra.TextChanged += (_, _) => Changed(a => a with { SystemPrompt = extra.Text });
        var extraCard = VerticalCard("Additional prompt", extra, Caption("Added on top of the default translation prompt."));
        _updates.Add(() => extraCard.Visibility = Shown(_draft.ProviderKind.UsesModel()));
        AddRow(extraCard);
    }

    /// <summary>
    /// macOS DraftSpeechFields: the engine, accent, speed and pitch. The cloud model and voice pickers and Preview come
    /// with the Speak card (Phase 19); the action keeps any it has.
    /// </summary>
    private void SpeechRows()
    {
        AddRow(Section("Speech"));

        var engineBox = new ComboBox { MinWidth = 200 };
        AutomationProperties.SetName(engineBox, "Speech engine");
        foreach (var engine in Engines) engineBox.Items.Add(EngineName(engine));
        engineBox.SelectionChanged += (_, _) =>
        {
            if (engineBox.SelectedIndex >= 0)
                Changed(a => a with { SpeakSettings = a.SpeakSettings with { SelectedEngine = Engines[engineBox.SelectedIndex] } });
        };
        var cloudNote = Caption("Falls back to the System voice when the cloud key is missing or offline.");
        _updates.Add(() =>
        {
            engineBox.SelectedIndex = Array.IndexOf(Engines, _draft.SpeakSettings.SelectedEngine);
            cloudNote.Visibility = Shown(_draft.SpeakSettings.SelectedEngine.CloudProvider is not null);
        });
        AddRow(new SettingsCard { Header = "Speech engine", Description = cloudNote, Content = engineBox });

        var accents = Enum.GetValues<SpeakAccent>();
        var accentBox = new ComboBox { MinWidth = 160 };
        AutomationProperties.SetName(accentBox, "Default Accent");
        foreach (var accent in accents) accentBox.Items.Add(AccentName(accent));
        accentBox.SelectionChanged += (_, _) =>
        {
            if (accentBox.SelectedIndex < 0) return;
            var accent = accents[accentBox.SelectedIndex];
            // A voice belongs to its accent.
            Changed(a => a.SpeakSettings.DefaultAccent == accent
                ? a
                : a with { SpeakSettings = a.SpeakSettings with { DefaultAccent = accent, DefaultVoiceId = null } });
        };
        _updates.Add(() => accentBox.SelectedIndex = Array.IndexOf(accents, _draft.SpeakSettings.DefaultAccent));
        AddRow(new SettingsCard { Header = "Default Accent", Content = accentBox });

        LevelRow(
            "Speed",
            () => CustomActionEditing.LevelForRate(_draft.SpeakSettings.Rate),
            level => a => a with { SpeakSettings = a.SpeakSettings with { Rate = CustomActionEditing.RateForLevel(level) } },
            () => true,
            "How fast the system voice speaks.",
            "The selected engine doesn't support a speed override; speech plays at the provider's default rate.");
        LevelRow(
            "Pitch",
            () => CustomActionEditing.LevelForPitch(_draft.SpeakSettings.Pitch),
            level => a => a with { SpeakSettings = a.SpeakSettings with { Pitch = CustomActionEditing.PitchForLevel(level) } },
            // OpenAI's speech API has no pitch.
            () => _draft.SpeakSettings.SelectedEngine.CloudProvider != TtsProviderKind.OpenAiTts,
            "The system voice's pitch. 1.0 is its natural tone; higher sounds brighter, lower sounds deeper.",
            "The selected engine doesn't support a pitch override; speech plays at the provider's natural pitch.");
    }

    /// <summary>
    /// A custom Dictionary action looks up in one provider (the built-in Look up queries them all). The macOS Dictionary
    /// shows only for an action that has it. Its pronunciation settings come with the Dictionary card (Phase 19).
    /// </summary>
    private void DictionaryRows()
    {
        AddRow(Section("Dictionary"));
        var providers = Enum.GetValues<DictionaryProviderKind>()
            .Where(k => k != DictionaryProviderKind.MacOSBuiltin || k == _draft.DictionaryConfig.Provider)
            .ToList();
        var box = new ComboBox { MinWidth = 200 };
        AutomationProperties.SetName(box, "Provider");
        foreach (var provider in providers) box.Items.Add(DictionaryName(provider));
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedIndex >= 0)
                Changed(a => a with { DictionaryConfig = a.DictionaryConfig with { Provider = providers[box.SelectedIndex] } });
        };
        _updates.Add(() => box.SelectedIndex = providers.IndexOf(_draft.DictionaryConfig.Provider));
        AddRow(new SettingsCard { Header = "Provider", Content = box });
        LanguageRow(
            "Default target language",
            () => _draft.DictionaryConfig.DefinitionLanguage,
            code => a => a with { DictionaryConfig = a.DictionaryConfig with { DefinitionLanguage = code } });
    }

    private void OpenUrlRows()
    {
        var template = new TextBox
        {
            Text = _draft.ScriptSource,
            PlaceholderText = "https://www.google.com/search?q={text}",
            FontFamily = Monospace,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetName(template, "URL Template");
        template.TextChanged += (_, _) => Changed(a => a with { ScriptSource = template.Text });
        AddRow(VerticalCard(
            "URL Template",
            template,
            InsertTokenButton(template, "Append the {text} placeholder at the end of the URL"),
            Caption("{text} is replaced with the selected text, URL-encoded. Place it in the path or query, not the hostname.")));
        AfterRunRow();
    }

    private void RunShortcutRows()
    {
        AddRow(Section("Shortcut"));
        AddRow(CautionLine(PopClipAdapter.NotRunnableOnWindowsReason));
        var name = TextField(_draft.ScriptSource, "e.g. My Shortcut", "Shortcut name");
        name.TextChanged += (_, _) => Changed(a => a with { ScriptSource = name.Text });
        AddRow(new SettingsCard
        {
            Header = "Shortcut name",
            Description = Caption("The selected text is passed to the Shortcut on standard input."),
            Content = name,
        });
        AfterRunRow();
    }

    private void AppleScriptRows()
    {
        var editor = MultiLine(_draft.ScriptSource, "", "AppleScript", 120, monospace: true);
        editor.TextChanged += (_, _) => Changed(a => a with { ScriptSource = editor.Text });
        AddRow(VerticalCard(
            "AppleScript",
            CautionLine(PopClipAdapter.NotRunnableOnWindowsReason),
            CautionLine("Runs the AppleScript you write with your full user permissions. Only use scripts you trust."),
            editor,
            InsertTokenButton(editor, "Append the {text} placeholder — becomes a quoted AppleScript string at runtime"),
            Caption("{text} is replaced with the selected text as a quoted AppleScript string literal.")));
        AfterRunRow();
    }

    private void ShellScriptRows()
    {
        var editor = MultiLine(_draft.ScriptSource, "", "Shell Script", 120, monospace: true);
        editor.TextChanged += (_, _) => Changed(a => a with { ScriptSource = editor.Text });
        // An imported macOS script keeps its zsh origin until its source is changed here.
        var zshNote = CautionLine(PopClipAdapter.WrittenForZshReason);
        _updates.Add(() => zshNote.Visibility = Shown(CustomActionEditing.ForSave(_original, _draft).Shell is null));
        AddRow(VerticalCard(
            "Shell Script",
            CautionLine("Runs the shell script you write with your full user permissions. Only use scripts you trust."),
            zshNote,
            editor,
            Caption("The selection is available as $env:POPGUY_TEXT (and $env:POPGUY_FULL_TEXT). Runs in PowerShell.")));
        AfterRunRow();
    }

    private void VisibilityRows()
    {
        // Capped as the import sanitizer caps it.
        var regex = TextField(_draft.AppliesWhenRegex, "Leave empty to always show", "Show only when selection matches (regex)");
        regex.MaxLength = 500;
        regex.HorizontalAlignment = HorizontalAlignment.Stretch;
        regex.MaxWidth = double.PositiveInfinity;
        regex.TextChanged += (_, _) => Changed(a => a with { AppliesWhenRegex = regex.Text });
        AddRow(VerticalCard(
            "Visibility",
            new TextBlock { Text = "Show only when selection matches (regex)" },
            regex,
            Caption(@"Leave empty to always show. Example for file paths: ^([A-Za-z]:\\|\\\\).+")));
    }

    // Row builders.

    /// <summary>The provider picker; the CLI latency warning shows under its title (macOS latencyNote).</summary>
    private void ProviderRow(IReadOnlyList<ProviderKind> allowed)
    {
        var providers = allowed;
        var box = new ComboBox { MinWidth = 220 };
        AutomationProperties.SetName(box, "Provider");
        foreach (var provider in providers) box.Items.Add(provider.DisplayName());
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedIndex >= 0) Changed(a => a with { ProviderKind = providers[box.SelectedIndex] });
        };
        var warningText = new TextBlock { Style = PanelStyle("CaptionStyle") };
        var warning = IconLine(warningText);
        _updates.Add(() =>
        {
            box.SelectedIndex = IndexOf(providers, _draft.ProviderKind);
            var latency = _draft.ProviderKind.LatencyWarning();
            warningText.Text = latency ?? "";
            warning.Visibility = Shown(latency is not null);
        });
        AddRow(new SettingsCard { Header = "Provider", Description = warning, Content = box });
    }

    /// <summary>The model field with its hint on the (i); hidden for the translation services, which have no model.</summary>
    private void ModelRow()
    {
        var field = new ModelField();
        field.Attach(_model, PanelStyle);
        field.Committed += text => Changed(a => a with { Model = text });
        _modelField = field;
        var icon = new FontIcon { Glyph = "", Style = PanelStyle("SecondaryIconStyle") };
        icon.FontSize = 12;
        var hint = new Border
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Padding = new Thickness(2),
            VerticalAlignment = VerticalAlignment.Center,
            Child = icon,
        };
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        header.Children.Add(new TextBlock { Text = "Model", VerticalAlignment = VerticalAlignment.Center });
        header.Children.Add(hint);
        var card = new SettingsCard { Header = header, Content = field };
        _updates.Add(() =>
        {
            var kind = _draft.ProviderKind;
            card.Visibility = Shown(kind.UsesModel());
            HoverTooltip.SetText(hint, kind.ModelHint());
            field.Show(kind, _draft.Model);
        });
        AddRow(card);
    }

    private void LanguageRow(string title, Func<string> read, Func<string, Func<CustomAction, CustomAction>> write)
    {
        var languages = TargetLanguages.All;
        var box = new ComboBox { MinWidth = 200 };
        AutomationProperties.SetName(box, title);
        foreach (var language in languages) box.Items.Add(language.Name);
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedIndex >= 0) Changed(write(languages[box.SelectedIndex].Code));
        };
        _updates.Add(() =>
        {
            var code = read();
            var index = -1;
            for (var i = 0; i < languages.Count; i++)
            {
                if (languages[i].Code == code) index = i;
            }
            box.SelectedIndex = index;
        });
        AddRow(new SettingsCard { Header = title, Content = box });
    }

    /// <summary>What a scriptable action does with its output.</summary>
    private void AfterRunRow()
    {
        var behaviors = Enum.GetValues<AfterRunBehavior>();
        var box = new ComboBox { MinWidth = 160 };
        AutomationProperties.SetName(box, "After run");
        foreach (var behavior in behaviors) box.Items.Add(AfterRunName(behavior));
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedIndex >= 0) Changed(a => a with { AfterRun = behaviors[box.SelectedIndex] });
        };
        _updates.Add(() => box.SelectedIndex = Array.IndexOf(behaviors, _draft.AfterRun));
        AddRow(new SettingsCard { Header = "After run", Content = box });
    }

    /// <summary>A 1-10 slider with its "N / 10" value; disabled, with the other caption, when the engine ignores it.</summary>
    private void LevelRow(
        string title, Func<int> read, Func<int, Func<CustomAction, CustomAction>> write, Func<bool> supported,
        string caption, string unsupportedCaption)
    {
        // No thumb tooltip: the app shows HoverTooltip only.
        var slider = new Slider
        {
            Minimum = 1,
            Maximum = 10,
            StepFrequency = 1,
            SnapsTo = SliderSnapsTo.StepValues,
            IsThumbToolTipEnabled = false,
            Width = 200,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(slider, title);
        var value = new TextBlock { Style = PanelStyle("SecondaryTextStyle"), VerticalAlignment = VerticalAlignment.Center, MinWidth = 44 };
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        content.Children.Add(slider);
        content.Children.Add(value);
        var description = Caption(caption);
        slider.ValueChanged += (_, e) =>
        {
            var level = (int)Math.Round(e.NewValue);
            value.Text = $"{level} / 10";
            Changed(write(level));
        };
        _updates.Add(() =>
        {
            var level = read();
            slider.Value = level;
            value.Text = $"{level} / 10";
            var on = supported();
            slider.IsEnabled = on;
            description.Text = on ? caption : unsupportedCaption;
        });
        AddRow(new SettingsCard { Header = title, Description = description, Content = content });
    }

    /// <summary>"Insert {text}": appends the placeholder to <paramref name="box"/>.</summary>
    private static Button InsertTokenButton(TextBox box, string tooltip)
    {
        var button = new Button { Content = $"Insert {TextToken}" };
        HoverTooltip.SetText(button, tooltip);
        button.Click += (_, _) =>
        {
            box.Text += TextToken;
            box.SelectionStart = box.Text.Length;
        };
        return button;
    }

    // Helpers.

    private void AddRow(UIElement row) => _typeRows.Children.Add(row);

    private Style PanelStyle(string key) => (Style)Resources[key];

    private TextBlock Section(string title) => new() { Text = title, Style = PanelStyle("SectionHeaderStyle") };

    private TextBlock Caption(string text) => new() { Text = text, Style = PanelStyle("CaptionStyle") };

    /// <summary>A card whose content sits under its header, full width.</summary>
    private static SettingsCard VerticalCard(string title, params UIElement[] children)
    {
        var body = new StackPanel { Spacing = 8 };
        foreach (var child in children) body.Children.Add(child);
        return new SettingsCard
        {
            Header = title,
            ContentAlignment = ContentAlignment.Vertical,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = body,
        };
    }

    private static TextBox TextField(string text, string placeholder, string name)
    {
        var box = new TextBox { Text = text, PlaceholderText = placeholder, MinWidth = 280, MaxWidth = 420 };
        AutomationProperties.SetName(box, name);
        return box;
    }

    private static TextBox MultiLine(string text, string placeholder, string name, double minHeight, bool monospace)
    {
        var box = new TextBox
        {
            Text = text,
            PlaceholderText = placeholder,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = minHeight,
            MaxHeight = 320,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        if (monospace) box.FontFamily = Monospace;
        ScrollViewer.SetVerticalScrollBarVisibility(box, ScrollBarVisibility.Auto);
        AutomationProperties.SetName(box, name);
        return box;
    }

    private static FontFamily Monospace => new("Cascadia Mono, Consolas");

    /// <summary>A caution icon, then <paramref name="text"/> wrapping.</summary>
    private Grid CautionLine(string text)
    {
        var line = IconLine(new TextBlock { Text = text, Style = PanelStyle("CaptionStyle") });
        line.Visibility = Visibility.Visible;
        return line;
    }

    /// <summary>A caution icon, then <paramref name="text"/> taking the rest of the line and wrapping. Collapsed.</summary>
    private Grid IconLine(TextBlock text)
    {
        var line = new Grid { ColumnSpacing = 6, Visibility = Visibility.Collapsed };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var icon = new FontIcon { Glyph = "", Style = PanelStyle("CautionIconStyle"), VerticalAlignment = VerticalAlignment.Top };
        icon.FontSize = 12;
        icon.Margin = new Thickness(0, 2, 0, 0);
        line.Children.Add(icon);
        Grid.SetColumn(text, 1);
        line.Children.Add(text);
        return line;
    }

    internal static void SetIcon(FontIcon target, ActionIcon icon)
    {
        if (icon.Type == ActionIconType.Emoji)
        {
            target.FontFamily = new FontFamily("Segoe UI Emoji");
            target.Glyph = icon.Value;
        }
        else
        {
            target.FontFamily = IconPicker.SymbolFont;
            target.Glyph = SymbolMap.Glyph(icon.Value);
        }
    }

    private static Visibility Shown(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    private static int IndexOf(IReadOnlyList<ProviderKind> list, ProviderKind kind)
    {
        for (var i = 0; i < list.Count; i++)
        {
            if (list[i] == kind) return i;
        }
        return -1;
    }

    // Display names (macOS displayName).

    internal static string TypeName(CustomActionType type) => type switch
    {
        CustomActionType.Ai => "AI",
        CustomActionType.Translation => "Translation",
        CustomActionType.Speech => "Speech",
        CustomActionType.Dictionary => "Dictionary",
        CustomActionType.OpenUrl => "Open URL",
        CustomActionType.RunShortcut => "Run Shortcut (macOS)",
        CustomActionType.AppleScript => "AppleScript (macOS)",
        _ => "Shell Script",
    };

    internal static string AfterRunName(AfterRunBehavior behavior) => behavior switch
    {
        AfterRunBehavior.CloseToolbar => "Close toolbar",
        AfterRunBehavior.None => "Do nothing",
        AfterRunBehavior.CopyResult => "Copy result",
        AfterRunBehavior.PasteResult => "Paste result",
        _ => "Show result",
    };

    private static string EngineName(SpeakEngineSelection engine) => engine.CloudProvider switch
    {
        null => "System voice",
        TtsProviderKind.OpenAiTts => "OpenAI",
        TtsProviderKind.GoogleCloudTts => "Google Cloud TTS",
        _ => "Azure Speech",
    };

    private static string AccentName(SpeakAccent accent) => accent switch
    {
        SpeakAccent.UsEnglish => "US English",
        SpeakAccent.UkEnglish => "UK English",
        SpeakAccent.French => "French",
        SpeakAccent.Spanish => "Spanish",
        _ => "German",
    };

    private static string DictionaryName(DictionaryProviderKind kind) => kind switch
    {
        DictionaryProviderKind.MacOSBuiltin => "macOS Dictionary",
        DictionaryProviderKind.Minhqnd => "minhqnd",
        DictionaryProviderKind.FreeDictionaryApi => "Free Dictionary API",
        _ => "Babylon (BGL)",
    };
}
