import {
  ArrowRight,
  BookOpen,
  Check,
  CheckCircle2,
  Clock3,
  Command,
  KeyRound,
  ShieldCheck,
  Volume2,
  WandSparkles
} from "lucide-react";
import { useState } from "react";
import { ButtonLink } from "../components/ButtonLink";
import { ChangelogModal } from "../components/ChangelogModal";
import { InteractiveDemo } from "../components/InteractiveDemo";
import {
  ProviderLogo,
  providerLogos
} from "../components/ProviderLogos";
import { releases } from "../data/changelog";
import { DOWNLOAD_URL, GITHUB_URL } from "../constants";

const features = [
  {
    icon: WandSparkles,
    title: "Custom actions",
    text: "Your prompts."
  },
  {
    icon: Command,
    title: "Global hotkeys",
    text: "Fast shortcuts."
  },
  {
    icon: Clock3,
    title: "History",
    text: "Recent results."
  },
  {
    icon: Volume2,
    title: "Speech",
    text: "Hear selected text."
  },
  {
    icon: BookOpen,
    title: "Dictionary",
    text: "Look up any word."
  }
];

const freeFeatures = [
  "Built-in actions",
  "8 custom actions",
  "35 recent results",
  "8 ignored apps",
  "5 active toolbar actions",
  "System speech",
  "Every supported provider",
  "Plugin import"
];

const proFeatures = [
  "Unlimited custom actions",
  "Unlimited history",
  "Unlimited ignored apps",
  "Cloud voices",
  "Import and export",
  "History search",
  "Double-click action"
];

export function HomePage() {
  const [changelogOpen, setChangelogOpen] = useState(false);
  const latest = releases[0];

  return (
    <main>
      <section className="hero shell">
        <div className="hero-copy">
          <h1>AI where you write.</h1>
          <p className="hero-lede">Select text. Choose an action. Done.</p>
          <div className="hero-actions">
            <ButtonLink href={DOWNLOAD_URL} icon="download">
              Download for macOS
            </ButtonLink>
            <ButtonLink href={GITHUB_URL} icon="github" variant="secondary">
              View on GitHub
            </ButtonLink>
          </div>
          <p className="system-note">macOS 13+</p>
        </div>
        <div className="hero-demo">
          <InteractiveDemo />
        </div>
      </section>

      <section className="providers section-blue">
        <div className="shell providers-inner">
          <div>
            <p className="section-label">Your models</p>
            <h2>Use your provider.</h2>
            <p>Cloud, local, or CLI.</p>
            <span className="security-line">
              <KeyRound size={16} /> Keys stay in Keychain.
            </span>
          </div>
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

      <section className="features shell section-pad">
        <div className="section-heading centered">
          <p className="section-label">Daily tools</p>
          <h2>Small and useful.</h2>
        </div>
        <div className="feature-row">
          {features.map(({ icon: Icon, title, text }) => (
            <article key={title}>
              <Icon aria-hidden="true" />
              <h3>{title}</h3>
              <p>{text}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="pricing section-blue">
        <div className="shell pricing-focus">
          <article className="free-plan">
            <div className="pricing-title-row">
              <div>
                <span className="plan-label">Free</span>
                <h2>Free and fully capable.</h2>
              </div>
              <strong>$0</strong>
            </div>
            <ul>
              {freeFeatures.map((feature) => (
                <li key={feature}><Check size={17} /> {feature}</li>
              ))}
            </ul>
            <ButtonLink href={DOWNLOAD_URL} icon="download">
              Download for macOS
            </ButtonLink>
          </article>

          <aside className="pro-addon">
            <span className="plan-label">Optional upgrade</span>
            <div className="pro-price">
              <h2>Pro</h2>
              <p><strong>$10</strong> one-time</p>
            </div>
            <p>More room for heavier use.</p>
            <ul>
              {proFeatures.map((feature) => (
                <li key={feature}><Check size={16} /> {feature}</li>
              ))}
            </ul>
            <button className="button button--secondary" disabled>
              Coming soon
            </button>
            <p className="pro-early-note">2 months of Pro, on us — for early adopters.</p>
          </aside>
        </div>
      </section>

      <section className="changelog-preview shell section-pad">
        <div className="section-heading">
          <p className="section-label">Changelog</p>
          <h2>What's new.</h2>
        </div>
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

      <ChangelogModal open={changelogOpen} onClose={() => setChangelogOpen(false)} />
    </main>
  );
}