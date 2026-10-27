using System.ComponentModel;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.Providers;
using PopGuy.Core.Secrets;
using PopGuy.Core.Settings;
using PopGuy.LocalLLM;
using PopGuy.Services;
using VirtualKey = Windows.System.VirtualKey;

namespace PopGuy.Onboarding;

/// <summary>Local AI or a cloud API key (macOS ProviderMode).</summary>
internal enum ProviderMode { Local, Cloud }

/// <summary>
/// The wizard's Set Up a Provider step (macOS OnboardingProviderPage.swift). Local AI downloads the first catalog model
/// through <see cref="LocalModels"/> (the download outlives the wizard); once it is on disk, Improve, Shorten, Proofread
/// and Prompt run it (first launch only, see <see cref="PointAiActionsAtLocalIfReady"/>, and after a download started
/// here through <see cref="LocalModels.PendingOnboardingMapId"/>). Cloud API key checks the typed key with the provider,
/// stores it in Credential Manager (never in the field or the logs; the field shows only a masked preview of a saved
/// key), then points the matching actions at that provider. Lives as long as the wizard: <see cref="Detach"/> when it
/// closes. UI thread only.
/// </summary>
public sealed partial class OnboardingProviderPage : UserControl
{
    /// <summary>The cloud providers offered here (no CLI, GLM, OpenRouter or Custom), with their API key pages.</summary>
    private static readonly (ProviderKind Kind, string KeyUrl)[] CloudProviders =
    [
        (ProviderKind.OpenAi, "https://platform.openai.com/api-keys"),
        (ProviderKind.Anthropic, "https://console.anthropic.com/settings/keys"),
        (ProviderKind.Gemini, "https://aistudio.google.com/app/apikey"),
        (ProviderKind.DeepL, "https://www.deepl.com/your-account/keys"),
        (ProviderKind.GoogleTranslate, "https://console.cloud.google.com/apis/credentials"),
    ];

    private readonly AppServices _services;
    private readonly Func<string, Style> _style;
    private readonly GgufModel _model = GgufCatalog.All[0];
    private ProviderMode _mode = ProviderMode.Local;
    private bool _detached;

    private readonly (Button Button, Border Card, FontIcon Check) _localChoice;
    private readonly (Button Button, Border Card, FontIcon Check) _cloudChoice;
    private readonly ContentControl _branch;

    // Local AI.
    private readonly Border _localCard;
    private readonly ContentControl _localTrailing;
    private readonly Button _downloadButton;
    private readonly Button _cancelButton;
    private readonly StackPanel _readyLabel;
    private readonly StackPanel _progressPanel;
    private readonly ProgressBar _progressBar;
    private readonly TextBlock _progressText;
    private readonly Grid _localError;

    // Cloud API key.
    private readonly Border _cloudCard;
    private readonly ComboBox _providerBox;
    private readonly TextBlock _actionNote;
    private readonly HyperlinkButton _keyLink;
    private readonly PasswordBox _keyBox;
    private readonly Button _saveButton;
    private readonly StackPanel _verifyingPanel;
    private readonly StackPanel _savedHint;
    private readonly TextBlock _keyPreview;
    private readonly StackPanel _savedLabel;
    private readonly Grid _cloudError;
    private CancellationTokenSource? _verify;
    private int _previewReads;

