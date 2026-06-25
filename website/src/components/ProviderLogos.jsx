import {
  siAnthropic,
  siDeepl,
  siGooglecloud,
  siGooglegemini,
  siGoogletranslate,
  siOllama,
  siOpenrouter,
  siWikipedia
} from "simple-icons";

// Bootstrap Icons v1.11+ path (16x16 viewBox) — simple-icons v16 does not include OpenAI
const openAI = {
  title: "OpenAI",
  hex: "000000",
  viewBox: "0 0 16 16",
  path: "M14.949 6.547a3.94 3.94 0 0 0-.348-3.273 4.11 4.11 0 0 0-4.4-1.934 4.1 4.1 0 0 0-1.778-.613 4.15 4.15 0 0 0-2.118-.114 4.1 4.1 0 0 0-1.891.948 4.04 4.04 0 0 0-1.158 1.753 4.1 4.1 0 0 0-1.563.679 4 4 0 0 0-1.14 1.253 3.99 3.99 0 0 0 .502 4.731 3.94 3.94 0 0 0 .346 3.274 4.11 4.11 0 0 0 4.402 1.933c.382.425.852.764 1.377.995.526.231 1.095.35 1.67.346 1.78.002 3.358-1.132 3.901-2.804a4.1 4.1 0 0 0 1.563-.68 4 4 0 0 0 1.14-1.253 3.99 3.99 0 0 0-.506-4.716m-6.097 8.406a3.05 3.05 0 0 1-1.945-.694l.096-.054 3.23-1.838a.53.53 0 0 0 .265-.455v-4.49l1.366.778q.02.011.025.035v3.722c-.003 1.653-1.361 2.992-3.037 2.996m-6.53-2.75a2.95 2.95 0 0 1-.36-2.01l.095.057L5.29 12.09a.53.53 0 0 0 .527 0l3.949-2.246v1.555a.05.05 0 0 1-.022.041L6.473 13.3c-1.454.826-3.311.335-4.15-1.098m-.85-6.94A3.02 3.02 0 0 1 3.07 3.949v3.785a.51.51 0 0 0 .262.451l3.93 2.237-1.366.779a.05.05 0 0 1-.048 0L2.585 9.342a2.98 2.98 0 0 1-1.113-4.094zm11.216 2.571L8.747 5.576l1.362-.776a.05.05 0 0 1 .048 0l3.265 1.86a3 3 0 0 1 1.173 1.207 2.96 2.96 0 0 1-.27 3.2 3.05 3.05 0 0 1-1.36.997V8.279a.52.52 0 0 0-.276-.445m1.36-2.015-.097-.057-3.226-1.855a.53.53 0 0 0-.53 0L6.249 6.153V4.598a.04.04 0 0 1 .019-.04L9.533 2.7a3.07 3.07 0 0 1 3.257.139c.474.325.843.778 1.066 1.303.223.526.289 1.103.191 1.664zM5.503 8.575 4.139 7.8a.05.05 0 0 1-.026-.037V4.049c0-.57.166-1.127.476-1.607s.752-.864 1.275-1.105a3.08 3.08 0 0 1 3.234.41l-.096.054-3.23 1.838a.53.53 0 0 0-.265.455zm.742-1.577 1.758-1 1.762 1v2l-1.755 1-1.762-1z"
};

const openAICompat = {
  title: "OpenAI-Compatible",
  hex: "666666",
  path: "M20.5 11H19V7c0-1.1-.9-2-2-2h-4V3.5C13 2.12 11.88 1 10.5 1S8 2.12 8 3.5V5H4c-1.1 0-1.99.9-1.99 2v3.8H3.5c1.49 0 2.7 1.21 2.7 2.7s-1.21 2.7-2.7 2.7H2V20c0 1.1.9 2 2 2h3.8v-1.5c0-1.49 1.21-2.7 2.7-2.7 1.49 0 2.7 1.21 2.7 2.7V22H17c1.1 0 2-.9 2-2v-4h1.5c1.38 0 2.5-1.12 2.5-2.5S21.88 11 20.5 11z"
};

// simple-icons removed microsoftazure in v12; path from simple-icons v11
const azureSpeech = {
  title: "Azure Speech",
  hex: "0078D4",
  path: "M22.379 23.343a1.62 1.62 0 0 0 1.536-2.14v.002L17.35 1.76A1.62 1.62 0 0 0 15.816.657H8.184A1.62 1.62 0 0 0 6.65 1.76L.086 21.204a1.62 1.62 0 0 0 1.536 2.139h4.741a1.62 1.62 0 0 0 1.535-1.103l.977-2.892 4.947 3.675c.28.208.618.32.966.32m-3.084-12.531 3.624 10.739a.54.54 0 0 1-.51.713v-.001h-.03a.54.54 0 0 1-.322-.106l-9.287-6.9h4.853m6.313 7.006c.116-.326.13-.694.007-1.058L9.79 1.76a1.722 1.722 0 0 0-.007-.02h6.034a.54.54 0 0 1 .512.366l6.562 19.445a.54.54 0 0 1-.338.684"
};

// Material Design "book" filled icon — represents GoldenDict, Apple Dictionary, Wiktionary
const dictionaries = {
  title: "Dictionaries",
  hex: "555555",
  path: "M18 2H6c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zM6 4h5v8l-2.5-1.5L6 12V4z"
};

const zAI = {
  title: "Z.ai",
  viewBox: "0 0 512 512",
  paths: [
    {
      d: "M96 18h320c43 0 78 35 78 78v320c0 43-35 78-78 78H96c-43 0-78-35-78-78V96c0-43 35-78 78-78Z",
      fill: "#2b2b2b"
    },
    {
      d: "M96 33h320c35 0 63 28 63 63v320c0 35-28 63-63 63H96c-35 0-63-28-63-63V96c0-35 28-63 63-63Z",
      fill: "none",
      stroke: "#ffffff",
      strokeWidth: "9"
    },
    {
      d: "M110 133h179l-31 43H110Zm200 0h91L221 379h-91Zm-92 204h183v43H188Z",
      fill: "#ffffff"
    }
  ]
};

export const providerLogos = [
  { name: "OpenAI", icon: openAI },
  { name: "OpenAI-Compatible", icon: openAICompat },
  { name: "Anthropic", icon: siAnthropic },
  { name: "Gemini", icon: siGooglegemini },
  { name: "Ollama & LM Studio", icon: siOllama },
  { name: "Google Cloud TTS", icon: siGooglecloud },
  { name: "Azure Speech", icon: azureSpeech },
  { name: "DeepL", icon: siDeepl },
  { name: "Google Translate", icon: siGoogletranslate },
  { name: "Dictionaries", icon: dictionaries },
  { name: "GLM", icon: zAI },
  { name: "OpenRouter", icon: siOpenrouter },
  { name: "Wiktionary", icon: siWikipedia }
];

export function ProviderLogo({ name, icon }) {
  return (
    <div className="provider-brand">
      <svg
        role="img"
        aria-label={name}
        viewBox={icon.viewBox || "0 0 24 24"}
        style={icon.hex ? { color: `#${icon.hex}` } : undefined}
      >
        {icon.paths ? (
          icon.paths.map((path) => <path key={path.d} {...path} />)
        ) : (
          <path d={icon.path} fill="currentColor" />
        )}
      </svg>
      <span>{name}</span>
    </div>
  );
}
