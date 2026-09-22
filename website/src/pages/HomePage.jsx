import {
  ArrowRight,
  CheckCircle2,
  ShieldCheck
} from "lucide-react";
import { useState } from "react";
import { ButtonLink } from "../components/ButtonLink";
import { ChangelogModal } from "../components/ChangelogModal";
import {
  ProviderLogo,
  providerLogos
} from "../components/ProviderLogos";
import { releases } from "../data/changelog";
import { DOWNLOAD_URL, GITHUB_URL } from "../constants";

const steps = [
  {
    n: "1",
    title: "Select",
    text: "Text in any app, or capture the screen."
  },
  {
    n: "2",
    title: "Act",
    text: "Pick an action from the toolbar."
  },
  {
    n: "3",
    title: "Use",
    text: "Paste back, or copy."
  }
];

const features = [
  {
    title: "Custom actions",
    text: "Your prompts, URLs, scripts, shortcuts."
  },
  {
    title: "Global hotkeys",
    text: "Trigger any action from the keyboard."
  },
  {
    title: "History",
    text: "Recent results, ready to reuse."
  },
  {
    title: "Speech",
    text: "Hear the selection."
  },
  {
    title: "Dictionary",
    text: "Look up any word."
  },
  {
    title: "Screen OCR",
    text: "Capture text from anywhere."
  },
  {
    title: "Translate",
    text: "DeepL, Google Translate, or any AI model."
  },
  {
    title: "Your models",
    text: "Cloud, local, or CLI. Keys stay in Keychain."
  }
];

export function HomePage() {
  const [changelogOpen, setChangelogOpen] = useState(false);
  const latest = releases[0];

  return (
    <main>
      <section className="hero shell">
        <h1>AI where you write.</h1>
        <p className="hero-lede">Select text. Pick an action. Done.</p>
        <a
          className="hero-license"
          href="https://github.com/dinhanhthi/PopGuy/blob/main/LICENSE"
        >
          Now open source under AGPLv3.
        </a>
        <div className="hero-actions">
          <ButtonLink href={DOWNLOAD_URL} icon="download">
            Download for macOS
          </ButtonLink>
          <ButtonLink href={GITHUB_URL} icon="github" variant="secondary">
            View on GitHub
          </ButtonLink>
        </div>
        <p className="system-note">macOS 13+</p>
      </section>

      <section className="workflow shell">
        <h2>How it works</h2>
        <div className="workflow-grid">
          <ol className="workflow-steps">
            {steps.map((step) => (
              <li key={step.n}>
                <span className="workflow-n">{step.n}</span>
                <div>
                  <h3>{step.title}</h3>
                  <p>{step.text}</p>
                </div>
              </li>
            ))}
          </ol>
          <div className="hero-demo">
            <div className="video-frame">
              <iframe
                src="https://player.vimeo.com/video/1209095226?title=0&byline=0&portrait=0&dnt=1"
                title="PopGuy Demo"
                loading="lazy"
                allow="autoplay; fullscreen; picture-in-picture"
                allowFullScreen
              />
            </div>
          </div>
        </div>
      </section>

      <section className="features shell">
        <h2>Features</h2>
        <dl className="feature-sheet">
          {features.map(({ title, text }) => (
            <div key={title}>
              <dt>{title}</dt>
              <dd>{text}</dd>
            </div>
          ))}
        </dl>
      </section>

      <section className="providers">
        <div className="shell providers-inner">
          <h2>Providers</h2>
          <div className="provider-list">
            {providerLogos.map((provider) => (
              <ProviderLogo key={provider.name} {...provider} />
            ))}
          </div>
          <p className="provider-cli-note">
            Claude CLI, Codex CLI, and Gemini CLI use your subscription — no API key.
          </p>
        </div>
      </section>

      <section className="changelog-preview shell">
        <h2>What's new</h2>
        <article className="latest-release">
          <div className="version-line">
            <h3>{latest.version}</h3>
            {latest.latest ? <span>Latest</span> : null}
            <time>{latest.date}</time>
          </div>
          <p className="latest-release-title">{latest.title}</p>
          <ul className="release-list">
            {latest.items.map((item) => (
              <li key={item}><CheckCircle2 size={16} /> {item}</li>
            ))}
          </ul>
          <button
            type="button"
            className="see-more"
            onClick={() => setChangelogOpen(true)}
          >
            See more <ArrowRight size={15} />
          </button>
        </article>
      </section>

      <section className="download-section shell">
        <img src="/popguy-logo.png" alt="" />
        <div>
          <h2>Get PopGuy</h2>
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

      <ChangelogModal open={changelogOpen} onClose={() => setChangelogOpen(false)} />
    </main>
  );
}
