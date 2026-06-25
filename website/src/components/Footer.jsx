import { Link } from "react-router-dom";
import { GITHUB_URL } from "../constants";
import { Brand } from "./Brand";
import { GitHubIcon } from "./GitHubIcon";

export function Footer() {
  return (
    <footer className="site-footer">
      <div className="shell footer-inner">
        <div>
          <Brand compact />
          <p>AI where you write.</p>
        </div>
        <nav aria-label="Footer navigation">
          <Link to="/actions">Actions</Link>
          <Link to="/docs">Docs</Link>
          <a href={GITHUB_URL} target="_blank" rel="noreferrer">
            <GitHubIcon size={15} />
            GitHub
          </a>
        </nav>
        <p className="copyright">
          © 2026 PopGuy · by{" "}
          <a href="https://dinhanhthi.com/" target="_blank" rel="noreferrer">
            Anh-Thi Dinh
          </a>
        </p>
      </div>
    </footer>
  );
}