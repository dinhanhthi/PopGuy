import { X } from "lucide-react";
import { useEffect } from "react";
import { libraryCategories, libraryPresets, libraryStats } from "../data/actionLibrary";

export function ActionLibraryModal({ open, onClose }) {
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
      aria-label="Action Library — all presets"
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
          <h2>Action Library</h2>
          <p>
            {libraryStats.total} actions · {libraryStats.categories} categories ·{" "}
            {libraryStats.local}
          </p>
        </div>
        <div className="library-modal-body">
          {libraryCategories.map((category) => {
            const presets = libraryPresets.filter((p) => p.category === category.id);
            return (
              <section className="library-category-group" key={category.id}>
                <h3>
                  <category.icon aria-hidden="true" />
                  {category.name}
                  <span className="library-category-count">{presets.length}</span>
                </h3>
                <ul className="library-preset-list">
                  {presets.map((preset) => (
                    <li className="library-preset-row" key={preset.id}>
                      <preset.icon aria-hidden="true" />
                      <span className="library-preset-copy">
                        <span className="library-preset-name">{preset.name}</span>
                        <span className="library-description">{preset.description}</span>
                      </span>
                      <span className="library-type-badge">{preset.type}</span>
                    </li>
                  ))}
                </ul>
              </section>
            );
          })}
        </div>
      </div>
    </div>
  );
}
