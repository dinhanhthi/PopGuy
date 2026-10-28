using PopGuy.Core.Actions;
using PopGuy.Core.Icons;

namespace PopGuy.Tests.Core;

// Contract: the icon picker offers macOS's curated SF Symbols, each with its own SymbolMap glyph (never the unknown-name
// stand-in), once each; its search matches names ignoring case; the emoji box keeps its last grapheme whole (macOS
// keeps the last Character) and an empty box falls back to the default icon.
public sealed class IconCatalogTests
{
    [Fact]
    public void EveryCuratedSymbolIsMappedOnce()
    {
        Assert.Equal(197, IconCatalog.Symbols.Count);
        Assert.Equal(IconCatalog.Symbols.Count, IconCatalog.Symbols.Distinct().Count());
        Assert.All(IconCatalog.Symbols, name => Assert.True(SymbolMap.IsKnown(name), name));
    }

    [Fact]
    public void SearchIgnoresCase() => Assert.Equal(["paintpalette"], IconCatalog.Search("PaintPal"));

    [Fact]
    public void EmptySearchListsEverySymbol() => Assert.Same(IconCatalog.Symbols, IconCatalog.Search(""));

    [Theory]
    [InlineData("ab❤️", "❤️")]
    [InlineData("✨\U0001F525", "\U0001F525")]
    public void EmojiInputKeepsLastGrapheme(string text, string emoji) => Assert.Equal(ActionIcon.Emoji(emoji), IconCatalog.EmojiFromInput(text));

    [Fact]
    public void EmptyEmojiInputIsDefault() => Assert.Equal(ActionIcon.Default, IconCatalog.EmojiFromInput(""));
}
