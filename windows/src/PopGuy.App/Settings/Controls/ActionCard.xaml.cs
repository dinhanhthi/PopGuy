using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.Icons;
using PopGuy.Core.Settings;
using PopGuy.Settings.ViewModels;

namespace PopGuy.Settings.Controls;

/// <summary>
/// One action's card on Settings → Actions (macOS ActionsView.swift: ActionCard and the card(for:) builders). The
/// header: icon, title, Built-in or From plugin badge, description, a custom action's Edit and Delete (after a
/// confirmation; locked like Activate), and the switches Activate, locked (the reason on hover) while the action is the
/// only enabled one, In More actions, and Show label, locked while the action is in More
/// actions (its value is kept). The rows by kind: Improve and Shorten provider, model, tone, prompt; Proofread
/// the same without tone; Prompt provider and model; Translate provider, model, target language, tone, additional
/// prompt; a custom AI action provider, model, its required prompt; a custom translation action as Translate; Speak
/// and a custom Speech action the <see cref="SpeakCard"/> rows (macOS SpeakCardView, CustomSpeechFields); Look up and
/// a custom Dictionary action the <see cref="DictionaryCard"/> rows (macOS DictionaryCardView, DictionaryConfigFields). Model,
/// tone and prompt hide for the providers that ignore them. Every kind ends with its keyboard shortcut. Each change
/// saves at once through <see cref="ActionsViewModel"/> (text 500 ms after the last keystroke, or when the box loses
/// focus). ActionsPage builds a card once per action and calls <see cref="Update"/> on every settings change, so an
/// edit, a recording and the expansion survive it. UI thread only.
/// </summary>
public sealed partial class ActionCard : UserControl
{
    private const string ActivateTooltip = "Turn this action on or off";
    private const string LockedTooltip =
        "Disabled because this is the only active action. The toolbar needs at least one. Turn on another action first.";
    private const string InMoreTooltip = "Show this action in the More actions menu instead of on the toolbar";
    private const string ShowLabelTooltip = "Show the action's name next to its icon on the toolbar";
    private const string ShowLabelLockedTooltip =
        "Disabled because this action is in More actions, which always shows action names. Turn off In More actions to use it.";
    private const string PromptCaption =
        "Use {{text}} for the selected text. Also available: {{app}}, {{date}}, {{language}}, {{domain}} (only when Ignored Domains is on).";
    private const string TranslatePromptCaption = "Added on top of the default translation prompt.";
    private const string DeleteLockedTooltip =
        "Can't delete the only active action. The toolbar needs at least one. Turn on another action first.";
    private const string SpeakSubtitle = "Read the selected text aloud using the system speech synthesiser.";
    private const string LookupSubtitle = "Look up definitions, phonetics, and examples across every dictionary provider.";

    /// <summary>Each row's refresh from the settings, in row order.</summary>
    private readonly List<Action<AppSettings>> _updates = [];
    private readonly List<PromptField> _prompts = [];
    private readonly List<ModelField> _modelFields = [];
    private ActionsViewModel _model = null!;
    private SpeakCard? _speak;
    private DictionaryCard? _dictionary;

    private TextBlock _noShortcut = null!;
    private Button _recordButton = null!;
    private Button _clearButton = null!;
    private TextBlock _shortcutStatus = null!;

    /// <summary>The controls are being set from the settings: their change events are not the user's.</summary>
    private bool _syncing;

    public ActionCard()
    {
        InitializeComponent();
        EnabledToggle.Toggled += (_, _) =>
            Save("enabled", s => ToolbarLayout.WithEnabled(s, Id, EnabledToggle.IsOn));
        InMoreToggle.Toggled += (_, _) =>
            Save("principalActionIDs", s => ToolbarLayout.WithPrincipal(s, Id, !InMoreToggle.IsOn));
        ShowLabelToggle.Toggled += (_, _) =>
            Save("labeledActionIDs", s => ToolbarLayout.WithLabeled(s, Id, ShowLabelToggle.IsOn));
        HoverTooltip.SetText(InMoreHost, InMoreTooltip);
        EditButton.Click += (_, _) => EditRequested?.Invoke(Id);
        HoverTooltip.SetText(EditButton, "Edit");
        DeleteButton.Click += async (_, _) => await ConfirmDeleteAsync();
    }

