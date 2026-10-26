using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.Settings;
using PopGuy.Platform.Input;
using PopGuy.Services;
using PopGuy.Settings.Controls;
using PopGuy.Settings.Panels;
using PopGuy.Settings.ViewModels;

namespace PopGuy.Settings.Pages;

/// <summary>
/// Settings → Actions (macOS ActionsView.swift, spec-3 §5.3): the toolbar layout editor
/// (<see cref="ToolbarLayoutEditor"/>), the toolbar's Settings-button switch, the search box and type filter, then one
/// <see cref="ActionCard"/> per action in the action order (built-ins and custom actions; Speak and Look up come in
/// Phase 19). Add action and a custom card's Edit open <see cref="CustomActionEditPanel"/> in the window's
/// <see cref="SlideOverPanel"/>. The navigation parameter is the AppServices. A card is built once and updated on every
/// settings change, so text being typed, a recording and the expansion survive; it is built again only when its custom
/// action's type, title, icon, description or origin changed. Search and filter only hide cards. While a card's
/// shortcut records, PopGuy's own hotkeys and chord are off (<see cref="AppServices.SetHotkeysSuspended"/>); after
/// each apply, a shortcut Windows refused shows on its card. A change from elsewhere shows while the page is open.
/// </summary>
public sealed partial class ActionsPage : Page
{
    private const string SettingsButtonTooltip = "Settings stay available from the PopGuy tray icon";

    private readonly Dictionary<ActionIdentifier, (ActionCard Card, object Signature)> _cards = [];
    private AppServices? _services;
    private ActionsViewModel? _model;
    private bool _subscribed;
    private ActionTypeFilter _filter = ActionTypeFilter.All;

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
        _model = new ActionsViewModel(_services.Settings, _services.Credentials, _services.Providers, _services.Log.Write);
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
