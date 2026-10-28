using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.Plugins;
using PopGuy.Core.Settings;
using PopGuy.Platform.Input;
using PopGuy.Services;
using PopGuy.Settings.Controls;
using PopGuy.Settings.Panels;
using PopGuy.Settings.ViewModels;
using Windows.Storage.Pickers;
using WinRT.Interop;
using CoreVirtualKeyStates = Windows.UI.Core.CoreVirtualKeyStates;
using VirtualKey = Windows.System.VirtualKey;

namespace PopGuy.Settings.Pages;

/// <summary>
/// Settings → Actions (macOS ActionsView.swift, spec-3 §5.3): the toolbar layout editor
/// (<see cref="ToolbarLayoutEditor"/>), the toolbar's Settings-button switch, the search box and type filter, then one
/// <see cref="ActionCard"/> per action in the action order (built-ins, Speak with its <see cref="SpeakCard"/> rows, Look
/// up with its <see cref="DictionaryCard"/> rows, and custom actions). Add action and a custom card's Edit open
/// <see cref="CustomActionEditPanel"/> in the window's <see cref="SlideOverPanel"/>. The navigation parameter is the AppServices. A card is built once and updated on every
/// settings change, so text being typed, a recording and the expansion survive; it is built again only when its custom
/// action's type, title, icon, description or origin changed. Search and filter only hide cards. While a card's
/// shortcut records, PopGuy's own hotkeys and chord are off (<see cref="AppServices.SetHotkeysSuspended"/>); after
/// each apply, a shortcut Windows refused shows on its card. A change from elsewhere shows while the page is open.
/// Export writes the custom actions to a JSON file; Import (a JSON file) and the plugin menu (a JSON or .popclipextz
/// file, a .popclipext folder, a pasted snippet) read off the UI thread, then show <see cref="PluginImportConsentDialog"/>
/// in the panel. Nothing imported runs or opens before the user adds it and clicks it. The library button opens
/// <see cref="ActionLibraryPanel"/>, whose Install adds a preset as a custom action.
/// </summary>
public sealed partial class ActionsPage : Page
{
    private const string SettingsButtonTooltip = "Settings stay available from the PopGuy tray icon";

    private readonly Dictionary<ActionIdentifier, (ActionCard Card, object Signature)> _cards = [];
    private AppServices? _services;
    private ActionsViewModel? _model;
    private bool _subscribed;
    private ActionTypeFilter _filter = ActionTypeFilter.All;

    /// <summary>A picker, dialog or read of an export or import is under way: another click waits for it.</summary>
    private bool _transferring;

    /// <summary>The controls are being set from the settings: their change events are not the user's.</summary>
    private bool _syncing;

