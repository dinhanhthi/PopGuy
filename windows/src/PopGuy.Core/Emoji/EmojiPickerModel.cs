namespace PopGuy.Core.Emojis;

/// <summary>One titled grid of the picker; never empty.</summary>
public sealed record PickerSection(string Id, string Title, IReadOnlyList<Emoji> Emojis, int Columns);

/// <summary>The browse tabs (used when the query is empty); one per <see cref="EmojiKind"/>.</summary>
public enum PickerTab
{
    Emoji,
    Symbols,
}

public static class PickerTabExtensions
{
    public static PickerTab FromKind(EmojiKind? kind) => kind is EmojiKind.Symbol ? PickerTab.Symbols : PickerTab.Emoji;

    public static string Title(this PickerTab tab) => tab == PickerTab.Emoji ? "Emoji" : "Symbols";

    /// <summary>The <see cref="Emoji.Kind"/> of this tab's rows.</summary>
    public static EmojiKind? Kind(this PickerTab tab) => tab == PickerTab.Emoji ? null : EmojiKind.Symbol;

    public static int Columns(this PickerTab tab) => 9;

    /// <summary>Section ids are "&lt;idPrefix&gt;-&lt;name&gt;".</summary>
    internal static string IdPrefix(this PickerTab tab) => tab == PickerTab.Emoji ? "category" : "symbols";

    /// <summary>Stable lowercase name for ids ("frequent-emoji", "results-symbols").</summary>
    internal static string Slug(this PickerTab tab) => tab == PickerTab.Emoji ? "emoji" : "symbols";
}

public readonly record struct PickerSelection(int Section, int Index);

public enum MoveDirection
{
    Left,
    Right,
    Up,
    Down,
}

/// <summary>
/// Read-only data built once from <see cref="CatalogIndex.Emojis"/>, so sections, lookups and search results hold the
/// same <see cref="Emoji"/> values (macOS <c>PickerCatalog</c>).
/// </summary>
public sealed class PickerCatalog
{
    private readonly Dictionary<PickerTab, IReadOnlyList<PickerSection>> _tabSections = [];

    public PickerCatalog(CatalogIndex index)
    {
        var byEmoji = new Dictionary<string, Emoji>(StringComparer.Ordinal);
        foreach (var emoji in index.Emojis)
            byEmoji.TryAdd(emoji.Glyph, emoji);
        ByEmoji = byEmoji;
        foreach (var tab in Enum.GetValues<PickerTab>())
            _tabSections[tab] = GroupByCategory(index.Emojis.Where(e => e.Kind == tab.Kind()), tab);
    }

    /// <summary>Glyph → emoji, to turn the frecency history back into emojis.</summary>
    public IReadOnlyDictionary<string, Emoji> ByEmoji { get; }

    /// <summary>The category sections of <paramref name="tab"/>, in catalog order (without "Frequently Used").</summary>
    public IReadOnlyList<PickerSection> CategorySections(PickerTab tab) => _tabSections.GetValueOrDefault(tab) ?? [];

    private static IReadOnlyList<PickerSection> GroupByCategory(IEnumerable<Emoji> catalog, PickerTab tab) =>
    [
        .. catalog.GroupBy(e => e.Category, StringComparer.Ordinal)
            .Select(g => new PickerSection($"{tab.IdPrefix()}-{g.Key}", g.Key, [.. g], tab.Columns())),
    ];
}

/// <summary>
/// Query, sections and keyboard selection of the emoji picker (macOS <c>EmojiPickerModel</c>). Navigation is driven by
/// method calls from a key handler, never by control focus. <see cref="Changed"/> fires after every change; use it from
/// the UI thread only.
/// </summary>
public sealed class EmojiPickerModel
{
    public const int FrequentCount = 18;

    private readonly PickerCatalog _catalog;
    private readonly EmojiSearch _search;
    private readonly EmojiFrecency _frecency;
    private string _query = "";
    private PickerTab _tab = PickerTab.Emoji;

    public EmojiPickerModel(PickerCatalog catalog, EmojiSearch search, EmojiFrecency frecency)
    {
        _catalog = catalog;
        _search = search;
        _frecency = frecency;
        Rebuild();
    }

    public event Action? Changed;

    /// <summary>The emoji the user confirmed, after it was recorded in the history.</summary>
    public event Action<Emoji>? Confirmed;

    public string Query
    {
        get => _query;
        set
        {
            // Text box bindings can write the same value back; keep the user's selection then.
            if (value == _query)
                return;
            _query = value;
            Rebuild();
            Changed?.Invoke();
        }
    }

    /// <summary>Browse tab, shown while the query is empty; a search lists every kind whatever the tab.</summary>
    public PickerTab Tab
    {
        get => _tab;
        set
        {
            if (value == _tab)
                return;
            _tab = value;
            // With a query the sections don't depend on the tab.
            if (_query.Length == 0)
                Rebuild();
            Changed?.Invoke();
        }
    }

    /// <summary>Every section holds at least one emoji; empty when a search has no hits.</summary>
    public IReadOnlyList<PickerSection> Sections { get; private set; } = [];

    public PickerSelection? Selection { get; private set; }

    /// <summary>Bumped by every <see cref="Reset"/> so views can react to a reopen even when nothing else changed.</summary>
    public int ResetCount { get; private set; }

