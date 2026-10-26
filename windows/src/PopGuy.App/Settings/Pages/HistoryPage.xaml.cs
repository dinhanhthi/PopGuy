using System.Collections.ObjectModel;
using System.ComponentModel;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.History;
using PopGuy.Core.Settings;
using PopGuy.Platform.Capture;
using PopGuy.Services;

namespace PopGuy.Settings.Pages;

/// <summary>
/// Settings → History (macOS HistoryView.swift, spec-3 §5.6). The navigation parameter is the AppServices. The card and
/// toggles show at once; the records are queried on the thread pool (a spinner only after 150 ms on the first load) and
/// again on every <see cref="HistoryStore.Changed"/>, search keystroke and action pick, the latest query winning. A store
/// change updates the rows in place (a new run slides in at the top, a delete removes one row); a new search or action
/// rebuilds them. A click on a row's summary toggles it at once; while searching every match is expanded. Copy writes
/// through <see cref="ClipboardGuard.WriteText"/> like the toolbar's Copy. Record text is never logged.
/// </summary>
public sealed partial class HistoryPage : Page
{
    private static readonly TimeSpan SpinnerDelay = TimeSpan.FromMilliseconds(150);

    private readonly HashSet<Guid> _expanded = [];
    private ObservableCollection<HistoryRowItem> _rows = [];
    private IReadOnlyList<string> _actionNames = [];
    private AppServices? _services;
    private DispatcherQueueTimer? _spinnerTimer;
    private bool _subscribed;
    private bool _loaded;

    /// <summary>The latest query; an older one that finishes later is dropped.</summary>
    private int _generation;

    /// <summary>The action menu's pick; null is "All actions".</summary>
    private string? _actionFilter;

    /// <summary>The filter the rows were built for: a different one rebuilds them instead of updating in place.</summary>
    private (string? Action, string Query)? _shownFilter;

    /// <summary>The action menu is being set from the records: its change event is not the user's.</summary>
    private bool _syncing;

