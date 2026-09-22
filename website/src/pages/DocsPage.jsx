import { useEffect, useState } from "react";
import { RichText } from "../components/RichText";
import { docsContent, docsSections } from "../data/docs";

const slug = (text) => text.toLowerCase().replace(/[^a-z0-9]+/g, "-");

export function DocsPage() {
  const [active, setActive] = useState(slug(docsSections[0]));

  // Scroll-spy: the active section is the last one whose top has passed near the viewport top.
  useEffect(() => {
    function update() {
      const atBottom =
        window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2;
      let current = slug(docsSections[0]);
      for (const item of docsSections) {
        const el = document.getElementById(slug(item));
        if (el && (atBottom || el.getBoundingClientRect().top <= 120)) current = slug(item);
      }
      setActive(current);
    }
    update();
    window.addEventListener("scroll", update, { passive: true });
    window.addEventListener("resize", update);
    return () => {
      window.removeEventListener("scroll", update);
      window.removeEventListener("resize", update);
    };
  }, []);

  return (
    <main>
      <section className="hero">
        <h1>Docs</h1>
      </section>

      <div className="docs-layout">
        <nav className="toc" aria-label="Documentation">
          <ul>
            {docsSections.map((item) => (
              <li key={item}>
                <a
                  href={`#${slug(item)}`}
                  aria-current={active === slug(item) ? "true" : undefined}
                >
                  {item}
                </a>
              </li>
            ))}
          </ul>
        </nav>

        <div className="docs-content">
          {docsSections.map((sectionKey) => {
            const section = docsContent[sectionKey];
            return (
              <section key={sectionKey} id={slug(sectionKey)} className="doc">
                <h2>{sectionKey}</h2>
                <p><RichText text={section.summary} /></p>
                {section.notice ? <p className="notice"><RichText text={section.notice} /></p> : null}

                {section.sections.map((sub) => (
                  <div key={sub.title}>
                    <h3>{sub.title}</h3>
                    {sub.body ? <p><RichText text={sub.body} /></p> : null}
                    {sub.code ? <pre><code>{sub.code}</code></pre> : null}
                    {sub.steps ? (
                      <ol className="steps">
                        {sub.steps.map((step, index) => {
                          const href = sub.stepLinks?.[index];
                          const safe =
                            typeof href === "string" &&
                            /^(https?:|mailto:|\/)/i.test(href);
                          return (
                            <li key={step}>
                              {safe ? (
                                <a href={href} target="_blank" rel="noopener noreferrer">
                                  <RichText text={step} />
                                </a>
                              ) : (
                                <RichText text={step} />
                              )}
                            </li>
                          );
                        })}
                      </ol>
                    ) : null}
                    {sub.bullets ? (
                      <ul className="list">
                        {sub.bullets.map((item) => <li key={item}><RichText text={item} /></li>)}
                      </ul>
                    ) : null}
                  </div>
                ))}
              </section>
            );
          })}
        </div>
      </div>
    </main>
  );
}
