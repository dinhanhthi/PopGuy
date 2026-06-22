import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { InteractiveDemo } from "../components/InteractiveDemo";

describe("InteractiveDemo", () => {
  it("opens the real-style toolbar and shows a translated result", () => {
    render(<InteractiveDemo />);

    expect(
      screen.queryByRole("toolbar", { name: "PopGuy actions" })
    ).not.toBeInTheDocument();

    fireEvent.click(
      screen.getByRole("button", { name: "Select example text" })
    );
    fireEvent.click(screen.getByRole("button", { name: "Translate" }));

    expect(
      screen.getByText(
        "Le départ des télécabines se situe à environ 830 mètres d’altitude."
      )
    ).toBeInTheDocument();

    ["Copy", "Paste back", "Edit", "Cancel"].forEach((label) => {
      expect(screen.getByRole("button", { name: label })).toBeInTheDocument();
    });
  });
});
