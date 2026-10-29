import { useEffect, useState } from "react";
import { ButtonLink } from "../components/ButtonLink";
import {
  DOWNLOAD_URL,
  GITHUB_URL,
  WINDOWS_DOWNLOAD_ARM64,
  WINDOWS_DOWNLOAD_X64,
  WINDOWS_RELEASE_URL
} from "../constants";
import { detectOs, detectWindowsArch } from "../platform";

const windowsSetup = { x64: WINDOWS_DOWNLOAD_X64, arm64: WINDOWS_DOWNLOAD_ARM64 };
const archLabel = { x64: "x64", arm64: "ARM64" };

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
  ["AI", "OpenAI, Anthropic, Gemini, OpenRouter, GLM, any OpenAI-compatible API, Ollama, LM Studio, and local models (MLX on Mac, llama.cpp on Windows)."],
  ["CLI", "Claude, Codex, and Gemini CLI use your subscription. No API key needed."],
  ["Translate", "DeepL, Google Translate."],
  ["Speech", "system voices, Google Cloud TTS, Azure Speech."],
  ["Dictionary", "macOS Dictionary (Mac), Wiktionary, and more."]
];

/**
 * The two download buttons on one line, their notes on the line below. The visitor's system comes first, as the
 * primary button. On a Windows PC the button takes the installer for its chip; the other builds are on the release page.
 */
function Downloads() {
  const os = detectOs();
  const [arch, setArch] = useState("x64");

  useEffect(() => {
    // Only a Windows PC's chip matters: a Mac's (Apple Silicon reports "arm") must not pick the ARM64 build.
    if (os !== "windows") return undefined;
    let live = true;
    detectWindowsArch().then((found) => {
      if (live) setArch(found);
    });
    return () => {
      live = false;
    };
  }, [os]);

  const windowsFirst = os === "windows";

  const macButton = (
    <ButtonLink href={DOWNLOAD_URL} icon="download" variant={windowsFirst ? "secondary" : "primary"} key="mac">
      Download for macOS
    </ButtonLink>
  );
  const windowsButton = (
    <ButtonLink href={windowsSetup[arch]} icon="download" variant={windowsFirst ? "primary" : "secondary"} key="windows">
      Download for Windows
    </ButtonLink>
  );
  const macNote = <span key="mac">macOS 13+, Apple Silicon &amp; Intel</span>;
  const windowsNote = (
    <span key="windows">
      Windows 11, {archLabel[arch]}, not code-signed yet (<a href="/docs#windows">why</a>)
    </span>
  );
  const notes = windowsFirst ? [windowsNote, macNote] : [macNote, windowsNote];

  return (
    <div className="downloads">
      <div className="download-buttons">{windowsFirst ? [windowsButton, macButton] : [macButton, windowsButton]}</div>
      <p className="note">
        {notes[0]} · {notes[1]} · <a href={WINDOWS_RELEASE_URL}>other downloads</a>
      </p>
    </div>
  );
}

export function HomePage() {
  return (
    <main>
      <section className="hero">
        <h1>A guy pops up from your selected text with magic.</h1>
        <p>Select text in any app on your Mac or PC, pick an action, and get the result right there.</p>
        <Downloads />
        <p className="note">
          Free and open source on <a href={GITHUB_URL}>GitHub</a>.
        </p>
      </section>

      <div className="video-frame">
        <iframe
          src="https://www.youtube-nocookie.com/embed/-ctYYSC4bWM?rel=0"
          title="PopGuy Demo"
          loading="lazy"
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
          referrerPolicy="strict-origin-when-cross-origin"
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
