using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.Settings;
using PopGuy.Core.Speak;
using PopGuy.Core.Speak.CloudTts;
using PopGuy.Settings.ViewModels;
using Windows.Storage.Pickers;
using WinRT.Interop;
using VirtualKey = Windows.System.VirtualKey;

namespace PopGuy.Settings.Controls;

/// <summary>
/// The Look up rows of an action card (macOS ActionsView.swift DictionaryConfigFields, for Look up and a custom
/// Dictionary action; for Look up also the providers and the Babylon card of macOS's Providers tab, e52e65c's
/// enable-all switch included). Look up writes <see cref="AppSettings.DictionaryConfig"/>, a custom Dictionary action
/// its own config (its provider is picked in the Add/Edit panel). The engine picker lists the System voice and each
/// cloud provider with a key in Credential Manager, plus the saved engine (as the Speak card). The saved keys and the
/// system voices are read off the UI thread once the rows are shown. Load picks .bgl files (the Settings window owns
/// the picker) and indexes them off the UI thread before they are added; each file's index status (its entry count,
/// "Indexing…" when a check takes over 150 ms, or why it cannot be indexed) is checked off the UI thread when the rows
/// are shown, which also rebuilds an index the file outdated. <see cref="ActionCard"/> takes the rows
/// (<see cref="TakeRows"/>) and calls <see cref="Update"/> on every settings change. UI thread only.
/// </summary>
public sealed partial class DictionaryCard : UserControl
{
    private const string LanguageTooltip = "Target language used by online providers (e.g. English, Vietnamese, French).";
    private const string AudioTooltip =
        "When no native source audio is available, try Free Dictionary API pronunciation before falling back to the selected TTS engine.";
    private const string EnableAllTooltip = "Enable or disable all Babylon dictionaries";
    private static readonly TimeSpan SaveDelay = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan IndexingDelay = TimeSpan.FromMilliseconds(150);

    private readonly SpeakAccent[] _accents = Enum.GetValues<SpeakAccent>();
    private readonly IReadOnlyList<TargetLanguage> _languages = TargetLanguages.All;
    private readonly Dictionary<Guid, FileRow> _files = [];
    private ActionsViewModel _model = null!;
    private ActionIdentifier _id = ActionIdentifier.Dictionary;

    private IReadOnlySet<TtsProviderKind> _keyed = new HashSet<TtsProviderKind>();
    private IReadOnlyList<SystemVoice> _voices = [];
    private bool _voicesLoaded;
    private IReadOnlyList<SpeakEngineSelection> _engines = [];
    private IReadOnlyList<SystemVoice>? _accentVoices;

    /// <summary>A picker is open or picked files are being indexed: another Load waits for it.</summary>
    private bool _loading;
    private string? _importError;

    /// <summary>The controls are being set from the settings: their change events are not the user's.</summary>
    private bool _syncing;

    public DictionaryCard()
    {
        InitializeComponent();
    }

    private bool IsLookup => _id.Type == ActionIdentifierType.Dictionary;

