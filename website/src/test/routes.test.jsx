import { fireEvent, render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import { AppRoutes } from "../App";

const pages = [
  ["/", "A guy pops up from your selected text with magic."],
  ["/actions", "Actions"],
  ["/docs", "Docs"],
  ["/privacy", "Privacy"]
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
      "Windows",
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

  it("shows the macOS and Windows downloads on the home page without a Pro checkout", () => {
    renderAt("/");

    expect(screen.getByRole("link", { name: /Download for macOS/ })).toHaveAttribute(
      "href",
      "https://github.com/dinhanhthi/PopGuy/releases/latest"
    );
    // A public download contract: the windows-v<csproj Version> release's Velopack Setup.exe per architecture. jsdom
    // tells no chip, so the button takes x64 and the ARM64 installer is linked below it.
    for (const [name, arch] of [[/Download for Windows/, "x64"], ["ARM64 installer", "arm64"]]) {
      expect(screen.getByRole("link", { name })).toHaveAttribute(
        "href",
        expect.stringMatching(
          new RegExp(`^https://github\\.com/dinhanhthi/PopGuy/releases/download/windows-v\\d+\\.\\d+\\.\\d+/PopGuy-win-${arch}-Setup\\.exe$`)
        )
      );
    }
    // The same release's Velopack Portable.zip per architecture.
    for (const arch of ["x64", "arm64"]) {
      expect(screen.getByRole("link", { name: arch === "x64" ? "x64" : "ARM64" })).toHaveAttribute(
        "href",
        expect.stringMatching(
          new RegExp(`^https://github\\.com/dinhanhthi/PopGuy/releases/download/windows-v\\d+\\.\\d+\\.\\d+/PopGuy-win-${arch}-Portable\\.zip$`)
        )
      );
    }
    expect(screen.getByText(/Windows protected your PC/)).toBeInTheDocument();
    expect(
      screen.queryByText(["Get", "Pro"].join(" "))
    ).not.toBeInTheDocument();
    expect(screen.queryByText("$10")).not.toBeInTheDocument();
  });

  it("puts the Windows download first for a Windows visitor", () => {
    const userAgent = Object.getOwnPropertyDescriptor(window.navigator, "userAgent");
    Object.defineProperty(window.navigator, "userAgent", {
      configurable: true,
      value: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36"
    });
    try {
      renderAt("/");

      const downloads = screen.getAllByRole("link", { name: /^Download for/ });
      expect(downloads.map((link) => link.textContent)).toEqual(["Download for Windows", "Download for macOS"]);
      expect(downloads[0]).toHaveClass("button--primary");
      expect(screen.getByText(/x64 installer for this PC/)).toBeInTheDocument();
    } finally {
      if (userAgent) Object.defineProperty(window.navigator, "userAgent", userAgent);
      else delete window.navigator.userAgent;
    }
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
    expect(screen.getByRole("link", { name: "Privacy" })).toHaveAttribute(
      "href",
      "/privacy"
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

  it("adds a canonical link for the current page", () => {
    renderAt("/docs");

    const canonical = document.querySelectorAll('link[rel="canonical"]');
    expect(canonical).toHaveLength(1);
    expect(canonical[0]).toHaveAttribute("href", "https://pg.dinhanhthi.com/docs");
    canonical[0].remove();
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
