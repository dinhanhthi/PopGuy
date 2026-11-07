// Terminal Composer drafts (macOS ComposerDraftStore.swift): one plain UTF-8 file per draft, "<draft id>.txt", in
// <see cref="DefaultDirectory"/> (%LOCALAPPDATA%\PopGuyData\Composer\drafts). On Windows each file gets a DACL that
// grants only the current user (inheritance off), so the text is never readable by others. The file's last-write time
// is the draft's age.
//
// Policy (applied by the owner): a session's draft is deleted once Done delivered the text; kept on Cancel, after an
// unconfirmed delivery, when the terminal session ends, and on app quit with changed text (Flush).
// Prompt text is never logged; only counts and states.

using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace PopGuy.Core.Composer;

/// <summary>A saved draft: its id and text.</summary>
public readonly record struct ComposerDraft(Guid Id, string Text);

/// <summary>
/// Thread-safe: every member takes one lock, and the file I/O runs under it (drafts are small). Autosave timers fire on
/// the thread pool.
/// </summary>
public sealed class ComposerDraftStore(string directory, Action<string>? log = null)
{
    public static readonly TimeSpan AutosaveDelay = TimeSpan.FromSeconds(2);
    public const int KeepCount = 5;
    public static readonly TimeSpan MaxAge = TimeSpan.FromDays(7);

    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    /// <summary>A debounced save: the latest text and its timer.</summary>
    private sealed class Pending(string text)
    {
        public string Text { get; } = text;
        public Timer? Timer { get; set; }
    }

    private readonly Lock _gate = new();
    // Guarded by _gate.
    private readonly Dictionary<Guid, Pending> _pending = [];
    private readonly Dictionary<Guid, string> _lastSaved = [];

    /// <summary><c>&lt;cache directory&gt;\Composer\drafts</c> (production: %LOCALAPPDATA%\PopGuyData\Composer\drafts).</summary>
    public static string DefaultDirectory(AppPaths paths) => Path.Combine(paths.CacheDirectory, "Composer", "drafts");

    /// <summary>Saves the draft <see cref="AutosaveDelay"/> after the last call for <paramref name="id"/> (debounced autosave).</summary>
    public void ScheduleSave(Guid id, string text)
    {
        lock (_gate)
        {
            DropPendingLocked(id);
            var pending = new Pending(text);
            _pending[id] = pending;
            pending.Timer = new Timer(_ => OnAutosave(id, pending), null, AutosaveDelay, Timeout.InfiniteTimeSpan);
        }
    }

    /// <summary>Saves the draft now (replacing a pending autosave). Empty text removes the draft.</summary>
    public void SaveNow(Guid id, string text)
    {
        lock (_gate)
        {
            DropPendingLocked(id);
            WriteIfChangedLocked(id, text);
        }
    }

    /// <summary>Writes every pending autosave before returning (app quit, composer close).</summary>
    public void Flush()
    {
        lock (_gate)
        {
            foreach (var (id, pending) in _pending.ToList())
            {
                DropPendingLocked(id);
                WriteIfChangedLocked(id, pending.Text);
            }
        }
    }

    /// <summary>Deletes the draft and drops its pending autosave, so it is not written again.</summary>
    public void Delete(Guid id)
    {
        lock (_gate)
        {
            DropPendingLocked(id);
            _lastSaved.Remove(id);
            RemoveFile(id);
        }
    }

    /// <summary>The most recently written non-empty draft other than <paramref name="excluding"/>, for "Restore draft".</summary>
    public ComposerDraft? LatestDraft(Guid? excluding)
    {
        lock (_gate)
        {
            foreach (var (id, _) in ListDrafts())
            {
                if (id == excluding) continue;
                if (Read(id) is { Length: > 0 } text) return new ComposerDraft(id, text);
            }
            return null;
        }
    }

    /// <summary>Deletes drafts older than <see cref="MaxAge"/> and all but the <see cref="KeepCount"/> newest.</summary>
    public void Prune()
    {
        lock (_gate)
        {
            var now = DateTime.UtcNow;
            var removed = 0;
            foreach (var (draft, index) in ListDrafts().Select((draft, index) => (draft, index)))
            {
                if (index < KeepCount && now - draft.Modified <= MaxAge) continue;
                RemoveFile(draft.Id);
                removed++;
            }
            if (removed > 0) log?.Invoke($"composer drafts: pruned {removed} file(s)");
        }
    }

    private void OnAutosave(Guid id, Pending pending)
    {
        lock (_gate)
        {
            // Replaced, flushed or deleted meanwhile.
            if (!_pending.TryGetValue(id, out var current) || current != pending) return;
            DropPendingLocked(id);
            WriteIfChangedLocked(id, pending.Text);
        }
    }

    private void DropPendingLocked(Guid id)
    {
        if (_pending.Remove(id, out var pending)) pending.Timer?.Dispose();
    }

    private void WriteIfChangedLocked(Guid id, string text)
    {
        if (_lastSaved.TryGetValue(id, out var saved) && saved == text) return;
        if (text.Length == 0)
        {
            RemoveFile(id);
            _lastSaved[id] = text;
        }
        else if (Write(id, text))
        {
            _lastSaved[id] = text;
        }
    }

    private bool Write(Guid id, string text)
    {
        var bytes = Utf8.GetBytes(text);
        try
        {
            Directory.CreateDirectory(directory);
            var path = FilePath(id);
            if (OperatingSystem.IsWindows())
            {
                WritePrivate(path, bytes);
            }
            else
            {
                File.WriteAllBytes(path, bytes);
            }
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            log?.Invoke($"composer drafts: save failed, {e.GetType().Name}");
            return false;
        }
    }

    /// <summary>
    /// Writes with a DACL that grants only the current user: set at creation for a new file, and again on the open
    /// handle for an existing one (Windows keeps an existing file's security when it is overwritten).
    /// </summary>
    [SupportedOSPlatform("windows")]
    private static void WritePrivate(string path, byte[] bytes)
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            WindowsIdentity.GetCurrent().User!, FileSystemRights.FullControl, AccessControlType.Allow));
        using var stream = new FileInfo(path).Create(
            FileMode.Create, FileSystemRights.Write | FileSystemRights.ChangePermissions, FileShare.None, 4096,
            FileOptions.None, security);
        stream.SetAccessControl(security);
        stream.Write(bytes);
    }

    private string? Read(Guid id)
    {
        try
        {
            return File.ReadAllText(FilePath(id), Utf8);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private void RemoveFile(Guid id)
    {
        try
        {
            File.Delete(FilePath(id));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            log?.Invoke($"composer drafts: delete failed, {e.GetType().Name}");
        }
    }

    /// <summary>The drafts (regular "&lt;guid&gt;.txt" files, no links), newest first.</summary>
    private List<(Guid Id, DateTime Modified)> ListDrafts()
    {
        var drafts = new List<(Guid, DateTime)>();
        try
        {
            foreach (var file in new DirectoryInfo(directory).EnumerateFiles("*.txt"))
            {
                if ((file.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                if (!Guid.TryParseExact(Path.GetFileNameWithoutExtension(file.Name), "D", out var id)) continue;
                drafts.Add((id, file.LastWriteTimeUtc));
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // No drafts directory yet, or it cannot be read.
        }
        return [.. drafts.OrderByDescending(draft => draft.Item2)];
    }

    private string FilePath(Guid id) => Path.Combine(directory, id.ToString("D") + ".txt");
}
