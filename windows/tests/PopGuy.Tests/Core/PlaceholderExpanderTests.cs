using PopGuy.Core.Scripts;

namespace PopGuy.Tests.Core;

// Security boundary (spec-4 §4.3): the untrusted selection enters a URL only percent-encoded with the exact macOS set
// (ALPHA, DIGIT and -._~!$'()*, stay bare; every other UTF-8 byte is %XX, uppercase), and a shell script only as
// environment values.
public sealed class PlaceholderExpanderTests
{
    [Theory]
    [InlineData("a b", "a%20b")]
    [InlineData("/?#&=+%@:;", "%2F%3F%23%26%3D%2B%25%40%3A%3B")]
    [InlineData("-._~!$'()*,", "-._~!$'()*,")]
    [InlineData("AZaz09", "AZaz09")]
    [InlineData("\"<>[]`{}|\\^\n", "%22%3C%3E%5B%5D%60%7B%7D%7C%5C%5E%0A")]
    [InlineData("../admin", "..%2Fadmin")]
    [InlineData("x&admin=true", "x%26admin%3Dtrue")]
    [InlineData("é", "%C3%A9")]
    [InlineData("😀", "%F0%9F%98%80")]
    public void UrlEncodesTheSelectionWithTheMacOSSet(string text, string encoded)
    {
        Assert.Equal("https://x.test/s?q=" + encoded, PlaceholderExpander.ExpandUrl("https://x.test/s?q={text}", text));
    }

    [Fact]
    public void UrlReplacesEveryToken()
    {
        Assert.Equal("https://x.test/a%20b?q=a%20b", PlaceholderExpander.ExpandUrl("https://x.test/{text}?q={text}", "a b"));
    }

    [Theory]
    [InlineData("~", @"C:\Users\me")]
    [InlineData("~/Downloads", @"C:\Users\me/Downloads")]
    [InlineData(@"~\Downloads", @"C:\Users\me\Downloads")]
    [InlineData("~alice/x", "~alice/x")]
    [InlineData("a ~/b", "a ~/b")]
    public void ScriptEnvironmentCarriesTheTextWithALeadingTildeExpanded(string text, string expected)
    {
        var environment = PlaceholderExpander.ScriptEnvironment(text, "  " + text, @"C:\Users\me");

        Assert.Equal(2, environment.Count);
        Assert.Equal(expected, environment["POPGUY_TEXT"]);
        Assert.Equal("  " + text, environment["POPGUY_FULL_TEXT"]); // untrimmed: no leading tilde
    }
}