    /// <param name="style">The wizard window's styles by key (its resources hold the theme brushes).</param>
    internal OnboardingProviderPage(AppServices services, Func<string, Style> style)
    {
        _services = services;
        _style = style;
        InitializeComponent();

        _localChoice = ModeCard(
            ProviderMode.Local, "\uE7F4", "Local AI",
            $"Private and free — it runs on your PC with no API key. You'll download a model ({SizeText(_model.Bytes)}), " +
            $"and it needs about {RamText(_model.RamMB)} of memory.");
        _cloudChoice = ModeCard(
            ProviderMode.Cloud, "\uE753", "Cloud API key",
            "Fast and top quality. Paste a small API key for OpenAI, Anthropic, Gemini, or DeepL — usage costs pennies.");
        var chooser = new StackPanel { Spacing = 10 };
        chooser.Children.Add(_localChoice.Button);
        chooser.Children.Add(_cloudChoice.Button);
        Root.Children.Add(chooser);

        // Local AI card: the model, its size, Download / Cancel / Ready, the progress and the last error.
        _downloadButton = new Button { Style = AppStyle("AccentButtonStyle") };
        _downloadButton.Click += async (_, _) => await DownloadAsync();
        _cancelButton = new Button { Content = "Cancel" };
        HoverTooltip.SetText(_cancelButton, "Cancel the download");
        _cancelButton.Click += (_, _) => _services.LocalModels.CancelDownload();
        _readyLabel = StatusLabel("\uE930", "Ready");
        _localTrailing = new ContentControl { IsTabStop = false, VerticalAlignment = VerticalAlignment.Center };

        var name = new StackPanel { Spacing = 4 };
        name.Children.Add(new TextBlock { Text = _model.DisplayName, Style = AppStyle("BodyStrongTextBlockStyle") });
        name.Children.Add(new TextBlock { Text = $"~{SizeText(_model.Bytes)}", Style = _style("CaptionSecondaryTextStyle") });
        var top = new Grid { ColumnSpacing = 12 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.Children.Add(name);
        Grid.SetColumn(_localTrailing, 1);
        top.Children.Add(_localTrailing);

        _progressBar = new ProgressBar { Maximum = 1 };
        _progressText = new TextBlock { Style = _style("CaptionSecondaryTextStyle") };
        _progressPanel = new StackPanel { Spacing = 3 };
        _progressPanel.Children.Add(_progressBar);
        _progressPanel.Children.Add(_progressText);
        _localError = Note("\uE7BA", "CautionIconStyle", "");

        _localCard = Card(top, _progressPanel, _localError);

        // Cloud API key card.
        _providerBox = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var (kind, _) in CloudProviders) _providerBox.Items.Add(kind.DisplayName());
        _providerBox.SelectedIndex = 0;
        AutomationProperties.SetName(_providerBox, "Provider");
        _providerBox.SelectionChanged += (_, _) => OnProviderChanged();
        var providerRow = new Grid { ColumnSpacing = 8 };
        providerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        providerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        providerRow.Children.Add(new TextBlock { Text = "Provider", VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(_providerBox, 1);
        providerRow.Children.Add(_providerBox);

        _actionNote = Secondary("");
        _keyLink = new HyperlinkButton { Content = "Get an API key ↗", Padding = new Thickness(0, 2, 0, 2) };
        var keyLinkPanel = new StackPanel { Spacing = 4 };
        keyLinkPanel.Children.Add(_keyLink);
        keyLinkPanel.Children.Add(Secondary("Register an account, create a new API key, then paste it below."));

        _keyBox = new PasswordBox { PlaceholderText = "API key", HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(_keyBox, "API key");
        _keyBox.PasswordChanged += (_, _) => RefreshSaveButton();
        // Enter saves (the wizard leaves Enter to a focused password field).
        _keyBox.PreviewKeyDown += async (_, e) =>
        {
            if (e.Key != VirtualKey.Enter) return;
            e.Handled = true;
            await SaveAndVerifyAsync();
        };
        _saveButton = new Button { Content = "Save & Verify", Style = AppStyle("AccentButtonStyle") };
        _saveButton.Click += async (_, _) => await SaveAndVerifyAsync();
        var keyRow = new Grid { ColumnSpacing = 8 };
        keyRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        keyRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        keyRow.Children.Add(_keyBox);
        Grid.SetColumn(_saveButton, 1);
        keyRow.Children.Add(_saveButton);

        _verifyingPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        _verifyingPanel.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        _verifyingPanel.Children.Add(new TextBlock { Text = "Verifying…", Style = _style("CaptionSecondaryTextStyle") });

        _keyPreview = new TextBlock
        {
            Style = _style("CaptionSecondaryTextStyle"),
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            IsTextSelectionEnabled = false,
        };
        _savedHint = new StackPanel { Spacing = 4 };
        _savedHint.Children.Add(Secondary("A key is already saved. Paste a new one to replace it."));
        _savedHint.Children.Add(_keyPreview);
        _savedLabel = StatusLabel("\uE930", "API key saved");
        _cloudError = Note("\uE783", "CriticalIconStyle", "");
        ((TextBlock)_cloudError.Children[1]).Style = _style("CriticalTextStyle");

        _cloudCard = Card(
            providerRow, _actionNote, keyLinkPanel, keyRow, _verifyingPanel, _savedHint, _savedLabel, _cloudError,
            Secondary(
                "For everyday selections, usage costs only a few cents per month — most users spend under a dollar. " +
                "You pay the provider directly; PopGuy adds nothing."));

        _branch = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch, IsTabStop = false };
        Root.Children.Add(_branch);

        _services.LocalModels.Changed += OnLocalModelsChanged;
        ResetCloud();
        ShowMode();
        _ = _services.LocalModels.RefreshAsync();
    }

    /// <summary>The wizard closed: stops listening and drops a key check in flight (a started download goes on).</summary>
    internal void Detach()
    {
        _detached = true;
        _services.LocalModels.Changed -= OnLocalModelsChanged;
        _verify?.Cancel();
        _verify = null;
    }

    private ProviderKind CloudProvider => CloudProviders[Math.Max(0, _providerBox.SelectedIndex)].Kind;

    // Chooser.

    private void SetMode(ProviderMode mode)
    {
        if (_mode == mode) return;
        _mode = mode;
        var models = _services.LocalModels;
        if (mode == ProviderMode.Cloud)
        {
            models.PendingOnboardingMapId = null;
        }
        else
        {
            // A key check in flight is dropped (macOS): it would point the actions at the cloud provider.
            _verify?.Cancel();
            _verify = null;
            if (models.ActiveDownloadId == _model.Id) models.PendingOnboardingMapId = _model.Id;
        }
        ShowMode();
        PointAiActionsAtLocalIfReady();
    }

    private void ShowMode()
    {
        var local = _mode == ProviderMode.Local;
        ShowChoice(_localChoice, local);
        ShowChoice(_cloudChoice, !local);
        _branch.Content = local ? _localCard : _cloudCard;
        if (local) RefreshLocal();
        else RefreshCloud();
    }

    /// <summary>The selected card: accent border and a filled check (macOS checkmark.circle.fill), else a ring.</summary>
    private void ShowChoice((Button Button, Border Card, FontIcon Check) choice, bool selected)
    {
        choice.Card.Style = _style(selected ? "SelectedCardStyle" : "CardStyle");
        choice.Check.Glyph = selected ? "\uEC61" : "\uEA3A";
        choice.Check.Style = _style(selected ? "AccentIconStyle" : "SecondaryIconStyle");
        AutomationProperties.SetItemStatus(choice.Button, selected ? "Selected" : "");
    }

    /// <summary>A card button of the chooser (macOS modeCard): its icon, title, caption and a check when selected.</summary>
    private (Button Button, Border Card, FontIcon Check) ModeCard(ProviderMode mode, string glyph, string title, string caption)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = new FontIcon { Glyph = glyph, FontSize = 18, Style = _style("AccentIconStyle"), VerticalAlignment = VerticalAlignment.Top };
        grid.Children.Add(icon);
        var text = new StackPanel { Spacing = 4 };
        text.Children.Add(new TextBlock { Text = title, Style = AppStyle("BodyStrongTextBlockStyle") });
        text.Children.Add(Secondary(caption));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        var check = new FontIcon { FontSize = 16, VerticalAlignment = VerticalAlignment.Top };
        Grid.SetColumn(check, 2);
        grid.Children.Add(check);

        var card = new Border { Style = _style("CardStyle"), Child = grid };
        var button = new Button
        {
            Content = card,
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Style = AppStyle("SubtleButtonStyle"),
        };
        AutomationProperties.SetName(button, title);
        button.Click += (_, _) => SetMode(mode);
        return (button, card, check);
    }

    // Local AI.

    private void OnLocalModelsChanged()
    {
        if (_detached) return;
        if (_mode == ProviderMode.Local) RefreshLocal();
        PointAiActionsAtLocalIfReady();
    }

    private void RefreshLocal()
    {
        var models = _services.LocalModels;
        var downloading = models.ActiveDownloadId == _model.Id;
        var file = models.FileState(_model);
        var installed = file == LocalModelFile.Installed && !models.IsDeleting(_model);
        if (!models.IsLoaded)
        {
            // The files are being looked up: no control until then (as Settings → Providers → Local AI).
            _localTrailing.Content = null;
        }
        else if (downloading)
        {
            _localTrailing.Content = _cancelButton;
        }
        else if (installed)
        {
            _localTrailing.Content = _readyLabel;
        }
        else
        {
            var otherDownload = models.ActiveDownloadId is not null;
            _downloadButton.Content = file == LocalModelFile.Partial ? "Resume" : "Download";
            _downloadButton.IsEnabled = !otherDownload && !models.IsDeleting(_model);
            HoverTooltip.SetText(_downloadButton, otherDownload
                ? "Another model is downloading — wait for it to finish"
                : $"Download {_model.DisplayName}");
            _localTrailing.Content = _downloadButton;
        }

        _progressPanel.Visibility = downloading ? Visibility.Visible : Visibility.Collapsed;
        if (downloading)
        {
            // Indeterminate until the first bytes arrive.
            var fraction = Math.Clamp(models.DownloadFraction ?? 0, 0, 1);
            _progressBar.IsIndeterminate = fraction <= 0;
            _progressBar.Value = fraction;
            _progressText.Text = fraction > 0
                ? $"Downloading {_model.DisplayName}… {Math.Round(fraction * 100)}%"
                : $"Preparing {_model.DisplayName}…";
        }
        SetNote(_localError, models.Error);
    }

    private async Task DownloadAsync()
    {
        var models = _services.LocalModels;
        var download = models.DownloadAsync(_model);
        // Set once it started (DownloadAsync does nothing while another download runs).
        if (models.ActiveDownloadId == _model.Id) models.PendingOnboardingMapId = _model.Id;
        await download;
    }

    /// <summary>
    /// macOS pointAIActionsAtLocalIfReady: on a first launch only (a replayed guide never remaps actions), with Local AI
    /// chosen and the model on disk, Improve, Shorten, Proofread and Prompt run it.
    /// </summary>
    private void PointAiActionsAtLocalIfReady()
    {
        var models = _services.LocalModels;
        if (_detached || _mode != ProviderMode.Local || _services.Settings.Current.HasOnboarded) return;
        if (models.FileState(_model) != LocalModelFile.Installed) return;
        OnboardingActions.Save(_services.Settings, _services.Log.Write, s => OnboardingActions.WithAiActionsOn(s, ProviderKind.MlxLocal, _model.Id));
    }

    // Cloud API key.

    private void OnProviderChanged()
    {
        _verify?.Cancel();
        _verify = null;
        ResetCloud();
        RefreshCloud();
    }

    /// <summary>A new provider: no draft, no result; the saved key's preview is looked up again.</summary>
    private void ResetCloud()
    {
        _keyBox.Password = "";
        _keyBox.IsEnabled = true;
        SetNote(_cloudError, null);
        _savedLabel.Visibility = Visibility.Collapsed;
        _savedHint.Visibility = Visibility.Collapsed;
        _verifyingPanel.Visibility = Visibility.Collapsed;
        _ = RefreshKeyPreviewAsync(CloudProvider);
    }

    private void RefreshCloud()
    {
        var kind = CloudProvider;
        var url = CloudProviders.First(p => p.Kind == kind).KeyUrl;
        _keyLink.NavigateUri = new Uri(url);
        HoverTooltip.SetText(_keyLink, $"Open {kind.DisplayName()} to create an API key");
        _actionNote.Text = kind is ProviderKind.DeepL or ProviderKind.GoogleTranslate
            ? "Powers Translate."
            : "Powers Improve, Shorten, Proofread, and Prompt.";
        RefreshSaveButton();
    }

    private void RefreshSaveButton()
    {
        var verifying = _verify is not null;
        _saveButton.IsEnabled = !verifying && _keyBox.Password.Trim().Length > 0;
        HoverTooltip.SetText(_saveButton, verifying
            ? "Verifying the API key…"
            : "Verify the key with the provider and save it");
    }

    /// <summary>The saved key's masked preview, read off the UI thread (never the key itself); the latest read wins.</summary>
    private async Task RefreshKeyPreviewAsync(ProviderKind kind)
    {
        var read = ++_previewReads;
        var preview = await Task.Run(() => ProviderFeedback.MaskedPreview(ReadKey(kind)));
        if (_detached || read != _previewReads || kind != CloudProvider) return;
        _keyPreview.Text = preview ?? "";
        _savedHint.Visibility = preview is not null && _savedLabel.Visibility != Visibility.Visible
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    /// <summary>
    /// Checks the typed key with the provider (off the UI thread), then stores it and points the matching actions at
    /// the provider. A switch to Local AI or another provider meanwhile drops the result (macOS).
    /// </summary>
    private async Task SaveAndVerifyAsync()
    {
        var key = _keyBox.Password.Trim();
        if (key.Length == 0 || _verify is not null) return;
        var kind = CloudProvider;
        var run = _verify = new CancellationTokenSource();
        _keyBox.IsEnabled = false;
        _verifyingPanel.Visibility = Visibility.Visible;
        _savedLabel.Visibility = Visibility.Collapsed;
        SetNote(_cloudError, null);
        RefreshSaveButton();

        string? error;
        try
        {
            await Task.Run(() => ProviderKeyValidator.ValidateAsync(kind, key, ct: run.Token), run.Token);
            error = run.IsCancellationRequested ? null : await StoreAsync(kind, key);
        }
        catch (OperationCanceledException) when (run.IsCancellationRequested)
        {
            error = null;
        }
        catch (Exception e)
        {
            error = ProviderFeedback.ValidationMessage(e);
        }

        if (run.IsCancellationRequested || _detached)
        {
            run.Dispose();
            return;
        }
        _verify = null;
        run.Dispose();
        _keyBox.IsEnabled = true;
        _verifyingPanel.Visibility = Visibility.Collapsed;
        if (error is null)
        {
            _keyBox.Password = "";
            _keyPreview.Text = ProviderFeedback.MaskedPreview(key) ?? "";
            _savedHint.Visibility = Visibility.Collapsed;
            _savedLabel.Visibility = Visibility.Visible;
            _services.LocalModels.PendingOnboardingMapId = null;
            OnboardingActions.Save(_services.Settings, _services.Log.Write, s => OnboardingActions.WithCloudProvider(s, kind));
        }
        SetNote(_cloudError, error);
        RefreshSaveButton();
    }

    /// <summary>Null when stored; else the message. Failures are logged with the Win32 code only.</summary>
    private async Task<string?> StoreAsync(ProviderKind kind, string key)
    {
        try
        {
            await Task.Run(() => _services.Credentials.Set(SecretIds.Provider(kind), key));
            return null;
        }
        catch (Win32Exception e)
        {
            _services.Log.Write($"credentials: save failed for {kind}, error {e.NativeErrorCode}");
            return "Could not save the API key. Please try again.";
        }
        catch (ArgumentException)
        {
            return "The API key is too long.";
        }
    }

    /// <summary>Any thread. Null when none is saved or Credential Manager refused (logged, never the key).</summary>
    private string? ReadKey(ProviderKind kind)
    {
        try
        {
            return _services.Credentials.Get(SecretIds.Provider(kind));
        }
        catch (Win32Exception e)
        {
            _services.Log.Write($"credentials: read failed for {kind}, error {e.NativeErrorCode}");
            return null;
        }
    }

    // Building blocks.

    private Border Card(params UIElement[] children)
    {
        var panel = new StackPanel { Spacing = 10 };
        foreach (var child in children) panel.Children.Add(child);
        return new Border { Style = _style("CardStyle"), Child = panel };
    }

    private Grid Note(string glyph, string iconStyle, string text)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new FontIcon
        {
            Glyph = glyph,
            FontSize = 14,
            Style = _style(iconStyle),
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 1, 0, 0),
        });
        var body = new TextBlock { Text = text, Style = _style("CaptionSecondaryTextStyle") };
        Grid.SetColumn(body, 1);
        grid.Children.Add(body);
        return grid;
    }

    /// <summary>Shows <paramref name="message"/> in a note, or hides it.</summary>
    private static void SetNote(Grid note, string? message)
    {
        ((TextBlock)note.Children[1]).Text = message ?? "";
        note.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private StackPanel StatusLabel(string glyph, string text)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14, Style = _style("SuccessIconStyle") });
        panel.Children.Add(new TextBlock { Text = text, Style = _style("SuccessTextStyle") });
        return panel;
    }

    private TextBlock Secondary(string text) => new() { Text = text, Style = _style("SecondaryTextStyle") };

    private static Style AppStyle(string key) => (Style)Application.Current.Resources[key];

    /// <summary>"1.3 GB": a download's size in decimal gigabytes (as Settings → Providers → Local AI).</summary>
    private static string SizeText(long bytes) => $"{(bytes / 1e9).ToString("0.0", CultureInfo.CurrentCulture)} GB";

    private static string RamText(int megabytes) => $"{(megabytes / 1024.0).ToString("0.#", CultureInfo.CurrentCulture)} GB";
}

