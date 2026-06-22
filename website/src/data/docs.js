export const docsSections = [
  "Installation",
  "Privacy",
  "Action Types",
  "Create an Action"
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
        body: "Export any action as a .json file via Settings → Actions → Export. Edit it by hand, share it, and others import it via Import Plugin → Choose file. This is the native PopGuy plugin format."
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
        body: "Actions are declarative: a URL template, a shortcut name, an AppleScript, or a shell command. There is no JavaScript engine or SDK. Anything PopClip expresses in JavaScript must be rewritten as a shell script. Shell actions should rely on tools that ship with macOS — awk, sed, tr, base64, shasum — since python3 is not guaranteed on a clean install."
      }
    ]
  }
};