namespace PopGuy.Core.Providers;

// The user-facing side of the Settings Providers page's checks (macOS SettingsView.swift: maskedKeyPreview,
// mapVerifyOutcome, mapModelCheckOutcome, validationMessage), kept here so the mapping is testable without the UI.

/// <summary>The result of a saved-key Verify or a model Check (macOS <c>VerifyOutcome</c>).</summary>
public enum VerifyOutcome
{
    /// <summary>The key (or model) was accepted.</summary>
    Valid,

    /// <summary>The provider rejected the key (HTTP 400/401/403; a model check also 404).</summary>
    Invalid,

    /// <summary>Any other HTTP error or a network failure: the key could not be confirmed either way.</summary>
    Unreachable,

    /// <summary>Custom has no base URL, so there is nothing to verify against.</summary>
    NoEndpoint,

    /// <summary>No key is saved.</summary>
    NoKey,
}

/// <summary>Masked previews, outcome mapping and the messages of the Providers page (spec-3 §1.12, §5.2).</summary>
public static class ProviderFeedback
{
    public const string MissingRegionMessage = "Azure region is required — set it above the API key field.";
    public const string InvalidRegionMessage = "Use the Azure region's short name, like eastus — not its display name.";
    public const string MissingKeyMessage = "Enter an API key.";
    public const string NetworkMessage = "Could not connect to the server. Check your network connection and try again.";
    public const string InvalidKeyMessage = "Invalid API key. Please check and try again.";
    public const string UnverifiedMessage = "Could not verify your API key. Please try again.";
    public const string LocalPathRequiredMessage = @"Use a local path — network (\\server\…) and \\?\ paths are not allowed.";

    /// <summary>
    /// A short preview that reminds the user which key is saved without revealing it: at most a quarter of the key.
    /// 28 characters or more → the first 3 (a provider prefix such as "sk-") + "…" + the last 4; 12 or more → "…" +
    /// the last 3; shorter → "…". Null for no key. Stricter than macOS <c>maskedKeyPreview</c> (12 + 10 characters,
    /// over half of a 36-character DeepL key).
    /// </summary>
    public static string? MaskedPreview(string? key)
    {
        if (string.IsNullOrEmpty(key)) return null;
        if (key.Length >= 28) return $"{key[..3]}…{key[^4..]}";
        if (key.Length >= 12) return $"…{key[^3..]}";
        return "…";
    }

    /// <summary>A saved-key Verify result (macOS <c>mapVerifyOutcome</c>): <paramref name="error"/> null is a success.</summary>
    public static VerifyOutcome MapVerifyOutcome(Exception? error, bool hasKey, bool customEndpointMissing)
    {
        if (!hasKey) return VerifyOutcome.NoKey;
        if (customEndpointMissing) return VerifyOutcome.NoEndpoint;
        if (error is null) return VerifyOutcome.Valid;
        return error is ProviderError { Kind: ProviderErrorKind.Http, StatusCode: 400 or 401 or 403 }
            ? VerifyOutcome.Invalid
            : VerifyOutcome.Unreachable;
    }

    /// <summary>A model Check result (macOS <c>mapModelCheckOutcome</c>): an unknown model (404) is invalid too.</summary>
    public static VerifyOutcome MapModelCheckOutcome(Exception? error, bool customEndpointMissing)
    {
        if (customEndpointMissing) return VerifyOutcome.NoEndpoint;
        if (error is null) return VerifyOutcome.Valid;
        return error is ProviderError { Kind: ProviderErrorKind.Http, StatusCode: 400 or 401 or 403 or 404 }
            ? VerifyOutcome.Invalid
            : VerifyOutcome.Unreachable;
    }

    /// <summary>The inline text of a saved-key Verify result.</summary>
    public static string VerifyText(VerifyOutcome outcome) => outcome switch
    {
        VerifyOutcome.Valid => "Key is valid",
        VerifyOutcome.Invalid => "Key invalid",
        VerifyOutcome.Unreachable => "Couldn't reach provider",
        VerifyOutcome.NoEndpoint => "Set the base URL first",
        _ => "No key saved",
    };

    /// <summary>
    /// Why a key was not saved (macOS <c>validationMessage</c>): an invalid key (400/401/403) is told apart from a network
    /// problem, which must not claim the key is invalid.
    /// </summary>
    public static string ValidationMessage(Exception error) => error switch
    {
        ProviderError { Kind: ProviderErrorKind.Http, StatusCode: 400 or 401 or 403 } => InvalidKeyMessage,
        ProviderError { Kind: ProviderErrorKind.Http, StatusCode: { } code } => $"Could not verify your API key (HTTP {code}).",
        ProviderError { Kind: ProviderErrorKind.Transport } or HttpRequestException => NetworkMessage,
        _ => UnverifiedMessage,
    };

    /// <summary>
    /// The message for a CLI path that may not be used, else null: a UNC path (<c>\\server\share</c>, also with
    /// forward slashes) or a <c>\\?\</c> / <c>\\.\</c> device path would start a program from another machine or
    /// bypass Windows' path checks (Phase 11 security review).
    /// </summary>
    public static string? CliPathRejection(string path)
    {
        var trimmed = path.Trim();
        return trimmed.StartsWith(@"\\", StringComparison.Ordinal) || trimmed.StartsWith("//", StringComparison.Ordinal)
            || trimmed.StartsWith(@"\/", StringComparison.Ordinal) || trimmed.StartsWith(@"/\", StringComparison.Ordinal)
            ? LocalPathRequiredMessage
            : null;
    }
}
