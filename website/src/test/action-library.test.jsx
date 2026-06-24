import { describe, expect, it } from "vitest";
import { libraryPresets } from "../data/actionLibrary";

describe("Action Library data", () => {
  it("gives every preset a short description", () => {
    const missingDescriptions = libraryPresets
      .filter(
        (preset) =>
          typeof preset.description !== "string" ||
          preset.description.trim().length === 0
      )
      .map((preset) => preset.id);
    const longDescriptions = libraryPresets
      .filter((preset) => preset.description.length > 60)
      .map((preset) => preset.id);

    expect(missingDescriptions).toEqual([]);
    expect(longDescriptions).toEqual([]);
  });
});
