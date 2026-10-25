using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using PopGuy.Core;
using PopGuy.Core.Actions;
using PopGuy.Core.Secrets;
using PopGuy.Core.Settings;
using PopGuy.Platform.SystemServices;

namespace PopGuy.Platform.Tests;

// Hard constraint: API keys live only in Credential Manager. These run against the real store under random
// PopGuy/test/<guid> ids (never a provider's own target, so a real key is never overwritten), deleted in finally.
public sealed class CredentialStoreTests
{
    private readonly ISecretStore _store = new CredentialStore();

    private static string RandomId() => "PopGuy/test/" + Guid.NewGuid().ToString("N");

    [Fact]
    public void ASecretIsWrittenReadReplacedAndDeleted()
    {
        RequireWindows();
        var id = RandomId();
        try
        {
            _store.Set(id, "sk-first-é漢");
            Assert.Equal("sk-first-é漢", _store.Get(id));
            // An empty secret is a stored "" (an empty blob), not a missing one.
            _store.Set(id, "");
            Assert.Equal("", _store.Get(id));
            _store.Set(id, "sk-second");
            Assert.Equal("sk-second", _store.Get(id));

            // Over the blob limit in UTF-8 bytes (not chars): refused, the error has no key text, the old key stays.
            var marker = Guid.NewGuid().ToString("N");
            var tooLong = marker + new string('é', CredentialStore.MaxSecretBytes / 2);
            Assert.True(tooLong.Length < CredentialStore.MaxSecretBytes);
            var error = Assert.Throws<ArgumentException>(() => _store.Set(id, tooLong));
            Assert.DoesNotContain(marker, error.ToString());
            Assert.Equal("sk-second", _store.Get(id));

            Assert.True(_store.Delete(id));
            Assert.Null(_store.Get(id));
        }
        finally
        {
            _store.Delete(id);
        }
    }

    [Fact]
    public void AMissingIdReadsAsNull()
    {
        RequireWindows();
        var id = RandomId();
        Assert.Null(_store.Get(id));
        Assert.False(_store.Delete(id));
    }

    [Fact]
    public void SavedSettingsNeverHoldTheKey()
    {
        RequireWindows();
        var id = RandomId();
        var key = "sk-settings-" + Guid.NewGuid().ToString("N");
        var root = Path.Combine(Path.GetTempPath(), "PopGuy-cred-" + Guid.NewGuid().ToString("N"));
        try
        {
            _store.Set(id, key);
            var paths = AppPaths.Resolve(root);
            var settings = new SettingsStore(paths);
            settings.Update(s => s with
            {
                ImproveConfig = s.ImproveConfig with { ProviderKind = ProviderKind.Custom },
                CustomBaseUrl = "https://example.invalid/v1",
            });

            var json = File.ReadAllBytes(paths.SettingsFile);
            Assert.True(json.AsSpan().IndexOf("https://example.invalid/v1"u8) >= 0);
            // Secondary: settings never read the store, so this only guards a future code path that writes keys there.
            Assert.True(json.AsSpan().IndexOf(Encoding.UTF8.GetBytes(key)) < 0);
            // The guard: no field that could hold a key, even an empty one.
            using var document = JsonDocument.Parse(json);
            Assert.DoesNotContain(PropertyNames(document.RootElement), name => SecretName.IsMatch(name));
            Assert.Equal(key, _store.Get(id));
        }
        finally
        {
            _store.Delete(id);
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    private static readonly Regex SecretName = new("api_?key|secret|accessToken|authToken|bearer", RegexOptions.IgnoreCase);

    private static IEnumerable<string> PropertyNames(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Object => element.EnumerateObject().SelectMany(p => PropertyNames(p.Value).Prepend(p.Name)),
        JsonValueKind.Array => element.EnumerateArray().SelectMany(PropertyNames),
        _ => [],
    };

    private static void RequireWindows()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("The credential tests need Windows.");
    }
}
