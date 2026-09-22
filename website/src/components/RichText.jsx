// Renders `backticked` spans of a plain string as inline <code>.
export function RichText({ text }) {
  return text
    .split(/`([^`]+)`/)
    .map((part, i) => (i % 2 ? <code key={i}>{part}</code> : part));
}
