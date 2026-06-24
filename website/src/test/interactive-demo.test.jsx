import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { InteractiveDemo } from "../components/InteractiveDemo";

const LOAD_TIMEOUT = 2000;

function loadingRegion() {
  const result = screen.getByRole("region", { name: "PopGuy result" });
  return result.querySelector('[aria-label="Loading"]');
}

describe("InteractiveDemo", () => {
  it("opens the real-style toolbar and shows a translated result", async () => {
    render(<InteractiveDemo />);

    expect(
      screen.queryByRole("toolbar", { name: "PopGuy actions" })
    ).not.toBeInTheDocument();

    fireEvent.click(
      screen.getByRole("button", { name: "Select example text" })
    );
    fireEvent.click(screen.getByRole("button", { name: "Translate" }));

    // Loading region appears immediately after clicking Translate.
    expect(loadingRegion()).toBeInTheDocument();

    // The Translate result appears only after the 1200ms loading timer fires.
    const translateResult = await screen.findByText(
      "Le départ des télécabines se situe à environ 830 mètres d’altitude.",
      {},
      { timeout: LOAD_TIMEOUT }
    );
    expect(translateResult).toBeInTheDocument();

    ["Copy", "Paste back", "Edit", "Cancel"].forEach((label) => {
      expect(screen.getByRole("button", { name: label })).toBeInTheDocument();
    });
  });

  it("toggles speaking on and off while keeping the panel open", () => {
    render(<InteractiveDemo />);

    fireEvent.click(
      screen.getByRole("button", { name: "Select example text" })
    );
    fireEvent.click(screen.getByRole("button", { name: "Speak" }));

    expect(screen.getByText("Speaking…")).toBeInTheDocument();
    const resultRegion = screen.getByRole("region", { name: "PopGuy result" });
    expect(
      resultRegion.querySelector(".real-speaking-wave")
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Stop" })).toBeInTheDocument();
    // Speak stays active in the toolbar.
    expect(
      screen.getByRole("button", { name: "Speak" })
    ).toBeInTheDocument();

    // Stop turns speaking off but the panel stays open and Speak is still active.
    fireEvent.click(screen.getByRole("button", { name: "Stop" }));
    expect(screen.queryByText("Speaking…")).not.toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Speak" })
    ).toBeInTheDocument();
    expect(
      screen.getByRole("region", { name: "PopGuy result" })
    ).toBeInTheDocument();

    // Clicking Speak again toggles speaking back on.
    fireEvent.click(screen.getByRole("button", { name: "Speak" }));
    expect(screen.getByText("Speaking…")).toBeInTheDocument();

    // Clicking Speak a second time (while speaking) toggles speaking off.
    fireEvent.click(screen.getByRole("button", { name: "Speak" }));
    expect(screen.queryByText("Speaking…")).not.toBeInTheDocument();
  });

  it("cancels the loading timer when switching actions mid-load", async () => {
    render(<InteractiveDemo />);

    fireEvent.click(
      screen.getByRole("button", { name: "Select example text" })
    );
    fireEvent.click(screen.getByRole("button", { name: "Translate" }));
    // Translate loading starts.
    expect(loadingRegion()).toBeInTheDocument();

    // Switch to Improve mid-loading — this must cancel the Translate timer.
    fireEvent.click(screen.getByRole("button", { name: "Improve" }));

    // After the loading duration elapses, the Improve result should appear,
    // not the Translate result.
    const improveResult = await screen.findByText(
      "The cable car station is located about 830 metres above sea level.",
      {},
      { timeout: LOAD_TIMEOUT }
    );
    expect(improveResult).toBeInTheDocument();
    expect(
      screen.queryByText(
        "Le départ des télécabines se situe à environ 830 mètres d’altitude."
      )
    ).not.toBeInTheDocument();
  });

  it("does not leak stale state after closing and re-selecting", async () => {
    render(<InteractiveDemo />);

    fireEvent.click(
      screen.getByRole("button", { name: "Select example text" })
    );
    fireEvent.click(screen.getByRole("button", { name: "Translate" }));
    // Wait for the result to render so the Cancel button is available.
    await screen.findByText(
      "Le départ des télécabines se situe à environ 830 mètres d’altitude.",
      {},
      { timeout: LOAD_TIMEOUT }
    );

    // Close the panel.
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(
      screen.queryByRole("toolbar", { name: "PopGuy actions" })
    ).not.toBeInTheDocument();

    // Re-select the text — no stale loading or speaking state should remain.
    fireEvent.click(
      screen.getByRole("button", { name: "Select example text" })
    );
    expect(screen.queryByText("Speaking…")).not.toBeInTheDocument();
    expect(
      screen.queryByRole("region", { name: "PopGuy result" })
    ).toBeInTheDocument();
    expect(loadingRegion()).not.toBeInTheDocument();
  });
});