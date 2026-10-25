using System.Reflection;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;

namespace PopGuy.Core.Json;

/// <summary>
/// The JSON settings shared by every PopGuy file (settings, plugin export/import). Property names are explicit
/// <c>[JsonPropertyName]</c>s matching the macOS Codable keys; enums are written as their Swift raw values.
/// </summary>
public static class PopGuyJson
{
    public static JsonSerializerOptions Options { get; } = CreateOptions();

    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions
        {
            // Keep URLs, quotes and non-ASCII text readable, as the macOS encoder does.
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            WriteIndented = true,
            // A JSON null or a missing constructor argument fails the decode instead of producing a null value.
            RespectNullableAnnotations = true,
            RespectRequiredConstructorParameters = true,
            TypeInfoResolver = new DefaultJsonTypeInfoResolver(),
        };
        options.MakeReadOnly();
        return options;
    }
}

/// <summary>
/// Reads and writes an enum as its Swift raw value: the member's <c>[JsonStringEnumMemberName]</c>, else its name.
/// Unlike <see cref="JsonStringEnumConverter"/>, matching is exact (case-sensitive, strings only), like Swift's
/// <c>RawRepresentable</c> decoding: an unknown raw value fails the decode.
/// </summary>
public sealed class RawValueEnumConverter<T> : JsonConverter<T> where T : struct, Enum
{
    private static readonly Dictionary<T, string> ToRawMap = Enum.GetValues<T>().ToDictionary(v => v, RawOf);
    private static readonly Dictionary<string, T> FromRawMap = ToRawMap.ToDictionary(p => p.Value, p => p.Key, StringComparer.Ordinal);

    public static string ToRaw(T value) => ToRawMap[value];

    public static bool TryParse(string raw, out T value) => FromRawMap.TryGetValue(raw, out value);

    public override T Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.String && TryParse(reader.GetString()!, out var value))
            return value;
        throw new JsonException($"Unknown {typeof(T).Name} raw value.");
    }

    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options) =>
        writer.WriteStringValue(ToRaw(value));

    private static string RawOf(T value)
    {
        var name = value.ToString();
        var field = typeof(T).GetField(name, BindingFlags.Public | BindingFlags.Static)!;
        return field.GetCustomAttribute<JsonStringEnumMemberNameAttribute>()?.Name ?? name;
    }
}

/// <summary>
/// Typed reads from a <see cref="JsonElement"/> for hand-written converters, mirroring Swift's <c>decode</c> (the key must
/// be present and non-null) and <c>decodeIfPresent</c> (absent or null reads as null). A wrong type throws
/// <see cref="JsonException"/>.
/// </summary>
internal static class JsonRead
{
    public static bool TryGet(JsonElement obj, string key, out JsonElement value) =>
        obj.TryGetProperty(key, out value) && value.ValueKind != JsonValueKind.Null;

    public static JsonElement Required(JsonElement obj, string key) =>
        TryGet(obj, key, out var value) ? value : throw new JsonException($"Missing required key '{key}'.");

    public static string RequiredString(JsonElement obj, string key) => AsString(Required(obj, key), key);

    public static bool RequiredBool(JsonElement obj, string key) => AsBool(Required(obj, key), key);

    public static string? OptionalString(JsonElement obj, string key) =>
        TryGet(obj, key, out var value) ? AsString(value, key) : null;

    public static bool? OptionalBool(JsonElement obj, string key) =>
        TryGet(obj, key, out var value) ? AsBool(value, key) : null;

    public static T Required<T>(JsonElement obj, string key, JsonSerializerOptions options) =>
        Required(obj, key).Deserialize<T>(options) ?? throw new JsonException($"Key '{key}' is null.");

    public static T? Optional<T>(JsonElement obj, string key, JsonSerializerOptions options) where T : class =>
        TryGet(obj, key, out var value) ? value.Deserialize<T>(options) : null;

    public static T? OptionalValue<T>(JsonElement obj, string key, JsonSerializerOptions options) where T : struct =>
        TryGet(obj, key, out var value) ? value.Deserialize<T>(options) : null;

    /// <summary>A hyphenated UUID, as Swift's <c>UUID(uuidString:)</c> accepts.</summary>
    public static Guid Uuid(string raw) =>
        Guid.TryParseExact(raw, "D", out var id) ? id : throw new JsonException($"Invalid UUID: {raw}");

    /// <summary>The uppercase hyphenated form Swift's <c>UUID.uuidString</c> writes.</summary>
    public static string UuidString(Guid id) => id.ToString("D").ToUpperInvariant();

    private static string AsString(JsonElement value, string key) =>
        value.ValueKind == JsonValueKind.String ? value.GetString()! : throw new JsonException($"Key '{key}' is not a string.");

    private static bool AsBool(JsonElement value, string key) => value.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => throw new JsonException($"Key '{key}' is not a boolean."),
    };
}