    internal ActionIdentifier Id { get; private set; } = ActionIdentifier.Speak;

    /// <summary>The shortcut row's recorder: the page keeps PopGuy's hotkeys off while it records.</summary>
    internal ShortcutRecorder Recorder { get; } = new() { VerticalAlignment = VerticalAlignment.Center };

    /// <summary>The recorder started listening.</summary>
    internal event Action? RecordingStarted;

    /// <summary>The recorder stopped, after the recorded (or cleared) shortcut was saved.</summary>
    internal event Action? RecordingEnded;

    /// <summary>A custom action's Edit: the page opens the Add/Edit panel.</summary>
    internal event Action<ActionIdentifier>? EditRequested;

    /// <summary>
    /// What the card is built from: a card whose signature changed is built again (a custom action's type, title, icon,
    /// description or plugin origin). Compared with Equals.
    /// </summary>
    internal static object Signature(AppSettings settings, ActionIdentifier id) =>
        ActionsViewModel.Custom(settings, id) is { } a ? (a.Type, a.Title, a.Icon, a.ActionDescription, a.IsFromPlugin) : id;

    /// <summary>Builds the header and the rows of <paramref name="id"/>'s kind. Once, before the card is shown.</summary>
    internal void Initialize(ActionsViewModel model, ActionIdentifier id)
    {
        _model = model;
        Id = id;
        var current = model.Current;
        if (id.BuiltinKind is { } kind)
        {
            var info = ActionsViewModel.Builtin(kind);
            SetHeader(info.Title, ActionIcon.SfSymbol(info.Symbol), info.Subtitle, builtin: true, fromPlugin: false);
            if (kind == ActionKind.Translate) TranslateRows();
            else AiRows(kind);
        }
        else if (ActionsViewModel.Custom(current, id) is { } action)
        {
            SetHeader(ActionsViewModel.Title(current, id), action.Icon, action.ActionDescription, builtin: false, action.IsFromPlugin);
            CustomButtons.Visibility = Visibility.Visible;
            if (action.Type == CustomActionType.Ai) CustomAiRows();
            else if (action.Type == CustomActionType.Translation) CustomTranslationRows();
            else if (action.Type == CustomActionType.Speech) SpeakRows();
            else if (action.Type == CustomActionType.Dictionary) DictionaryRows();
        }
        else if (id.Type == ActionIdentifierType.Speak)
        {
            SetHeader("Speak", ActionIcon.SfSymbol("speaker.wave.2"), SpeakSubtitle, builtin: true, fromPlugin: false);
            SpeakRows();
        }
        else if (id.Type == ActionIdentifierType.Dictionary)
        {
            SetHeader("Look up", ActionIcon.SfSymbol("character.book.closed"), LookupSubtitle, builtin: true, fromPlugin: false);
            DictionaryRows();
        }
        ShortcutRow();
        Update(current);
    }

    /// <summary>Every control shows <paramref name="current"/>, except a text box being edited.</summary>
    internal void Update(AppSettings current)
    {
        _syncing = true;
        EnabledToggle.IsOn = ToolbarLayout.IsEnabled(current, Id);
        var locked = ToolbarLayout.IsLastEnabledAction(current, Id);
        EnabledToggle.IsEnabled = !locked;
        HoverTooltip.SetText(EnabledHost, locked ? LockedTooltip : ActivateTooltip);
        DeleteButton.IsEnabled = !locked;
        DeleteButton.Opacity = locked ? 0.35 : 1;
        HoverTooltip.SetText(DeleteHost, locked ? DeleteLockedTooltip : "Delete");
        var principal = ToolbarLayout.IsPrincipal(current, Id);
        InMoreToggle.IsOn = !principal;
        // Kept while in More actions, which always shows names: locked, not cleared (macOS).
        ShowLabelToggle.IsOn = ToolbarLayout.IsLabeled(current, Id);
        ShowLabelToggle.IsEnabled = principal;
        HoverTooltip.SetText(ShowLabelHost, principal ? ShowLabelTooltip : ShowLabelLockedTooltip);
        foreach (var update in _updates) update(current);
        _syncing = false;
    }

