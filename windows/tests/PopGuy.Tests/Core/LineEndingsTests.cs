using PopGuy.Core.Text;

namespace PopGuy.Tests.Core;

// Regression: Notepad's UI Automation selection came with bare "\r" breaks and the provider merged the paragraphs.
public sealed class LineEndingsTests
{
    [Theory]
    [InlineData("a\rb\r\rc", "a\nb\n\nc")]
    [InlineData("a\r\nb\r\n\r\nc", "a\nb\n\nc")]
    [InlineData("a\nb\r\n\rc", "a\nb\n\nc")]
    [InlineData("no breaks", "no breaks")]
    public void ToLfNormalizesEveryBreak(string input, string expected) => Assert.Equal(expected, LineEndings.ToLf(input));

    [Theory]
    [InlineData("a\nb\n\nc", "a\r\nb\r\n\r\nc")]
    [InlineData("a\r\nb\rc", "a\r\nb\r\nc")]
    [InlineData("no breaks", "no breaks")]
    public void ToCrLfNeverDoublesTheCarriageReturn(string input, string expected) =>
        Assert.Equal(expected, LineEndings.ToCrLf(input));
}