    public HistoryPage()
    {
        InitializeComponent();
        EnabledBox.Click += (_, _) => Save("historyEnabled", s => s with { HistoryEnabled = EnabledBox.IsChecked == true });
        FullTextBox.Click += (_, _) =>
            Save("historyStoreFullText", s => s with { HistoryStoreFullText = FullTextBox.IsChecked == true });
        ClearAllButton.Click += (_, _) => _ = ConfirmClearAllAsync();
        SearchBox.TextChanged += (_, _) => Reload();
        SearchBox.Loaded += (_, _) => AttachClearTooltip();
        ActionBox.SelectionChanged += (_, _) => OnActionPicked();
        Repeater.ItemsSource = _rows;
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _services = e.Parameter as AppServices;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_services is null) return;
        if (!_subscribed)
        {
            _services.Settings.Changed += OnSettingsChanged;
            _services.History.Changed += OnHistoryChanged;
        }
        _subscribed = true;
        RefreshToggles();
        if (!_loaded) StartSpinnerTimer();
        Reload();
    }

    /// <summary>The window's first-show re-attach may raise Loaded before this Unloaded: a page still loaded keeps listening.</summary>
    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_services is null || IsLoaded) return;
        _services.Settings.Changed -= OnSettingsChanged;
        _services.History.Changed -= OnHistoryChanged;
        _subscribed = false;
        _spinnerTimer?.Stop();
    }

    /// <summary>Queued: a change may be saved from any thread.</summary>
    private void OnSettingsChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(RefreshToggles);

    /// <summary>Queued: a run records on its own thread.</summary>
    private void OnHistoryChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Reload);

    private void RefreshToggles()
    {
        if (_services is null) return;
        var current = _services.Settings.Current;
        EnabledBox.IsChecked = current.HistoryEnabled;
        FullTextBox.IsChecked = current.HistoryStoreFullText;
        FullTextBox.IsEnabled = current.HistoryEnabled;
    }

    /// <summary>Saves one change; a failed write is logged and the toggles go back to the saved settings.</summary>
    private void Save(string key, Func<AppSettings, AppSettings> change)
    {
        if (_services is null) return;
        try
        {
            _services.Settings.Update(change);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _services.Log.Write($"settings: {key} not saved, {e.GetType().Name}");
            RefreshToggles();
        }
    }

    // Loading.

    private void StartSpinnerTimer()
    {
        if (_spinnerTimer is null)
        {
            _spinnerTimer = DispatcherQueue.CreateTimer();
            _spinnerTimer.Interval = SpinnerDelay;
            _spinnerTimer.IsRepeating = false;
            _spinnerTimer.Tick += (timer, _) =>
            {
                timer.Stop();
                if (!_loaded) Spinner.IsActive = true;
            };
        }
        _spinnerTimer.Start();
    }

    /// <summary>Queries the records for the current filter on the thread pool, then shows them if no newer query started.</summary>
    private async void Reload()
    {
        if (_services is null) return;
        var history = _services.History;
        var generation = ++_generation;
        var action = _actionFilter;
        var query = SearchBox.Text;
        IReadOnlyList<HistoryRecord> all, matches;
        try
        {
            (all, matches) = await Task.Run(() => (history.Records, history.Query(action, query)));
        }
        catch (Exception e)
        {
            _services.Log.Write($"settings: history not loaded, {e.GetType().Name}");
            return;
        }
        if (generation != _generation) return;
        Show(all, matches, action, query);
    }

    private void Show(IReadOnlyList<HistoryRecord> all, IReadOnlyList<HistoryRecord> matches, string? action, string query)
    {
        if (!_loaded)
        {
            _loaded = true;
            _spinnerTimer?.Stop();
            Spinner.IsActive = false;
        }

        CountText.Text = all.Count == 1 ? "1 record" : $"{all.Count} records";
        ClearAllButton.IsEnabled = all.Count > 0;

        if (!ShowActionNames(all))
        {
            // The picked action has no records left: back to all actions.
            Reload();
            return;
        }

        FilterBar.Visibility = all.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyState.Visibility = all.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        NoMatchesState.Visibility = all.Count > 0 && matches.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ListScroller.Visibility = matches.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _expanded.IntersectWith(all.Select(r => r.Id));
        ShowRows(matches, (action, query));
    }

    // Rows.

    /// <summary>
    /// A new filter builds the rows again; the same filter updates them in place (the store only adds at the top and
    /// removes, so the kept rows stay in order) and refreshes their relative times.
    /// </summary>
    private void ShowRows(IReadOnlyList<HistoryRecord> records, (string? Action, string Query) filter)
    {
        var searching = !string.IsNullOrWhiteSpace(filter.Query);
        var now = DateTime.UtcNow;
        if (_shownFilter != filter)
        {
            _shownFilter = filter;
            _rows = [.. records.Select(r => new HistoryRowItem(r, now, _expanded.Contains(r.Id), searching))];
            Repeater.ItemsSource = _rows;
            return;
        }

        var existing = _rows.ToDictionary(row => row.Id);
        var wanted = records
            .Select(r => existing.TryGetValue(r.Id, out var row) ? row : new HistoryRowItem(r, now, _expanded.Contains(r.Id), searching))
            .ToList();
        var keep = wanted.ToHashSet();
        for (var i = _rows.Count - 1; i >= 0; i--)
        {
            if (!keep.Contains(_rows[i])) _rows.RemoveAt(i);
        }
        for (var i = 0; i < wanted.Count; i++)
        {
            if (i >= _rows.Count || !ReferenceEquals(_rows[i], wanted[i])) _rows.Insert(i, wanted[i]);
        }
        foreach (var row in _rows) row.UpdateTime(now);
    }

    /// <summary>A click on the summary toggles the row, unless it was on the row's delete button.</summary>
    private void OnRowTapped(object sender, TappedRoutedEventArgs e) => ToggleRow(sender, e.OriginalSource);

    /// <summary>A quick second click is a double tap, not a tap: it toggles too, so no click is lost.</summary>
    private void OnRowDoubleTapped(object sender, DoubleTappedRoutedEventArgs e) => ToggleRow(sender, e.OriginalSource);

    private void ToggleRow(object sender, object source)
    {
        if (sender is not FrameworkElement { DataContext: HistoryRowItem row } summary || IsInButton(source, summary)) return;
        if (!_expanded.Remove(row.Id)) _expanded.Add(row.Id);
        row.IsExpanded = _expanded.Contains(row.Id);
    }

    private static bool IsInButton(object source, DependencyObject root)
    {
        for (var node = source as DependencyObject; node is not null && node != root; node = VisualTreeHelper.GetParent(node))
        {
            if (node is ButtonBase) return true;
        }
        return false;
    }

    /// <summary>The row goes at once; the store saves in the background and its change updates the rest.</summary>
    private void OnDeleteClick(object sender, RoutedEventArgs e)
    {
        if (_services is null || RowOf(sender) is not { } row) return;
        _expanded.Remove(row.Id);
        _rows.Remove(row);
        _services.History.Delete(row.Id);
    }

    private void OnCopyInputClick(object sender, RoutedEventArgs e) => Copy(RowOf(sender)?.Record.Input, "input");

    private void OnCopyOutputClick(object sender, RoutedEventArgs e) => Copy(RowOf(sender)?.Record.Output, "output");

    private void OnCopyErrorClick(object sender, RoutedEventArgs e) => Copy(RowOf(sender)?.ErrorText, "error");

    private static HistoryRowItem? RowOf(object sender) => (sender as FrameworkElement)?.DataContext as HistoryRowItem;

    /// <summary>
    /// A deliberate copy (the toolbar's Copy): the clipboard is not restored and the text may go to clipboard history.
    /// Off the UI thread; the log gets the outcome only.
    /// </summary>
    private void Copy(string? text, string what)
    {
        if (text is null || _services is not { } services) return;
        _ = Task.Run(() =>
        {
            try
            {
                services.Log.Write($"history copy {what}: written {ClipboardGuard.WriteText(text, excludeFromHistory: false)}");
            }
            catch (Exception e)
            {
                services.Log.Write($"history copy {what}: failed, {e.GetType().Name}");
            }
        });
    }

    // Filter bar.

    /// <summary>
    /// Fills the action menu with "All actions" and the records' action names, sorted. False when the picked action is
    /// gone (it is reset to all actions).
    /// </summary>
    private bool ShowActionNames(IReadOnlyList<HistoryRecord> all)
    {
        var names = all.Select(r => r.ActionName).Distinct().Order(StringComparer.Ordinal).ToList();
        var stillThere = _actionFilter is null || names.Contains(_actionFilter);
        if (!stillThere) _actionFilter = null;
        if (!names.SequenceEqual(_actionNames))
        {
            _actionNames = names;
            _syncing = true;
            ActionBox.Items.Clear();
            ActionBox.Items.Add("All actions");
            foreach (var name in names) ActionBox.Items.Add(name);
            _syncing = false;
        }
        _syncing = true;
        ActionBox.SelectedIndex = _actionFilter is null ? 0 : names.IndexOf(_actionFilter) + 1;
        _syncing = false;
        return stillThere;
    }

    private void OnActionPicked()
    {
        if (_syncing || ActionBox.SelectedIndex < 0) return;
        var picked = ActionBox.SelectedIndex == 0 ? null : _actionNames[ActionBox.SelectedIndex - 1];
        if (picked == _actionFilter) return;
        _actionFilter = picked;
        Reload();
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

    // Clear All.

    private async Task ConfirmClearAllAsync()
    {
        if (_services is null || XamlRoot is null) return;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
            Title = "Clear all history?",
            Content = new TextBlock
            {
                Text = "This permanently removes every recorded action. This cannot be undone.",
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = "Clear All",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        try
        {
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        }
        catch (System.Runtime.InteropServices.COMException e)
        {
            // Another dialog is open.
            _services.Log.Write($"settings: clear history dialog failed, 0x{e.HResult:X8}");
            return;
        }
        _expanded.Clear();
        _services.History.ClearAll();
    }
}

/// <summary>
/// One history row (macOS HistoryRow): the record and its display text, and whether it is expanded (by a click, or by
/// an active search).
/// </summary>
public sealed partial class HistoryRowItem : INotifyPropertyChanged
{
    private const string ChevronRight = "";
    private const string ChevronDown = "";

    private readonly bool _searching;
    private bool _isExpanded;

    internal HistoryRowItem(HistoryRecord record, DateTime now, bool isExpanded, bool searching)
    {
        Record = record;
        _isExpanded = isExpanded;
        _searching = searching;
        DetailLine = Detail(record, now);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public HistoryRecord Record { get; }
    public Guid Id => Record.Id;
    public string ActionName => Record.ActionName;
    public string ProviderText => ProviderModel(Record);

    /// <summary>"App · 5 minutes ago · 842 ms".</summary>
    public string DetailLine { get; private set; }

    public string InputText => OrDash(Record.Input);
    public string OutputText => OrDash(Record.Output);
    public string ErrorText => Record.ErrorMessage ?? "Unknown error";
    public string ErrorDisplayText => OrDash(ErrorText);
    public Visibility SuccessVisibility => Record.Success ? Visibility.Visible : Visibility.Collapsed;
    public Visibility FailureVisibility => Record.Success ? Visibility.Collapsed : Visibility.Visible;
    public Visibility TruncatedVisibility => Record.Truncated ? Visibility.Visible : Visibility.Collapsed;
    public Visibility DetailVisibility => Shown ? Visibility.Visible : Visibility.Collapsed;
    public string ChevronGlyph => Shown ? ChevronDown : ChevronRight;

    /// <summary>Expanded by a click (a search expands every row whatever this says).</summary>
    public bool IsExpanded
    {
        get => _isExpanded;
        set
        {
            if (_isExpanded == value) return;
            _isExpanded = value;
            Raise(nameof(DetailVisibility));
            Raise(nameof(ChevronGlyph));
        }
    }

    private bool Shown => _searching || _isExpanded;

    internal void UpdateTime(DateTime now)
    {
        var line = Detail(Record, now);
        if (line == DetailLine) return;
        DetailLine = line;
        Raise(nameof(DetailLine));
    }

    private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private static string OrDash(string text) => text.Length == 0 ? "—" : text;

    /// <summary>The provider, plus the model when the provider has one; runs without a provider show their label.</summary>
    private static string ProviderModel(HistoryRecord record)
    {
        if (record.ProviderKind is { } kind)
            return kind.UsesModel() && record.Model.Length > 0 ? $"{kind.DisplayName()} · {record.Model}" : kind.DisplayName();
        var label = record.ProviderLabel ?? "—";
        return record.Model.Length == 0 ? label : $"{label} · {record.Model}";
    }

    private static string Detail(HistoryRecord record, DateTime now) =>
        $"{record.SourceAppName ?? "—"} · {RelativeTime(record.Timestamp, now)} · {record.DurationMs} ms";

    /// <summary>English relative time in the style of the macOS named relative format ("5 minutes ago", "yesterday").</summary>
    private static string RelativeTime(DateTime timestamp, DateTime now)
    {
        var elapsed = now - timestamp.ToUniversalTime();
        if (elapsed < TimeSpan.FromSeconds(1)) return "now";
        if (elapsed < TimeSpan.FromMinutes(1)) return Ago((int)elapsed.TotalSeconds, "second");
        if (elapsed < TimeSpan.FromHours(1)) return Ago((int)elapsed.TotalMinutes, "minute");
        if (elapsed < TimeSpan.FromDays(1)) return Ago((int)elapsed.TotalHours, "hour");
        var days = (int)elapsed.TotalDays;
        if (days == 1) return "yesterday";
        if (days < 7) return Ago(days, "day");
        if (days < 30) return days < 14 ? "last week" : Ago(days / 7, "week");
        if (days < 365) return days < 60 ? "last month" : Ago(days / 30, "month");
        return days < 730 ? "last year" : Ago(days / 365, "year");
    }

    private static string Ago(int count, string unit) => count == 1 ? $"1 {unit} ago" : $"{count} {unit}s ago";
}
