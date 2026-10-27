namespace PopGuy.LocalLLM;

/// <summary>One downloadable GGUF chat model: a single file of a Hugging Face repo at a pinned commit.</summary>
/// <param name="Id">Stable id kept in the actions' model field (<c>gguf-…</c>).</param>
/// <param name="Repo">Hugging Face repo id.</param>
/// <param name="Revision">Full 40-character commit SHA the download is pinned to (never <c>main</c>).</param>
/// <param name="File">The <c>.gguf</c> file at the repo root; also its name in the Models folder.</param>
/// <param name="Bytes">Exact file size from the HF tree.</param>
/// <param name="Sha256">Expected SHA-256 of the file, lowercase hex.</param>
/// <param name="ContextTokens">The model's training context window.</param>
/// <param name="RamMB">Estimated memory while loaded, for the RAM guidance in Settings.</param>
public sealed record GgufModel(
    string Id, string DisplayName, string Repo, string Revision, string File, long Bytes, string Sha256,
    int ContextTokens, int RamMB, bool IsDefault = false);

/// <summary>
/// The local models PopGuy for Windows offers (macOS <c>LocalModelCatalog</c>, MLX there): the Q4_K_M quantizations
/// from unsloth, at the revisions, sizes and SHA-256s EchoDiar pinned. Nothing under about 1.5B parameters: smaller
/// models fail the Improve prompt.
/// </summary>
public static class GgufCatalog
{
    public static readonly IReadOnlyList<GgufModel> All =
    [
        new("gguf-qwen3.5-2b", "Qwen3.5 2B",
            "unsloth/Qwen3.5-2B-GGUF", "f6d5376be1edb4d416d56da11e5397a961aca8ae",
            "Qwen3.5-2B-Q4_K_M.gguf", 1_280_835_840,
            "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223", 262_144, 3100),
        new("gguf-gemma-4-e2b", "Gemma 4 E2B",
            "unsloth/gemma-4-E2B-it-GGUF", "0314792d7f1f7e229411f620751375812bb9faf2",
            "gemma-4-E2B-it-Q4_K_M.gguf", 3_106_738_272,
            "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8", 131_072, 4500),
        new("gguf-qwen3.5-4b", "Qwen3.5 4B",
            "unsloth/Qwen3.5-4B-GGUF", "e87f176479d0855a907a41277aca2f8ee7a09523",
            "Qwen3.5-4B-Q4_K_M.gguf", 2_740_937_888,
            "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4", 262_144, 5200, IsDefault: true),
        new("gguf-gemma-4-e4b", "Gemma 4 E4B",
            "unsloth/gemma-4-E4B-it-GGUF", "bfc15c382204943c3a8fff0c750b94ae2364d7a3",
            "gemma-4-E4B-it-Q4_K_M.gguf", 4_977_171_584,
            "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87", 131_072, 6800),
    ];

    public static GgufModel Default { get; } = All.Single(m => m.IsDefault);

    /// <summary>
    /// macOS model ids with a GGUF twin: the MLX catalog id an action keeps, and its repo id (macOS treats an id it
    /// does not know as a repo id, so an exported action may hold one).
    /// </summary>
    private static readonly Dictionary<string, string> MacIds = new(StringComparer.OrdinalIgnoreCase)
    {
        ["qwen3.5-2b"] = "gguf-qwen3.5-2b",
        ["mlx-community/Qwen3.5-2B-MLX-4bit"] = "gguf-qwen3.5-2b",
        ["qwen3.5-4b"] = "gguf-qwen3.5-4b",
        ["mlx-community/Qwen3.5-4B-MLX-4bit"] = "gguf-qwen3.5-4b",
        ["gemma-4-e2b"] = "gguf-gemma-4-e2b",
        ["mlx-community/gemma-4-e2b-it-4bit"] = "gguf-gemma-4-e2b",
        ["gemma-4-e4b"] = "gguf-gemma-4-e4b",
        ["mlx-community/gemma-4-e4b-it-4bit"] = "gguf-gemma-4-e4b",
    };

    public static GgufModel? Find(string? id) => All.FirstOrDefault(m => m.Id == id);

    /// <summary>
    /// The entry an action's model id runs: a catalog id as is, a macOS id through its GGUF twin, anything else
    /// (another macOS model, an empty or unknown id) the default model.
    /// </summary>
    public static GgufModel Resolve(string? id) =>
        Find(id) ?? (id is not null && MacIds.TryGetValue(id, out var twin) ? Find(twin) : null) ?? Default;
}
