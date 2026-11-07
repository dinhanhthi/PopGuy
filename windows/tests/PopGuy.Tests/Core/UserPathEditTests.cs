using PopGuy.Core.Composer;

namespace PopGuy.Tests.Core;

// Security of the user's environment: "Install command" / "Remove" edit the user PATH (HKCU\Environment\Path, read
// unexpanded). Only our entry may be added or removed; every other entry keeps its text and its place.
public sealed class UserPathEditTests
{
    private const string Ours = @"C:\Users\thi\AppData\Local\PopGuy\current\bin";

    [Fact]
    public void AddAndRemoveKeepEveryOtherEntryAndItsOrder()
    {
        const string others = @"%USERPROFILE%\bin; C:\Program Files\Tool ;;""C:\Quoted Dir"";C:\last\";

        Assert.Equal(others + ";" + Ours, UserPathEdit.Add(others, Ours));
        Assert.Equal(others + ";" + Ours, UserPathEdit.Add(others + ";", Ours));
        Assert.Equal(Ours, UserPathEdit.Add(null, Ours));
        Assert.Equal(Ours, UserPathEdit.Add("", Ours));

        Assert.Equal(others, UserPathEdit.Remove(others + ";" + Ours, Ours));
        Assert.Equal(@"%USERPROFILE%\bin;C:\a;", UserPathEdit.Remove(@"%USERPROFILE%\bin;" + Ours + @";C:\a;", Ours));
        Assert.Equal(others, UserPathEdit.Remove(Ours + ";" + others, Ours));
        Assert.Equal("", UserPathEdit.Remove(Ours, Ours));
    }

    [Fact]
    public void IdempotentCaseInsensitiveAndTrailingBackslashIgnored()
    {
        const string path = @"C:\a;" + Ours + @";C:\b";
        Assert.Equal(path, UserPathEdit.Add(path, Ours));
        Assert.Equal(UserPathEdit.Add(@"C:\a", Ours), UserPathEdit.Add(UserPathEdit.Add(@"C:\a", Ours), Ours));
        Assert.Equal(@"C:\a;;C:\b", UserPathEdit.Remove(@"C:\a;;C:\b", Ours));

        const string variant = @"C:\a; c:\users\THI\appdata\local\popguy\current\bin\ ;C:\b";
        Assert.True(UserPathEdit.Contains(variant, Ours));
        Assert.Equal(variant, UserPathEdit.Add(variant, Ours));
        Assert.Equal(@"C:\a;C:\b", UserPathEdit.Remove(variant, Ours + @"\"));
    }

    [Fact]
    public void VariableEntriesAreComparedLiterallyAndNeverRewritten()
    {
        const string path = @"%LOCALAPPDATA%\PopGuy\current\bin;%PATH%;C:\a";
        Assert.False(UserPathEdit.Contains(path, Ours));
        Assert.Equal(path, UserPathEdit.Remove(path, Ours));
        Assert.Equal(path + ";" + Ours, UserPathEdit.Add(path, Ours));
        Assert.Equal(@"%PATH%;C:\a", UserPathEdit.Remove(path, @"%localappdata%\PopGuy\current\bin"));
    }
}
