using System.Globalization;
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Shapes;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.Providers;
using PopGuy.Core.Settings;
using PopGuy.LocalLLM;
using PopGuy.Services;
using PopGuy.Settings.ViewModels;
using VirtualKey = Windows.System.VirtualKey;

namespace PopGuy.Settings.Pages;

/// <summary>
/// Settings → Providers (macOS SettingsView.swift APIKeysTab, spec-3 §5.2): the AI, Local AI, Translation and Speech
/// segments, one card per provider; Local AI lists the downloadable local models (<see cref="LocalModels"/>). API keys
/// go only to Credential Manager, after a live check (<see cref="ProvidersViewModel"/>); a saved key shows only as a
/// masked preview. Base URLs, CLI paths and the Azure region save through
/// <see cref="SettingsStore.Update"/> 500 ms after the last keystroke, when the box loses focus and when the page goes
/// (as GeneralPage's Global Prompt); a UNC or <c>\\?\</c> CLI path is refused. The navigation parameter is the
/// AppServices. A change from elsewhere shows while the page is open.
/// </summary>
public sealed partial class ProvidersPage : Page
{
    private static readonly TimeSpan FieldSaveDelay = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan CliWorkingDuration = TimeSpan.FromSeconds(3);

    private readonly List<SettingField> _fields = [];
    private readonly List<CliCard> _clis = [];
    private readonly List<LocalRow> _localRows = [];
    private TextBlock? _localError;
    private Grid? _localErrorRow;
    private AppServices? _services;
    private ProvidersViewModel? _model;
    private bool _subscribed;
    private bool _keysLoaded;

    /// <summary>The boxes are being set from the settings: their change events are not the user's.</summary>
    private bool _syncing;

