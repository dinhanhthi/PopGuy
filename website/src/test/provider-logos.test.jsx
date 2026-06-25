import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ProviderLogo, providerLogos } from "../components/ProviderLogos";

describe("ProviderLogo", () => {
  it("renders GLM with a logo instead of the z.ai text fallback", () => {
    const glm = providerLogos.find((provider) => provider.name === "GLM");
    const { container } = render(<ProviderLogo {...glm} />);

    expect(screen.getByText("GLM")).toBeInTheDocument();
    expect(screen.queryByText("z.ai")).not.toBeInTheDocument();
    expect(container.querySelector("svg")).not.toBeNull();
  });

  it("uses the updated OpenAI logo path", () => {
    const openAI = providerLogos.find((provider) => provider.name === "OpenAI");

    expect(openAI.icon).toBeDefined();
    expect(openAI.icon.path).toContain("M14.949 6.547");
    expect(openAI.icon.viewBox).toBe("0 0 16 16");
  });

  it("includes an OpenAI-Compatible entry", () => {
    const compat = providerLogos.find((p) => p.name === "OpenAI-Compatible");

    expect(compat).toBeDefined();
    expect(compat.icon.path).toBeTruthy();
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
