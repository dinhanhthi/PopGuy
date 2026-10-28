namespace PopGuy.Core;

/// <summary>
/// Where PopGuy keeps its files: settings and history in <see cref="DataDirectory"/> (<c>%APPDATA%\PopGuy</c>), caches
/// and models in <see cref="CacheDirectory"/> (<c>%LOCALAPPDATA%\PopGuyData</c>, outside Velopack's
/// <c>%LOCALAPPDATA%\PopGuy</c>). The <c>POPGUY_DATA_ROOT</c> variable moves both under one root, as
/// <c>&lt;root&gt;\Data</c> and <c>&lt;root&gt;\Cache</c> (tests and QA). Nothing is created here.
/// </summary>
public sealed record AppPaths(string DataDirectory, string CacheDirectory)
{
    public const string DataRootVariable = "POPGUY_DATA_ROOT";

    public string SettingsFile => Path.Combine(DataDirectory, "settings.json");

    public string HistoryFile => Path.Combine(DataDirectory, "history.json");

    public static AppPaths Resolve() => Resolve(Environment.GetEnvironmentVariable(DataRootVariable));

    /// <summary>The paths under <paramref name="dataRoot"/>, or the per-user folders when it is null or empty.</summary>
    public static AppPaths Resolve(string? dataRoot) => string.IsNullOrEmpty(dataRoot)
        ? new(
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PopGuy"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PopGuyData"))
        : new(Path.Combine(dataRoot, "Data"), Path.Combine(dataRoot, "Cache"));
}
