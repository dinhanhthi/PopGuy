using PopGuy.Core.Composer;

namespace PopGuy.Tests.Core;

// Contract: composer drafts are pruned to the newest 5, and drafts older than 7 days are deleted (macOS
// ComposerDraftStore.prune).
public sealed class ComposerDraftStoreTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "PopGuyTests-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_directory))
            Directory.Delete(_directory, recursive: true);
    }

    /// <summary>Saves a draft and dates its file <paramref name="age"/> ago.</summary>
    private Guid SaveDraft(ComposerDraftStore store, TimeSpan age)
    {
        var id = Guid.NewGuid();
        store.SaveNow(id, $"draft {id}");
        File.SetLastWriteTimeUtc(Path.Combine(_directory, id + ".txt"), DateTime.UtcNow - age);
        return id;
    }

    private HashSet<Guid> DraftsOnDisk() =>
        Directory.EnumerateFiles(_directory, "*.txt").Select(path => Guid.Parse(Path.GetFileNameWithoutExtension(path))).ToHashSet();

    [Fact]
    public void PruneKeepsTheNewestFive()
    {
        var store = new ComposerDraftStore(_directory);
        // Index 0 is the newest; distinct ages so the order is certain.
        var ids = Enumerable.Range(0, 7).Select(i => SaveDraft(store, TimeSpan.FromMinutes(i + 1))).ToList();

        store.Prune();

        Assert.Equal(ids.Take(5).ToHashSet(), DraftsOnDisk());
    }

    [Fact]
    public void PruneDeletesDraftsOlderThanSevenDays()
    {
        var store = new ComposerDraftStore(_directory);
        var recent = SaveDraft(store, TimeSpan.FromDays(6));
        SaveDraft(store, TimeSpan.FromDays(8));

        store.Prune();

        Assert.Equal([recent], DraftsOnDisk());
    }
}
