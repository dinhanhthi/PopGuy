import { Moon, Sun } from "lucide-react";
import { useState } from "react";
import { NavLink } from "react-router-dom";
import { GITHUB_URL } from "../constants";
import { Brand } from "./Brand";
import { GitHubIcon } from "./GitHubIcon";

const navigation = [
  ["Actions", "/actions"],
  ["Docs", "/docs"]
];

function ThemeToggle() {
  const [theme, setTheme] = useState(
    () => document.documentElement.dataset.theme || "light"
  );
  const next = theme === "dark" ? "light" : "dark";

  function toggle() {
    document.documentElement.dataset.theme = next;
    try {
      localStorage.setItem("theme", next);
    } catch {
      // Storage blocked (private mode): the theme still applies for this visit.
    }
    setTheme(next);
  }

  return (
    <button
      type="button"
      className="nav-link theme-toggle"
      aria-label={`Switch to ${next} theme`}
      onClick={toggle}
    >
      {theme === "dark" ? <Sun size={18} aria-hidden="true" /> : <Moon size={18} aria-hidden="true" />}
    </button>
  );
}

export function Header() {
  return (
    <header className="site-header">
      <Brand />
      <nav aria-label="Primary navigation">
        {navigation.map(([label, href]) => (
          <NavLink key={href} className="nav-link" to={href}>
            {label}
          </NavLink>
        ))}
        <ThemeToggle />
        <a className="nav-link" href={GITHUB_URL} target="_blank" rel="noreferrer" aria-label="GitHub">
          <GitHubIcon size={18} />
        </a>
      </nav>
    </header>
  );
}