    /// <summary>The shortcut row's registration problem, or null.</summary>
    internal void ShowShortcutStatus(string? message)
    {
        _shortcutStatus.Text = message ?? "";
        _shortcutStatus.Visibility = Shown(message is not null);
    }

    /// <summary>Saves the text being edited now (the page goes).</summary>
    internal void Flush()
    {
        foreach (var field in _modelFields) field.Flush();
        foreach (var prompt in _prompts) prompt.Flush();
        _speak?.Flush();
        _dictionary?.Flush();
    }

    /// <summary>The card goes: pending text is saved, a check and a recording stop.</summary>
    internal void Release()
    {
        foreach (var field in _modelFields) field.Release();
        foreach (var prompt in _prompts) prompt.Flush();
        _speak?.Release();
        _dictionary?.Release();
        Recorder.Cancel();
    }

    private void SetHeader(string title, ActionIcon icon, string subtitle, bool builtin, bool fromPlugin)
    {
        TitleText.Text = title;
        AutomationProperties.SetName(Expander, title);
        Expander.HeaderIcon = icon.Type == ActionIconType.Emoji
            ? new FontIcon { FontFamily = new FontFamily("Segoe UI Emoji"), Glyph = icon.Value }
            : new FontIcon { Glyph = SymbolMap.Glyph(icon.Value) };
        if (subtitle.Length > 0) Expander.Description = subtitle;
        BuiltinBadge.Visibility = Shown(builtin);
        PluginBadge.Visibility = Shown(!builtin && fromPlugin);
    }

