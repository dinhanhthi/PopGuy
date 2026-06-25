import { fireEvent, render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import { AppRoutes } from "../App";

const pages = [
  ["/", "AI where you write."],
  ["/actions", "Anything you do with text."],
  ["/docs", "Installation"]
];

describe("website routes", () => {
  it.each(pages)("renders %s", (path, heading) => {
    render(
      <MemoryRouter initialEntries={[path]}>
        <AppRoutes />
      </MemoryRouter>
    );

    expect(
      screen.getByRole("heading", { name: heading, level: 1 })
    ).toBeInTheDocument();
  });

  it("renders the docs sidebar with the six main sections", () => {
    render(
      <MemoryRouter initialEntries={["/docs"]}>
        <AppRoutes />
      </MemoryRouter>
    );

    const docsNavigation = screen.getByRole("navigation", {
      name: "Documentation"
    });
    const pageButtons = within(docsNavigation).getAllByRole("button");

    expect(pageButtons.map((button) => button.textContent)).toEqual([
      "Installation",
      "Privacy",
      "Action Types",
      "Create an Action",
      "Create a Plugin",
      "PopClip Extensions"
    ]);
  });

  it("presents Pro as an optional $10 one-time upgrade on the home page", () => {
    render(
      <MemoryRouter initialEntries={["/"]}>
        <AppRoutes />
      </MemoryRouter>
    );

    expect(screen.getByText("$10", { exact: true })).toBeInTheDocument();
    expect(screen.getByText("Optional upgrade")).toBeInTheDocument();
  });

  it("uses provider logos and no repository preview", () => {
    render(
      <MemoryRouter initialEntries={["/"]}>
        <AppRoutes />
      </MemoryRouter>
    );

    expect(
      screen.queryByLabelText("PopGuy GitHub repository preview")
    ).not.toBeInTheDocument();
    expect(screen.getByRole("img", { name: "OpenAI" })).toBeInTheDocument();
    expect(screen.getByRole("img", { name: "Anthropic" })).toBeInTheDocument();
  });

  it("opens the changelog modal when See more is clicked", () => {
    render(
      <MemoryRouter initialEntries={["/"]}>
        <AppRoutes />
      </MemoryRouter>
    );

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /See more/ }));

    expect(screen.getByRole("dialog")).toBeInTheDocument();
    // The latest version is shown inside the opened changelog modal.
    expect(
      screen.getAllByText("0.3.0").length
    ).toBeGreaterThanOrEqual(1);
  });

  it("shows short descriptions for Action Library cards and modal rows", () => {
    render(
      <MemoryRouter initialEntries={["/actions"]}>
        <AppRoutes />
      </MemoryRouter>
    );

    expect(
      screen.getByText("Search the selection with Google.")
    ).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /View all 93/ }));

    const modal = screen.getByRole("dialog", {
      name: "Action Library — all presets"
    });
    expect(
      within(modal).getByText("Open the selected place in Apple Maps.")
    ).toBeInTheDocument();
  });
});