    /// <summary>Wires the rows of <paramref name="id"/> (Look up or a custom Dictionary action). Once, before the rows are taken.</summary>
    internal void Initialize(ActionsViewModel model, ActionIdentifier id)
    {
        _model = model;
        _id = id;
        foreach (var language in _languages) LanguageBox.Items.Add(language.Name);
        foreach (var accent in _accents) AccentBox.Items.Add(accent.DisplayName());
        HoverTooltip.SetText(LanguageCard, LanguageTooltip);
        HoverTooltip.SetText(AudioCard, AudioTooltip);
        HoverTooltip.SetText(EnableAllHost, EnableAllTooltip);

        LanguageBox.SelectionChanged += (_, _) =>
        {
            if (_syncing || LanguageBox.SelectedIndex < 0) return;
            var code = _languages[LanguageBox.SelectedIndex].Code;
            SaveDictionary("definitionLanguage", c => c with { DefinitionLanguage = code });
        };
        EngineBox.SelectionChanged += (_, _) =>
        {
            if (_syncing || EngineBox.SelectedIndex < 0 || EngineBox.SelectedIndex >= _engines.Count) return;
            var engine = _engines[EngineBox.SelectedIndex];
            SaveDictionary("selectedEngine", c => c with { SpeakSettings = c.SpeakSettings with { SelectedEngine = engine } });
        };
        AccentBox.SelectionChanged += (_, _) =>
        {
            if (_syncing || AccentBox.SelectedIndex < 0) return;
            var accent = _accents[AccentBox.SelectedIndex];
            // A system voice belongs to its accent (macOS: a new accent clears the voice and sets the speech accent too).
            SaveDictionary("accent", c => c.Accent == accent ? c : c with
            {
                Accent = accent,
                SpeakSettings = c.SpeakSettings with { DefaultAccent = accent, DefaultVoiceId = null },
            });
        };
        SystemVoiceBox.SelectionChanged += (_, _) =>
        {
            if (_syncing || SystemVoiceBox.SelectedIndex < 0) return;
            var voice = SystemVoiceBox.SelectedIndex == 0 ? null : _accentVoices![SystemVoiceBox.SelectedIndex - 1].Id;
            SaveDictionary("defaultVoiceID", c => c with { SpeakSettings = c.SpeakSettings with { DefaultVoiceId = voice } });
        };
        AudioToggle.Toggled += (_, _) =>
            SaveDictionary("dictionaryAudioEnabled", c => c with
            {
                SpeakSettings = c.SpeakSettings with { DictionaryAudioEnabled = AudioToggle.IsOn },
            });
        SpeedSlider.ValueChanged += (_, e) =>
        {
            var level = (int)Math.Round(e.NewValue);
            SpeedValue.Text = $"{level} / 10";
            if (!_syncing)
                SaveDictionary("rate", c => c with { SpeakSettings = c.SpeakSettings with { Rate = CustomActionEditing.RateForLevel(level) } });
        };
        PitchSlider.ValueChanged += (_, e) =>
        {
            var level = (int)Math.Round(e.NewValue);
            PitchValue.Text = $"{level} / 10";
            if (!_syncing)
                SaveDictionary("pitch", c => c with { SpeakSettings = c.SpeakSettings with { Pitch = CustomActionEditing.PitchForLevel(level) } });
        };

        EnableAllToggle.Toggled += (_, _) =>
        {
            var on = EnableAllToggle.IsOn;
            Save("babylonDictionaries", s => s with { BabylonDictionaries = [.. s.BabylonDictionaries.Select(d => d with { IsEnabled = on })] });
        };
        LoadButton.Click += async (_, _) => await LoadAsync();

        // Shown rows read the saved keys and voices again (a key may have been added on the Providers page), and the
        // files' index status. A row taken out and put back in one tick may load before it unloads.
        EngineCard.Loaded += async (_, _) => await OnShownAsync();
        FilesCard.Loaded += (_, _) =>
        {
            foreach (var row in _files.Values) _ = row.CheckAsync();
        };
    }

    /// <summary>
    /// The rows, out of this control, for the action card's expander: a custom Dictionary action has no providers or
    /// Babylon files (macOS DictionaryConfigFields). Once, after <see cref="Initialize"/>.
    /// </summary>
    internal IReadOnlyList<UIElement> TakeRows()
    {
        var rows = RowsPanel.Children.Where(row => IsLookup || (row != ProvidersCard && row != BabylonCard && row != FilesCard)).ToList();
        RowsPanel.Children.Clear();
        return rows;
    }

