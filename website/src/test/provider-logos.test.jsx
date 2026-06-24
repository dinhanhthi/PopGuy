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

  it("uses the real OpenAI logo path", () => {
    const openAI = providerLogos.find((provider) => provider.name === "OpenAI");

    expect(openAI.icon.path).toContain("M22.2819 9.8211");
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
