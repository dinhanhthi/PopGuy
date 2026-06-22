import {
  Apple,
  Bot,
  BookOpen,
  Globe,
  Link2,
  Settings2,
  Share2,
  Terminal,
  Volume2
} from "lucide-react";
import { ButtonLink } from "../components/ButtonLink";
import { DOWNLOAD_URL } from "../constants";

const actionTypes = [
  {
    icon: Bot,
    name: "AI",
    text: "Send text to any AI model with your prompt."
  },
  {
    icon: Globe,
    name: "Translate",
    text: "DeepL or Google Translate."
  },
  {
    icon: Volume2,
    name: "Speech",
    text: "Hear the selection aloud."
  },
  {
    icon: BookOpen,
    name: "Dictionary",
    text: "Look up words."
  },
  {
    icon: Link2,
    name: "Open URL",
    text: "Build a URL from the selection."
  },
  {
    icon: Terminal,
    name: "Shell Script",
    text: "Run a shell command. Text via $POPGUY_TEXT."
  },
  {
    icon: Apple,
    name: "AppleScript",
    text: "Run AppleScript. Text safely quoted."
  },
  {
    icon: Settings2,
    name: "Run Shortcut",
    text: "Trigger a macOS Shortcut."
  }
];

const builtIn = [
  { name: "Improve", text: "Rewrite for clarity." },
  { name: "Shorten", text: "Cut the fluff." },
  { name: "Proofread", text: "Fix grammar." },
  { name: "Translate", text: "Any language." },
  { name: "Prompt", text: "Ask anything." },
  { name: "Speak", text: "Read aloud." }
];

const afterRunOptions = [
  "Close toolbar",
  "Do nothing",
  "Copy result",
  "Paste back",
  "Show as popup"
];

export function ActionsPage() {
  return (
    <main>
      <section className="page-hero actions-hero shell">
        <div>
          <p className="section-label">Actions</p>
          <h1>Anything you do with text.</h1>
          <p className="page-lede">
            Eight action types. Built-in or custom. One toolbar, everywhere.
          </p>
        </div>
      </section>

      <section className="shell section-pad">
        <div className="section-heading centered">
          <h2>Action types</h2>
          <p>Four AI-powered. Four scriptable.</p>
        </div>
        <div className="action-grid">
          {actionTypes.map(({ icon: Icon, name, text }) => (
            <article key={name} className="action-card">
              <Icon aria-hidden="true" />
              <h3>{name}</h3>
              <p>{text}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="section-blue">
        <div className="shell section-pad">
          <div className="section-heading centered">
            <h2>Built-in actions</h2>
            <p>Ready to use. No setup.</p>
          </div>
          <div className="builtin-grid">
            {builtIn.map(({ name, text }) => (
              <article key={name} className="builtin-card">
                <h3>{name}</h3>
                <p>{text}</p>
              </article>
            ))}
          </div>
        </div>
      </section>

      <section className="shell section-pad">
        <div className="section-heading">
          <h2>Make your own.</h2>
          <p>Two ways to create custom actions.</p>
        </div>
        <div className="create-ways">
          <article className="create-card">
            <span className="create-number">1</span>
            <h3>In the app</h3>
            <p>
              Settings → Actions → Add. Set name, icon, type, and content. Done.
            </p>
          </article>
          <article className="create-card">
            <span className="create-number">2</span>
            <h3>Share a JSON file</h3>
            <p>
              Export any action as a <code>.json</code> file. Share it. Others
              import it.
            </p>
          </article>
        </div>
      </section>

      <section className="section-blue">
        <div className="shell section-pad">
          <div className="section-heading">
            <h2>Each action has</h2>
          </div>
          <div className="action-options">
            <article>
              <Settings2 aria-hidden="true" />
              <h3>Icon</h3>
              <p>SF Symbol or emoji.</p>
            </article>
            <article>
              <Share2 aria-hidden="true" />
              <h3>After Run</h3>
              <p>What happens with the result.</p>
              <ul>
                {afterRunOptions.map((option) => (
                  <li key={option}>{option}</li>
                ))}
              </ul>
            </article>
            <article>
              <Bot aria-hidden="true" />
              <h3>Show When</h3>
              <p>Regex filter. Only appear for matching text.</p>
            </article>
          </div>
        </div>
      </section>

      <section className="shell">
        <div className="download-section">
          <img src="/popguy-logo.png" alt="" />
          <div>
            <h2>Start in a minute.</h2>
            <div className="inline-actions">
              <ButtonLink href={DOWNLOAD_URL} icon="download">
                Download for macOS
              </ButtonLink>
            </div>
          </div>
        </div>
      </section>
    </main>
  );
}