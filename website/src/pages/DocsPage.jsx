import { CheckCircle2, Info, Menu, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { docsContent, docsSections } from "../data/docs";

export function DocsPage() {
  const [active, setActive] = useState("Installation");
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const manualClick = useRef(false);

  // Scroll-spy: highlight the section currently in view as the user scrolls.
  useEffect(() => {
    if (typeof IntersectionObserver === "undefined") return;
    const blocks = Array.from(
      document.querySelectorAll(".docs-section-block")
    );
    if (blocks.length === 0) return;

    const observer = new IntersectionObserver(
      (entries) => {
        if (manualClick.current) return;
        const visible = entries
          .filter((entry) => entry.isIntersecting)
          .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
        if (visible.length > 0 && visible[0].target.id) {
          setActive(visible[0].target.id);
        }
      },
      { rootMargin: "-80px 0px -60% 0px" }
    );

    blocks.forEach((block) => observer.observe(block));
    return () => observer.disconnect();
  }, []);

  // Scroll into view on manual sidebar click only.
  useEffect(() => {
    if (active && manualClick.current) {
      const el = document.getElementById(active);
      if (el && typeof el.scrollIntoView === "function") {
        el.scrollIntoView({ behavior: "smooth", block: "start" });
      }
      // Reset once the smooth scroll settles. Prefer the scrollend event,
      // falling back to a timeout for browsers without it (Safari < 18).
      const reset = () => {
        manualClick.current = false;
        if (typeof window !== "undefined") {
          window.removeEventListener("scrollend", reset);
        }
      };
      let timer;
      if (typeof window !== "undefined" && "onscrollend" in window) {
        window.addEventListener("scrollend", reset, { once: true });
      } else {
        timer = setTimeout(reset, 900);
      }
      return () => {
        if (timer) clearTimeout(timer);
        if (typeof window !== "undefined") {
          window.removeEventListener("scrollend", reset);
        }
      };
    }
    return undefined;
  }, [active]);

  function selectSection(item) {
    manualClick.current = true;
    setActive(item);
    setSidebarOpen(false);
  }

  return (
    <main className="docs-page">
      <button
        className="docs-mobile-toggle"
        type="button"
        onClick={() => setSidebarOpen(true)}
      >
        <Menu size={18} /> Docs
      </button>
      <div className="docs-layout shell-wide">
        <aside className={`docs-sidebar ${sidebarOpen ? "is-open" : ""}`}>
          <div className="docs-sidebar-mobile-head">
            <strong>Docs</strong>
            <button
              type="button"
              aria-label="Close documentation navigation"
              onClick={() => setSidebarOpen(false)}
            >
              <X />
            </button>
          </div>
          <nav className="docs-nav-group" aria-label="Documentation">
            {docsSections.map((item) => (
              <button
                type="button"
                key={item}
                className={active === item ? "is-active" : ""}
                onClick={() => selectSection(item)}
              >
                {item}
              </button>
            ))}
          </nav>
        </aside>

        <article className="docs-article">
          {docsSections.map((sectionKey) => {
            const section = docsContent[sectionKey];
            return (
              <section
                key={sectionKey}
                id={sectionKey}
                className="docs-section-block"
              >
                <h1>{sectionKey}</h1>
                <p className="docs-summary">{section.summary}</p>

                {section.notice ? (
                  <div className="docs-notice">
                    <Info size={19} aria-hidden="true" />
                    <p>{section.notice}</p>
                  </div>
                ) : null}

                {section.sections.map((sub) => (
                  <div key={sub.title} className="docs-subsection">
                    <h2>{sub.title}</h2>
                    {sub.body ? <p>{sub.body}</p> : null}
                    {sub.code ? (
                      <pre className="docs-code">
                        <code>{sub.code}</code>
                      </pre>
                    ) : null}
                    {sub.steps ? (
                      <ol className="docs-steps">
                        {sub.steps.map((step, index) => {
                          const href = sub.stepLinks?.[index];
                          const safe =
                            typeof href === "string" &&
                            /^(https?:|mailto:|\/)/i.test(href);
                          return (
                            <li key={step}>
                              <span>{index + 1}</span>
                              {safe ? (
                                <a
                                  href={href}
                                  target="_blank"
                                  rel="noopener noreferrer"
                                >
                                  {step}
                                </a>
                              ) : (
                                <p>{step}</p>
                              )}
                            </li>
                          );
                        })}
                      </ol>
                    ) : null}
                    {sub.bullets ? (
                      <ul className="docs-bullets">
                        {sub.bullets.map((item) => (
                          <li key={item}>
                            <CheckCircle2 size={17} />
                            {item}
                          </li>
                        ))}
                      </ul>
                    ) : null}
                  </div>
                ))}
              </section>
            );
          })}
        </article>
      </div>
    </main>
  );
}