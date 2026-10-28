using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.Json;
using PopGuy.Core.Settings;
using PopGuy.Core.Speak;
using PopGuy.Core.Speak.CloudTts;
using PopGuy.Core.Toolbar;
using PopGuy.Settings.ViewModels;
using VirtualKey = Windows.System.VirtualKey;

namespace PopGuy.Settings.Controls;

/// <summary>
/// The Speak rows of an action card (macOS ActionsView.swift: SpeakCardView for Speak, CustomSpeechFields for a custom
/// Speech action, VoiceTestButton). Speak writes <see cref="AppSettings.SpeakSettings"/> and the provider-wide
/// <see cref="AppSettings.TtsProviderConfigs"/>; a custom Speech action its own speech settings and single TTS config.
/// The engine picker lists the System voice and each cloud provider with a key in Credential Manager (Windows-only;
/// macOS lists them all), plus the saved engine. The saved keys and the system voices are read off the UI thread once
/// the rows are shown, so the pickers show at once and fill in. Preview and the voice tests play through the Settings
/// preview coordinator (never the toolbar's), one at a time across the cards. <see cref="ActionCard"/> takes the rows
/// (<see cref="TakeRows"/>) and calls <see cref="Update"/> on every settings change. UI thread only.
/// </summary>
public sealed partial class SpeakCard : UserControl
{
    private const string CustomModelTag = "Custom…";
    private const string VoiceTestTooltip = "Preview this voice";
    private const string CloudUnavailableTooltip = "Cloud voice unavailable — the System voice is being used instead.";
    private static readonly TimeSpan SaveDelay = TimeSpan.FromMilliseconds(500);

    private readonly SpeakAccent[] _accents = Enum.GetValues<SpeakAccent>();
    private readonly Dictionary<TtsProviderKind, bool> _modelCustom = [];
    private ActionsViewModel _model = null!;
    private ActionIdentifier _id = ActionIdentifier.Speak;
    private VoiceTest _voiceTest = null!;
    private VoiceTest _languageVoiceTest = null!;

    private IReadOnlySet<TtsProviderKind> _keyed = new HashSet<TtsProviderKind>();
    private IReadOnlyList<SystemVoice> _voices = [];
    private bool _voicesLoaded;

    // What each picker lists now (a voice list is null until its picker is first filled).
    private IReadOnlyList<SpeakEngineSelection> _engines = [];
    private IReadOnlyList<string> _models = [];
    private IReadOnlyList<string>? _cloudVoices;
    private IReadOnlyList<string>? _languageVoices;
    private IReadOnlyList<SystemVoice>? _accentVoices;
    private SpeakAccent _voiceLanguage;
    private SpeakAccent? _sampleAccent;
    private DispatcherQueueTimer? _modelTimer;
    private SpeakCoordinator? _listening;

    /// <summary>The controls are being set from the settings: their change events are not the user's.</summary>
    private bool _syncing;

    public SpeakCard()
    {
        InitializeComponent();
    }

    private bool IsSpeak => _id.Type == ActionIdentifierType.Speak;

    /// <summary>The preview rows of this card start with this key (one coordinator serves every card).</summary>
    private string RowKey => IsSpeak ? "speak" : _id.CustomId?.ToString() ?? "";

