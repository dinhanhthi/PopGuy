// Brand marks for OpenAI-Compatible, Local AI (MLX), and Dictionaries have no
// dedicated logo file, so they keep an inline path here. All other providers
// render from the SVG/PNG assets in public/providers/.

const openAICompat = {
  title: "OpenAI-Compatible",
  hex: "666666",
  path: "M20.5 11H19V7c0-1.1-.9-2-2-2h-4V3.5C13 2.12 11.88 1 10.5 1S8 2.12 8 3.5V5H4c-1.1 0-1.99.9-1.99 2v3.8H3.5c1.49 0 2.7 1.21 2.7 2.7s-1.21 2.7-2.7 2.7H2V20c0 1.1.9 2 2 2h3.8v-1.5c0-1.49 1.21-2.7 2.7-2.7 1.49 0 2.7 1.21 2.7 2.7V22H17c1.1 0 2-.9 2-2v-4h1.5c1.38 0 2.5-1.12 2.5-2.5S21.88 11 20.5 11z"
};

// Material Design "memory" chip icon — represents on-device MLX inference
const mlxLocal = {
  title: "Local AI (MLX)",
  hex: "5B5EA6",
  path: "M9 2H15V4H17C18.1 4 19 4.9 19 6V8H21V10H19V12H21V14H19V16C19 17.1 18.1 18 17 18H15V20H13V18H11V20H9V18H7C5.9 18 5 17.1 5 16V14H3V12H5V10H3V8H5V6C5 4.9 5.9 4 7 4H9V2ZM7 6V16H17V6H7ZM9 8H15V14H9V8Z"
};

// Material Design "book" filled icon — represents GoldenDict, Apple Dictionary, Wiktionary
const dictionaries = {
  title: "Dictionaries",
  hex: "555555",
  path: "M18 2H6c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zM6 4h5v8l-2.5-1.5L6 12V4z"
};

export const providerLogos = [
  { name: "OpenAI", src: "/providers/openai.svg" },
  { name: "OpenAI-Compatible", icon: openAICompat },
  { name: "Anthropic", src: "/providers/anthropic.svg" },
  { name: "Gemini", src: "/providers/gemini.svg" },
  { name: "Ollama & LM Studio", src: "/providers/ollama.svg" },
  { name: "Local AI (MLX)", icon: mlxLocal },
  { name: "Google Cloud TTS", src: "/providers/googlecloud.svg" },
  { name: "Azure Speech", src: "/providers/azure.svg" },
  { name: "DeepL", src: "/providers/deepl.svg" },
  { name: "Google Translate", src: "/providers/google_translate.svg" },
  { name: "Dictionaries", icon: dictionaries },
  { name: "GLM", src: "/providers/zai.svg" },
  { name: "OpenRouter", src: "/providers/openrouter.svg" },
  { name: "Wiktionary", src: "/providers/wiktionary.png" }
];

// Dark theme: near-black / grey brand marks (OpenAI-Compatible, Dictionaries)
// are invisible on the dark surface, so render those light. Saturated brand
// colours have enough contrast and are kept as-is.
function displayColor(hex) {
  if (!hex) return undefined;
  const r = parseInt(hex.slice(0, 2), 16);
  const g = parseInt(hex.slice(2, 4), 16);
  const b = parseInt(hex.slice(4, 6), 16);
  const luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  const saturation = Math.max(r, g, b) - Math.min(r, g, b);
  const isDim = (saturation < 28 && luminance < 150) || luminance < 45;
  return isDim ? "#e5e7eb" : `#${hex}`;
}

export function ProviderLogo({ name, icon, src }) {
  return (
    <div className="provider-brand">
      {src ? (
        <img src={src} alt={name} loading="lazy" />
      ) : (
        <svg
          role="img"
          aria-label={name}
          viewBox={icon.viewBox || "0 0 24 24"}
          style={icon.hex ? { color: displayColor(icon.hex) } : undefined}
        >
          {icon.paths ? (
            icon.paths.map((path) => <path key={path.d} {...path} />)
          ) : (
            <path d={icon.path} fill="currentColor" />
          )}
        </svg>
      )}
      <span>{name}</span>
    </div>
  );
}
