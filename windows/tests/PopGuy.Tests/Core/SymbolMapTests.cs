using PopGuy.Core.Actions;
using PopGuy.Core.Icons;
using PopGuy.Core.Library;

namespace PopGuy.Tests.Core;

// Contract: icons and Translate targets come from settings shared with macOS, so any name or code can arrive. A known SF
// Symbol gets its glyph and anything else the sparkles stand-in (never an empty glyph); an unknown language code reads
// as English (macOS TargetLanguage(bcp47:)).
public sealed class SymbolMapTests
{
    [Theory]
    [InlineData("doc.on.doc", "\uE8C8")]
    [InlineData("character.bubble", "\uE774")]
    [InlineData("sparkles", SymbolMap.Sparkles)]
    [InlineData("no.such.symbol", SymbolMap.Sparkles)]
    [InlineData("", SymbolMap.Sparkles)]
    // A ".fill" variant without its own entry draws as its base symbol (search-wikipedia.json uses book.fill).
    [InlineData("book.fill", "")]
    [InlineData("no.such.fill", SymbolMap.Sparkles)]
    [InlineData(".fill", SymbolMap.Sparkles)]
    public void GlyphFallsBackToSparkles(string sfSymbol, string glyph) => Assert.Equal(glyph, SymbolMap.Glyph(sfSymbol));

    // The Action Library shows every preset and category icon: none may fall back to the sparkles stand-in.
    [Fact]
    public void LibraryIconsAreMapped()
    {
        var names = ActionLibrary.AllPresets().Select(p => p.Make().Icon)
            .Where(i => i.Type == ActionIconType.SfSymbol).Select(i => i.Value)
            .Concat(ActionLibrary.Categories.Select(c => c.IconName()));
        var missing = names.Where(n => !SymbolMap.IsKnown(n) && !(n.EndsWith(".fill", StringComparison.Ordinal) && SymbolMap.IsKnown(n[..^5])))
            .Distinct().ToList();
        Assert.Empty(missing);
    }

    [Theory]
    [InlineData("vi", "Vietnamese")]
    [InlineData("xx", "English")]
    public void TargetLanguageFallsBackToEnglish(string code, string name) => Assert.Equal(name, TargetLanguages.FromCode(code).Name);
}
