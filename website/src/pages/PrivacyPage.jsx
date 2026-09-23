import { RichText } from "../components/RichText";
import { GITHUB_URL } from "../constants";

const LAST_UPDATED = "September 23, 2026";

const sections = [
  {
    title: "The short version",
    bullets: [
      "No account, no sign-up.",
      "No analytics, telemetry, or tracking in the app.",
      "Your text leaves your Mac only when you run an action, and only to the provider you picked.",
      "Everything PopGuy stores stays on your Mac."
    ]
  },
  {
    title: "Text you select",
    body: "PopGuy reads the text you select so it can show the toolbar. Nothing is sent anywhere until you click an action. Then the text goes straight from your Mac to the provider you set for that action (for example OpenAI, Anthropic, Google Gemini, OpenRouter, DeepL, or Google Translate). PopGuy has no server in between. That provider's own privacy policy applies to what you send them.",
    notice: "Local AI models (built-in MLX, Ollama, LM Studio) run on your Mac. With them, your text never leaves your computer."
  },
  {
    title: "API keys",
    body: "Your API keys are stored only in macOS Keychain. They are never written to plain files or `UserDefaults`, and they are only sent to the provider they belong to."
  },
  {
    title: "History",
    body: "PopGuy keeps a history of your recent actions (up to 500) in `~/Library/Application Support/PopGuy/history.json`. It never leaves your Mac. You can turn history off, keep only short previews, or clear it at any time in Settings → History."
  },
  {
    title: "Settings",
    body: "Your preferences and custom actions are saved locally on your Mac. Nothing is synced to a cloud."
  },
  {
    title: "Permissions",
    bullets: [
      "Accessibility — to read the selected text and paste results back.",
      "Screen Recording — only if you use screen text capture (OCR). The capture is read on your Mac and not saved or uploaded.",
      "Automation — only if you set ignored websites. PopGuy reads the current browser tab address to hide the toolbar there. The address is not stored or sent."
    ]
  },
  {
    title: "Clipboard",
    body: "When PopGuy has to copy text with Cmd+C to read it, it puts your previous clipboard back right after."
  },
  {
    title: "Network requests PopGuy makes",
    bullets: [
      "To your chosen AI, translation, speech, or dictionary provider — when you run an action.",
      "To GitHub — to check for updates and download them. You can turn automatic checks off in Settings → About.",
      "To Hugging Face — only when you download a local AI model."
    ]
  },
  {
    title: "This website",
    body: "This site has no cookies and no analytics. It only remembers your light or dark theme in your browser. The hosting provider may keep standard server logs, such as IP addresses."
  },
  {
    title: "Contact",
    body: "Questions about privacy? ",
    link: [`${GITHUB_URL}/discussions`, "Ask on GitHub Discussions"]
  }
];

export function PrivacyPage() {
  return (
    <main>
      <section className="hero">
        <h1>Privacy</h1>
        <p>PopGuy is built to keep your text on your Mac.</p>
        <p className="note">Last updated {LAST_UPDATED}</p>
      </section>

      <div className="docs-content">
        {sections.map((section) => (
          <section key={section.title} className="doc">
            <h2>{section.title}</h2>
            {section.body ? (
              <p>
                <RichText text={section.body} />
                {section.link ? <><a href={section.link[0]} target="_blank" rel="noreferrer">{section.link[1]}</a>.</> : null}
              </p>
            ) : null}
            {section.notice ? <p className="notice"><RichText text={section.notice} /></p> : null}
            {section.bullets ? (
              <ul className="list">
                {section.bullets.map((item) => <li key={item}><RichText text={item} /></li>)}
              </ul>
            ) : null}
          </section>
        ))}
      </div>
    </main>
  );
}
