export const docsSections = [
  "Installation",
  "Privacy",
  "Action Types",
  "Create an Action",
  "Create a Plugin",
  "PopClip Extensions"
];

export const docsContent = {
  Installation: {
    summary: "Get PopGuy running in under a minute.",
    sections: [
      {
        title: "Download",
        steps: [
          "Download the latest release from GitHub.",
          "Move PopGuy to Applications.",
          "Open PopGuy."
        ],
        stepLinks: [
          "https://github.com/dinhanhthi/PopGuy/releases/latest"
        ]
      },
      {
        title: "Requirements",
        bullets: ["macOS 13+", "Apple Silicon or Intel"]
      }
    ]
  },
  Privacy: {
    summary:
      "PopGuy works across apps, so it needs the Accessibility permission. It is not sandboxed.",
    notice:
      "PopGuy is not sandboxed. Cross-app text capture requires direct Accessibility API access, which the App Store sandbox blocks.",
    sections: [
      {
        title: "Grant Accessibility",
        steps: [
          "Open System Settings.",
          "Go to Privacy & Security → Accessibility.",
          "Enable PopGuy."
        ]
      },
      {
        title: "Your keys stay in Keychain",
        body: "API keys for AI and translation providers are stored only in macOS Keychain under the app bundle id. They are never written to UserDefaults, plist files, or any plaintext store."
      },
      {
        title: "Clipboard is restored",
        body: "When PopGuy falls back to simulating Cmd+C to capture text, it reads the pasteboard then immediately restores whatever you had there before. Your clipboard is never left clobbered."
      },
      {
        title: "Plugins are reviewed before they run",
        body: "Installing a plugin shows a mandatory preview of every script body. Nothing runs until you click an action in the toolbar. There is no signature check — only install plugins you trust."
      }
    ]
  },
  "Action Types": {
    summary: "Eight types. Four powered by AI and providers, four scriptable.",
    sections: [
      {
        title: "AI-powered",
        bullets: [
          "AI — your prompt, any provider and model",
          "Translate — DeepL or Google Translate",
          "Speech — system or cloud voices",
          "Dictionary — look up the selection"
        ]
      },
      {
        title: "Scriptable",
        bullets: [
          "Open URL — build a URL with {text}, auto percent-encoded",
          "Shell Script — text arrives via $POPGUY_TEXT, never interpolated",
          "AppleScript — {text} becomes a safely-quoted string literal",
          "Run Shortcut — trigger a macOS Shortcut with the selection"
        ]
      }
    ]
  },
  "Create an Action": {
    summary: "Two ways to make a custom action. Both take under a minute.",
    sections: [
      {
        title: "Inside the app",
        steps: [
          "Open Settings → Actions → Add Custom Action.",
          "Set the name, icon (SF Symbol or emoji), and type.",
          "Fill in the content — prompt, URL, script, or shortcut name.",
          "Save. The action appears on the toolbar immediately."
        ]
      },
      {
        title: "From a JSON file",
        body: "Export any action as a .json file via Settings → Actions → Export. Edit it by hand, share it, and others import it via Import Plugin → Choose file. This is the native PopGuy plugin format.",
        code: `{
  "name": "Base64 Encode",
  "icon": "square.and.arrow.up",
  "type": "shellScript",
  "scriptSource": "echo "$POPGUY_TEXT" | base64",
  "afterRunBehavior": "pasteResult"
}`
      },
      {
        title: "Per-action options",
        bullets: [
          "Icon — SF Symbol or emoji",
          "After Run — close toolbar, do nothing, copy, paste back, or show popup",
          "Show When (Regex) — only appear when the selection matches a pattern"
        ]
      },
      {
        title: "Limits to know",
        body: "Actions are declarative: a URL template, a shortcut name, an AppleScript, or a shell command. There is no JavaScript engine or SDK. Anything PopClip expresses in JavaScript must be rewritten as a shell script. Shell actions should rely on tools that ship with macOS — awk, sed, tr, base64, shasum — since python3 is not guaranteed on a clean install.",
        code: `# Selection is passed via env var — never interpolated.
echo "$POPGUY_TEXT" | base64`
      }
    ]
  },
  "Create a Plugin": {
    summary:
      "Plugins are JSON files containing one or more actions. Share them, import them, and review every script before anything runs.",
    sections: [
      {
        title: "What a plugin is",
        body: "A plugin is a JSON array of action objects. Each object has the same fields as a single exported action — name, icon, type, scriptSource, afterRunBehavior, and an optional show-when regex. A one-action plugin is an array of one; most plugins bundle several.",
        code: `[
  {
    "name": "URL Encode",
    "icon": "link",
    "type": "shellScript",
    "scriptSource": "printf '%s' "$POPGUY_TEXT" | jq -sRr @uri",
    "afterRunBehavior": "pasteResult"
  },
  {
    "name": "URL Decode",
    "icon": "link",
    "type": "shellScript",
    "scriptSource": "printf '%s' "$POPGUY_TEXT" | jq -sRr @uri",
    "afterRunBehavior": "pasteResult"
  }
]`
      },
      {
        title: "Export a plugin",
        steps: [
          "Open Settings → Actions → Export.",
          "Pick the actions to bundle (or export a single action).",
          "Save the .json file. Share it anywhere."
        ],
        body: "Export is a Pro feature; importing plugins is free. The exported file is plain JSON — no binary, no signature — so anyone can read it before installing."
      },
      {
        title: "Import a plugin",
        steps: [
          "Open Settings → Actions → Import Plugin → Choose file.",
          "Select a .json (native) or .popclipext (PopClip) file.",
          "Review the consent sheet — it shows every action's full source.",
          "Confirm. Imported actions appear on the toolbar immediately."
        ],
        body: "A single import brings in up to 100 actions; the file size cap is 2 MiB. Anything beyond that is rejected before any script is shown."
      },
      {
        title: "The consent step",
        body: "Every import opens a mandatory preview listing every action's full script source and any skipped items (unsupported types, missing fields). Nothing executes during import — scripts only run when you later trigger the action from the toolbar. There is no signature check: the consent preview is the safety boundary, so only install plugins from sources you trust."
      },
      {
        title: "Limitations",
        bullets: [
          "Declarative only — a URL template, a Shortcut name, an AppleScript, or a shell command. No JavaScript engine or SDK.",
          "Shell actions receive the selection via the $POPGUY_TEXT environment variable — never string-interpolated.",
          "Use only tools that ship with macOS (awk, sed, tr, base64, shasum, md5, date, bc, wc, perl). python3 is not guaranteed on a clean install.",
          "No digital signature verification — the consent preview is the safety boundary.",
          "Apple has indicated Perl and Ruby runtimes may be removed in a future macOS — a long-term risk for interpreter-dependent shell actions."
        ]
      }
    ]
  },
  "PopClip Extensions": {
    summary:
      "PopGuy imports PopClip extensions (.popclipext) and PopClip snippets — URL, shell, AppleScript, and Shortcut actions map directly.",
    notice:
      "PopClip is a separate product by PilotPop Ltd. PopGuy is not affiliated with or endorsed by PilotPop.",
    sections: [
      {
        title: "What imports",
        bullets: [
          "URL actions → Open URL (with {text} placeholder rewriting)",
          "Shell script actions → Shell Script ($POPCLIP_TEXT → $POPGUY_TEXT)",
          "AppleScript actions → AppleScript",
          "Shortcut actions → Run Shortcut",
          "Config in Config.plist, Config.json, Config.yaml, or Config.yml",
          "PopClip snippet strings (#popclip + fenced YAML/JSON)"
        ]
      },
      {
        title: "What does NOT import",
        bullets: [
          "JavaScript actions — PopClip's JS uses a proprietary popclip.* API and module system that PopGuy does not implement. Rewrite them as shell scripts.",
          "Key-combo and Service actions — skipped.",
          "Plugin options — actions import without their option sheets.",
          "Requirements other than regex — only regex filters are enforced.",
          "Icons in text:, shape:, image:, or iconify: formats — only symbol: and emoji map; others fall back to a default icon."
        ]
      },
      {
        title: "How to import",
        steps: [
          "Download or unzip the .popclipext bundle.",
          "In PopGuy: Settings → Actions → Import Plugin → Choose file.",
          "Select the .popclipext folder or its Config file.",
          "Review the consent sheet — note any skipped actions.",
          "Confirm. Imported actions appear on the toolbar immediately."
        ]
      },
      {
        title: "Snippet import",
        body: "PopClip snippet strings start with #popclip. Paste one into the Import Plugin snippet box and the adapter converts it to a PopGuy action on the same consent flow.",
        code: `#popclip
name: Uppercase
icon: symbol:characters.uppercase
shell script: |
  echo "$POPCLIP_TEXT" | tr '[:lower:]' '[:upper:]'
after: paste-result`
      }
    ]
  }
};