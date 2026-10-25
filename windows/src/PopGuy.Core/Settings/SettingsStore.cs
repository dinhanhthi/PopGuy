using System.Text.Json;
using PopGuy.Core.Actions;
using PopGuy.Core.Json;

namespace PopGuy.Core.Settings;

/// <summary>
/// Loads and saves settings.json. Every change goes through <see cref="Update"/> (or the custom-action API on top of
/// it): the new settings are written atomically, then <see cref="Changed"/> fires. A file that does not decode is
/// renamed <c>settings.corrupt-&lt;UTC timestamp&gt;.json</c> and the defaults load.
/// </summary>
public sealed class SettingsStore
{
    private readonly string _path;

    public SettingsStore(AppPaths paths)
    {
        _path = paths.SettingsFile;
        var loaded = Load();
        Current = ToolbarLayout.Reconciled(loaded);
        // Persist the first-launch toolbar migration now; a reconciled order waits for the next change (macOS parity).
        if (loaded.PrincipalActionIds is null)
            Save(Current);
    }

    public AppSettings Current { get; private set; }

    /// <summary>Raised after a change is saved (not on load).</summary>
    public event EventHandler? Changed;

    public void Update(Func<AppSettings, AppSettings> change)
    {
        var updated = change(Current);
        Save(updated);
        Current = updated;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    // MARK: - Custom actions (SettingsStore.swift addCustomAction / updateCustomAction / deleteCustomAction)

    /// <summary>Appends the action and puts it last in the action order. Every add path (editor, import, Library) uses this.</summary>
    public void AddCustomAction(CustomAction action) => Update(s => s with
    {
        CustomActions = [.. s.CustomActions, action],
        ActionOrder = [.. s.ActionOrder, ActionIdentifier.Custom(action.Id)],
    });

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

    private AppSettings Load()
    {
        if (!File.Exists(_path))
            return new AppSettings();
        try
        {
            // ReadAllText drops a UTF-8 BOM, which the JSON reader refuses.
            if (JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(_path), PopGuyJson.Options) is { } loaded)
                return loaded;
        }
        catch (JsonException)
        {
        }
        var backup = Path.Combine(Path.GetDirectoryName(_path)!, $"settings.corrupt-{DateTime.UtcNow:yyyyMMdd-HHmmss}.json");
        File.Move(_path, backup, overwrite: true);
        return new AppSettings();
    }

    private void Save(AppSettings settings) => PopGuyJson.WriteFileAtomically(_path, settings);
}
