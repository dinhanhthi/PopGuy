using PopGuy.Platform.SystemServices;

namespace PopGuy.Platform.Tests;

// Start at login must survive updates: a Velopack install starts the stub outside current\ (which an update replaces);
// any other copy starts itself. Pure: no registry.
public sealed class LaunchAtLoginTests
{
    private static readonly string LocalAppData = Path.Combine(Path.GetTempPath(), "LocalAppData");

    [Theory]
    [InlineData(new[] { "PopGuy", "current", "PopGuy.exe" }, new[] { "PopGuy", "PopGuy.exe" })]
    // A folder that only starts with "current" is not the install.
    [InlineData(new[] { "PopGuy", "current-old", "PopGuy.exe" }, new[] { "PopGuy", "current-old", "PopGuy.exe" })]
    [InlineData(new[] { "Dev", "PopGuy.exe" }, new[] { "Dev", "PopGuy.exe" })]
    public void TargetPath(string[] process, string[] expected)
    {
        var target = LaunchAtLogin.TargetPath(Path.Combine([LocalAppData, .. process]), LocalAppData);

        Assert.Equal(Path.Combine([LocalAppData, .. expected]), target);
    }
}
