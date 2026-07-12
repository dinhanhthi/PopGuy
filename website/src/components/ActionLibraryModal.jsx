import { Search, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { libraryCategories, libraryPresets, libraryStats } from "../data/actionLibrary";

export function ActionLibraryModal({ open, onClose }) {
  const [query, setQuery] = useState("");

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
      setQuery("");
    };
  }, [open, onClose]);

  const trimmedQuery = query.trim().toLowerCase();

  const groups = useMemo(() => {
    return libraryCategories
      .map((category) => {
        const presets = libraryPresets.filter((preset) => {
          if (preset.category !== category.id) return false;
          if (!trimmedQuery) return true;
          return (
            preset.name.toLowerCase().includes(trimmedQuery) ||
            preset.description.toLowerCase().includes(trimmedQuery)
          );
        });
        return { category, presets };
      })
      .filter((group) => group.presets.length > 0);
  }, [trimmedQuery]);

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
          <div className="library-search">
            <Search size={16} aria-hidden="true" />
            <input
              type="text"
              className="library-search-input"
              placeholder="Search actions…"
              aria-label="Search actions"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
            {query && (
              <button
                type="button"
                className="library-search-clear"
                aria-label="Clear search"
                onClick={() => setQuery("")}
              >
                <X size={14} />
              </button>
            )}
          </div>
        </div>
        <div className="library-modal-body">
          {groups.length === 0 ? (
            <p className="library-search-empty">No actions match "{query.trim()}".</p>
          ) : (
            groups.map(({ category, presets }) => (
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
            ))
          )}
        </div>
      </div>
    </div>
  );
}
