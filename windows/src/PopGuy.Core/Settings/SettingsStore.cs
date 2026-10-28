using System.Text.Json;
using PopGuy.Core.Actions;
using PopGuy.Core.Json;
using PopGuy.Core.Providers;

namespace PopGuy.Core.Settings;

/// <summary>
/// Loads and saves settings.json. Every change goes through <see cref="Update"/> (or the custom-action API on top of
/// it): the new settings are written atomically, then <see cref="Changed"/> fires. A file that does not decode is
/// renamed <c>settings.corrupt-&lt;UTC timestamp&gt;.json</c> (never overwriting an earlier backup) and the defaults
/// load. A file that cannot be read (locked, no access) or backed up is left in place and the defaults load without
/// being saved; the next <see cref="Update"/> reads it again first, so a change never replaces it with the defaults.
/// Load-time I/O errors never fail the constructor. A deprecated model in the file is replaced on load and the result
/// saved (<see cref="ModelDeprecations"/>).
/// </summary>
public sealed class SettingsStore
{
    private readonly string _path;
    private bool _keepFile;

    public SettingsStore(AppPaths paths)
    {
        _path = paths.SettingsFile;
        var loaded = Load(out _keepFile);
        var migrated = ModelDeprecations.Migrated(loaded);
        Current = ToolbarLayout.Reconciled(migrated);
        // Persist the first-launch toolbar migration and a deprecated-model migration now (macOS parity); otherwise a
        // reconciled order waits for the next change.
        if ((loaded.PrincipalActionIds is null || !ReferenceEquals(migrated, loaded)) && !_keepFile)
        {
            try
            {
                Save(Current);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Keep the defaults in memory; the next change tries again.
            }
        }
    }

    public AppSettings Current { get; private set; }

    /// <summary>Raised after a change is saved (not on load).</summary>
    public event EventHandler? Changed;

    /// <summary>
    /// Applies <paramref name="change"/>, saves, then sets <see cref="Current"/> and raises <see cref="Changed"/>. When
    /// the load left the file in place, it is read again first and the change applies to what it holds (a corrupt file
    /// is backed up and the change applies to the defaults); a file that still cannot be read or backed up throws an
    /// <see cref="IOException"/> instead of being replaced. When the save fails, <see cref="Current"/> keeps the old
    /// value and the exception propagates.
    /// </summary>
    public void Update(Func<AppSettings, AppSettings> change)
    {
        var current = Current;
        if (_keepFile)
        {
            current = ToolbarLayout.Reconciled(ModelDeprecations.Migrated(Load(out var keepFile)));
            if (keepFile)
                throw new IOException("settings.json still cannot be read, so it was not overwritten.");
        }
        var updated = change(current);
        Save(updated);
        _keepFile = false;
        Current = updated;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    // MARK: - Custom actions (SettingsStore.swift addCustomAction / updateCustomAction / deleteCustomAction)

    /// <summary>
    /// Appends the action, a deprecated model migrated first (covers plugin import), and puts it last in the action
    /// order. Every add path (editor, import, Library) uses this.
    /// </summary>
    public void AddCustomAction(CustomAction action)
    {
        action = ModelDeprecations.Migrated(action);
        Update(s => s with
        {
            CustomActions = [.. s.CustomActions, action],
            ActionOrder = [.. s.ActionOrder, ActionIdentifier.Custom(action.Id)],
        });
    }

    /// <summary>Replaces the action with the same id; does nothing when there is none.</summary>
    public void UpdateCustomAction(CustomAction action)
    {
        if (!Current.CustomActions.Any(a => a.Id == action.Id))
            return;
        Update(s => s with { CustomActions = [.. s.CustomActions.Select(a => a.Id == action.Id ? action : a)] });
    }

    /// <summary>Removes the action, its hotkey, and its action-order, inline-row and label entries.</summary>
    public void DeleteCustomAction(Guid id)
    {
        var custom = ActionIdentifier.Custom(id);
        Update(s => s with
        {
            CustomActions = [.. s.CustomActions.Where(a => a.Id != id)],
            ShortcutBindings = [.. s.ShortcutBindings.Where(b => b.Id != custom)],
            ActionOrder = [.. s.ActionOrder.Where(a => a != custom)],
            PrincipalActionIds = s.PrincipalActionIds is { } principal ? [.. principal.Where(a => a != custom)] : null,
            LabeledActionIds = [.. s.LabeledActionIds.Where(a => a != custom)],
        });
    }

    // MARK: - File

    /// <summary><paramref name="keepFile"/>: the file could not be read or backed up, so no save may replace it.</summary>
    private AppSettings Load(out bool keepFile)
    {
        keepFile = false;
        if (!File.Exists(_path))
            return new AppSettings();
        try
        {
            // ReadAllText drops a UTF-8 BOM, which the JSON reader refuses.
            if (JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(_path), PopGuyJson.Options) is { } loaded
                && !HasNullElement(loaded))
                return loaded;
        }
        catch (JsonException)
        {
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Locked or unreadable is not corrupt: leave the file as it is.
            keepFile = true;
            return new AppSettings();
        }
        keepFile = !BackUpCorruptFile();
        return new AppSettings();
    }

    // The nullable annotations don't cover collection elements or dictionary values: a null there is corrupt too.
    private static bool HasNullElement(AppSettings s) =>
        s.CustomActions.Contains(null!) || s.ShortcutBindings.Contains(null!) || s.BabylonDictionaries.Contains(null!)
        || s.TtsProviderConfigs.Values.Contains(null!) || s.IgnoredAppExeNames.Contains(null!)
        || s.IgnoredDomains.Contains(null!) || s.ActionOrder.Contains(null!) || s.LabeledActionIds.Contains(null!)
        || s.PrincipalActionIds?.Contains(null!) == true;

    private bool BackUpCorruptFile()
    {
        var stem = Path.Combine(Path.GetDirectoryName(_path)!, $"settings.corrupt-{DateTime.UtcNow:yyyyMMdd-HHmmss-fff}");
        try
        {
            var backup = stem + ".json";
            for (var i = 2; File.Exists(backup); i++)
                backup = $"{stem}-{i}.json";
            File.Move(_path, backup);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private void Save(AppSettings settings) => PopGuyJson.WriteFileAtomically(_path, settings);
}
