using PopGuy.Core.Actions;
using PopGuy.Core.Icons;

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
    public void GlyphFallsBackToSparkles(string sfSymbol, string glyph) => Assert.Equal(glyph, SymbolMap.Glyph(sfSymbol));

    [Theory]
    [InlineData("vi", "Vietnamese")]
    [InlineData("xx", "English")]
    public void TargetLanguageFallsBackToEnglish(string code, string name) => Assert.Equal(name, TargetLanguages.FromCode(code).Name);
}
