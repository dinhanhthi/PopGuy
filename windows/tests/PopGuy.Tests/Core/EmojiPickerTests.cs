using PopGuy.Core;
using PopGuy.Core.Emojis;

namespace PopGuy.Tests.Core;

// Key feature and file-format contract: the emoji picker reads the macOS data (macos/PopGuy/Resources/Emoji, linked into
// PopGuy.Core as embedded resources), so a broken link or a renamed category shows here; the country-flag filter keeps
// the non-country flags; toning mirrors macOS Emoji.toned (EmojiToningTests). Search, navigation and frecency mirror
// the macOS EmojiSearchTests, EmojiPickerNavigationTests and EmojiFrecencyTests (same queries and expectations).
public sealed class EmojiPickerTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "PopGuyTests-" + Guid.NewGuid().ToString("N"));

    private string UsageFile => AppPaths.Resolve(_root).EmojiUsageFile;

    public void Dispose()
    {
        if (Directory.Exists(_root))
            Directory.Delete(_root, recursive: true);
    }

    private static Emoji Row(string glyph, string[] aliases, string[]? keywords = null, EmojiKind? kind = null, string category = "Test") => new()
    {
        Glyph = glyph,
        Description = aliases[0].Replace('_', ' '),
        Category = category,
        Aliases = aliases,
        Tags = [],
        Keywords = keywords,
        Kind = kind,
    };

    private static IEnumerable<string> Glyphs(IEnumerable<Emoji> emojis) => emojis.Select(e => e.Glyph);

    [Fact]
    public void ExactAliasRanksFirstEvenASymbolOverAnEmojiPrefixMatch()
    {
        // The expected losers come first in the catalog, so a scoring tie would fail the test.
        var search = new EmojiSearch([
            Row("\U0001F63A", ["smiley_cat"]), // 😺
            Row("\U0001F604", ["smile"]), // 😄
            Row("\U0001F4BB", ["cmdline"]), // 💻
            Row("⌘", ["cmd"], kind: EmojiKind.Symbol),
        ]);

        Assert.Equal("\U0001F604", search.Search("smile", _ => 0).First().Glyph);
        Assert.Equal("⌘", search.Search("cmd", _ => 0).First().Glyph);
    }

    [Fact]
    public void ScatteredLettersInsideAWordDoNotMatch()
    {
        var search = new EmojiSearch([Row("\U0001F41E", ["lady_beetle"])]); // 🐞

        Assert.Empty(search.Search("yeet", _ => 0));
        Assert.Equal(["\U0001F41E"], Glyphs(search.Search("eetle", _ => 0)));
    }

    [Fact]
    public void AccentFreeVietnameseKeywordMatches()
    {
        var search = new EmojiSearch([
            Row("\U0001F622", ["cry"], keywords: ["khóc"]), // 😢
            Row("\U0001F606", ["laughing"], keywords: ["cười"]), // 😆
        ]);

        Assert.Equal(["\U0001F606"], Glyphs(search.Search("cuoi", _ => 0)));
    }

    [Fact]
    public void DownFromTheLastRowIntoAShorterSectionClampsToItsLastCell()
    {
        // Category A: 13 emoji (the last row holds indices 9...12); category B: 2 emoji.
        var catalog = Enumerable.Range(0, 13).Select(i => Row($"a{i}", [$"a_{i}"], category: "A"))
            .Concat(Enumerable.Range(0, 2).Select(i => Row($"b{i}", [$"b_{i}"], category: "B")))
            .ToList();
        var index = new CatalogIndex(catalog);
        var model = new EmojiPickerModel(new PickerCatalog(index), new EmojiSearch(index), new EmojiFrecency(UsageFile));
        Assert.Equal([13, 2], model.Sections.Select(s => s.Emojis.Count));

        model.Select(model.Sections[0].Emojis[12], section: 0);
        model.Move(MoveDirection.Down);

        Assert.Equal(new PickerSelection(1, 1), model.Selection);
    }

    [Fact]
    public void DecayReordersTopAnOldFrequentPickFallsBehindARecentOne()
    {
        var monthAgo = DateTimeOffset.FromUnixTimeSeconds(1_000_000_000);
        var now = monthAgo.AddDays(30);
        var frecency = new EmojiFrecency(UsageFile);
        for (var i = 0; i < 3; i++)
            frecency.Record("\U0001F602", monthAgo); // 😂
        frecency.Record("\U0001F44D", now); // 👍
        frecency.Reload(); // the order below comes back from emoji-usage.json

        Assert.Equal(["\U0001F602", "\U0001F44D"], frecency.Top(2, monthAgo));
        Assert.Equal(["\U0001F44D", "\U0001F602"], frecency.Top(2, now));
    }

    [Fact]
    public void CatalogLoadsEmbeddedDataAndHidesCountryFlags()
    {
        var catalog = EmojiCatalog.Load(maxVersion: 15.1, hideCountryFlags: true);

        Assert.Equal(
            ["Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink", "Travel & Places", "Activities",
             "Objects", "Symbols", "Flags"],
            catalog.Where(e => e.Kind == null).Select(e => e.Category).Distinct());
        Assert.Equal(
            ["Arrows", "Checkboxes", "Currency", "Keyboard", "Math", "Typography"],
            catalog.Where(e => e.Kind == EmojiKind.Symbol).Select(e => e.Category).Distinct().Order(StringComparer.Ordinal));
        Assert.Contains(catalog, e => e.Glyph == "\U0001F3F4‍☠️"); // 🏴‍☠️
        Assert.DoesNotContain(catalog, e => e.Glyph == "\U0001F1EB\U0001F1F7"); // 🇫🇷
    }

    // Real catalog rows, so a regenerated emoji.json without skin_tones fails too. A fixed maxVersion keeps the test
    // independent of the catalog cut-off for the running Windows build.
    [Theory]
    [InlineData("\u270C\uFE0F", "\u270C\U0001F3FD")] // ✌️ -> ✌🏽: the modifier replaces the U+FE0F after the base
    [InlineData( // 🧑‍🤝‍🧑 -> 🧑🏽‍🤝‍🧑🏽: both people take the tone, the handshake between them does not
        "\U0001F9D1\u200D\U0001F91D\u200D\U0001F9D1",
        "\U0001F9D1\U0001F3FD\u200D\U0001F91D\u200D\U0001F9D1\U0001F3FD")]
    public void TonedAppliesTheModifierToEachBase(string glyph, string expected)
    {
        var emoji = EmojiCatalog.Load(maxVersion: 17.0, hideCountryFlags: false).First(e => e.Glyph == glyph);

        Assert.Equal(expected, emoji.Toned(SkinTone.Medium));
    }
}
