using PopGuy.Core.Actions;
using PopGuy.Core.Json;

namespace PopGuy.Core.Secrets;

/// <summary>
/// API keys by id (macOS <c>KeychainManager</c>). Keys live only here, never in settings.json, history or logs. The
/// Windows store is Platform's <c>CredentialStore</c> (Credential Manager). Errors never carry key text.
/// </summary>
public interface ISecretStore
{
    /// <summary>The saved secret, or null when there is none.</summary>
    string? Get(string id);

    /// <summary>Saves <paramref name="secret"/> as is (an empty one too, as on macOS), replacing an older one.</summary>
    void Set(string id, string secret);

    /// <summary>Deletes the secret; false when there was none.</summary>
    bool Delete(string id);
}

/// <summary>
/// Secret ids, the Credential Manager target names: <c>PopGuy/provider/&lt;ProviderKind raw&gt;</c> and
/// <c>PopGuy/tts/&lt;TtsProviderKind raw&gt;</c> (the macOS Keychain accounts, namespaced).
/// </summary>
public static class SecretIds
{
    public static string Provider(ProviderKind kind) => "PopGuy/provider/" + RawValueEnumConverter<ProviderKind>.ToRaw(kind);

    public static string Tts(TtsProviderKind kind) => "PopGuy/tts/" + RawValueEnumConverter<TtsProviderKind>.ToRaw(kind);
}
