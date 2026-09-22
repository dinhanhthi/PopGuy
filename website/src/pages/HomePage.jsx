import { ButtonLink } from "../components/ButtonLink";
import { DOWNLOAD_URL, GITHUB_URL } from "../constants";

const steps = [
  "Select text in any app, or capture text from the screen.",
  "Pick an action from the toolbar that pops up.",
  "Paste the result back, or copy it."
];

const features = [
  ["Custom actions", "your own prompts, URLs, scripts, and Shortcuts."],
  ["Hotkeys", "run any action from the keyboard."],
  ["History", "reuse recent results."],
  ["Translate", "DeepL, Google Translate, or any AI model."],
  ["Speech", "hear the selected text."],
  ["Dictionary", "look up any word."],
  ["Screen text", "grab text from anywhere on screen."]
];

const providers = [
  ["AI", "OpenAI, Anthropic, Gemini, OpenRouter, GLM, any OpenAI-compatible API, Ollama, LM Studio, and local MLX models."],
  ["CLI", "Claude, Codex, and Gemini CLI use your subscription. No API key needed."],
  ["Translate", "DeepL, Google Translate."],
  ["Speech", "macOS voices, Google Cloud TTS, Azure Speech."],
  ["Dictionary", "macOS Dictionary, Wiktionary, and more."]
];

export function HomePage() {
  return (
    <main>
      <section className="hero">
        <h1>AI where you write.</h1>
        <p>Select text in any Mac app, pick an action, and get the result right there.</p>
        <div className="actions">
          <ButtonLink href={DOWNLOAD_URL} icon="download">Download</ButtonLink>
          <ButtonLink href={GITHUB_URL} icon="github" variant="secondary">GitHub</ButtonLink>
        </div>
        <p className="note">Free and open source. macOS 13+. Keys stay in Keychain.</p>
      </section>

      <div className="video-frame">
        <iframe
          src="https://player.vimeo.com/video/1209095226?title=0&byline=0&portrait=0&dnt=1"
          title="PopGuy Demo"
          loading="lazy"
          allow="autoplay; fullscreen; picture-in-picture"
          allowFullScreen
        />
      </div>

      <section>
        <h2>How it works</h2>
        <ol className="steps">
          {steps.map((step) => <li key={step}>{step}</li>)}
        </ol>
      </section>

      <section>
        <h2>Features</h2>
        <ul className="list">
          {features.map(([name, text]) => (
            <li key={name}><strong>{name}</strong>: {text}</li>
          ))}
        </ul>
      </section>

      <section>
        <h2>Providers</h2>
        <ul className="list">
          {providers.map(([name, text]) => (
            <li key={name}><strong>{name}</strong>: {text}</li>
          ))}
        </ul>
      </section>
    </main>
  );
}
