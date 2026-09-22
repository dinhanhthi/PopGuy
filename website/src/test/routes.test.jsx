import { fireEvent, render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import { AppRoutes } from "../App";

const pages = [
  ["/", "AI where you write."],
  ["/actions", "Actions"],
  ["/docs", "Docs"]
];

function renderAt(path) {
  render(
    <MemoryRouter initialEntries={[path]}>
      <AppRoutes />
    </MemoryRouter>
  );
}

describe("website routes", () => {
  it.each(pages)("renders %s", (path, heading) => {
    renderAt(path);

    expect(
      screen.getByRole("heading", { name: heading, level: 1 })
    ).toBeInTheDocument();
  });

  it("renders the docs table of contents with the six main sections", () => {
    renderAt("/docs");

    const docsNavigation = screen.getByRole("navigation", {
      name: "Documentation"
    });
    const links = within(docsNavigation).getAllByRole("link");

    expect(links.map((link) => link.textContent)).toEqual([
      "Installation",
      "Privacy",
      "Action Types",
      "Create an Action",
      "Create a Plugin",
      "PopClip Extensions"
    ]);
    expect(links[2]).toHaveAttribute("href", "#action-types");
    expect(
      links.filter((link) => link.getAttribute("aria-current") === "true")
    ).toHaveLength(1);
  });

  it("renders backticked docs text as inline code", () => {
    renderAt("/docs");

    const codes = screen.getAllByText("$POPGUY_TEXT", { selector: "code" });
    expect(codes.length).toBeGreaterThan(0);
    expect(screen.queryByText(/`/)).not.toBeInTheDocument();
  });

  it("shows a single Download link on the home page without a Pro checkout", () => {
    renderAt("/");

    expect(screen.getAllByRole("link", { name: /Download/ })).toHaveLength(1);
    expect(
      screen.queryByText(["Get", "Pro"].join(" "))
    ).not.toBeInTheDocument();
    expect(screen.queryByText("$10")).not.toBeInTheDocument();
  });

  it("links the AGPLv3 license and GitHub releases in the footer", () => {
    renderAt("/");

    expect(screen.getByRole("link", { name: "AGPLv3" })).toHaveAttribute(
      "href",
      "https://github.com/dinhanhthi/PopGuy/blob/main/LICENSE"
    );
    expect(screen.getByRole("link", { name: "Changelog" })).toHaveAttribute(
      "href",
      "https://github.com/dinhanhthi/PopGuy/releases"
    );
  });

  it("filters the action library with search", () => {
    renderAt("/actions");

    fireEvent.change(screen.getByRole("searchbox", { name: "Search actions" }), {
      target: { value: "apple maps" }
    });

    expect(
      screen.getByText("Open the selected place in Apple Maps.", { exact: false })
    ).toBeInTheDocument();
    expect(
      screen.queryByText("Search the selection with Google.", { exact: false })
    ).not.toBeInTheDocument();
  });

  it("toggles the color theme from the header", () => {
    renderAt("/");

    document.documentElement.dataset.theme = "light";
    fireEvent.click(screen.getByRole("button", { name: "Switch to dark theme" }));

    expect(document.documentElement.dataset.theme).toBe("dark");
    expect(
      screen.getByRole("button", { name: "Switch to light theme" })
    ).toBeInTheDocument();
  });
});