    /// <summary>Delete after a confirmation (macOS: "Delete this action?"); the page drops the card on the settings change.</summary>
    private async Task ConfirmDeleteAsync()
    {
        if (XamlRoot is null || Id.CustomId is not { } customId) return;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Style = AppStyle("DefaultContentDialogStyle"),
            Title = "Delete this action?",
            Content = new TextBlock { Text = "This custom action will be permanently removed.", TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        try
        {
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            // Another dialog is open.
            return;
        }
        _model.DeleteCustomAction(customId);
    }

    // Rows by kind (macOS aiActionCard, translateCard, customActionCard).

    private void AiRows(ActionKind kind)
    {
        ProviderRow(
            ProviderKindExtensions.AllowedProviders(kind),
            s => ActionsViewModel.Config(s, kind).ProviderKind,
            (s, provider) => ActionsViewModel.WithConfig(s, kind, c => c with { ProviderKind = provider }));
        ModelRow(
            s => ActionsViewModel.Config(s, kind).ProviderKind,
            s => ActionsViewModel.Config(s, kind).Model,
            (s, model) => ActionsViewModel.WithConfig(s, kind, c => c with { Model = model }));
        // Proofread keeps the author's tone; Prompt's one-off prompt says it all.
        if (kind is ActionKind.Improve or ActionKind.Shorten)
        {
            ToneRow(
                _ => true,
                s => ActionsViewModel.Config(s, kind).Tone ?? TranslateTone.Neutral,
                (s, tone) => ActionsViewModel.WithConfig(s, kind, c => c with { Tone = tone }));
        }
        if (kind != ActionKind.Prompt)
        {
            PromptRow(
                new PromptField(this, "Prompt", null, "Custom prompt", PromptCaption, allowsPredefined: true),
                _ => true,
                s => ActionsViewModel.Config(s, kind).CustomPrompt ?? "",
                (s, text) => ActionsViewModel.WithConfig(s, kind, c => c with { CustomPrompt = text.Length == 0 ? null : text }));
        }
    }

    private void TranslateRows()
    {
        const ActionKind kind = ActionKind.Translate;
        static ProviderKind Provider(AppSettings s) => s.TranslateConfig.ProviderKind;
        ProviderRow(
            ProviderKindExtensions.AllowedProviders(kind),
            Provider,
            (s, provider) => s with { TranslateConfig = s.TranslateConfig with { ProviderKind = provider } });
        ModelRow(Provider, s => s.TranslateConfig.Model, (s, model) => s with { TranslateConfig = s.TranslateConfig with { Model = model } });
        LanguageRow(s => s.DefaultTargetLanguage, (s, code) => s with { DefaultTargetLanguage = code });
        // DeepL maps the tone to its formality; Google Translate has no register control.
        ToneRow(
            s => Provider(s).UsesModel() || Provider(s) == ProviderKind.DeepL,
            s => s.TranslateConfig.Tone ?? TranslateTone.Neutral,
            (s, tone) => s with { TranslateConfig = s.TranslateConfig with { Tone = tone } });
        // The translation services ignore any prompt.
        PromptRow(
            new PromptField(
                this, "Additional prompt",
                "Extra instructions applied on top of translating to your chosen language and tone. The selected language and tone keep priority, but a conflicting instruction here may still influence the result.",
                "Custom prompt", TranslatePromptCaption, allowsPredefined: true),
            s => Provider(s).UsesModel(),
            s => s.TranslateConfig.CustomPrompt ?? "",
            (s, text) => s with { TranslateConfig = s.TranslateConfig with { CustomPrompt = text.Length == 0 ? null : text } });
    }

    private void CustomAiRows()
    {
        ProviderRow(
            ProviderKindExtensions.AllowedProviders(CustomActionType.Ai),
            CustomProvider,
            (s, provider) => ActionsViewModel.WithCustom(s, Id, a => a with { ProviderKind = provider }));
        ModelRow(CustomProvider, s => CustomOf(s)?.Model ?? "", (s, model) => ActionsViewModel.WithCustom(s, Id, a => a with { Model = model }));
        // Required: an empty prompt is never saved (the saved one shows again).
        PromptRow(
            new PromptField(this, "Prompt", null, "Required — system prompt for this action", PromptCaption, allowsPredefined: false),
            _ => true,
            s => CustomOf(s)?.SystemPrompt ?? "",
            (s, text) => text.Trim().Length == 0 ? s : ActionsViewModel.WithCustom(s, Id, a => a with { SystemPrompt = text }));
    }

    private void CustomTranslationRows()
    {
        ProviderRow(
            ProviderKindExtensions.AllowedProviders(CustomActionType.Translation),
            CustomProvider,
            (s, provider) => ActionsViewModel.WithCustom(s, Id, a => a with { ProviderKind = provider }));
        ModelRow(CustomProvider, s => CustomOf(s)?.Model ?? "", (s, model) => ActionsViewModel.WithCustom(s, Id, a => a with { Model = model }));
        LanguageRow(
            s => CustomOf(s)?.TargetLanguage ?? "en",
            (s, code) => ActionsViewModel.WithCustom(s, Id, a => a with { TargetLanguage = code }));
        ToneRow(
            s => CustomProvider(s).UsesModel() || CustomProvider(s) == ProviderKind.DeepL,
            s => CustomOf(s)?.Tone ?? TranslateTone.Neutral,
            (s, tone) => ActionsViewModel.WithCustom(s, Id, a => a with { Tone = tone }));
        PromptRow(
            new PromptField(
                this, "Additional prompt", "Extra instructions applied on top of translating to your chosen language and tone.",
                "Custom prompt", TranslatePromptCaption, allowsPredefined: true),
            s => CustomProvider(s).UsesModel(),
            s => CustomOf(s)?.SystemPrompt ?? "",
            (s, text) => ActionsViewModel.WithCustom(s, Id, a => a with { SystemPrompt = text }));
    }

    /// <summary>The engine, voices, accent, speed, pitch and Preview rows, taken from a <see cref="SpeakCard"/>.</summary>
    private void SpeakRows()
    {
        _speak = new SpeakCard();
        _speak.Initialize(_model, Id);
        foreach (var row in _speak.TakeRows()) AddRow(row);
        _updates.Add(_speak.Update);
    }

    /// <summary>The definition language and pronunciation rows (and Look up's Babylon files), taken from a <see cref="DictionaryCard"/>.</summary>
    private void DictionaryRows()
    {
        _dictionary = new DictionaryCard();
        _dictionary.Initialize(_model, Id);
        foreach (var row in _dictionary.TakeRows()) AddRow(row);
        _updates.Add(_dictionary.Update);
    }

    private CustomAction? CustomOf(AppSettings settings) => ActionsViewModel.Custom(settings, Id);

    private ProviderKind CustomProvider(AppSettings settings) => CustomOf(settings)?.ProviderKind ?? ProviderKind.Anthropic;

    // Row builders.

    /// <summary>The provider picker; the CLI latency warning shows under its title (macOS latencyNote).</summary>
    private void ProviderRow(
        IReadOnlyList<ProviderKind> allowed, Func<AppSettings, ProviderKind> read, Func<AppSettings, ProviderKind, AppSettings> write)
    {
        var box = new ComboBox { MinWidth = 220 };
        AutomationProperties.SetName(box, "Provider");
        var warningText = new TextBlock { Style = CardStyle("CaptionStyle") };
        var warning = IconLine("\uE7BA", "CautionIconStyle", warningText);
        IReadOnlyList<ProviderKind> shown = [];
        box.SelectionChanged += (_, _) =>
        {
            if (_syncing || box.SelectedIndex < 0 || box.SelectedIndex >= shown.Count) return;
            var provider = shown[box.SelectedIndex];
            Save("provider", s => write(s, provider));
        };
        _updates.Add(s =>
        {
            var current = read(s);
            var providers = ActionsViewModel.PickerProviders(allowed, current);
            if (!providers.SequenceEqual(shown))
            {
                shown = providers;
                box.Items.Clear();
                foreach (var provider in providers) box.Items.Add(provider.DisplayName());
            }
            box.SelectedIndex = IndexOf(shown, current);
            var latency = current.LatencyWarning();
            warningText.Text = latency ?? "";
            warning.Visibility = Shown(latency is not null);
        });
        AddRow(new SettingsCard { Header = "Provider", Description = warning, Content = box });
    }

    /// <summary>The model field with its hint on the (i); hidden for the translation services, which have no model.</summary>
    private void ModelRow(
        Func<AppSettings, ProviderKind> provider, Func<AppSettings, string> read, Func<AppSettings, string, AppSettings> write)
    {
        var field = new ModelField();
        field.Attach(_model, CardStyle);
        field.Committed += text =>
        {
            if (read(_model.Current) != text) Save("model", s => write(s, text));
        };
        _modelFields.Add(field);
        var hint = InfoIcon();
        var card = new SettingsCard { Header = Labeled("Model", hint), Content = field };
        _updates.Add(s =>
        {
            var kind = provider(s);
            card.Visibility = Shown(kind.UsesModel());
            HoverTooltip.SetText(hint, kind.ModelHint());
            field.Show(kind, read(s));
        });
        AddRow(card);
    }

    private void ToneRow(
        Func<AppSettings, bool> visible, Func<AppSettings, TranslateTone> read, Func<AppSettings, TranslateTone, AppSettings> write)
    {
        var tones = Enum.GetValues<TranslateTone>();
        var box = new ComboBox { MinWidth = 160 };
        AutomationProperties.SetName(box, "Tone");
        // The enum names are the macOS display names.
        foreach (var tone in tones) box.Items.Add(tone.ToString());
        box.SelectionChanged += (_, _) =>
        {
            if (_syncing || box.SelectedIndex < 0) return;
            var tone = tones[box.SelectedIndex];
            Save("tone", s => write(s, tone));
        };
        var card = new SettingsCard { Header = "Tone", Content = box };
        _updates.Add(s =>
        {
            card.Visibility = Shown(visible(s));
            box.SelectedIndex = Array.IndexOf(tones, read(s));
        });
        AddRow(card);
    }

    private void LanguageRow(Func<AppSettings, string> read, Func<AppSettings, string, AppSettings> write)
    {
        var languages = TargetLanguages.All;
        var box = new ComboBox { MinWidth = 200 };
        AutomationProperties.SetName(box, "Default Target Language");
        foreach (var language in languages) box.Items.Add(language.Name);
        box.SelectionChanged += (_, _) =>
        {
            if (_syncing || box.SelectedIndex < 0) return;
            var code = languages[box.SelectedIndex].Code;
            Save("targetLanguage", s => write(s, code));
        };
        _updates.Add(s =>
        {
            var code = read(s);
            var index = -1;
            for (var i = 0; i < languages.Count; i++)
            {
                if (languages[i].Code == code) index = i;
            }
            box.SelectedIndex = index;
        });
        AddRow(new SettingsCard { Header = "Default Target Language", Content = box });
    }

    private void PromptRow(
        PromptField field, Func<AppSettings, bool> visible, Func<AppSettings, string> read, Func<AppSettings, string, AppSettings> write)
    {
        field.Committed += text =>
        {
            if (read(_model.Current) != text) Save("prompt", s => write(s, text));
        };
        _prompts.Add(field);
        _updates.Add(s =>
        {
            field.Root.Visibility = Shown(visible(s));
            field.Show(read(s));
        });
        AddRow(field.Root);
    }

    /// <summary>
    /// The shortcut badge, "None" without one, then Remove and Record (macOS ShortcutRecorderRow); a registration problem
    /// shows under the title. One recorder records at a time (the recorder's own rule).
    /// </summary>
    private void ShortcutRow()
    {
        _noShortcut = new TextBlock { Text = "None", Style = CardStyle("SecondaryTextStyle"), VerticalAlignment = VerticalAlignment.Center };
        _clearButton = IconButton("\uE894", "Remove shortcut");
        _recordButton = IconButton("\uE7C8", "Record shortcut");
        _shortcutStatus = new TextBlock { Style = CardStyle("ErrorTextStyle"), Visibility = Visibility.Collapsed };
        AutomationProperties.SetName(Recorder, "Keyboard shortcut");

        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        content.Children.Add(_noShortcut);
        content.Children.Add(Recorder);
        content.Children.Add(_clearButton);
        content.Children.Add(_recordButton);

        _recordButton.Click += (_, _) => Recorder.Start();
        _clearButton.Click += (_, _) => SaveShortcut(null);
        Recorder.RecordingStarted += () =>
        {
            RefreshShortcutButtons();
            ShowShortcutStatus(null);
            RecordingStarted?.Invoke();
        };
        Recorder.RecordingEnded += (outcome, recorded) =>
        {
            if (outcome == ShortcutKeyOutcome.Record) SaveShortcut(recorded);
            else if (outcome == ShortcutKeyOutcome.Clear) SaveShortcut(null);
            RefreshShortcutButtons();
            RecordingEnded?.Invoke();
        };
        _updates.Add(s =>
        {
            if (!Recorder.IsRecording) Recorder.Shortcut = s.ShortcutBindings.FirstOrDefault(b => b.Id == Id)?.Shortcut;
            RefreshShortcutButtons();
        });
        AddRow(new SettingsCard { Header = "Keyboard shortcut", Description = _shortcutStatus, Content = content });
    }

    /// <summary>Records <paramref name="shortcut"/> (taking it from any other action), or removes the action's one.</summary>
    private void SaveShortcut(Shortcut? shortcut) =>
        Save("shortcutBindings", s => s with { ShortcutBindings = ShortcutBinding.Set(s.ShortcutBindings, Id, shortcut) });

    /// <summary>macOS: "None" and Remove only when not recording, Remove only with a shortcut; no Record while recording.</summary>
    private void RefreshShortcutButtons()
    {
        var recording = Recorder.IsRecording;
        var has = Recorder.Shortcut is not null;
        _noShortcut.Visibility = Shown(!recording && !has);
        _clearButton.Visibility = Shown(!recording && has);
        _recordButton.Visibility = Shown(!recording);
    }

    // Helpers.

    /// <summary>Saves one change; a failed write is logged and the controls go back to the saved settings.</summary>
    private void Save(string key, Func<AppSettings, AppSettings> change)
    {
        if (_syncing || _model is null) return;
        if (!_model.Save(key, change)) Update(_model.Current);
    }

    private void AddRow(UIElement row) => Expander.Items.Add(row);

    private Style CardStyle(string key) => (Style)Resources[key];

    private static Style AppStyle(string key) => (Style)Application.Current.Resources[key];

    private static Visibility Shown(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    private static int IndexOf(IReadOnlyList<ProviderKind> list, ProviderKind kind)
    {
        for (var i = 0; i < list.Count; i++)
        {
            if (list[i] == kind) return i;
        }
        return -1;
    }

    /// <summary>An icon-only subtle button; its name and tooltip are <paramref name="title"/>.</summary>
    private static Button IconButton(string glyph, string title)
    {
        var button = new Button
        {
            Content = new FontIcon { FontSize = 14, Glyph = glyph },
            Style = AppStyle("SubtleButtonStyle"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(button, title);
        HoverTooltip.SetText(button, title);
        return button;
    }

    /// <summary>The (i) icon whose hint shows on hover (macOS InfoTooltip). The transparent border takes the pointer.</summary>
    private Border InfoIcon()
    {
        var icon = new FontIcon { Glyph = "\uE946", Style = CardStyle("SecondaryIconStyle") };
        icon.FontSize = 12;
        return new Border
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Padding = new Thickness(2),
            VerticalAlignment = VerticalAlignment.Center,
            Child = icon,
        };
    }

    private static StackPanel Labeled(string label, UIElement info)
    {
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        header.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center });
        header.Children.Add(info);
        return header;
    }

    /// <summary>An icon, then <paramref name="text"/> taking the rest of the line and wrapping.</summary>
    private Grid IconLine(string glyph, string iconStyle, TextBlock text)
    {
        var line = new Grid { ColumnSpacing = 6, Visibility = Visibility.Collapsed };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var icon = new FontIcon { Glyph = glyph, Style = CardStyle(iconStyle), VerticalAlignment = VerticalAlignment.Top };
        icon.FontSize = 12;
        icon.Margin = new Thickness(0, 2, 0, 0);
        line.Children.Add(icon);
        Grid.SetColumn(text, 1);
        line.Children.Add(text);
        return line;
    }

    /// <summary>
    /// A multi-line prompt (macOS CustomPromptField): the label (with an (i) when there is more to say), the box, its
    /// caption. With a predefined fallback, an empty prompt shows "Predefined prompt is being used" and Edit instead of
    /// the box, and Reset (after a confirmation) empties the prompt again. Once edited, the box stays until Reset. The
    /// text is handed to <see cref="Committed"/> 500 ms after the last keystroke and when the box loses focus.
    /// </summary>
    private sealed class PromptField
    {
        private static readonly TimeSpan SaveDelay = TimeSpan.FromMilliseconds(500);

        private readonly ActionCard _card;
        private readonly bool _allowsPredefined;
        private readonly TextBox _box;
        private readonly Grid _captionRow = new() { ColumnSpacing = 8 };
        private readonly Grid _predefinedRow = new() { ColumnSpacing = 8 };
        private DispatcherQueueTimer? _timer;
        private bool _editing;
        private bool _syncing;

        public PromptField(ActionCard card, string label, string? info, string placeholder, string caption, bool allowsPredefined)
        {
            _card = card;
            _allowsPredefined = allowsPredefined;
            _box = new TextBox
            {
                PlaceholderText = placeholder,
                AcceptsReturn = true,
                TextWrapping = TextWrapping.Wrap,
                MinHeight = 64,
                MaxHeight = 140,
                HorizontalAlignment = HorizontalAlignment.Stretch,
            };
            ScrollViewer.SetVerticalScrollBarVisibility(_box, ScrollBarVisibility.Auto);
            AutomationProperties.SetName(_box, label);

            object header = label;
            if (info is not null)
            {
                var icon = card.InfoIcon();
                HoverTooltip.SetText(icon, info);
                header = Labeled(label, icon);
            }

            _captionRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            _captionRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _captionRow.Children.Add(new TextBlock { Text = caption, Style = card.CardStyle("CaptionStyle"), VerticalAlignment = VerticalAlignment.Center });
            if (allowsPredefined)
            {
                var reset = new Button { Content = "Reset", VerticalAlignment = VerticalAlignment.Center };
                reset.Click += async (_, _) => await ConfirmResetAsync();
                Grid.SetColumn(reset, 1);
                _captionRow.Children.Add(reset);
            }

            _predefinedRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            _predefinedRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _predefinedRow.Children.Add(new TextBlock
            {
                Text = "Predefined prompt is being used",
                Style = card.CardStyle("SecondaryTextStyle"),
                VerticalAlignment = VerticalAlignment.Center,
            });
            var edit = new Button { Content = "Edit", VerticalAlignment = VerticalAlignment.Center };
            edit.Click += (_, _) =>
            {
                _editing = true;
                UpdateMode();
                _box.DispatcherQueue.TryEnqueue(() => _box.Focus(FocusState.Programmatic));
            };
            Grid.SetColumn(edit, 1);
            _predefinedRow.Children.Add(edit);

            var body = new StackPanel { Spacing = 6 };
            body.Children.Add(_box);
            body.Children.Add(_captionRow);
            body.Children.Add(_predefinedRow);
            Root = new SettingsCard
            {
                Header = header,
                ContentAlignment = ContentAlignment.Vertical,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Content = body,
            };

            _box.TextChanged += (_, _) =>
            {
                if (_syncing) return;
                _editing = true;
                _timer ??= CreateTimer();
                _timer.Stop();
                _timer.Start();
            };
            _box.LostFocus += (_, _) => Flush();
        }

        public SettingsCard Root { get; }

        /// <summary>The text to save as the prompt.</summary>
        public event Action<string>? Committed;

        /// <summary>Shows the saved <paramref name="text"/>, unless the box is being edited.</summary>
        public void Show(string text)
        {
            if (_box.FocusState != FocusState.Unfocused || _timer?.IsRunning == true) return;
            if (_box.Text != text)
            {
                _syncing = true;
                _box.Text = text;
                _syncing = false;
            }
            UpdateMode();
        }

        public void Flush()
        {
            if (_timer?.IsRunning == true) Commit();
        }

        private void Commit()
        {
            _timer?.Stop();
            Committed?.Invoke(_box.Text);
        }

        /// <summary>The box shows when the prompt is required, has text, or was edited.</summary>
        private void UpdateMode()
        {
            var showsInput = !_allowsPredefined || _box.Text.Length > 0 || _editing;
            _box.Visibility = Shown(showsInput);
            _captionRow.Visibility = Shown(showsInput);
            _predefinedRow.Visibility = Shown(!showsInput);
        }

        private async Task ConfirmResetAsync()
        {
            if (_card.XamlRoot is null) return;
            var dialog = new ContentDialog
            {
                XamlRoot = _card.XamlRoot,
                Style = AppStyle("DefaultContentDialogStyle"),
                Title = "Reset to predefined prompt?",
                Content = new TextBlock
                {
                    Text = "Your custom prompt will be discarded and PopGuy will use the predefined prompt again.",
                    TextWrapping = TextWrapping.Wrap,
                },
                PrimaryButtonText = "Reset",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            };
            try
            {
                if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            }
            catch (System.Runtime.InteropServices.COMException)
            {
                // Another dialog is open.
                return;
            }
            _timer?.Stop();
            _syncing = true;
            _box.Text = "";
            _syncing = false;
            _editing = false;
            UpdateMode();
            Committed?.Invoke("");
        }

        private DispatcherQueueTimer CreateTimer()
        {
            var timer = _box.DispatcherQueue.CreateTimer();
            timer.Interval = SaveDelay;
            timer.IsRepeating = false;
            timer.Tick += (sender, _) =>
            {
                sender.Stop();
                Commit();
            };
            return timer;
        }
    }
}