/// <summary>
/// Where the wizard points the built-in actions (macOS pointAIActionsAtLocalModel and pointActionsAtCloudProvider):
/// each config keeps its custom prompt and tone; a change is saved only when it differs.
/// </summary>
internal static class OnboardingActions
{
    /// <summary>Improve, Shorten, Proofread and Prompt on <paramref name="kind"/>'s <paramref name="model"/>; Translate untouched.</summary>
    public static AppSettings WithAiActionsOn(AppSettings s, ProviderKind kind, string model) => s with
    {
        ImproveConfig = s.ImproveConfig with { ProviderKind = kind, Model = model },
        ShortenConfig = s.ShortenConfig with { ProviderKind = kind, Model = model },
        ProofreadConfig = s.ProofreadConfig with { ProviderKind = kind, Model = model },
        PromptConfig = s.PromptConfig with { ProviderKind = kind, Model = model },
    };

    /// <summary>
    /// A verified cloud key: the AI providers take Improve, Shorten, Proofread and Prompt with their first curated model;
    /// DeepL and Google Translate take Translate (keeping its model, they use none).
    /// </summary>
    public static AppSettings WithCloudProvider(AppSettings s, ProviderKind kind) => kind switch
    {
        ProviderKind.DeepL or ProviderKind.GoogleTranslate => s with
        {
            TranslateConfig = s.TranslateConfig with
            {
                ProviderKind = kind,
                Model = kind.CuratedModels().FirstOrDefault() ?? s.TranslateConfig.Model,
            },
        },
        _ => WithAiActionsOn(s, kind, kind.CuratedModels().FirstOrDefault() ?? ""),
    };

    /// <summary>Saves <paramref name="change"/> when it changes anything; a failed write is logged.</summary>
    public static void Save(SettingsStore settings, Action<string> log, Func<AppSettings, AppSettings> change)
    {
        var current = settings.Current;
        if (change(current) == current) return;
        try
        {
            settings.Update(change);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            log($"settings: onboarding actions not saved, {e.GetType().Name}");
        }
    }
}
