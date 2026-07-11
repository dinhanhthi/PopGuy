import { Download, Menu, X } from "lucide-react";
import { useEffect, useState } from "react";
import { NavLink } from "react-router-dom";
import { DOWNLOAD_URL, GITHUB_URL } from "../constants";
import { Brand } from "./Brand";
import { GitHubIcon } from "./GitHubIcon";

const navigation = [
  ["Home", "/"],
  ["Actions", "/actions"],
  ["Docs", "/docs"]
];

export function Header() {
  const [isOpen, setIsOpen] = useState(false);
  const [scrollProgress, setScrollProgress] = useState(0);

  useEffect(() => {
    function updateProgress() {
      const doc = document.documentElement;
      const max = doc.scrollHeight - window.innerHeight;
      setScrollProgress(max > 0 ? Math.min(1, window.scrollY / max) : 0);
    }
    updateProgress();
    window.addEventListener("scroll", updateProgress, { passive: true });
    window.addEventListener("resize", updateProgress);
    return () => {
      window.removeEventListener("scroll", updateProgress);
      window.removeEventListener("resize", updateProgress);
    };
  }, []);

  return (
    <header className="site-header">
      <div className="shell header-inner">
        <Brand />
        <button
          className="mobile-menu-button"
          type="button"
          aria-expanded={isOpen}
          aria-label={isOpen ? "Close navigation" : "Open navigation"}
          onClick={() => setIsOpen((open) => !open)}
        >
          {isOpen ? <X /> : <Menu />}
        </button>
        <div className={`header-nav-wrap ${isOpen ? "is-open" : ""}`}>
          <nav className="primary-nav" aria-label="Primary navigation">
            {navigation.map(([label, href]) => (
              <NavLink
                key={href}
                className={({ isActive }) =>
                  `nav-link ${isActive ? "is-active" : ""}`
                }
                to={href}
                end={href === "/"}
                onClick={() => setIsOpen(false)}
              >
                {label}
              </NavLink>
            ))}
          </nav>
          <div className="header-actions">
            <a
              className="github-link"
              href={GITHUB_URL}
              target="_blank"
              rel="noreferrer"
            >
              <GitHubIcon size={18} aria-label="GitHub" />
            </a>
            <a
              className="button button--primary button--header"
              href={DOWNLOAD_URL}
              target="_blank"
              rel="noreferrer"
            >
              <Download size={15} aria-hidden="true" />
              Download
            </a>
          </div>
        </div>
      </div>
      <span
        className="scroll-progress"
        style={{ transform: `scaleX(${scrollProgress})` }}
        aria-hidden="true"
      />
    </header>
  );
}