    /// <summary>Every control shows <paramref name="current"/>, except a language code being typed.</summary>
    internal void Update(AppSettings current)
    {
        _syncing = true;
        var config = ActionsViewModel.DictionaryOf(current, _id);
        var speak = config.SpeakSettings;
        var engine = speak.SelectedEngine;

        // An off-list code shows as English (macOS TargetLanguage(bcp47:) coercion).
        LanguageBox.SelectedIndex = IndexOf(_languages, TargetLanguages.FromCode(config.DefinitionLanguage));

        var engines = ActionsViewModel.EngineChoices(_keyed, engine);
        if (EngineBox.Items.Count == 0 || !engines.SequenceEqual(_engines))
        {
            _engines = engines;
            EngineBox.Items.Clear();
            foreach (var choice in engines) EngineBox.Items.Add(choice.DisplayName());
        }
        EngineBox.SelectedIndex = IndexOf(_engines, engine);

        AccentBox.SelectedIndex = Array.IndexOf(_accents, config.Accent);
        UpdateSystemVoices(config);
        AudioToggle.IsOn = speak.DictionaryAudioEnabled;

        SpeedSlider.Value = CustomActionEditing.LevelForRate(speak.Rate);
        SpeedValue.Text = $"{(int)SpeedSlider.Value} / 10";
        PitchSlider.Value = CustomActionEditing.LevelForPitch(speak.Pitch);
        PitchValue.Text = $"{(int)PitchSlider.Value} / 10";
        // The cloud engines that take no pitch play at their natural pitch.
        PitchSlider.IsEnabled = engine.CloudProvider?.SupportsPitch() ?? true;

        if (IsLookup) UpdateBabylon(current.BabylonDictionaries);
        _syncing = false;
    }

    /// <summary>The page goes: the language codes being typed are saved.</summary>
    internal void Flush()
    {
        foreach (var row in _files.Values) row.Flush();
    }

    /// <summary>The card goes: as <see cref="Flush"/>.</summary>
    internal void Release() => Flush();

    // System voice.

    /// <summary>The voices of the accent's language; with none, the picker hides and the note shows.</summary>
    private void UpdateSystemVoices(DictionaryConfig config)
    {
        var voices = ActionsViewModel.VoicesFor(_voices, config.Accent);
        if (_accentVoices is null || !voices.SequenceEqual(_accentVoices))
        {
            _accentVoices = voices;
            SystemVoiceBox.Items.Clear();
            SystemVoiceBox.Items.Add("Default (best available)");
            foreach (var voice in voices) SystemVoiceBox.Items.Add($"{voice.DisplayName} — {voice.Language}");
        }
        // A saved voice that is not installed (another PC, a macOS id) plays the default voice of the language.
        var id = config.SpeakSettings.DefaultVoiceId;
        var index = id is null ? -1 : _accentVoices.ToList().FindIndex(v => v.Id == id);
        SystemVoiceBox.SelectedIndex = index + 1;
        var none = _voicesLoaded && voices.Count == 0;
        SystemVoiceBox.Visibility = Shown(!none);
        NoVoicesNote.Visibility = Shown(none);
    }

    private async Task OnShownAsync()
    {
        var keyed = _model.SavedTtsKeysAsync();
        var voices = _model.SystemVoicesAsync();
        _keyed = await keyed;
        _voices = await voices;
        _voicesLoaded = true;
        Update(_model.Current);
    }

    // Babylon files (macOS SettingsView.swift: the Babylon card, loadBGLDictionaries, BabylonDictionarySettingsRow).

    private void UpdateBabylon(IReadOnlyList<BabylonDictionary> dictionaries)
    {
        EnableAllToggle.IsOn = dictionaries.Any(d => d.IsEnabled);
        EnableAllToggle.IsEnabled = dictionaries.Count > 0;
        LoadButton.IsEnabled = !_loading;
        ImportErrorText.Text = _importError ?? "";
        ImportErrorLine.Visibility = Shown(_importError is not null);
        EmptyLine.Visibility = Shown(dictionaries.Count == 0);

        var ids = dictionaries.Select(d => d.Id).ToList();
        foreach (var gone in _files.Keys.Except(ids).ToList())
        {
            _files[gone].Flush();
            _files.Remove(gone);
        }
        foreach (var dictionary in dictionaries)
        {
            if (!_files.TryGetValue(dictionary.Id, out var row))
            {
                row = new FileRow(this, dictionary);
                _files[dictionary.Id] = row;
                if (FilesCard.IsLoaded) _ = row.CheckAsync();
            }
            row.Show(dictionary);
        }
        var ordered = ids.Select(id => _files[id].Root).ToList();
        if (!ordered.SequenceEqual(FilesPanel.Children.OfType<Border>()) || FilesPanel.Children.Count != ordered.Count)
        {
            FilesPanel.Children.Clear();
            foreach (var root in ordered) FilesPanel.Children.Add(root);
        }
    }

