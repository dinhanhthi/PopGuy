using PopGuy.Core.Diff;

namespace PopGuy.Tests.Core;

// Contract: the Improve/Proofread diff matches macOS DiffAlgorithm.swift segment for segment (the expected values are
// the Swift implementation's output for the same inputs), and a rejected hunk puts the original words back into the
// text Copy and Paste back use.
public sealed class DiffTests
{
    // One segment per "|"-separated item: "=" equal, "+" inserted, "-" deleted, then the text.
    public static TheoryData<string, string, string> SwiftOutputs => new()
    {
        { "The quick brown fox", "The slow brown fox", "=The |-quick|+slow|= brown fox" },
        { "foo bar baz", "foo INSERTED bar baz", "=foo|+ INSERTED|= bar baz" },
        { "  hello world  ", "  hi world  ", "=  |-hello|+hi|= world  " },
        { "The quick brown fox", "The lazy dog", "=The|- quick|= |-brown|+lazy|= |-fox|+dog" },
        {
            "First para here.\n\nSecond one is old.", "First paragraph here.\n\nSecond one is new.\n\nThird.",
            "=First |-para|+paragraph|= here.\n\nSecond one is |-old.|+new.\n\nThird."
        },
        { "", "Hello world", "+Hello world" },
        { "a  b  c", "a  b  c", "=a  b  c" },
    };

    [Theory]
    [MemberData(nameof(SwiftOutputs))]
    public void DiffMatchesTheSwiftSegments(string original, string improved, string expected) =>
        Assert.Equal(expected, Format(DiffAlgorithm.Diff(original, improved)));

    [Fact]
    public void RejectingAHunkKeepsItsOriginalWords()
    {
        var segments = DiffAlgorithm.Diff("The cat ran fast.", "The dog ran slowly.");

        Assert.Equal(2, DiffHunks.HunkRanges(segments).Count);
        Assert.Equal("The dog ran slowly.", DiffHunks.Merged(segments, new HashSet<int>()));
        Assert.Equal("The dog ran fast.", DiffHunks.Merged(segments, new HashSet<int> { 1 }));
        Assert.Equal("The cat ran fast.", DiffHunks.Merged(segments, new HashSet<int> { 0, 1 }));
        // An index that names no hunk changes nothing.
        Assert.Equal("The dog ran slowly.", DiffHunks.Merged(segments, new HashSet<int> { -1, 5 }));
    }

    private static string Format(IReadOnlyList<DiffSegment> segments) => string.Join("|", segments.Select(s => s.Kind switch
    {
        DiffKind.Equal => "=",
        DiffKind.Inserted => "+",
        _ => "-",
    } + s.Text));
}
