import { CheckCircle2, X } from "lucide-react";
import { useEffect } from "react";
import { releases } from "../data/changelog";

export function ChangelogModal({ open, onClose }) {
  useEffect(() => {
    if (!open) return;
    function onKey(event) {
      if (event.key === "Escape") onClose();
    }
    document.addEventListener("keydown", onKey);
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = "";
    };
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div
      className="modal-overlay"
      role="dialog"
      aria-modal="true"
      aria-label="All releases"
      onClick={onClose}
    >
      <div className="modal-panel" onClick={(event) => event.stopPropagation()}>
        <button
          type="button"
          className="modal-close"
          aria-label="Close"
          onClick={onClose}
        >
          <X size={18} />
        </button>
        <div className="modal-head">
          <h2>Changelog</h2>
          <p>Every release.</p>
        </div>
        <div className="modal-body">
          {releases.map((release) => (
            <article className="modal-release" key={release.version}>
              <div className="modal-release-head">
                <h3>{release.version}</h3>
                {release.latest ? <span className="modal-badge">Latest</span> : null}
                <time>{release.date}</time>
              </div>
              <p className="modal-release-title">{release.title}</p>
              <ul className="modal-release-list">
                {release.items.map((item) => (
                  <li key={item}>
                    <CheckCircle2 size={15} /> {item}
                  </li>
                ))}
              </ul>
            </article>
          ))}
        </div>
      </div>
    </div>
  );
}