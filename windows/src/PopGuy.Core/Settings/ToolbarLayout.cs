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

    /// <summary><paramref name="s"/> with <paramref name="id"/> turned on or off; an unknown custom action is left as it is.</summary>
    public static AppSettings WithEnabled(AppSettings s, ActionIdentifier id, bool enabled) => id.Type switch
    {
        ActionIdentifierType.Builtin => id.BuiltinKind switch
        {
            ActionKind.Improve => s with { ImproveEnabled = enabled },
            ActionKind.Shorten => s with { ShortenEnabled = enabled },
            ActionKind.Proofread => s with { ProofreadEnabled = enabled },
            ActionKind.Prompt => s with { PromptEnabled = enabled },
            ActionKind.Translate => s with { TranslateEnabled = enabled },
            _ => s,
        },
        ActionIdentifierType.Speak => s with { SpeakEnabled = enabled },
        ActionIdentifierType.Dictionary => s with { DictionaryConfig = s.DictionaryConfig with { IsEnabled = enabled } },
        _ => s with
        {
            CustomActions = [.. s.CustomActions.Select(a => a.Id == id.CustomId ? a with { IsEnabled = enabled } : a)],
        },
    };

    /// <summary>
    /// True when <paramref name="id"/> is the only enabled action: the toolbar needs at least one, so Settings locks its
    /// switch (macOS isLastEnabledAction).
    /// </summary>
    public static bool IsLastEnabledAction(AppSettings s, ActionIdentifier id) => EnabledOrdered(s) is [var only] && only == id;

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
    /// <paramref name="s"/> with <paramref name="id"/> on the inline row (<paramref name="principal"/>) or in More
    /// actions; the action order is kept (macOS setPrincipal).
    /// </summary>
    public static AppSettings WithPrincipal(AppSettings s, ActionIdentifier id, bool principal)
    {
        var current = s.PrincipalActionIds ?? [];
        if (current.Contains(id) == principal) return s;
        return s with { PrincipalActionIds = principal ? [.. current, id] : [.. current.Where(a => a != id)] };
    }

    public static bool IsLabeled(AppSettings s, ActionIdentifier id) => s.LabeledActionIds.Contains(id);

    /// <summary>
    /// <paramref name="s"/> with <paramref name="id"/>'s toolbar button showing its title next to the icon, or the icon
    /// only (macOS setLabeled). The value is kept while the action is in More actions.
    /// </summary>
    public static AppSettings WithLabeled(AppSettings s, ActionIdentifier id, bool labeled)
    {
        if (IsLabeled(s, id) == labeled) return s;
        return s with { LabeledActionIds = labeled ? [.. s.LabeledActionIds, id] : [.. s.LabeledActionIds.Where(a => a != id)] };
    }

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
        s = WithPrincipal(s, id, toPrincipal);
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

/// <summary>
/// The layout editor's drag math (macOS <c>ToolbarLayoutEditMath</c>): where a dragged action lands among a row's shown
/// actions, and that slot as a <see cref="ToolbarLayout.MoveAction"/> index.
/// </summary>
public static class ToolbarLayoutEditMath
{
    /// <summary>
    /// Insertion index of <paramref name="dragging"/> among the other items of a row, by neighbour swap with hysteresis:
    /// the index steps right only once the pointer passes the centre of the next neighbour, and left only once it passes
    /// the centre of the previous one, so uneven widths (labeled and icon-only buttons) do not flicker.
    /// </summary>
    /// <param name="current">The dragged item's current index among the others; 0 when it is entering the row.</param>
    /// <param name="ordered">The row's shown order (may include <paramref name="dragging"/>).</param>
    /// <param name="centers">Each shown item's horizontal centre; a missing neighbour stops the stepping.</param>
    public static int InsertionIndex(
        double pointerX,
        int current,
        IReadOnlyList<ActionIdentifier> ordered,
        IReadOnlyDictionary<ActionIdentifier, double> centers,
        ActionIdentifier dragging)
    {
        var others = ordered.Where(a => a != dragging).ToList();
        var index = Math.Clamp(current, 0, others.Count);
        while (index < others.Count && centers.TryGetValue(others[index], out var next) && pointerX > next)
            index++;
        while (index > 0 && centers.TryGetValue(others[index - 1], out var previous) && pointerX < previous)
            index--;
        return index;
    }

    /// <summary>
    /// The <see cref="ToolbarLayout.MoveAction"/> index for slot <paramref name="shownIndex"/> among the row's shown
    /// actions (<paramref name="shown"/>): the zone (<paramref name="zone"/>, its enabled actions) may hold actions the
    /// toolbar does not show, so the slot is placed before the shown action it lands on, or after the last shown one.
    /// </summary>
    public static int ZoneIndex(
        IReadOnlyList<ActionIdentifier> zone,
        IReadOnlyList<ActionIdentifier> shown,
        ActionIdentifier dragging,
        int shownIndex)
    {
        var zoneOthers = zone.Where(a => a != dragging).ToList();
        var shownOthers = shown.Where(a => a != dragging && zoneOthers.Contains(a)).ToList();
        if (shownOthers.Count == 0) return zoneOthers.Count;
        var index = Math.Clamp(shownIndex, 0, shownOthers.Count);
        return index < shownOthers.Count
            ? zoneOthers.IndexOf(shownOthers[index])
            : zoneOthers.IndexOf(shownOthers[^1]) + 1;
    }
}
