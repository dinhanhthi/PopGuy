import { useMemo, useState } from "react";
import { RichText } from "../components/RichText";
import { libraryCategories, libraryPresets, libraryStats } from "../data/actionLibrary";

const builtIn = [
  ["Improve", "rewrite for clarity."],
  ["Shorten", "cut the fluff, keep the meaning."],
  ["Proofread", "fix grammar and spelling."],
  ["Translate", "any language, any provider."],
  ["Prompt", "ask anything with your own prompt."],
  ["Speak", "read the text aloud."],
  ["Look up", "look up the word."]
];

const actionTypes = [
  ["AI", "send text to any AI model with your prompt."],
  ["Translate", "DeepL, Google Translate, or any AI model."],
  ["Speech", "system or cloud voices."],
  ["Dictionary", "macOS Dictionary, Free Dictionary API, and more."],
  ["Open URL", "build a URL from the text."],
  ["Shell Script", "run a command. The text comes in `$POPGUY_TEXT`."],
  ["AppleScript", "run AppleScript. The text is safely quoted."],
  ["Run Shortcut", "run a macOS Shortcut."]
];

export function ActionsPage() {
  const [query, setQuery] = useState("");
  const q = query.trim().toLowerCase();

  const groups = useMemo(
    () =>
      libraryCategories
        .map((category) => ({
          category,
          presets: libraryPresets.filter(
            (preset) =>
              preset.category === category.id &&
              (!q ||
                preset.name.toLowerCase().includes(q) ||
                preset.description.toLowerCase().includes(q))
          )
        }))
        .filter((group) => group.presets.length > 0),
    [q]
  );

  return (
    <main>
      <section className="hero">
        <h1>Actions</h1>
        <p>Everything the toolbar can do. Use the built-in ones, or make your own.</p>
      </section>

      <section>
        <h2>Built-in</h2>
        <ul className="list">
          {builtIn.map(([name, text]) => (
            <li key={name}><strong>{name}</strong>: {text}</li>
          ))}
        </ul>
      </section>

      <section>
        <h2>Action types</h2>
        <ul className="list">
          {actionTypes.map(([name, text]) => (
            <li key={name}><strong>{name}</strong>: <RichText text={text} /></li>
          ))}
        </ul>
      </section>

      <section>
        <h2>Action library</h2>
        <p className="note">
          {libraryStats.total} ready-made actions in {libraryStats.categories} groups. Install them from the app.
        </p>
        <input
          type="search"
          className="search"
          placeholder="Search actions…"
          aria-label="Search actions"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
        {groups.length === 0 ? (
          <p className="note">No actions match "{query.trim()}".</p>
        ) : (
          groups.map(({ category, presets }) => (
            // Keyed by query state so groups re-open/close when searching starts or ends.
            <details key={`${category.id}-${Boolean(q)}`} className="group" open={Boolean(q)}>
              <summary>
                {category.name} <span className="count">{presets.length}</span>
              </summary>
              <ul className="list">
                {presets.map((preset) => (
                  <li key={preset.id}>
                    <strong>{preset.name}</strong>: {preset.description}
                  </li>
                ))}
              </ul>
            </details>
          ))
        )}
      </section>

      <section>
        <h2>Make your own</h2>
        <ol className="steps">
          <li>In the app: Settings → Actions → Add. Set a name, icon, type, and content.</li>
          <li>From a file: export any action as <code>.json</code>, share it, and others import it.</li>
        </ol>
      </section>
    </main>
  );
}
