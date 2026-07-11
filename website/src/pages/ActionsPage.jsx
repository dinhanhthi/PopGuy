import { useState } from "react";
import {
  Apple,
  ArrowRight,
  BookOpen,
  Bot,
  Languages,
  Link2,
  ListMinus,
  MessageSquareCheck,
  Settings2,
  ShieldCheck,
  SquarePen,
  Terminal,
  Volume2,
  WandSparkles
} from "lucide-react";
import { ButtonLink } from "../components/ButtonLink";
import { ActionLibraryModal } from "../components/ActionLibraryModal";
import { DOWNLOAD_URL, GITHUB_URL } from "../constants";
import { libraryPresets, libraryStats } from "../data/actionLibrary";

const actionTypes = [
  {
    icon: Bot,
    name: "AI",
    text: "Send text to any AI model with your prompt."
  },
  {
    icon: Languages,
    name: "Translate",
    text: "DeepL, Google Translate, or any AI provider."
  },
  {
    icon: Volume2,
    name: "Speech",
    text: "Hear the selection aloud — system or cloud voices."
  },
  {
    icon: BookOpen,
    name: "Dictionary",
    text: "Look up words — macOS built-in, Free Dictionary API, and more."
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
  { icon: WandSparkles, name: "Improve", text: "Rewrite for clarity and flow." },
  { icon: ListMinus, name: "Shorten", text: "Cut the fluff, keep the meaning." },
  { icon: MessageSquareCheck, name: "Proofread", text: "Fix grammar and spelling." },
  { icon: Languages, name: "Translate", text: "Any language, any provider." },
  { icon: SquarePen, name: "Prompt", text: "Ask anything with your own prompt." },
  { icon: Volume2, name: "Speak", text: "Read the selection aloud." },
  { icon: BookOpen, name: "Look up", text: "Look up the selection." }
];

// The 12 most useful, broadly appealing presets across categories.
const featuredPresetIds = [
  "search.google",
  "ai.chatgpt",
  "ai.claude",
  "translate.deepl",
  "web.wikipedia",
  "web.github",
  "maps.google",
  "text.titlecase",
  "dev.jsonprettyprint",
  "dev.base64encode",
  "dev.calculate",
  "apps.obsidian"
];

const featuredLibrary = featuredPresetIds
  .map((id) => libraryPresets.find((preset) => preset.id === id))
  .filter(Boolean);

export function ActionsPage() {
  const [libraryModalOpen, setLibraryModalOpen] = useState(false);

  return (
    <main>
      <section className="page-hero actions-hero section-blue">
        <div className="shell">
          <div>
            <p className="section-label">Actions</p>
            <h1 className="rainbow-title">Anything you do with text.</h1>
            <p className="page-lede">
              Eight action types. Built-in or custom. One toolbar, everywhere.
            </p>
          </div>
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
            {builtIn.map(({ icon: Icon, name, text }) => (
              <article key={name} className="builtin-card">
                <Icon aria-hidden="true" />
                <h3>{name}</h3>
                <p>{text}</p>
              </article>
            ))}
          </div>
        </div>
      </section>

      <section className="shell section-pad">
        <div className="section-heading centered">
          <h2>Action Library</h2>
          <p>{libraryStats.total} ready-to-install actions. Browse, install, done.</p>
        </div>
        <div className="library-stats">
          <span><strong>{libraryStats.total}</strong> actions</span>
          <span aria-hidden="true">·</span>
          <span><strong>{libraryStats.categories}</strong> categories</span>
          <span aria-hidden="true">·</span>
          <span>{libraryStats.local}</span>
        </div>
        <div className="library-grid">
          {featuredLibrary.map((preset) => (
            <article key={preset.id} className="library-card">
              <preset.icon aria-hidden="true" />
              <span className="library-name">{preset.name}</span>
              <span className="library-description">{preset.description}</span>
              <span className="library-type-badge">{preset.type}</span>
            </article>
          ))}
        </div>
        <div className="library-cta">
          <button
            type="button"
            className="button button--secondary"
            onClick={() => setLibraryModalOpen(true)}
          >
            View all {libraryStats.total} <ArrowRight size={16} />
          </button>
        </div>
      </section>

      <section className="section-blue">
        <div className="shell section-pad">
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
        </div>
      </section>

      <section className="download-section page-actions shell">
        <img src="/popguy-logo.png" alt="" />
        <div>
          <h2>Get PopGuy.</h2>
          <div className="inline-actions">
            <ButtonLink href={DOWNLOAD_URL} icon="download">
              Download for macOS
            </ButtonLink>
            <ButtonLink href={GITHUB_URL} icon="github" variant="secondary">
              View on GitHub
            </ButtonLink>
          </div>
          <div className="download-trust">
            <span><ShieldCheck size={15} /> macOS 13+</span>
          </div>
        </div>
      </section>

      <ActionLibraryModal
        open={libraryModalOpen}
        onClose={() => setLibraryModalOpen(false)}
      />
    </main>
  );
}
