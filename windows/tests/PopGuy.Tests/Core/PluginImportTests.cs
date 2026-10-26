using System.IO.Compression;
using PopGuy.Core.Actions;
using PopGuy.Core.Plugins;

namespace PopGuy.Tests.Core;

// Security and contract: the PopClip import pipeline reads untrusted extensions without running anything
// (spec-4 §5.3–5.5, PopClipExtensionReader.swift, PopClipToPopGuyAdapter.swift).
public class PluginImportTests
{
    private static string MacExample(string name) =>
        Path.Combine(AppContext.BaseDirectory, "Fixtures", "macos-examples", name);

    private static (string Label, string Reason)[] Notes(PluginImportResult result) =>
        result.Skipped.Select(s => (s.Label, s.Reason)).ToArray();

    private static MemoryStream Zip(params (string Name, string Content)[] entries)
    {
        var stream = new MemoryStream();
        using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (var (name, content) in entries)
            {
                using var writer = new StreamWriter(zip.CreateEntry(name).Open());
                writer.Write(content);
            }
        }
        stream.Position = 0;
        return stream;
    }

    [Fact]
    public void BingJsonFolderBecomesOpenUrlAction()
    {
        var result = PopClipAdapter.Adapt(PopClipReader.ReadFolder(MacExample("Bing.popclipext")));

        Assert.Equal("Bing", result.SourceName);
        var imported = Assert.Single(result.Imported);
        var action = imported.Action;
        Assert.Equal("Bing", action.Title);
        Assert.Equal(CustomActionType.OpenUrl, action.Type);
        Assert.Equal("http://www.bing.com/search?q={text}", action.ScriptSource);
        Assert.Equal("(?s)^.{1,1900}$", action.AppliesWhenRegex);
        Assert.Equal(ActionIcon.Default, action.Icon);
        Assert.Equal(AfterRunBehavior.CloseToolbar, action.AfterRun);
        Assert.Equal("", action.SystemPrompt);
        Assert.True(action.IsFromPlugin);
        Assert.True(action.IsEnabled);
        Assert.False(imported.WrittenForMacShell);
        Assert.Equal([("Bing", "icon 'bing.svg' not supported, using default icon")], Notes(result));
    }

    [Fact]
    public void AlfredYamlFolderIsKeptAsAppleScriptButNotRunnable()
    {
        var result = PopClipAdapter.Adapt(PopClipReader.ReadFolder(MacExample("Alfred.popclipext")));

        var action = Assert.Single(result.Imported).Action;
        Assert.Equal("Alfred", action.Title);
        Assert.Equal(CustomActionType.AppleScript, action.Type);
        // The quoted placeholder keeps its quotes (spec-4 §5.5 "Known quirk", ported as is).
        Assert.Equal("tell application id \"com.runningwithcrayons.Alfred\" to search \"{text}\"", action.ScriptSource);
        Assert.False(action.RunnableOnWindows);
        Assert.Equal(
            [
                ("Alfred", "icon 'bowler.png' not supported, using default icon"),
                ("Alfred", PopClipAdapter.NotRunnableOnWindowsReason),
            ],
            Notes(result));
    }

    [Fact]
    public void SnippetMapsEachActionKindWithItsSkipReason()
    {
        const string snippet = """
            ```yaml
            # PopClip
            name: Mixed
            actions:
            - title: Upper
              shell script: echo "$POPCLIP_TEXT" | tr a-z A-Z; echo $POPCLIP_URLS
              after: paste-result
              options: []
            - title: Hello
              javascript: popclip.showText('hi')
            - 42
            - title: Mail
              shortcut name: Send Mail
              requirements: url
            ```
            """;

        var result = PopClipAdapter.Adapt(PopClipReader.ReadSnippet(snippet.Replace("\n", "\r\n")));

        Assert.Equal("Mixed", result.SourceName);
        Assert.Equal(2, result.Imported.Count);
        var (shell, shortcut) = (result.Imported[0], result.Imported[1]);
        Assert.Equal(CustomActionType.ShellScript, shell.Action.Type);
        Assert.Equal("echo \"$POPGUY_TEXT\" | tr a-z A-Z; echo $POPCLIP_URLS", shell.Action.ScriptSource);
        Assert.Equal(AfterRunBehavior.PasteResult, shell.Action.AfterRun);
        // zsh origin: no PowerShell shell, imported disabled, as the native JSON import does.
        Assert.Null(shell.Action.Shell);
        Assert.True(shell.WrittenForMacShell);
        Assert.False(shell.Action.IsEnabled);
        Assert.Equal(CustomActionType.RunShortcut, shortcut.Action.Type);
        Assert.Equal("Send Mail", shortcut.Action.ScriptSource);
        Assert.Equal(
            [
                ("Upper", "uses PopClip variable(s) not translated: POPCLIP_URLS"),
                ("Upper", PopClipAdapter.WrittenForZshReason),
                ("Hello", "JavaScript actions are not supported"),
                ("Mail", "requirement 'url' not enforced"),
                ("Mail", PopClipAdapter.NotRunnableOnWindowsReason),
                ("Mixed", "Plugin options are not supported (actions imported without options)"),
            ],
            Notes(result));
    }

    [Theory]
    [InlineData("name: !!binary aGk=")]
    [InlineData("name: Evil\nicon: !System.Diagnostics.Process { StartInfo: { FileName: calc } }")]
    [InlineData("name: ! plain")]
    [InlineData("name: &a Evil\ntitle: *a")]
    public void YamlTagsAndAliasesAreRejected(string yaml)
    {
        var error = Assert.Throws<PopClipReadException>(() => PopClipReader.ReadSnippet(yaml));

        Assert.Equal(PopClipReadErrorKind.Malformed, error.Kind);
    }

    [Fact]
    public void ZipWrappingAnExtensionFolderReadsLikeTheFolder()
    {
        var config = File.ReadAllText(Path.Combine(MacExample("Bing.popclipext"), "Config.json"));
        using var zip = Zip(("Bing.popclipext/Config.json", config), ("__MACOSX/._Config.json", "x"));

        var result = PopClipAdapter.Adapt(PopClipReader.ReadArchive(zip));

        Assert.Equal("http://www.bing.com/search?q={text}", Assert.Single(result.Imported).Action.ScriptSource);
    }

    [Theory]
    [InlineData("../x")]
    [InlineData("a/../../x")]
    [InlineData("..\\x")]
    [InlineData("/etc/x")]
    [InlineData("C:/x")]
    public void ZipWithAnEscapingEntryIsRejected(string entry)
    {
        using var zip = Zip(("Config.json", """{"name":"Z","url":"https://a.b/?q=***"}"""), (entry, "x"));

        var error = Assert.Throws<PopClipReadException>(() => PopClipReader.ReadArchive(zip));

        Assert.Equal(PopClipReadErrorKind.Malformed, error.Kind);
    }

    [Fact]
    public void ZipFileOverTheSizeCapIsRejected()
    {
        var padded = "{\"name\":\"Big\",\"url\":\"https://a.b/?q=***\",\"pad\":\"" + new string('x', PopClipReader.MaxFileBytes) + "\"}";
        using var zip = Zip(("Config.json", padded));

        var error = Assert.Throws<PopClipReadException>(() => PopClipReader.ReadArchive(zip));

        Assert.Equal(PopClipReadErrorKind.TooLarge, error.Kind);
    }

    [Fact]
    public void XmlPlistFolderIsReadWithItsDoctypeIgnored()
    {
        var bundle = Directory.CreateTempSubdirectory("popclip-");
        try
        {
            File.WriteAllText(Path.Combine(bundle.FullName, "Config.plist"), """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Extension Name</key><string>Ignored</string>
                    <key>name</key><string>Plist</string>
                    <key>url</key><string>https://example.com/?q=***</string>
                </dict>
                </plist>
                """);

            var result = PopClipAdapter.Adapt(PopClipReader.ReadFolder(bundle.FullName));

            Assert.Equal("https://example.com/?q={text}", Assert.Single(result.Imported).Action.ScriptSource);
        }
        finally
        {
            bundle.Delete(recursive: true);
        }
    }

    [Theory]
    [InlineData("../outside.sh")]
    [InlineData("OUTSIDE_ABSOLUTE")]
    public void ScriptFileOutsideTheFolderIsRejected(string scriptFile)
    {
        var root = Directory.CreateTempSubdirectory("popclip-");
        try
        {
            var bundle = root.CreateSubdirectory("Evil.popclipext");
            var outside = Path.Combine(root.FullName, "outside.sh");
            File.WriteAllText(outside, "echo secret");
            var path = scriptFile == "OUTSIDE_ABSOLUTE" ? outside : scriptFile;
            File.WriteAllText(Path.Combine(bundle.FullName, "Config.json"),
                $$"""{"name":"Evil","shell script file":{{System.Text.Json.JsonSerializer.Serialize(path)}}}""");

            var error = Assert.Throws<PopClipReadException>(() => PopClipReader.ReadFolder(bundle.FullName));

            Assert.Equal(PopClipReadErrorKind.Malformed, error.Kind);
        }
        finally
        {
            root.Delete(recursive: true);
        }
    }
}