    public ProvidersPage()
    {
        InitializeComponent();
        SegmentBar.SelectedItem = SegmentBar.Items[0];
        SegmentBar.SelectionChanged += (_, _) => ShowSegment();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _services = e.Parameter as AppServices;
        if (_services is null || _model is not null) return;
        _model = new ProvidersViewModel(_services.Settings, _services.Credentials, _services.Providers, _services.Log.Write);
        BuildCards(_model);
        BuildLocalCards(_services.LocalModels);
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_services is null || _model is null) return;
        if (!_subscribed)
        {
            _services.Settings.Changed += OnSettingsChanged;
            _services.LocalModels.Changed += RenderLocal;
        }
        _subscribed = true;
        RefreshFields();
        RenderLocal();
        _ = _services.LocalModels.RefreshAsync();
        if (_keysLoaded) return;
        _keysLoaded = true;
        _ = _model.LoadKeysAsync();
    }

    /// <summary>
    /// Pending fields are saved before the page goes. The window's first-show re-attach takes the page out and puts it
    /// back in one tick, and its Loaded may come before this Unloaded: a page still loaded keeps listening and running.
    /// </summary>
    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_services is null) return;
        FlushFields();
        if (IsLoaded) return;
        _services.Settings.Changed -= OnSettingsChanged;
        // A download goes on without the page (macOS: the store runs it).
        _services.LocalModels.Changed -= RenderLocal;
        _subscribed = false;
        foreach (var cli in _clis)
        {
            cli.Run?.Cancel();
            cli.Dismiss?.Stop();
        }
    }

    /// <summary>Queued: a change may be saved from any thread. The default local model is a setting too.</summary>
    private void OnSettingsChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(() =>
    {
        RefreshFields();
        RenderLocal();
    });

    private void ShowSegment()
    {
        var index = SegmentBar.Items.IndexOf(SegmentBar.SelectedItem);
        if (index < 0) return;
        AiCards.Visibility = index == 0 ? Visibility.Visible : Visibility.Collapsed;
        LocalCards.Visibility = index == 1 ? Visibility.Visible : Visibility.Collapsed;
        TranslationCards.Visibility = index == 2 ? Visibility.Visible : Visibility.Collapsed;
        SpeechCards.Visibility = index == 3 ? Visibility.Visible : Visibility.Collapsed;
        CardsScroller.ChangeView(null, 0, null, disableAnimation: true);
    }

    // Cards (spec-3 §5.2 order and copy).

    private void BuildCards(ProvidersViewModel model)
    {
        Add(AiCards, KeyCard("OpenAI", "https://platform.openai.com/api-keys", model.Key(ProviderKind.OpenAi)));
        Add(AiCards, KeyCard("Anthropic", "https://console.anthropic.com/settings/keys", model.Key(ProviderKind.Anthropic)));
        Add(AiCards, KeyCard("Google Gemini", "https://aistudio.google.com/app/apikey", model.Key(ProviderKind.Gemini)));
        Add(AiCards, KeyCard("GLM / z.ai", "https://z.ai/manage-apikey/apikey-list", model.Key(ProviderKind.Glm)));
        Add(AiCards, KeyCard("OpenRouter", "https://openrouter.ai/keys", model.Key(ProviderKind.OpenRouter)));

        var ollama = Field("ollamaBaseURL", "Ollama Base URL", "", s => s.OllamaBaseUrl, (s, text) => s with { OllamaBaseUrl = text });
        Add(AiCards, Card("Ollama", null, Row(Label("Base URL"), ollama.Box), Caption("Ollama does not require an API key.")));

        Add(AiCards, CliCardFor(
            ProviderKind.ClaudeCli, "Claude CLI (subscription)", @"e.g. ~\.local\bin\claude.exe",
            "Uses your Claude subscription login — no API key needed. Slower than the API providers."));
        Add(AiCards, CliCardFor(
            ProviderKind.CodexCli, "Codex CLI (subscription)", @"e.g. ~\AppData\Roaming\npm\codex.cmd",
            "Uses your Codex subscription login — no API key needed. Slower than the API providers."));
        Add(AiCards, CliCardFor(
            ProviderKind.GeminiCli, "Gemini CLI (subscription)", @"e.g. ~\AppData\Roaming\npm\gemini.cmd",
            "Uses your Gemini subscription login — no API key needed. Slower than the API providers."));

        var custom = Field(
            "customBaseURL", "Custom Base URL", "http://localhost:8080/v1", s => s.CustomBaseUrl,
            (s, text) => s with { CustomBaseUrl = text });
        var customLabel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        customLabel.Children.Add(Label("Base URL"));
        customLabel.Children.Add(InfoIcon("OpenAI-compatible endpoint for your custom provider, e.g. \"http://localhost:8080/v1\"."));
        var customKey = new KeyRow(this, "Custom (OpenAI-compatible)", model.Key(ProviderKind.Custom));
        Add(AiCards, Card("Custom (OpenAI-compatible)", null, Row(customLabel, custom.Box), customKey.Root));

        Add(TranslationCards, KeyCard("DeepL", "https://www.deepl.com/your-account/keys", model.Key(ProviderKind.DeepL)));
        Add(TranslationCards, KeyCard(
            "Google Translate", "https://console.cloud.google.com/apis/credentials", model.Key(ProviderKind.GoogleTranslate)));

        Add(SpeechCards, TtsCard("OpenAI", "https://platform.openai.com/api-keys", model.TtsKey(TtsProviderKind.OpenAiTts)));
        Add(SpeechCards, TtsCard(
            "Google Cloud TTS", "https://console.cloud.google.com/apis/credentials", model.TtsKey(TtsProviderKind.GoogleCloudTts)));
        var region = Field(
            "ttsProviderConfigs", "Azure Speech Region", "e.g. eastus", ProvidersViewModel.AzureRegion,
            ProvidersViewModel.WithAzureRegion);
        Add(SpeechCards, TtsCard(
            "Azure Speech", "https://portal.azure.com/", model.TtsKey(TtsProviderKind.AzureTts),
            Row(Label("Region"), region.Box), Caption("Azure region, e.g. eastus — required.")));
    }

    private static void Add(Panel panel, UIElement card) => panel.Children.Add(card);

    private SettingsCard KeyCard(string title, string keyUrl, KeyEntryViewModel key) =>
        Card(title, keyUrl, new KeyRow(this, title, key).Root);

    /// <summary>A Speech card: <paramref name="before"/> (Azure's region), the key row without Verify, the privacy note.</summary>
    private SettingsCard TtsCard(string title, string keyUrl, KeyEntryViewModel key, params UIElement[] before) =>
        Card(title, keyUrl, [
            .. before,
            new KeyRow(this, title, key).Root,
            Caption($"Cloud speech sends the selected text to {title}'s servers. The local System voice keeps everything on-device."),
        ]);

    /// <summary>A card titled <paramref name="title"/>, with the "Get API key ↗" link when the provider has a console.</summary>
    private static SettingsCard Card(string title, string? keyUrl, params UIElement[] content)
    {
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        header.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center });
        if (keyUrl is not null)
        {
            var link = new HyperlinkButton
            {
                Content = new TextBlock { Text = "Get API key ↗", Style = AppStyle("CaptionTextBlockStyle") },
                NavigateUri = new Uri(keyUrl),
                Padding = new Thickness(4, 2, 4, 2),
                VerticalAlignment = VerticalAlignment.Center,
            };
            AutomationProperties.SetName(link, $"Get API key for {title}");
            HoverTooltip.SetText(link, "Open the provider's website to get an API key");
            header.Children.Add(link);
        }
        var body = new StackPanel { Spacing = 10 };
        foreach (var element in content) body.Children.Add(element);
        return new SettingsCard
        {
            Header = header,
            ContentAlignment = ContentAlignment.Vertical,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = body,
        };
    }

    /// <summary>A label, the field filling the row, then <paramref name="trailing"/> (a button).</summary>
    private static Grid Row(FrameworkElement label, FrameworkElement field, params FrameworkElement[] trailing)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(label);
        Grid.SetColumn(field, 1);
        grid.Children.Add(field);
        for (var i = 0; i < trailing.Length; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(trailing[i], i + 2);
            grid.Children.Add(trailing[i]);
        }
        return grid;
    }

    private static TextBlock Label(string text) => new() { Text = text, VerticalAlignment = VerticalAlignment.Center };

    private TextBlock Caption(string text) => new() { Text = text, Style = PageStyle("CaptionStyle") };

    /// <summary>The (i) icon whose hint shows on hover (macOS InfoTooltip). The transparent border takes the pointer.</summary>
    private Border InfoIcon(string hint)
    {
        var icon = new FontIcon { Glyph = "", Style = PageStyle("SecondaryIconStyle") };
        icon.FontSize = 12;
        var target = new Border
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Padding = new Thickness(2),
            VerticalAlignment = VerticalAlignment.Center,
            Child = icon,
        };
        HoverTooltip.SetText(target, hint);
        return target;
    }

    private Style PageStyle(string key) => (Style)Resources[key];

    private static Style AppStyle(string key) => (Style)Application.Current.Resources[key];

    private static Visibility Shown(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    // Local AI (macOS LocalModelsView.swift; LocalModelMemoryInfoView.swift's panel is the expander below the card).

    /// <summary>
    /// The models card: the subtitle, the last error, then one row per catalog model; then the memory guidance. The
    /// state lives in <see cref="LocalModels"/>, so a download shows again when the page comes back.
    /// </summary>
    private void BuildLocalCards(LocalModels local)
    {
        var warning = new FontIcon { Glyph = "\uE7BA", Style = PageStyle("CautionIconStyle"), VerticalAlignment = VerticalAlignment.Top };
        _localError = new TextBlock { Style = PageStyle("CaptionStyle") };
        _localErrorRow = new Grid { ColumnSpacing = 8, Visibility = Visibility.Collapsed };
        _localErrorRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _localErrorRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _localErrorRow.Children.Add(warning);
        Grid.SetColumn(_localError, 1);
        _localErrorRow.Children.Add(_localError);

        List<UIElement> content =
        [
            Caption("Run AI privately — no API key, no internet required."),
            Caption("An action set to Local model (on this PC) runs the model in its Model field; an empty or unknown id runs the default model."),
            _localErrorRow,
        ];
        foreach (var entry in GgufCatalog.All)
        {
            content.Add(new Rectangle { Style = PageStyle("DividerStyle") });
            var row = new LocalRow(this, local, entry);
            _localRows.Add(row);
            content.Add(row.Root);
        }
        Add(LocalCards, Card("Local (On-Device) Models", null, [.. content]));
        Add(LocalCards, MemoryGuidance());
    }

    private void RenderLocal()
    {
        if (_services is null || _localError is null || _localErrorRow is null) return;
        var error = _services.LocalModels.Error;
        _localError.Text = error ?? "";
        _localErrorRow.Visibility = Shown(error is not null);
        foreach (var row in _localRows) row.Render();
    }

    /// <summary>
    /// macOS "How Models Use Memory", for llama.cpp in PopGuy's own process: no idle picker, Unload button or
    /// "In memory" badge here, and the model is freed after 5 minutes without a run.
    /// </summary>
    private static SettingsExpander MemoryGuidance()
    {
        (string Title, string Text)[] sections =
        [
            ("What \"needs X GB RAM\" means",
                "The RAM figure is an estimate of the memory a model uses while it runs, its working space included. It is guidance for choosing a model that suits your PC, not a live usage counter: pick one that leaves room for your other apps."),
            ("When a model loads (cold start)",
                "A model is not loaded when you download it or when PopGuy starts. It loads the first time you run an action that uses it: the multi-gigabyte model file is read from disk into memory, which takes a few seconds for small models and longer for large ones. Once loaded, every later action with the same model starts fast."),
            ("One model at a time",
                "Only the model you are using takes memory. If you run an action with a different model, the previous one is unloaded before the new one loads. You will not have two models in memory at once."),
            ("Downloaded does not mean in memory",
                "Downloading several models only uses disk space — it does not use memory. A model takes memory only while it is loaded."),
            ("Automatic release",
                "After 5 minutes without an action, the model is unloaded and its memory is freed. The next action loads it again. Deleting a model also unloads it first."),
        ];
        var expander = new SettingsExpander
        {
            Header = "How models use memory",
            Description = "What the RAM figures mean, and when a model loads and frees its memory.",
        };
        foreach (var (title, text) in sections)
        {
            expander.Items.Add(new SettingsCard
            {
                Header = title,
                Description = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap },
            });
        }
        return expander;
    }

    /// <summary>"1.3 GB": a download's size in decimal gigabytes (macOS ByteCountFormatter's file style).</summary>
    private static string SizeText(long bytes) => $"{(bytes / 1e9).ToString("0.0", CultureInfo.CurrentCulture)} GB";

    /// <summary>"needs about 4.4 GB RAM": the catalog's estimate while loaded.</summary>
    private static string RamText(int megabytes) => $"needs about {(megabytes / 1024.0).ToString("0.#", CultureInfo.CurrentCulture)} GB RAM";

    /// <summary>
    /// One model (macOS LocalModelsView.modelRow): its name and Default badge, size and RAM, then the controls of its
    /// state: Cancel while it downloads (with the progress below), Installed with Set as default and Delete, or Download
    /// (Resume over a partial file, which Delete also removes). Every click shows at once; the work runs in
    /// <see cref="LocalModels"/>.
    /// </summary>
    private sealed class LocalRow
    {
        private readonly ProvidersPage _page;
        private readonly LocalModels _local;
        private readonly GgufModel _entry;
        private readonly Border _defaultBadge;
        private readonly StackPanel _controls = new() { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        private readonly StackPanel _installed = new() { Orientation = Orientation.Horizontal, Spacing = 4 };
        private readonly StackPanel _deleting = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
        private readonly ProgressRing _deletingRing = new() { Width = 16, Height = 16, IsActive = false };
        private readonly Button _setDefault = new() { Content = "Set as default" };
        private readonly Button _download = new();
        private readonly Button _cancel = new() { Content = "Cancel" };
        private readonly Button _delete = new() { Content = "Delete" };
        private readonly StackPanel _progress = new() { Spacing = 3 };
        private readonly ProgressBar _bar = new() { Minimum = 0, Maximum = 1 };
        private readonly TextBlock _progressText;

        public LocalRow(ProvidersPage page, LocalModels local, GgufModel entry)
        {
            _page = page;
            _local = local;
            _entry = entry;

            var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            name.Children.Add(new TextBlock { Text = entry.DisplayName, VerticalAlignment = VerticalAlignment.Center });
            _defaultBadge = new Border
            {
                Style = page.PageStyle("BadgeStyle"),
                Child = new TextBlock { Text = "Default", Style = page.PageStyle("CaptionStyle") },
            };
            HoverTooltip.SetText(_defaultBadge, "Runs when an action's model is empty or not a local model");
            name.Children.Add(_defaultBadge);
            var details = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            details.Children.Add(name);
            details.Children.Add(page.Caption($"{SizeText(entry.Bytes)} · {RamText(entry.RamMB)}"));

            _installed.Children.Add(new FontIcon { Glyph = "\uEC61", Style = page.PageStyle("SuccessIconStyle"), VerticalAlignment = VerticalAlignment.Center });
            _installed.Children.Add(new TextBlock { Text = "Installed", Style = page.PageStyle("CaptionStyle"), VerticalAlignment = VerticalAlignment.Center });
            _deleting.Children.Add(_deletingRing);
            _deleting.Children.Add(new TextBlock { Text = "Deleting…", Style = page.PageStyle("CaptionStyle"), VerticalAlignment = VerticalAlignment.Center });
            _download.Style = AppStyle("AccentButtonStyle");
            HoverTooltip.SetText(_setDefault, "Use this model when an action's model is empty or not a local model");
            HoverTooltip.SetText(_cancel, "Cancel the download; Resume continues it later");
            HoverTooltip.SetText(_delete, "Remove this model from disk");
            AutomationProperties.SetName(_setDefault, $"Set {entry.DisplayName} as default");
            AutomationProperties.SetName(_cancel, $"Cancel the download of {entry.DisplayName}");
            AutomationProperties.SetName(_delete, $"Delete {entry.DisplayName}");
            foreach (var element in new FrameworkElement[] { _installed, _deleting, _setDefault, _download, _cancel, _delete })
            {
                element.VerticalAlignment = VerticalAlignment.Center;
                _controls.Children.Add(element);
            }

            var top = new Grid { ColumnSpacing = 8 };
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            top.Children.Add(details);
            Grid.SetColumn(_controls, 1);
            top.Children.Add(_controls);

            _progressText = page.Caption("");
            AutomationProperties.SetName(_bar, $"Download of {entry.DisplayName}");
            _progress.Children.Add(_bar);
            _progress.Children.Add(_progressText);

            Root.Children.Add(top);
            Root.Children.Add(_progress);

            _setDefault.Click += (_, _) => _local.SetDefault(_entry);
            _download.Click += (_, _) => _ = _local.DownloadAsync(_entry);
            _cancel.Click += (_, _) => _local.CancelDownload();
            _delete.Click += async (_, _) => await ConfirmDeleteAsync();
            Render();
        }

        public StackPanel Root { get; } = new() { Spacing = 8 };

        public void Render()
        {
            var file = _local.FileState(_entry);
            var downloading = _local.ActiveDownloadId == _entry.Id;
            var otherDownloading = _local.ActiveDownloadId is not null && !downloading;
            var deleting = _local.IsDeleting(_entry);
            var installed = !downloading && !deleting && file == LocalModelFile.Installed;
            var isDefault = _local.DefaultId == _entry.Id;

            _defaultBadge.Visibility = Shown(isDefault);
            _controls.Visibility = Shown(_local.IsLoaded);
            _installed.Visibility = Shown(installed);
            _deleting.Visibility = Shown(deleting);
            _deletingRing.IsActive = deleting;
            _setDefault.Visibility = Shown(installed && !isDefault);
            _cancel.Visibility = Shown(downloading);
            _delete.Visibility = Shown(!downloading && !deleting && file != LocalModelFile.Missing);

            var resume = file == LocalModelFile.Partial;
            _download.Visibility = Shown(!downloading && !deleting && file != LocalModelFile.Installed);
            _download.Content = resume ? "Resume" : "Download";
            _download.IsEnabled = !otherDownloading;
            AutomationProperties.SetName(_download, $"{(resume ? "Resume" : "Download")} {_entry.DisplayName}");
            HoverTooltip.SetText(_download, otherDownloading
                ? "Another model is downloading — wait for it to finish"
                : resume ? $"Resume the download of {_entry.DisplayName}" : $"Download {_entry.DisplayName}");

            // macOS: "Preparing" until the first bytes, then the percentage.
            _progress.Visibility = Shown(downloading);
            var fraction = downloading ? _local.DownloadFraction : null;
            _bar.IsIndeterminate = fraction is null;
            _bar.Value = fraction ?? 0;
            _progressText.Text = fraction is { } f
                ? $"Downloading {_entry.DisplayName}… {(int)Math.Round(f * 100)}%"
                : $"Preparing {_entry.DisplayName}…";
        }

        /// <summary>Delete after a confirmation (macOS: "Delete … ?").</summary>
        private async Task ConfirmDeleteAsync()
        {
            if (_page.XamlRoot is null) return;
            var dialog = new ContentDialog
            {
                XamlRoot = _page.XamlRoot,
                Style = AppStyle("DefaultContentDialogStyle"),
                Title = $"Delete {_entry.DisplayName}?",
                Content = new TextBlock
                {
                    Text = "This will remove the model files from this PC. You can download it again later.",
                    TextWrapping = TextWrapping.Wrap,
                },
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
            await _local.DeleteAsync(_entry);
        }
    }

    // Settings fields.

    /// <summary>A text box saved into the settings; <see cref="Reject"/> (CLI paths) blocks the save with a message.</summary>
    private sealed class SettingField
    {
        public required string Key { get; init; }
        public required TextBox Box { get; init; }
        public required Func<AppSettings, string> Read { get; init; }
        public required Func<AppSettings, string, AppSettings> Write { get; init; }
        public Func<string, string?>? Reject { get; init; }
        public TextBlock? Error { get; init; }
        public DispatcherQueueTimer? Timer { get; set; }

        /// <summary>The user changed the text (the CLI card enables Verify).</summary>
        public Action? Edited { get; set; }
    }

    private SettingField Field(
        string key, string name, string placeholder, Func<AppSettings, string> read, Func<AppSettings, string, AppSettings> write,
        Func<string, string?>? reject = null)
    {
        var box = new TextBox { PlaceholderText = placeholder, HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(box, name);
        var field = new SettingField
        {
            Key = key,
            Box = box,
            Read = read,
            Write = write,
            Reject = reject,
            Error = reject is null ? null : new TextBlock { Style = PageStyle("ErrorTextStyle"), Visibility = Visibility.Collapsed },
        };
        box.TextChanged += (_, _) => OnFieldChanged(field);
        box.LostFocus += (_, _) => SaveField(field);
        _fields.Add(field);
        return field;
    }

    private void OnFieldChanged(SettingField field)
    {
        if (_syncing || _model is null) return;
        ShowRejection(field);
        field.Edited?.Invoke();
        if (field.Timer is null)
        {
            field.Timer = DispatcherQueue.CreateTimer();
            field.Timer.Interval = FieldSaveDelay;
            field.Timer.IsRepeating = false;
            field.Timer.Tick += (_, _) => SaveField(field);
        }
        field.Timer.Stop();
        field.Timer.Start();
    }

    /// <summary>Saves the box's text when it is allowed and changes the setting; a failed write is logged (the text stays).</summary>
    private void SaveField(SettingField field)
    {
        field.Timer?.Stop();
        if (_model is null || ShowRejection(field)) return;
        var text = field.Box.Text;
        var current = _model.Current;
        if (field.Read(field.Write(current, text)) == field.Read(current)) return;
        _model.Save(field.Key, s => field.Write(s, text));
    }

    private void FlushFields()
    {
        foreach (var field in _fields) SaveField(field);
    }

    /// <summary>Shows or hides the field's refusal; true when its text may not be saved.</summary>
    private static bool ShowRejection(SettingField field)
    {
        var message = field.Reject?.Invoke(field.Box.Text);
        if (field.Error is { } error)
        {
            error.Text = message ?? "";
            error.Visibility = Shown(message is not null);
        }
        return message is not null;
    }

    /// <summary>Every box shows the current settings, except one the user is editing.</summary>
    private void RefreshFields()
    {
        if (_model is null) return;
        var current = _model.Current;
        _syncing = true;
        foreach (var field in _fields)
        {
            if (field.Box.FocusState != FocusState.Unfocused || field.Timer?.IsRunning == true) continue;
            var saved = field.Read(current);
            if (field.Read(field.Write(current, field.Box.Text)) != saved) field.Box.Text = saved;
            ShowRejection(field);
        }
        _syncing = false;
        foreach (var cli in _clis) UpdateCliVerify(cli);
    }

    // CLI cards.

    private sealed class CliCard
    {
        public required ProviderKind Kind { get; init; }
        public required SettingField Field { get; init; }
        public required Button Verify { get; init; }
        public required ProgressRing Ring { get; init; }
        public required TextBlock Running { get; init; }
        public required Grid Feedback { get; init; }
        public required FontIcon FeedbackIcon { get; init; }
        public required TextBlock FeedbackText { get; init; }
        public CancellationTokenSource? Run { get; set; }
        public DispatcherQueueTimer? Dismiss { get; set; }
    }

    /// <summary>Path + Detect, the caption, then Verify with its outcome (macOS CLIVerifyButton).</summary>
    private SettingsCard CliCardFor(ProviderKind kind, string title, string placeholder, string caption)
    {
        var field = Field(
            kind switch
            {
                ProviderKind.ClaudeCli => "claudeCLIPath",
                ProviderKind.CodexCli => "codexCLIPath",
                _ => "geminiCLIPath",
            },
            $"{title} Path", placeholder, s => ProvidersViewModel.CliPath(s, kind),
            (s, text) => ProvidersViewModel.WithCliPath(s, kind, text), ProviderFeedback.CliPathRejection);
        var detect = new Button { Content = "Detect" };

        var verify = new Button { Content = "Verify", VerticalAlignment = VerticalAlignment.Center };
        var ring = new ProgressRing { Width = 16, Height = 16, IsActive = false, Visibility = Visibility.Collapsed };
        var running = Caption("Running…");
        running.Visibility = Visibility.Collapsed;
        running.VerticalAlignment = VerticalAlignment.Center;
        var feedbackIcon = new FontIcon { VerticalAlignment = VerticalAlignment.Center };
        var feedbackText = new TextBlock
        {
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var feedback = new Grid { ColumnSpacing = 6, Visibility = Visibility.Collapsed };
        feedback.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        feedback.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        feedback.Children.Add(feedbackIcon);
        Grid.SetColumn(feedbackText, 1);
        feedback.Children.Add(feedbackText);

        // Verify, then the spinner and "Running…" or the outcome, which takes the rest of the row and wraps.
        var verifyRow = new Grid { ColumnSpacing = 8 };
        verifyRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        verifyRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        verifyRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        verifyRow.Children.Add(verify);
        Grid.SetColumn(ring, 1);
        verifyRow.Children.Add(ring);
        Grid.SetColumn(running, 2);
        verifyRow.Children.Add(running);
        Grid.SetColumn(feedback, 2);
        verifyRow.Children.Add(feedback);

        var cli = new CliCard
        {
            Kind = kind,
            Field = field,
            Verify = verify,
            Ring = ring,
            Running = running,
            Feedback = feedback,
            FeedbackIcon = feedbackIcon,
            FeedbackText = feedbackText,
        };
        field.Edited = () => UpdateCliVerify(cli);
        detect.Click += async (_, _) => await DetectAsync(cli, detect);
        verify.Click += async (_, _) => await VerifyCliAsync(cli);
        _clis.Add(cli);
        return Card(title, null, Row(Label("Path"), field.Box, detect), field.Error!, Caption(caption), verifyRow);
    }

    /// <summary>Fills the path with the installed CLI (looked up off the UI thread) and saves it; none found leaves it.</summary>
    private async Task DetectAsync(CliCard cli, Button detect)
    {
        detect.IsEnabled = false;
        var path = await ProvidersViewModel.DetectCliAsync(cli.Kind);
        detect.IsEnabled = true;
        if (path is null) return;
        cli.Field.Box.Text = path;
        SaveField(cli.Field);
        UpdateCliVerify(cli);
    }

    /// <summary>
    /// Runs the CLI once with the path in the box (an empty one is looked up on the PATH). Cancelled when the page goes.
    /// </summary>
    private async Task VerifyCliAsync(CliCard cli)
    {
        if (_model is null || cli.Run is not null || ProviderFeedback.CliPathRejection(cli.Field.Box.Text) is not null) return;
        SaveField(cli.Field);
        cli.Dismiss?.Stop();
        var run = cli.Run = new CancellationTokenSource();
        ShowCliRunning(cli, true);
        CliValidationOutcome outcome;
        try
        {
            outcome = await _model.VerifyCliAsync(cli.Kind, cli.Field.Box.Text, run.Token);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        finally
        {
            cli.Run = null;
            run.Dispose();
            ShowCliRunning(cli, false);
        }
        ShowCliOutcome(cli, outcome);
    }

    private void ShowCliRunning(CliCard cli, bool running)
    {
        cli.Ring.IsActive = running;
        cli.Ring.Visibility = Shown(running);
        cli.Running.Visibility = Shown(running);
        if (running) cli.Feedback.Visibility = Visibility.Collapsed;
        UpdateCliVerify(cli);
    }

    /// <summary>"Working" clears after 3 s; "Set the CLI path first" and a failure stay (macOS parity).</summary>
    private void ShowCliOutcome(CliCard cli, CliValidationOutcome outcome)
    {
        var (glyph, iconStyle, text, textStyle) = outcome.Kind switch
        {
            CliValidationOutcomeKind.Working => ("", "SuccessIconStyle", "Working", "CaptionStyle"),
            CliValidationOutcomeKind.NoPath => ("", "CautionIconStyle", "Set the CLI path first", "CaptionStyle"),
            _ => ("", "CriticalIconStyle", outcome.Message, "ErrorTextStyle"),
        };
        cli.FeedbackIcon.Glyph = glyph;
        cli.FeedbackIcon.Style = PageStyle(iconStyle);
        cli.FeedbackText.Style = PageStyle(textStyle);
        cli.FeedbackText.Text = text;
        // The full failure on hover: the line may be cut after two lines.
        HoverTooltip.SetText(cli.FeedbackText, outcome.Kind == CliValidationOutcomeKind.Failed ? text : null);
        cli.Feedback.Visibility = Visibility.Visible;
        if (outcome.Kind != CliValidationOutcomeKind.Working) return;
        if (cli.Dismiss is null)
        {
            cli.Dismiss = DispatcherQueue.CreateTimer();
            cli.Dismiss.Interval = CliWorkingDuration;
            cli.Dismiss.IsRepeating = false;
            cli.Dismiss.Tick += (timer, _) =>
            {
                timer.Stop();
                cli.Feedback.Visibility = Visibility.Collapsed;
            };
        }
        cli.Dismiss.Stop();
        cli.Dismiss.Start();
    }

    /// <summary>Verify waits for a running check and refuses a UNC or <c>\\?\</c> path; an empty path is allowed (PATH lookup).</summary>
    private static void UpdateCliVerify(CliCard cli) =>
        cli.Verify.IsEnabled = cli.Run is null && ProviderFeedback.CliPathRejection(cli.Field.Box.Text) is null;

    // Key rows.

    /// <summary>
    /// The view of one <see cref="KeyEntryViewModel"/> (macOS KeyEntryRow): the key field or the saved preview, the error
    /// line, then Save / Edit / Verify / Cancel / Clear and the Verify feedback. The typed draft lives only in the
    /// PasswordBox, emptied after a save, Cancel and Clear. Hidden until the saved key was looked up.
    /// </summary>
    private sealed class KeyRow
    {
        private readonly ProvidersPage _page;
        private readonly KeyEntryViewModel _key;
        private readonly PasswordBox _box = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly Grid _fieldRow;
        private readonly StackPanel _savedRow = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
        private readonly TextBlock _preview = new() { VerticalAlignment = VerticalAlignment.Center };
        private readonly Grid _errorRow = new() { ColumnSpacing = 6 };
        private readonly TextBlock _error = new();
        private readonly Button _save = new() { Content = "Save" };
        private readonly StackPanel _validating = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
        private readonly ProgressRing _validatingRing = new() { Width = 16, Height = 16, IsActive = false };
        private readonly Button _edit = new() { Content = "Edit" };
        private readonly Button _verify = new();
        private readonly ProgressRing _verifyRing = new() { Width = 12, Height = 12, IsActive = false };
        private readonly Button _cancel = new() { Content = "Cancel" };
        private readonly Button _clear = new() { Content = "Clear" };
        private readonly StackPanel _feedback = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
        private readonly FontIcon _feedbackIcon = new() { VerticalAlignment = VerticalAlignment.Center };
        private readonly TextBlock _feedbackText = new() { VerticalAlignment = VerticalAlignment.Center };

        public KeyRow(ProvidersPage page, string title, KeyEntryViewModel key)
        {
            _page = page;
            _key = key;
            AutomationProperties.SetName(_box, $"{title} API Key");
            _fieldRow = Row(Label("API Key"), _box);

            var check = new FontIcon { Glyph = "", Style = page.PageStyle("SuccessIconStyle"), VerticalAlignment = VerticalAlignment.Center };
            _preview.Style = page.PageStyle("SecondaryTextStyle");
            _preview.FontFamily = new FontFamily("Cascadia Mono, Consolas");
            _preview.IsTextSelectionEnabled = false;
            _savedRow.Children.Add(check);
            _savedRow.Children.Add(_preview);

            var warning = new FontIcon { Glyph = "", Style = page.PageStyle("CriticalIconStyle"), VerticalAlignment = VerticalAlignment.Top };
            _error.Style = page.PageStyle("ErrorTextStyle");
            _errorRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _errorRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            _errorRow.Children.Add(warning);
            Grid.SetColumn(_error, 1);
            _errorRow.Children.Add(_error);

            _save.Style = AppStyle("AccentButtonStyle");
            _validating.Children.Add(_validatingRing);
            _validating.Children.Add(new TextBlock
            {
                Text = "Verifying…",
                Style = page.PageStyle("CaptionStyle"),
                VerticalAlignment = VerticalAlignment.Center,
            });
            // The spinner sits inside Verify, before its label.
            var verifyContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            verifyContent.Children.Add(_verifyRing);
            verifyContent.Children.Add(new TextBlock { Text = "Verify" });
            _verify.Content = verifyContent;
            AutomationProperties.SetName(_verify, "Verify");
            _feedback.Children.Add(_feedbackIcon);
            _feedback.Children.Add(_feedbackText);

            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            foreach (var element in new FrameworkElement[] { _save, _validating, _edit, _verify, _cancel, _clear, _feedback })
            {
                element.VerticalAlignment = VerticalAlignment.Center;
                buttons.Children.Add(element);
            }

            Root.Children.Add(_fieldRow);
            Root.Children.Add(_savedRow);
            Root.Children.Add(_errorRow);
            Root.Children.Add(buttons);

            _box.PasswordChanged += (_, _) => Render();
            _box.PreviewKeyDown += async (_, e) =>
            {
                if (e.Key != VirtualKey.Enter) return;
                e.Handled = true;
                await SaveAsync();
            };
            _save.Click += async (_, _) => await SaveAsync();
            _edit.Click += (_, _) =>
            {
                _key.Edit();
                _box.DispatcherQueue.TryEnqueue(() => _box.Focus(FocusState.Programmatic));
            };
            _verify.Click += async (_, _) =>
            {
                _page.FlushFields();
                await _key.VerifyAsync();
            };
            _cancel.Click += (_, _) =>
            {
                _box.Password = "";
                _key.Cancel();
            };
            _clear.Click += async (_, _) =>
            {
                _box.Password = "";
                await _key.ClearAsync();
            };
            _key.Changed += Render;
            Render();
        }

        public StackPanel Root { get; } = new() { Spacing = 10 };

        /// <summary>The base URL and region are saved first: the check reads them from the settings.</summary>
        private async Task SaveAsync()
        {
            if (_box.Password.Length == 0 || _key.IsValidating) return;
            _page.FlushFields();
            if (await _key.SaveAsync(_box.Password)) _box.Password = "";
        }

        private void Render()
        {
            var showsField = _key.ShowsField;
            Root.Visibility = Shown(_key.IsLoaded);
            _fieldRow.Visibility = Shown(showsField);
            _savedRow.Visibility = Shown(!showsField);
            _preview.Text = _key.Preview ?? "Key is saved";
            _box.IsEnabled = !_key.IsValidating;
            _error.Text = _key.ErrorMessage ?? "";
            _errorRow.Visibility = Shown(_key.ErrorMessage is not null);

            _save.Visibility = Shown(showsField);
            _save.IsEnabled = _box.Password.Length > 0 && !_key.IsValidating;
            _validating.Visibility = Shown(showsField && _key.IsValidating);
            _validatingRing.IsActive = showsField && _key.IsValidating;
            _edit.Visibility = Shown(!showsField);
            _verify.Visibility = Shown(!showsField && _key.CanVerify);
            _verify.IsEnabled = !_key.IsVerifying;
            _verifyRing.IsActive = _key.IsVerifying;
            _verifyRing.Visibility = Shown(_key.IsVerifying);
            _cancel.Visibility = Shown(_key.IsSaved && _key.IsEditing);
            _cancel.IsEnabled = !_key.IsValidating;
            _clear.IsEnabled = _key.IsSaved && !_key.IsValidating;

            if (showsField || _key.Outcome is not { } outcome)
            {
                _feedback.Visibility = Visibility.Collapsed;
                return;
            }
            var (glyph, iconStyle, textStyle) = outcome switch
            {
                VerifyOutcome.Valid => ("", "SuccessIconStyle", "CaptionStyle"),
                VerifyOutcome.Invalid => ("", "CriticalIconStyle", "ErrorTextStyle"),
                VerifyOutcome.NoKey => ("", "SecondaryIconStyle", "CaptionStyle"),
                _ => ("", "CautionIconStyle", "CaptionStyle"),
            };
            _feedbackIcon.Glyph = glyph;
            _feedbackIcon.Style = _page.PageStyle(iconStyle);
            _feedbackText.Style = _page.PageStyle(textStyle);
            _feedbackText.Text = ProviderFeedback.VerifyText(outcome);
            _feedback.Visibility = Visibility.Visible;
        }
    }
}
