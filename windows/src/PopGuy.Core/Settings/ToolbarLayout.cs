using PopGuy.Core.Actions;

namespace PopGuy.Core.Settings;

/// <summary>
/// The toolbar layout over <see cref="AppSettings"/> (macOS <c>SettingsStore.swift</c>, Action order): the action order,
/// the inline row (principal set) and More actions (every other enabled action). There are no caps. Mutations return
/// new settings for <see cref="SettingsStore.Update"/>.
/// </summary>
public static class ToolbarLayout
{
    public static bool IsEnabled(AppSettings s, ActionIdentifier id) => id.Type switch
    {
        ActionIdentifierType.Builtin => id.BuiltinKind switch
        {
            ActionKind.Improve => s.ImproveEnabled,
            ActionKind.Shorten => s.ShortenEnabled,
            ActionKind.Proofread => s.ProofreadEnabled,
            ActionKind.Prompt => s.PromptEnabled,
            ActionKind.Translate => s.TranslateEnabled,
            _ => false,
        },
        ActionIdentifierType.Speak => s.SpeakEnabled,
        ActionIdentifierType.Dictionary => s.DictionaryConfig.IsEnabled,
        _ => s.CustomActions.FirstOrDefault(a => a.Id == id.CustomId)?.IsEnabled ?? false,
    };

    /// <summary>The enabled actions, in action order.</summary>
    public static IReadOnlyList<ActionIdentifier> EnabledOrdered(AppSettings s) => [.. s.ActionOrder.Where(id => IsEnabled(s, id))];

    /// <summary>The enabled actions on the inline row, in action order.</summary>
    public static IReadOnlyList<ActionIdentifier> PrincipalOrdered(AppSettings s) =>
        [.. EnabledOrdered(s).Where(id => IsPrincipal(s, id))];

    /// <summary>The enabled actions in More actions, in action order.</summary>
    public static IReadOnlyList<ActionIdentifier> OverflowOrdered(AppSettings s) =>
        [.. EnabledOrdered(s).Where(id => !IsPrincipal(s, id))];

    public static bool IsPrincipal(AppSettings s, ActionIdentifier id) => s.PrincipalActionIds?.Contains(id) ?? false;

    /// <summary>
    /// The settings as loaded: the action order cleaned up (<see cref="ReconcileOrder"/>), stale ids dropped from the
    /// inline row, and on first launch (no principal set yet) every enabled action put inline (macOS: no caps). An empty principal set is the user's choice and is kept.
    /// </summary>
    public static AppSettings Reconciled(AppSettings s)
    {
        var order = ReconcileOrder(s.ActionOrder, s.CustomActions);
        var reconciled = s with { ActionOrder = order };
        IReadOnlyList<ActionIdentifier> principal = s.PrincipalActionIds is { } persisted
            ? [.. order.Where(persisted.Contains)]
            : [.. EnabledOrdered(reconciled)];
        return reconciled with { PrincipalActionIds = principal };
    }

    /// <summary>
    /// The built-ins then every custom action, in <paramref name="persisted"/> order where present: duplicates and
    /// unknown ids are dropped (first wins), and missing actions are appended in canonical order.
    /// </summary>
    public static IReadOnlyList<ActionIdentifier> ReconcileOrder(IReadOnlyList<ActionIdentifier> persisted, IReadOnlyList<CustomAction> customActions)
    {
        IReadOnlyList<ActionIdentifier> canonical = [.. AppSettings.DefaultBuiltinOrder, .. customActions.Select(a => ActionIdentifier.Custom(a.Id))];
        var known = canonical.ToHashSet();
        var kept = persisted.Where(known.Contains).Distinct().ToList();
        return [.. kept, .. canonical.Except(kept)];
    }

    /// <summary>
    /// Moves <paramref name="id"/> to the inline row or More actions, at <paramref name="atIndex"/> (clamped) among that
    /// zone's enabled actions; every other action keeps its place. A disabled action only switches zone.
    /// </summary>
    public static AppSettings MoveAction(AppSettings s, ActionIdentifier id, bool toPrincipal, int atIndex)
    {
        var principal = s.PrincipalActionIds ?? [];
        if (principal.Contains(id) != toPrincipal)
            s = s with { PrincipalActionIds = toPrincipal ? [.. principal, id] : [.. principal.Where(a => a != id)] };
        if (!s.ActionOrder.Contains(id) || !IsEnabled(s, id))
            return s;

        bool InZone(ActionIdentifier a) => IsPrincipal(s, a) == toPrincipal && IsEnabled(s, a);
        var reordered = s.ActionOrder.Where(a => InZone(a) && a != id).ToList();
        reordered.Insert(Math.Clamp(atIndex, 0, reordered.Count), id);
        // Each zone slot in the old order takes the next zone member; the other actions stay where they are.
        var slot = 0;
        return s with { ActionOrder = [.. s.ActionOrder.Select(a => InZone(a) ? reordered[slot++] : a)] };
    }
}