    public ActionsPage()
    {
        InitializeComponent();
        SettingsButtonToggle.Toggled += (_, _) =>
            Save("showToolbarSettingsButton", s => s with { ShowToolbarSettingsButton = SettingsButtonToggle.IsOn });
        HoverTooltip.SetText(SettingsButtonToggle, SettingsButtonTooltip);
        AddButton.Click += (_, _) => OpenEditor(new CustomAction { Title = "", SystemPrompt = "" });
        HoverTooltip.SetText(AddButton, "Add action");
        ExportButton.Click += (_, _) => Transfer(ExportAsync);
        HoverTooltip.SetText(ExportButton, "Export custom actions");
        ImportButton.Click += (_, _) => Transfer(ImportActionsAsync);
        HoverTooltip.SetText(ImportButton, "Import custom actions");
        PluginButton.Flyout = PluginMenu();
        HoverTooltip.SetText(PluginButton, "Import plugin");
        LibraryButton.Click += (_, _) => OpenLibrary();
        HoverTooltip.SetText(LibraryButton, "Browse Action Library");

        foreach (var (_, name) in ActionsViewModel.Filters) TypeFilterBox.Items.Add(name);
        TypeFilterBox.SelectedIndex = 0;
        TypeFilterBox.SelectionChanged += (_, _) =>
        {
            if (TypeFilterBox.SelectedIndex < 0) return;
            _filter = ActionsViewModel.Filters[TypeFilterBox.SelectedIndex].Filter;
            ApplyFilter();
        };
        HoverTooltip.SetText(TypeFilterBox, "Filter actions by type");
        SearchBox.TextChanged += (_, _) => ApplyFilter();
        SearchBox.Loaded += (_, _) => AttachClearTooltip();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _services = e.Parameter as AppServices;
        if (_services is null || _model is not null) return;
        _model = new ActionsViewModel(
            _services.Settings, _services.Credentials, _services.Providers, _services.Log.Write,
            _services.SystemVoices, () => _services.SpeakPreview);
        LayoutEditor.Initialize(_model, _services);
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_services is null) return;
        if (!_subscribed)
        {
            _services.Settings.Changed += OnSettingsChanged;
            _services.HotkeysApplied += OnHotkeysApplied;
        }
        _subscribed = true;
        Refresh();
    }

    /// <summary>
    /// Text being typed is saved before the page goes. The window's first-show re-attach takes the page out and puts it
    /// back in one tick, and its Loaded may come before this Unloaded: a page still loaded keeps listening. (A recorder
    /// cancels itself when it really leaves, which turns the hotkeys back on.)
    /// </summary>
    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_services is null) return;
        foreach (var (card, _) in _cards.Values) card.Flush();
        if (IsLoaded) return;
        _services.Settings.Changed -= OnSettingsChanged;
        _services.HotkeysApplied -= OnHotkeysApplied;
        _subscribed = false;
    }

    /// <summary>Queued: a change may be saved from any thread.</summary>
    private void OnSettingsChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    /// <summary>Raised on the thread pool once the hotkeys are registered again.</summary>
    private void OnHotkeysApplied() => DispatcherQueue.TryEnqueue(RefreshStatus);

    /// <summary>Every control and card shows the current settings.</summary>
    private void Refresh()
    {
        if (_model is null) return;
        var current = _model.Current;
        _syncing = true;
        SettingsButtonToggle.IsOn = current.ShowToolbarSettingsButton;
        _syncing = false;
        ExportButton.IsEnabled = current.CustomActions.Count > 0;
        LayoutEditor.Refresh();
        SyncCards(current);
        foreach (var (card, _) in _cards.Values) card.Update(current);
        ApplyFilter();
        RefreshStatus();
    }

    // Cards.

    /// <summary>
    /// One card per action, in action order: a card whose signature still matches is kept, a changed or new one is
    /// built, a removed action's card is released. The panel is refilled only when the order changed.
    /// </summary>
    private void SyncCards(AppSettings current)
    {
        if (_model is null) return;
        var ids = ActionsViewModel.CardIds(current);
        foreach (var id in ids)
        {
            var signature = ActionCard.Signature(current, id);
            if (_cards.TryGetValue(id, out var existing))
            {
                if (existing.Signature.Equals(signature)) continue;
                existing.Card.Release();
            }
            var card = new ActionCard();
            card.Initialize(_model, id);
            card.RecordingStarted += OnRecordingStarted;
            card.RecordingEnded += OnRecordingEnded;
            card.EditRequested += OnEditRequested;
            _cards[id] = (card, signature);
        }
        foreach (var gone in _cards.Keys.Except(ids).ToList())
        {
            _cards[gone].Card.Release();
            _cards.Remove(gone);
        }

        var ordered = ids.Select(id => _cards[id].Card).ToList();
        if (ordered.SequenceEqual(CardsPanel.Children.OfType<ActionCard>()) && CardsPanel.Children.Count == ordered.Count) return;
        CardsPanel.Children.Clear();
        foreach (var card in ordered) CardsPanel.Children.Add(card);
    }

    /// <summary>Shows the cards that match the type filter and the search (macOS filteredActionOrder).</summary>
    private void ApplyFilter()
    {
        if (_model is null) return;
        var shown = ActionsViewModel.Filtered(_model.Current, _filter, SearchBox.Text).ToHashSet();
        foreach (var (id, (card, _)) in _cards)
            card.Visibility = shown.Contains(id) ? Visibility.Visible : Visibility.Collapsed;
    }

    // Add/Edit panel.

    /// <summary>A custom card's Edit: the action as saved now.</summary>
    private void OnEditRequested(ActionIdentifier id)
    {
        if (_model is not null && ActionsViewModel.Custom(_model.Current, id) is { } action) OpenEditor(action);
    }

    /// <summary>Shows the Add/Edit panel on <paramref name="action"/> at once, over the window (macOS editingAction).</summary>
    private void OpenEditor(CustomAction action)
    {
        if (_model is null || SlideOverPanel.Of(this) is not { } panels) return;
        var editor = new CustomActionEditPanel();
        editor.Initialize(_model, action, panels);
        panels.Present(editor, editor.InitialFocus);
    }

    /// <summary>
    /// Shows the Action Library at once, as a modal in the middle of the window (macOS showingLibrary slides it in); an
    /// install refreshes the cards through the settings change.
    /// </summary>
    private void OpenLibrary()
    {
        if (_model is null || SlideOverPanel.Of(this) is not { } panels) return;
        var library = new ActionLibraryPanel();
        library.Initialize(_model, panels);
        panels.Present(library, library.InitialFocus, minWidth: ActionLibraryPanel.SheetMinWidth, centered: true);
    }

    // Export and import (macOS exportActions, importActions, importPluginFromFile, the snippet sheet).

    /// <summary>The plugin menu (macOS: Choose file… / Paste snippet…). A file picker cannot pick a folder, so a .popclipext folder has its own item.</summary>
    private MenuFlyout PluginMenu()
    {
        var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight };
        menu.Items.Add(MenuItem("Choose file…", "\uE8E5", ImportPluginFileAsync));
        menu.Items.Add(MenuItem("Choose .popclipext folder…", "\uE8B7", ImportPluginFolderAsync));
        menu.Items.Add(MenuItem("Paste snippet…", "\uE77F", ImportSnippetAsync));
        return menu;
    }

    private MenuFlyoutItem MenuItem(string text, string glyph, Func<Task> run)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
        item.Click += (_, _) => Transfer(run);
        return item;
    }

    /// <summary>Runs one export or import flow at a time.</summary>
    private async void Transfer(Func<Task> run)
    {
        if (_transferring || _model is null) return;
        _transferring = true;
        try
        {
            await run();
        }
        catch (COMException e)
        {
            // A picker or dialog Windows refused to show.
            _services?.Log.Write($"settings: import/export picker failed, 0x{e.HResult:X8}");
        }
        finally
        {
            _transferring = false;
        }
    }

    /// <summary>Every custom action to a JSON file (macOS default name), encoded and written off the UI thread.</summary>
    private async Task ExportAsync()
    {
        var actions = _model!.Current.CustomActions;
        if (actions.Count == 0) return;
        var picker = new FileSavePicker
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            SuggestedFileName = Path.GetFileNameWithoutExtension(ActionExport.DefaultFileName),
        };
        picker.FileTypeChoices.Add("JSON", new List<string> { ".json" });
        if (!Own(picker)) return;
        var file = await picker.PickSaveFileAsync();
        if (file?.Path is not { Length: > 0 } path) return;

        var error = await Task.Run(() =>
        {
            byte[] json;
            try
            {
                json = ActionExport.Serialize(actions);
            }
            catch (Exception e) when (e is JsonException or NotSupportedException)
            {
                return $"Could not encode the actions: {e.Message}";
            }
            try
            {
                File.WriteAllBytes(path, json);
                return null;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return $"Could not write the file: {e.Message}";
            }
        });
        if (error is not null) await AlertAsync("Export Failed", error);
    }

    /// <summary>Import custom actions: a PopGuy JSON file.</summary>
    private async Task ImportActionsAsync()
    {
        if (await PickFileAsync(".json") is { } path) await ImportAsync(() => ReadActions(path));
    }

    /// <summary>The plugin menu's file: a PopGuy JSON file or a zipped PopClip extension (.popclipextz).</summary>
    private async Task ImportPluginFileAsync()
    {
        if (await PickFileAsync(".json", ".popclipextz") is not { } path) return;
        await ImportAsync(() => path.EndsWith(".popclipextz", StringComparison.OrdinalIgnoreCase) ? ReadArchive(path) : ReadActions(path));
    }

    /// <summary>The plugin menu's folder: a PopClip extension (.popclipext); any other folder fails with the reader's message.</summary>
    private async Task ImportPluginFolderAsync()
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        if (!Own(picker)) return;
        var folder = await picker.PickSingleFolderAsync();
        if (folder?.Path is not { Length: > 0 } path) return;
        await ImportAsync(() => ImportConsent.FromPlugin(PopClipAdapter.Adapt(PopClipReader.ReadFolder(path))));
    }

    private async Task ImportSnippetAsync()
    {
        if (await SnippetAsync() is { } snippet)
            await ImportAsync(() => ImportConsent.FromPlugin(PopClipAdapter.Adapt(PopClipReader.ReadSnippet(snippet))));
    }

    private async Task<string?> PickFileAsync(params string[] types)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, ViewMode = PickerViewMode.List };
        foreach (var type in types) picker.FileTypeFilter.Add(type);
        if (!Own(picker)) return null;
        var file = await picker.PickSingleFileAsync();
        return file?.Path is { Length: > 0 } path ? path : null;
    }

    /// <summary>The picker belongs to the Settings window.</summary>
    private bool Own(object picker)
    {
        if (XamlRoot?.ContentIslandEnvironment is not { } environment) return false;
        InitializeWithWindow.Initialize(picker, Win32Interop.GetWindowFromWindowId(environment.AppWindowId));
        return true;
    }

    /// <summary>
    /// Reads and adapts off the UI thread, then shows the consent panel, or "Import Failed" with the macOS message. With
    /// every action refused for its provider there is nothing to review: "Unsupported Provider" shows at once.
    /// </summary>
    private async Task ImportAsync(Func<ImportConsent> read)
    {
        var (consent, error) = await Task.Run<(ImportConsent?, string?)>(() =>
        {
            try
            {
                return (read(), null);
            }
            catch (ImportRefusedException e)
            {
                return (null, e.Message);
            }
            catch (PopClipReadException e)
            {
                return (null, e.Message);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return (null, "The file could not be read.");
            }
            catch (Exception e)
            {
                // Untrusted input: an unexpected failure is reported, never thrown on the UI thread.
                _services?.Log.Write($"settings: import failed, {e.GetType().Name}");
                return (null, null);
            }
        });
        if (consent is null)
        {
            await AlertAsync("Import Failed", error ?? "The file could not be imported.");
            return;
        }
        if (consent.Actions.Count == 0 && consent.UnsupportedProviderCount > 0)
        {
            await AlertAsync("Unsupported Provider", ImportConsent.UnsupportedProviderMessage(consent.UnsupportedProviderCount));
            return;
        }
        ShowConsent(consent);
    }

    /// <summary>The consent panel; after Add, the actions dropped for their provider are reported (macOS handleConsentConfirm).</summary>
    private void ShowConsent(ImportConsent consent)
    {
        if (_model is null || SlideOverPanel.Of(this) is not { } panels) return;
        var dialog = new PluginImportConsentDialog();
        dialog.Initialize(_model, consent, panels);
        panels.Present(dialog, closed: () =>
        {
            if (dialog.Added && consent.UnsupportedProviderCount > 0)
                Transfer(() => AlertAsync("Unsupported Provider", ImportConsent.UnsupportedProviderMessage(consent.UnsupportedProviderCount)));
        });
    }

    /// <summary>A PopGuy JSON file through the import gate; the source name is the file name without its extension.</summary>
    private static ImportConsent ReadActions(string path)
    {
        if (new FileInfo(path).Length > ActionImport.MaxFileBytes)
            throw new ImportRefusedException(ImportConsent.RejectionMessage(ImportRejection.TooLarge));
        var result = ActionImport.SanitizeImported(File.ReadAllBytes(path));
        if (result.Rejection is { } rejection) throw new ImportRefusedException(ImportConsent.RejectionMessage(rejection));
        return ImportConsent.FromNative(Path.GetFileNameWithoutExtension(path), result);
    }

    private static ImportConsent ReadArchive(string path)
    {
        using var stream = File.OpenRead(path);
        return ImportConsent.FromPlugin(PopClipAdapter.Adapt(PopClipReader.ReadArchive(stream)));
    }

    /// <summary>A refused PopGuy JSON file; the message is the macOS alert text.</summary>
    private sealed class ImportRefusedException(string message) : Exception(message);

    /// <summary>
    /// The Paste PopClip Snippet dialog (macOS SnippetInputSheet): a monospace editor; Import… (or Ctrl+Enter, macOS
    /// Cmd+Return) is off while it is blank. The trimmed text, or null when cancelled.
    /// </summary>
    private async Task<string?> SnippetAsync()
    {
        if (XamlRoot is null) return null;
        var box = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.NoWrap,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            Height = 240,
        };
        ScrollViewer.SetVerticalScrollBarVisibility(box, ScrollBarVisibility.Auto);
        ScrollViewer.SetHorizontalScrollBarVisibility(box, ScrollBarVisibility.Auto);
        AutomationProperties.SetName(box, "PopClip snippet");
        var content = new StackPanel { Spacing = 12, Width = 480 };
        content.Children.Add(new TextBlock
        {
            Text = "Paste a PopClip snippet in YAML, JSON, or the #popclip header format.",
            TextWrapping = TextWrapping.Wrap,
        });
        content.Children.Add(box);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Style = AppStyle("DefaultContentDialogStyle"),
            Title = "Paste PopClip Snippet",
            Content = content,
            PrimaryButtonText = "Import…",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            IsPrimaryButtonEnabled = false,
        };
        box.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = box.Text.Trim().Length > 0;
        var submitted = false;
        box.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Enter || !dialog.IsPrimaryButtonEnabled
                || !InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down)) return;
            e.Handled = true;
            submitted = true;
            dialog.Hide();
        };
        var result = await dialog.ShowAsync();
        var text = box.Text.Trim();
        return (submitted || result == ContentDialogResult.Primary) && text.Length > 0 ? text : null;
    }

    /// <summary>A macOS-style alert: a title, the message and OK.</summary>
    private async Task AlertAsync(string title, string message)
    {
        if (XamlRoot is null) return;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Style = AppStyle("DefaultContentDialogStyle"),
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = "OK",
            DefaultButton = ContentDialogButton.Close,
        };
        await dialog.ShowAsync();
    }

    private static Style AppStyle(string key) => (Style)Application.Current.Resources[key];

    // Shortcuts.

    /// <summary>The hotkeys go off first, so the combo the user presses reaches the recorder.</summary>
    private void OnRecordingStarted()
    {
        _services?.SetHotkeysSuspended(true);
        RefreshStatus();
    }

    /// <summary>The card saved the shortcut; the hotkeys come back on, and the statuses follow that apply.</summary>
    private void OnRecordingEnded() => _services?.SetHotkeysSuspended(false);

    /// <summary>
    /// Each card's message when Windows refused its shortcut: the PopGuy action whose hotkey has the keys, else "another
    /// app"; nothing while recording (the hotkeys are off) or when it registered.
    /// </summary>
    private void RefreshStatus()
    {
        if (_services is null) return;
        var current = _services.Settings.Current;
        var registrations = _services.HotkeyRegistrations;
        foreach (var (id, (card, _)) in _cards)
        {
            string? message = null;
            if (!card.Recorder.IsRecording && current.ShortcutBindings.FirstOrDefault(b => b.Id == id) is { } binding)
            {
                var status = registrations.FirstOrDefault(r => r.Id == id && r.Shortcut == binding.Shortcut)?.Status;
                var owner = registrations
                    .Where(r => r.Id != id && r.Status == HotkeyStatus.Registered && r.Shortcut == binding.Shortcut
                        && current.ShortcutBindings.Any(b => b.Id == r.Id))
                    .Select(r => ActionsViewModel.Title(current, r.Id))
                    .FirstOrDefault();
                message = status switch
                {
                    HotkeyStatus.InUse => owner is null ? "Shortcut in use by another app" : $"Already used by {owner}",
                    HotkeyStatus.Invalid => "Windows refused this shortcut",
                    _ => null,
                };
            }
            card.ShowShortcutStatus(message);
        }
    }

    // Header.

    /// <summary>Saves one change; a failed write is logged and the controls go back to the saved settings.</summary>
    private void Save(string key, Func<AppSettings, AppSettings> change)
    {
        if (_syncing || _model is null) return;
        if (!_model.Save(key, change)) Refresh();
    }

    /// <summary>
    /// The search box's own clear button (shown while the box has focus) is the macOS clear button: it gets the fast
    /// tooltip. It is a template part, found once the template is applied.
    /// </summary>
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
}