    /// <summary>
    /// Load (macOS loadBGLDictionaries): .bgl files from a picker the Settings window owns; Load shows a spinner and
    /// "Indexing" at once while they are indexed off the UI thread, then the ones that indexed are added and the others'
    /// reasons show above the list.
    /// </summary>
    private async Task LoadAsync()
    {
        if (_loading || BabylonCard.XamlRoot?.ContentIslandEnvironment is not { } environment) return;
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, ViewMode = PickerViewMode.List };
        picker.FileTypeFilter.Add(".bgl");
        InitializeWithWindow.Initialize(picker, Win32Interop.GetWindowFromWindowId(environment.AppWindowId));
        _loading = true;
        try
        {
            var files = await picker.PickMultipleFilesAsync();
            var paths = files.Select(f => f.Path).Where(p => p is { Length: > 0 }).ToList();
            if (paths.Count == 0) return;
            _importError = null;
            ShowIndexing(true);
            _importError = await _model.AddBabylonAsync(paths);
        }
        catch (COMException)
        {
            // A picker Windows refused to show: nothing changes.
        }
        finally
        {
            _loading = false;
            ShowIndexing(false);
            Update(_model.Current);
        }
    }

    private void ShowIndexing(bool indexing)
    {
        LoadButton.IsEnabled = !indexing;
        LoadIcon.Visibility = Shown(!indexing);
        LoadRing.IsActive = indexing;
        LoadRing.Visibility = Shown(indexing);
        LoadLabel.Text = indexing ? "Indexing" : "Load";
        AutomationProperties.SetName(LoadButton, LoadLabel.Text);
    }

    // Saving.

    private void SaveDictionary(string key, Func<DictionaryConfig, DictionaryConfig> change) =>
        Save(key, s => ActionsViewModel.WithDictionary(s, _id, change));

    /// <summary>Saves one change; a failed write is logged and the controls go back to the saved settings.</summary>
    private void Save(string key, Func<AppSettings, AppSettings> change)
    {
        if (_syncing) return;
        if (!_model.Save(key, change)) Update(_model.Current);
    }

    private Style CardStyle(string key) => (Style)Resources[key];

    private static Visibility Shown(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    private static int IndexOf<T>(IReadOnlyList<T> list, T item)
    {
        for (var i = 0; i < list.Count; i++)
        {
            if (EqualityComparer<T>.Default.Equals(list[i], item)) return i;
        }
        return -1;
    }

    /// <summary>
    /// One .bgl file (macOS BabylonDictionarySettingsRow): its name and path, its switch and Remove, its index status,
    /// and its source and target language codes (stored for later use; empty means unspecified). A code is saved
    /// normalized 500 ms after the last keystroke, on Enter, or when its box loses focus.
    /// </summary>
    private sealed class FileRow
    {
        private readonly DictionaryCard _card;
        private readonly Guid _id;
        private readonly TextBlock _name = new() { FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
        private readonly TextBlock _path = new() { TextTrimming = TextTrimming.CharacterEllipsis };
        private readonly ToggleSwitch _enabled = new();
        private readonly ProgressRing _ring = new() { Width = 12, Height = 12, IsActive = false, Visibility = Visibility.Collapsed };
        private readonly FontIcon _caution = new() { Glyph = "\uE7BA", Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Top };
        private readonly TextBlock _status = new();
        private readonly LanguageBox _source;
        private readonly LanguageBox _target;
        private BabylonDictionary _dictionary;
        private bool _checking;
        private (long? Count, string? Error)? _result;

        public FileRow(DictionaryCard card, BabylonDictionary dictionary)
        {
            _card = card;
            _id = dictionary.Id;
            _dictionary = dictionary;
            _path.Style = card.CardStyle("CaptionStyle");
            _path.TextWrapping = TextWrapping.NoWrap;
            _status.Style = card.CardStyle("CaptionStyle");
            _caution.Style = card.CardStyle("CautionIconStyle");
            _caution.Margin = new Thickness(0, 2, 0, 0);
            AutomationProperties.SetName(_enabled, "Enabled");
            _enabled.Toggled += (_, _) =>
            {
                var on = _enabled.IsOn;
                _card.Save("babylonDictionaries", s => ActionsViewModel.WithBabylon(s, _id, d => d with { IsEnabled = on }));
            };
            var remove = new Button
            {
                Content = new FontIcon { Glyph = "\uE74D", Style = card.CardStyle("CriticalIconStyle") },
                Style = (Style)Application.Current.Resources["SubtleButtonStyle"],
                VerticalAlignment = VerticalAlignment.Center,
            };
            AutomationProperties.SetName(remove, "Remove dictionary");
            HoverTooltip.SetText(remove, "Remove dictionary");
            remove.Click += (_, _) => _card._model.RemoveBabylon(_id);
            _source = new LanguageBox(this, "en", "Source language", d => d.SourceLanguage, (d, code) => d with { SourceLanguage = code });
            _target = new LanguageBox(this, "vi", "Target language", d => d.TargetLanguage, (d, code) => d with { TargetLanguage = code });

            var names = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            names.Children.Add(_name);
            names.Children.Add(_path);
            var top = new Grid { ColumnSpacing = 8 };
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            top.Children.Add(names);
            Grid.SetColumn(_enabled, 1);
            top.Children.Add(_enabled);
            Grid.SetColumn(remove, 2);
            top.Children.Add(remove);

            var status = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            status.Children.Add(_ring);
            status.Children.Add(_caution);
            status.Children.Add(_status);

            var languages = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            languages.Children.Add(Caption("Source"));
            languages.Children.Add(_source.Box);
            languages.Children.Add(new FontIcon { FontSize = 10, Glyph = "\uE72A", VerticalAlignment = VerticalAlignment.Center });
            languages.Children.Add(Caption("Target"));
            languages.Children.Add(_target.Box);

            var body = new StackPanel { Spacing = 6 };
            body.Children.Add(top);
            body.Children.Add(status);
            body.Children.Add(languages);
            body.Children.Add(Caption("Language codes (ISO 639 / BCP-47), e.g. en, vi, fr, zh. Leave empty if unsure."));
            Root = new Border { Style = card.CardStyle("FileRowStyle"), Child = body };
        }

        public Border Root { get; }

        /// <summary>Shows <paramref name="dictionary"/> as saved, except a code being typed.</summary>
        public void Show(BabylonDictionary dictionary)
        {
            _dictionary = dictionary;
            _name.Text = DisplayName(dictionary);
            _path.Text = dictionary.FilePath;
            HoverTooltip.SetText(_path, dictionary.FilePath);
            AutomationProperties.SetName(_enabled, $"Enable {_name.Text}");
            _enabled.IsOn = dictionary.IsEnabled;
            _source.Show(dictionary);
            _target.Show(dictionary);
            ShowStatus();
        }

        public void Flush()
        {
            _source.Flush();
            _target.Flush();
        }

        /// <summary>
        /// The index's status off the UI thread (building it when missing or stale); "Indexing…" shows only when the
        /// check takes over 150 ms, so a valid index never flashes it. One check at a time.
        /// </summary>
        public async Task CheckAsync()
        {
            if (_checking) return;
            _checking = true;
            var status = _card._model.BabylonStatusAsync(_dictionary);
            if (await Task.WhenAny(status, Task.Delay(IndexingDelay)) != status)
            {
                _ring.IsActive = true;
                _ring.Visibility = Visibility.Visible;
                _caution.Visibility = Visibility.Collapsed;
                _status.Text = "Indexing…";
            }
            _result = await status;
            _checking = false;
            ShowStatus();
        }

        private void ShowStatus()
        {
            if (_checking && _ring.IsActive) return;
            _ring.IsActive = false;
            _ring.Visibility = Visibility.Collapsed;
            var error = _result?.Error;
            _caution.Visibility = Shown(error is not null);
            // Before the first check: the count saved when the file was added.
            var count = _result?.Count ?? _dictionary.EntryCount;
            _status.Text = error ?? (count == 1 ? "1 entry" : $"{count:N0} entries");
        }

        private void Save(Func<BabylonDictionary, BabylonDictionary> change) =>
            _card.Save("babylonDictionaries", s => ActionsViewModel.WithBabylon(s, _id, change));

        private TextBlock Caption(string text)
        {
            var caption = new TextBlock { Text = text, Style = _card.CardStyle("CaptionStyle") };
            caption.VerticalAlignment = VerticalAlignment.Center;
            return caption;
        }

        /// <summary>The trimmed display name, else the file name without its extension (macOS resolvedDisplayName).</summary>
        private static string DisplayName(BabylonDictionary dictionary) =>
            dictionary.DisplayName.Trim() is { Length: > 0 } name ? name
            : Path.GetFileNameWithoutExtension(dictionary.FilePath) is { Length: > 0 } file ? file
            : "Babylon Dictionary";

        /// <summary>A language code box: shows the saved code unless being typed; saves it normalized.</summary>
        private sealed class LanguageBox
        {
            private readonly FileRow _row;
            private readonly Func<BabylonDictionary, string> _read;
            private readonly Func<BabylonDictionary, string, BabylonDictionary> _write;
            private DispatcherQueueTimer? _timer;

            public LanguageBox(
                FileRow row, string placeholder, string name,
                Func<BabylonDictionary, string> read, Func<BabylonDictionary, string, BabylonDictionary> write)
            {
                _row = row;
                _read = read;
                _write = write;
                Box = new TextBox { PlaceholderText = placeholder, Width = 72, MaxLength = 40, VerticalAlignment = VerticalAlignment.Center };
                AutomationProperties.SetName(Box, name);
                Box.TextChanged += (_, _) =>
                {
                    // Raised after the change, so a code set from the settings is told apart by its text.
                    if (_row._card._syncing || Box.Text == _read(_row._dictionary)) return;
                    _timer ??= CreateTimer();
                    _timer.Stop();
                    _timer.Start();
                };
                Box.LostFocus += (_, _) => Commit();
                Box.KeyDown += (_, e) =>
                {
                    if (e.Key != VirtualKey.Enter) return;
                    e.Handled = true;
                    Commit();
                };
            }

            public TextBox Box { get; }

            public void Show(BabylonDictionary dictionary)
            {
                if (Box.FocusState != FocusState.Unfocused || _timer?.IsRunning == true) return;
                var code = _read(dictionary);
                if (Box.Text != code) Box.Text = code;
            }

            public void Flush()
            {
                if (_timer?.IsRunning == true) Commit();
            }

            private void Commit()
            {
                _timer?.Stop();
                var code = ActionsViewModel.NormalizedLanguageCode(Box.Text);
                if (code != _read(_row._dictionary)) _row.Save(d => _write(d, code));
                // Typed "EN_us" shows as saved ("en-us") once the box is left.
                if (Box.FocusState == FocusState.Unfocused && Box.Text != code) Box.Text = code;
            }

            private DispatcherQueueTimer CreateTimer()
            {
                var timer = Box.DispatcherQueue.CreateTimer();
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
}
