# Example Plugins

Test fixtures for the PopGuy plugin import pipeline.

---

## Native PopGuy examples

These are authored as valid `[CustomAction]` JSON arrays in the PopGuy native format.

### `search-wikipedia.json`

An Open URL action that searches Wikipedia for the selected text using
`https://en.wikipedia.org/w/index.php?search={text}`.

### `reveal-in-finder.json`

A Shell Script action that calls `open -R "$POPGUY_TEXT"` to reveal the
selected path in Finder. Includes an `appliesWhenRegex` filter so the action
is only shown when the selection looks like a file path or `file://` URL.

---

## Real PopClip extensions (MIT)

These are verbatim copies of open-source PopClip extensions from
<https://github.com/pilotmoon/PopClip-Extensions>, licensed under the
**MIT License** (confirmed via the GitHub API, June 2026).

### `Bing.popclipext`

A single-action URL extension that searches Bing for the selected text.

- Source: <https://github.com/pilotmoon/PopClip-Extensions/tree/master/source/Bing.popclipext>
- Author: Morton Fox (<https://github.com/mortonfox>)
- License: MIT
- Config format: JSON (single-action root)
- Action type: URL — `http://www.bing.com/search?q={popclip text}`

### `Alfred.popclipext`

A single-action AppleScript extension that activates Alfred with the selected text.

- Source: <https://github.com/pilotmoon/PopClip-Extensions/tree/master/source/Alfred.popclipext>
- Author: pilotmoon (<https://github.com/pilotmoon>)
- License: MIT
- Config format: YAML (single-action root)
- Action type: AppleScript — `tell application id "com.runningwithcrayons.Alfred" to search "{popclip text}"`