    /// <summary>True once the user moved the selection since the last query change / reset.</summary>
    public bool HasMoved { get; private set; }

    public Emoji? SelectedEmoji => Selection is { } s ? Sections[s.Section].Emojis[s.Index] : null;

    public void Move(MoveDirection direction)
    {
        HasMoved = true;
        if (Selection is not { } current)
            return;
        var columns = Sections[current.Section].Columns;
        var count = Sections[current.Section].Emojis.Count;
        var row = current.Index / columns;
        var col = current.Index % columns;
        var lastRow = (count - 1) / columns;
        var hasNext = current.Section + 1 < Sections.Count;
        var hasPrevious = current.Section > 0;
        var next = current;

        switch (direction)
        {
            case MoveDirection.Right:
                if (current.Index + 1 < count)
                    next = current with { Index = current.Index + 1 };
                else if (hasNext)
                    next = new PickerSelection(current.Section + 1, 0);
                break;
            case MoveDirection.Left:
                if (current.Index > 0)
                    next = current with { Index = current.Index - 1 };
                else if (hasPrevious)
                    next = new PickerSelection(current.Section - 1, Sections[current.Section - 1].Emojis.Count - 1);
                break;
            case MoveDirection.Down:
                if (row < lastRow)
                {
                    next = current with { Index = Math.Min(current.Index + columns, count - 1) };
                }
                else if (hasNext)
                {
                    var following = Sections[current.Section + 1];
                    next = new PickerSelection(
                        current.Section + 1, Math.Min(Math.Min(col, following.Columns - 1), following.Emojis.Count - 1));
                }
                break;
            case MoveDirection.Up:
                if (row > 0)
                {
                    next = current with { Index = current.Index - columns };
                }
                else if (hasPrevious)
                {
                    var previous = Sections[current.Section - 1];
                    var previousLastRow = (previous.Emojis.Count - 1) / previous.Columns;
                    next = new PickerSelection(
                        current.Section - 1,
                        Math.Min(previousLastRow * previous.Columns + Math.Min(col, previous.Columns - 1), previous.Emojis.Count - 1));
                }
                break;
        }
        Selection = next;
        Changed?.Invoke();
    }

    /// <summary>Selects the first cell of section <paramref name="sectionIndex"/> (category bar). Counts as a user move.</summary>
    public void Jump(int sectionIndex)
    {
        if (sectionIndex < 0 || sectionIndex >= Sections.Count)
            return;
        Selection = new PickerSelection(sectionIndex, 0);
        HasMoved = true;
        Changed?.Invoke();
    }

    /// <summary>Selects <paramref name="emoji"/> in section <paramref name="section"/> (it may also appear in "Frequently Used").</summary>
    public void Select(Emoji emoji, int section)
    {
        if (section < 0 || section >= Sections.Count)
            return;
        var emojis = Sections[section].Emojis;
        for (var i = 0; i < emojis.Count; i++)
        {
            if (emojis[i] == emoji)
            {
                Selection = new PickerSelection(section, i);
                Changed?.Invoke();
                return;
            }
        }
    }

    /// <summary>Records the selected emoji in the history, then raises <see cref="Confirmed"/>.</summary>
    public void Confirm()
    {
        if (SelectedEmoji is not { } emoji)
            return;
        _frecency.Record(emoji.Glyph);
        Confirmed?.Invoke(emoji);
    }

    /// <summary>Re-reads the history, clears the query and refreshes "Frequently Used" (call each time the picker opens).</summary>
    public void Reset()
    {
        _frecency.Reload();
        _query = "";
        Rebuild();
        ResetCount++;
        Changed?.Invoke();
    }

    private void Rebuild()
    {
        if (_query.Length == 0)
        {
            // Rank the whole history, then keep this tab's kind, so other kinds never take its slots.
            var tab = _tab;
            List<Emoji> frequent =
            [
                .. _frecency.Top(_frecency.Entries.Count)
                    .Select(g => _catalog.ByEmoji.GetValueOrDefault(g))
                    .OfType<Emoji>()
                    .Where(e => e.Kind == tab.Kind())
                    .Take(FrequentCount),
            ];
            Sections =
            [
                .. frequent.Count == 0
                    ? []
                    : new[] { new PickerSection($"frequent-{tab.Slug()}", "Frequently Used", frequent, tab.Columns()) },
                .. _catalog.CategorySections(tab),
            ];
        }
        else
        {
            var hits = _search.Search(_query, g => _frecency.Score(g));
            Sections = GroupByKind(hits);
        }
        Selection = Sections.Count == 0 ? null : new PickerSelection(0, 0);
        HasMoved = false;
    }

    /// <summary>
    /// One section per kind ("Emoji", "Symbols"), in order of first appearance in the ranked hits, so the kind with the
    /// best (penalized) score leads; each keeps the ranked order.
    /// </summary>
    private static IReadOnlyList<PickerSection> GroupByKind(IReadOnlyList<Emoji> hits) =>
    [
        .. hits.GroupBy(e => PickerTabExtensions.FromKind(e.Kind))
            .Select(g => new PickerSection($"results-{g.Key.Slug()}", g.Key.Title(), [.. g], g.Key.Columns())),
    ];
}
