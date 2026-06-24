import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ProviderLogo } from "../components/ProviderLogos";

describe("ProviderLogo", () => {
  it("renders a textOnly brand with name and sub, no svg", () => {
    const { container } = render(
      <ProviderLogo name="GLM" textOnly sub="z.ai" />
    );

    expect(screen.getByText("GLM")).toBeInTheDocument();
    expect(screen.getByText("z.ai")).toBeInTheDocument();
    expect(container.querySelector("svg")).toBeNull();
  });

  it("renders an svg logo for non-textOnly providers", () => {
    const { container } = render(
      <ProviderLogo
        name="OpenAI"
        icon={{ hex: "000000", path: "M0 0h1v1H0z" }}
      />
    );

    expect(container.querySelector("svg")).not.toBeNull();
    expect(screen.getByText("OpenAI")).toBeInTheDocument();
  });
});