    /// <summary>Wires the rows of <paramref name="id"/> (Speak or a custom Speech action). Once, before the rows are taken.</summary>
    internal void Initialize(ActionsViewModel model, ActionIdentifier id)
    {
        _model = model;
        _id = id;
        var speak = ActionsViewModel.SpeakOf(model.Current, id);
        _voiceLanguage = speak.DefaultAccent;
        SampleBox.Text = speak.DefaultAccent.PreviewSample();
        _sampleAccent = speak.DefaultAccent;

        foreach (var accent in _accents)
        {
            AccentBox.Items.Add(accent.DisplayName());
            VoiceLanguageBox.Items.Add(accent.DisplayName());
        }
        AccentNote.Visibility = Shown(IsSpeak);

        EngineBox.SelectionChanged += (_, _) =>
        {
            if (_syncing || EngineBox.SelectedIndex < 0 || EngineBox.SelectedIndex >= _engines.Count) return;
            var engine = _engines[EngineBox.SelectedIndex];
            SaveSpeak("selectedEngine", s => s with { SelectedEngine = engine });
        };
        ModelBox.SelectionChanged += (_, _) => OnModelPicked();
        ModelText.TextChanged += (_, _) =>
        {
            if (_syncing) return;
            _modelTimer ??= CreateModelTimer();
            _modelTimer.Stop();
            _modelTimer.Start();
        };
        ModelText.LostFocus += (_, _) => CommitModelText();
        ModelText.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Enter) return;
            e.Handled = true;
            CommitModelText();
        };
        VoiceBox.SelectionChanged += (_, _) =>
        {
            if (_syncing || VoiceBox.SelectedIndex < 0 || Cloud() is not { } kind) return;
            var voice = VoiceBox.SelectedIndex == 0 ? null : _cloudVoices![VoiceBox.SelectedIndex - 1];
            SaveTts("defaultVoice", kind, c => c with { DefaultVoice = voice });
        };
        VoiceLanguageBox.SelectionChanged += (_, _) =>
        {
            if (_syncing || VoiceLanguageBox.SelectedIndex < 0) return;
            _voiceLanguage = _accents[VoiceLanguageBox.SelectedIndex];
            Update(_model.Current);
        };
        LanguageVoiceBox.SelectionChanged += (_, _) =>
        {
            if (_syncing || LanguageVoiceBox.SelectedIndex < 0 || Cloud() is not { } kind) return;
            var voice = LanguageVoiceBox.SelectedIndex == 0 ? null : _languageVoices![LanguageVoiceBox.SelectedIndex - 1];
            var language = _voiceLanguage.Bcp47();
            SaveTts("voiceOverrides", kind, c =>
            {
                var overrides = new Dictionary<string, string>(c.VoiceOverrides);
                if (voice is null) overrides.Remove(language);
                else overrides[language] = voice;
                return c with { VoiceOverrides = overrides };
            });
        };
        AccentBox.SelectionChanged += (_, _) =>
        {
            if (_syncing || AccentBox.SelectedIndex < 0) return;
            var accent = _accents[AccentBox.SelectedIndex];
            // A system voice belongs to its accent.
            SaveSpeak("defaultAccent", s => s.DefaultAccent == accent ? s : s with { DefaultAccent = accent, DefaultVoiceId = null });
        };
        SystemVoiceBox.SelectionChanged += (_, _) =>
        {
            if (_syncing || SystemVoiceBox.SelectedIndex < 0) return;
            var voice = SystemVoiceBox.SelectedIndex == 0 ? null : _accentVoices![SystemVoiceBox.SelectedIndex - 1].Id;
            SaveSpeak("defaultVoiceID", s => s with { DefaultVoiceId = voice });
        };
        SpeedSlider.ValueChanged += (_, e) =>
        {
            var level = (int)Math.Round(e.NewValue);
            SpeedValue.Text = $"{level} / 10";
            if (!_syncing) SaveSpeak("rate", s => s with { Rate = CustomActionEditing.RateForLevel(level) });
        };
        PitchSlider.ValueChanged += (_, e) =>
        {
            var level = (int)Math.Round(e.NewValue);
            PitchValue.Text = $"{level} / 10";
            if (!_syncing) SaveSpeak("pitch", s => s with { Pitch = CustomActionEditing.PitchForLevel(level) });
        };
        PreviewButton.Click += (_, _) => OnPreviewClicked();

        // OpenAI's voice plays the default accent's sample; a per-language voice its language's.
        _voiceTest = new VoiceTest(
            this, () => Cloud() is { } kind ? (kind, ActionsViewModel.SpeakOf(_model.Current, _id).DefaultAccent) : null, "voice");
        VoiceRow.Children.Add(_voiceTest.Root);
        _languageVoiceTest = new VoiceTest(this, () => Cloud() is { } kind ? (kind, _voiceLanguage) : null, "language");
        LanguageVoicesRow.Children.Add(_languageVoiceTest.Root);

        // Shown rows read the saved keys and voices again (a key may have been added on the Providers page) and follow
        // the preview. A row taken out and put back in one tick may load before it unloads.
        EngineCard.Loaded += async (_, _) => await OnShownAsync();
        EngineCard.Unloaded += (_, _) =>
        {
            if (EngineCard.IsLoaded) return;
            StopOwnPreview();
            StopListening();
        };
    }

    /// <summary>
    /// The rows, out of this control, for the action card's expander: a custom Speech action has no per-language voices
    /// or system voice picker (macOS CustomSpeechFields). Once, after <see cref="Initialize"/>.
    /// </summary>
    internal IReadOnlyList<UIElement> TakeRows()
    {
        var rows = RowsPanel.Children.Where(row => IsSpeak || (row != LanguageVoicesCard && row != SystemVoiceCard)).ToList();
        RowsPanel.Children.Clear();
        return rows;
    }

    /// <summary>Every control shows <paramref name="current"/>, except the custom model being typed.</summary>
    internal void Update(AppSettings current)
    {
        _syncing = true;
        var speak = ActionsViewModel.SpeakOf(current, _id);
        var engine = speak.SelectedEngine;
        var kind = engine.CloudProvider;

        var engines = ActionsViewModel.EngineChoices(_keyed, engine);
        if (EngineBox.Items.Count == 0 || !engines.SequenceEqual(_engines))
        {
            _engines = engines;
            EngineBox.Items.Clear();
            foreach (var choice in engines) EngineBox.Items.Add(choice.DisplayName());
        }
        EngineBox.SelectedIndex = IndexOf(_engines, engine);
        EngineNote.Text = IsSpeak
            ? "Falls back to the System voice when the cloud key is missing, offline, or the text exceeds the cloud limit."
            : "Falls back to the System voice when the cloud key is missing or offline.";
        EngineNote.Visibility = Shown(kind is not null);
        PrivacyNote.Text = kind is null
            ? ""
            : $"Cloud speech sends the selected text to {engine.DisplayName()}'s servers. The local System voice keeps everything on-device.";
        PrivacyNote.Visibility = Shown(kind is not null);

        UpdateCloudRows(current, kind);

        AccentBox.SelectedIndex = Array.IndexOf(_accents, speak.DefaultAccent);
        UpdateSystemVoices(speak, kind);

        SpeedSlider.Value = CustomActionEditing.LevelForRate(speak.Rate);
        SpeedValue.Text = $"{(int)SpeedSlider.Value} / 10";
        SpeedNote.Text = IsSpeak
            ? "How fast synthesized speech plays. Lower is slower — useful for hearing each sound clearly."
            : "How fast the system voice speaks.";
        var pitchSupported = kind?.SupportsPitch() ?? true;
        PitchSlider.Value = CustomActionEditing.LevelForPitch(speak.Pitch);
        PitchValue.Text = $"{(int)PitchSlider.Value} / 10";
        PitchSlider.IsEnabled = pitchSupported;
        PitchNote.Text = pitchSupported
            ? "The system voice's pitch. 1.0 is its natural tone; higher sounds brighter, lower sounds deeper."
            : "The selected engine doesn't support a pitch override; speech plays at the provider's natural pitch.";

        // A new accent brings its own sample sentence (macOS onChange of defaultAccent).
        if (_sampleAccent != speak.DefaultAccent)
        {
            _sampleAccent = speak.DefaultAccent;
            SampleBox.Text = speak.DefaultAccent.PreviewSample();
        }
        _syncing = false;
        RefreshPreview();
    }

    /// <summary>The page goes: the custom model being typed is saved, and this card's preview stops.</summary>
    internal void Flush()
    {
        if (_modelTimer?.IsRunning == true) CommitModelText();
        StopOwnPreview();
    }

    /// <summary>The card goes: as <see cref="Flush"/>, and the preview is no longer followed.</summary>
    internal void Release()
    {
        Flush();
        StopListening();
    }

    // Cloud rows.

    private TtsProviderKind? Cloud() => ActionsViewModel.SpeakOf(_model.Current, _id).SelectedEngine.CloudProvider;

    private void UpdateCloudRows(AppSettings current, TtsProviderKind? kind)
    {
        var config = kind is { } k ? ActionsViewModel.TtsConfigOf(current, _id, k) : new TtsProviderConfig();

        // Model (OpenAI): a curated model, or Custom… with the text box.
        var usesModel = kind?.UsesModel() ?? false;
        ModelCard.Visibility = Shown(usesModel);
        var model = config.Model ?? kind?.DefaultModel() ?? "";
        if (kind is { } modelKind && usesModel)
        {
            var curated = modelKind.CuratedModels();
            if (ModelBox.Items.Count == 0 || !curated.SequenceEqual(_models))
            {
                _models = curated;
                ModelBox.Items.Clear();
                foreach (var id in curated) ModelBox.Items.Add(id);
                ModelBox.Items.Add(CustomModelTag);
            }
            if (!_modelCustom.ContainsKey(modelKind)) _modelCustom[modelKind] = !curated.Contains(model);
            var custom = _modelCustom[modelKind] || !curated.Contains(model);
            ModelBox.SelectedIndex = custom ? curated.Count : IndexOf(curated, model);
            ModelText.Visibility = Shown(custom);
            ModelText.PlaceholderText = modelKind.DefaultModel() ?? "model identifier";
            if (ModelText.FocusState == FocusState.Unfocused && _modelTimer?.IsRunning != true && ModelText.Text != (config.Model ?? ""))
                ModelText.Text = config.Model ?? "";
        }

        // One voice for every language (OpenAI).
        var modelVoices = kind?.CuratedVoices(model) ?? [];
        VoiceCard.Visibility = Shown(modelVoices.Count > 0);
        if (_cloudVoices is null || !modelVoices.SequenceEqual(_cloudVoices))
        {
            _cloudVoices = modelVoices;
            VoiceBox.Items.Clear();
            VoiceBox.Items.Add("Default (alloy)");
            foreach (var voice in modelVoices) VoiceBox.Items.Add(voice is "marin" or "cedar" ? $"{voice} — recommended" : voice);
        }
        // A saved voice the list lacks is sent as it is: the picker shows none rather than Default.
        VoiceBox.SelectedIndex = config.DefaultVoice is { } saved ? Picked(_cloudVoices, saved) : 0;

        // A voice per language (Google, Azure).
        var perLanguage = IsSpeak && kind is { } languageKind && languageKind.CuratedVoicesForLanguage("en-US").Count > 0;
        LanguageVoicesCard.Visibility = Shown(perLanguage);
        if (perLanguage)
        {
            VoiceLanguageBox.SelectedIndex = Array.IndexOf(_accents, _voiceLanguage);
            var language = _voiceLanguage.Bcp47();
            var voices = kind!.Value.CuratedVoicesForLanguage(language);
            if (_languageVoices is null || !voices.SequenceEqual(_languageVoices))
            {
                _languageVoices = voices;
                LanguageVoiceBox.Items.Clear();
                LanguageVoiceBox.Items.Add("Default");
                foreach (var voice in voices) LanguageVoiceBox.Items.Add(voice);
            }
            LanguageVoiceBox.SelectedIndex = config.VoiceOverrides.TryGetValue(language, out var chosen) ? Picked(_languageVoices, chosen) : 0;
        }
    }

    /// <summary>A curated model is saved at once; Custom… shows the text box (macOS isModelCustom).</summary>
    private void OnModelPicked()
    {
        if (_syncing || ModelBox.SelectedIndex < 0 || Cloud() is not { } kind) return;
        if (ModelBox.SelectedIndex >= _models.Count)
        {
            _modelCustom[kind] = true;
            Update(_model.Current);
            return;
        }
        _modelCustom[kind] = false;
        var model = _models[ModelBox.SelectedIndex];
        SaveTts("model", kind, c => (c with { Model = model }).ClearingInvalidDefaultVoice(kind.CuratedVoices(model)));
    }

    /// <summary>The custom model (trimmed; empty means the default model); a voice the model lacks is cleared.</summary>
    private void CommitModelText()
    {
        _modelTimer?.Stop();
        if (Cloud() is not { } kind || !kind.UsesModel()) return;
        var text = ModelText.Text.Trim();
        var model = text.Length == 0 ? null : text;
        if (ActionsViewModel.TtsConfigOf(_model.Current, _id, kind).Model == model) return;
        var effective = model ?? kind.DefaultModel() ?? "";
        SaveTts("model", kind, c => (c with { Model = model }).ClearingInvalidDefaultVoice(kind.CuratedVoices(effective)));
    }

    private DispatcherQueueTimer CreateModelTimer()
    {
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = SaveDelay;
        timer.IsRepeating = false;
        timer.Tick += (sender, _) =>
        {
            sender.Stop();
            CommitModelText();
        };
        return timer;
    }

    // System voice.

    /// <summary>The voices of the accent's language; with none, the picker hides and the download note shows.</summary>
    private void UpdateSystemVoices(SpeakSettings speak, TtsProviderKind? kind)
    {
        if (!IsSpeak) return;
        var voices = ActionsViewModel.VoicesFor(_voices, speak.DefaultAccent);
        if (_accentVoices is null || !voices.SequenceEqual(_accentVoices))
        {
            _accentVoices = voices;
            SystemVoiceBox.Items.Clear();
            SystemVoiceBox.Items.Add("Default (best available)");
            foreach (var voice in voices) SystemVoiceBox.Items.Add($"{voice.DisplayName} — {voice.Language}");
        }
        // A saved voice that is not installed (another PC, a macOS id) plays the default voice of the language.
        var index = speak.DefaultVoiceId is { } id ? _accentVoices.ToList().FindIndex(v => v.Id == id) : -1;
        SystemVoiceBox.SelectedIndex = index + 1;
        var none = _voicesLoaded && voices.Count == 0;
        SystemVoiceBox.Visibility = Shown(!none);
        NoVoicesNote.Visibility = Shown(none);
        FallbackWarning.Visibility = Shown(kind is not null);
    }

    // Shown rows.

    private async Task OnShownAsync()
    {
        StartListening();
        var keyed = _model.SavedTtsKeysAsync();
        var voices = IsSpeak ? _model.SystemVoicesAsync() : Task.FromResult<IReadOnlyList<SystemVoice>>([]);
        _keyed = await keyed;
        _voices = await voices;
        _voicesLoaded = true;
        Update(_model.Current);
    }

    // Preview (macOS SpeakPreviewRow, CustomSpeechPreviewRow, VoiceTestButton).

    private void StartListening()
    {
        if (_listening is not null || _model.SpeakPreview is not { } preview) return;
        _listening = preview;
        preview.Changed += OnPreviewChanged;
        RefreshPreview();
    }

    private void StopListening()
    {
        if (_listening is null) return;
        _listening.Changed -= OnPreviewChanged;
        _listening = null;
    }

    /// <summary>Raised on any thread.</summary>
    private void OnPreviewChanged() => DispatcherQueue.TryEnqueue(RefreshPreview);

    /// <summary>The sample with the card's engine, voice and accent; Stop while this card's preview loads or plays.</summary>
    private void OnPreviewClicked()
    {
        var row = RowKey + ":preview";
        if (IsPlaying(row))
        {
            _model.StopPreview();
            return;
        }
        var current = _model.Current;
        var speak = ActionsViewModel.SpeakOf(current, _id);
        var config = speak.SelectedEngine.CloudProvider is { } kind
            ? ActionsViewModel.TtsConfigOf(current, _id, kind)
            : new TtsProviderConfig();
        _model.Preview(row, SampleBox.Text, speak.DefaultAccent, speak, config);
    }

    /// <summary>A voice test: the accent's sample with <paramref name="kind"/>'s saved voice for <paramref name="accent"/>.</summary>
    private void OnVoiceTestClicked(string row, TtsProviderKind kind, SpeakAccent accent)
    {
        if (IsPlaying(row))
        {
            _model.StopPreview();
            return;
        }
        var current = _model.Current;
        var speak = ActionsViewModel.SpeakOf(current, _id) with { SelectedEngine = SpeakEngineSelection.Cloud(kind) };
        _model.Preview(row, accent.PreviewSample(), accent, speak, ActionsViewModel.TtsConfigOf(current, _id, kind));
    }

    private bool IsPlaying(string row) =>
        _listening is { } preview && preview.Phase != SpeakPhase.Idle && _model.ActivePreviewRow == row;

    private void StopOwnPreview() => _model.StopPreview(RowKey + ":");

    private void RefreshPreview()
    {
        var phase = _listening?.Phase ?? SpeakPhase.Idle;
        var fellBack = _listening?.DidFallBackToSystem ?? false;
        var active = IsPlaying(RowKey + ":preview");
        PreviewButton.IsEnabled = _listening is not null;
        PreviewIcon.Glyph = active ? "" : "";
        PreviewIcon.Visibility = Shown(!(active && phase == SpeakPhase.Loading));
        PreviewRing.IsActive = active && phase == SpeakPhase.Loading;
        PreviewRing.Visibility = Shown(PreviewRing.IsActive);
        PreviewLabel.Text = active ? "Stop" : "Preview";
        AutomationProperties.SetName(PreviewButton, PreviewLabel.Text);
        PreviewFallbackText.Visibility = Shown(active && fellBack);
        _voiceTest.Refresh(phase, fellBack);
        _languageVoiceTest.Refresh(phase, fellBack);
    }

    // Saving.

    private void SaveSpeak(string key, Func<SpeakSettings, SpeakSettings> change) =>
        Save(key, s => ActionsViewModel.WithSpeak(s, _id, change));

    private void SaveTts(string key, TtsProviderKind kind, Func<TtsProviderConfig, TtsProviderConfig> change) =>
        Save(key, s => ActionsViewModel.WithTtsConfig(s, _id, kind, change));

    /// <summary>Saves one change; a failed write is logged and the controls go back to the saved settings.</summary>
    private void Save(string key, Func<AppSettings, AppSettings> change)
    {
        if (_syncing) return;
        if (!_model.Save(key, change)) Update(_model.Current);
    }

    private static Visibility Shown(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>The picker index of <paramref name="voice"/> after the Default entry, or none (-1) when it is not listed.</summary>
    private static int Picked(IReadOnlyList<string> voices, string voice) => IndexOf(voices, voice) is var i and >= 0 ? i + 1 : -1;

    private static int IndexOf<T>(IReadOnlyList<T> list, T item)
    {
        for (var i = 0; i < list.Count; i++)
        {
            if (EqualityComparer<T>.Default.Equals(list[i], item)) return i;
        }
        return -1;
    }

    /// <summary>
    /// A cloud voice's test button (macOS VoiceTestButton): plays the accent's sample with the provider's saved voice;
    /// a spinner while it loads, Stop while it plays, and "cloud isn't available" when the System voice stood in.
    /// </summary>
    private sealed class VoiceTest
    {
        private readonly SpeakCard _card;
        private readonly Func<(TtsProviderKind Kind, SpeakAccent Accent)?> _target;
        private readonly string _name;
        private readonly Button _button;
        private readonly FontIcon _icon = new() { FontSize = 14, Glyph = "" };
        private readonly ProgressRing _ring = new() { Width = 16, Height = 16, IsActive = false, Visibility = Visibility.Collapsed };
        private readonly StackPanel _fallback = new() { Orientation = Orientation.Horizontal, Spacing = 3, VerticalAlignment = VerticalAlignment.Center };

        public VoiceTest(SpeakCard card, Func<(TtsProviderKind Kind, SpeakAccent Accent)?> target, string name)
        {
            _card = card;
            _target = target;
            _name = name;
            var glyphs = new Grid { Width = 16, Height = 16 };
            glyphs.Children.Add(_icon);
            glyphs.Children.Add(_ring);
            _button = new Button
            {
                Content = glyphs,
                Style = (Style)Application.Current.Resources["SubtleButtonStyle"],
                VerticalAlignment = VerticalAlignment.Center,
            };
            AutomationProperties.SetName(_button, VoiceTestTooltip);
            HoverTooltip.SetText(_button, VoiceTestTooltip);
            _button.Click += (_, _) =>
            {
                if (_target() is { } t) _card.OnVoiceTestClicked(Row(t.Kind, t.Accent), t.Kind, t.Accent);
            };

            var caution = new FontIcon
            {
                FontSize = 12,
                Glyph = "",
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SystemFillColorCautionBrush"],
            };
            _fallback.Children.Add(caution);
            _fallback.Children.Add(new TextBlock
            {
                Text = "cloud isn't available",
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                VerticalAlignment = VerticalAlignment.Center,
            });
            _fallback.Visibility = Visibility.Collapsed;
            AutomationProperties.SetName(_fallback, "Cloud voice unavailable, using System voice");
            HoverTooltip.SetText(_fallback, CloudUnavailableTooltip);

            Root.Children.Add(_button);
            Root.Children.Add(_fallback);
        }

        public StackPanel Root { get; } = new() { Orientation = Orientation.Horizontal, Spacing = 4 };

        /// <summary>The row id (macOS rowID): the card, the provider, then "voice" or the language played.</summary>
        private string Row(TtsProviderKind kind, SpeakAccent accent) =>
            $"{_card.RowKey}:{RawValueEnumConverter<TtsProviderKind>.ToRaw(kind)}:{(_name == "voice" ? _name : accent.Bcp47())}";

        public void Refresh(SpeakPhase phase, bool fellBack)
        {
            var active = _target() is { } t && _card.IsPlaying(Row(t.Kind, t.Accent));
            _button.IsEnabled = _card._listening is not null;
            _icon.Glyph = active && phase == SpeakPhase.Playing ? "" : "";
            _icon.Visibility = Shown(!(active && phase == SpeakPhase.Loading));
            _ring.IsActive = active && phase == SpeakPhase.Loading;
            _ring.Visibility = Shown(_ring.IsActive);
            _fallback.Visibility = Shown(active && fellBack);
            HoverTooltip.SetText(_button, active && fellBack ? CloudUnavailableTooltip : VoiceTestTooltip);
        }
    }
}
