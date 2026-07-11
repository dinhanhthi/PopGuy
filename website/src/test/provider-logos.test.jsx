import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ProviderLogo, providerLogos } from "../components/ProviderLogos";

describe("ProviderLogo", () => {
  it("renders GLM with an image logo instead of the z.ai text fallback", () => {
    const glm = providerLogos.find((provider) => provider.name === "GLM");
    render(<ProviderLogo {...glm} />);

    expect(screen.getByText("GLM")).toBeInTheDocument();
    expect(screen.queryByText("z.ai")).not.toBeInTheDocument();
    expect(screen.getByAltText("GLM")).toHaveAttribute(
      "src",
      "/providers/zai.svg"
    );
  });

  it("uses the OpenAI logo asset", () => {
    const openAI = providerLogos.find((provider) => provider.name === "OpenAI");

    expect(openAI.src).toBe("/providers/openai.svg");
  });

  it("includes an OpenAI-Compatible entry with an inline icon", () => {
    const compat = providerLogos.find((p) => p.name === "OpenAI-Compatible");

    expect(compat).toBeDefined();
    expect(compat.icon.path).toBeTruthy();
  });

  it("renders an image logo when a src is provided", () => {
    render(<ProviderLogo name="OpenAI" src="/providers/openai.svg" />);

    expect(screen.getByAltText("OpenAI")).toBeInTheDocument();
    expect(screen.getByText("OpenAI")).toBeInTheDocument();
  });

  it("renders an inline svg for icon-based providers", () => {
    const { container } = render(
      <ProviderLogo
        name="Dictionaries"
        icon={{ hex: "555555", path: "M0 0h1v1H0z" }}
      />
    );

    expect(container.querySelector("svg")).not.toBeNull();
    expect(screen.getByText("Dictionaries")).toBeInTheDocument();
  });
});
