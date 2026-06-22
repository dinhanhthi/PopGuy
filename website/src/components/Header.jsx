import { Download, Menu, X } from "lucide-react";
import { useState } from "react";
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
              <GitHubIcon size={18} />
              GitHub
            </a>
            <a
              className="button button--primary button--header"
              href={DOWNLOAD_URL}
              target="_blank"
              rel="noreferrer"
            >
              <Download size={17} aria-hidden="true" />
              Download
            </a>
          </div>
        </div>
      </div>
    </header>
  );
}