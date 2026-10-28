using PopGuy.Core.Actions;

namespace PopGuy.Core.Library;

// AI Writing presets (macOS ActionLibrary+AI.swift): an AI action with a fixed system prompt, verbatim. The prompt
// must not contain {{text}} (the engine would move it into the user message). The provider and model are the
// CustomAction defaults here; InstallableAction replaces them with the Improve action's.
public static partial class ActionLibrary
{
    private static LibraryPreset[] AiPresets() =>
    [
        new("ai.humanize", LibraryCategory.AiWriting, () => new CustomAction
        {
            Title = "Humanize",
            ActionDescription = "Rewrite AI-sounding text so it reads like a person wrote it.",
            Icon = ActionIcon.SfSymbol("person.wave.2"),
            Type = CustomActionType.Ai,
            SystemPrompt = """
                Rewrite the text below so it reads like a person wrote it, not a language model.

                Reorganize it as you see fit. Vary sentence length on purpose. Cut hedging, throat-clearing, and any sentence that only announces what comes next. Prefer the concrete word over the abstract one. It is fine to sound uneven.

                Every fact, number, unit, date, name and quotation must survive unchanged. Keep the original language. Return only the rewritten text, with no commentary.
                """,
        }),
    ];
}
