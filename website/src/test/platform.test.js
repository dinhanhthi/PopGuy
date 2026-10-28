import { describe, expect, it } from "vitest";
import { detectOs, detectWindowsArch } from "../platform";

describe("detectOs", () => {
  it.each([
    ["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", "windows"],
    ["Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", "mac"],
    ["Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36", null],
    ["", null]
  ])("%s → %s", (userAgent, os) => {
    expect(detectOs(userAgent)).toBe(os);
  });
});

describe("detectWindowsArch", () => {
  const hints = (architecture) => ({
    userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
    userAgentData: { getHighEntropyValues: async () => ({ architecture }) }
  });

  it("trusts the client hints over the user agent string", async () => {
    await expect(detectWindowsArch(hints("arm"))).resolves.toBe("arm64");
    await expect(detectWindowsArch(hints("x86"))).resolves.toBe("x64");
  });

  it("falls back to the user agent string without hints", async () => {
    await expect(detectWindowsArch({ userAgent: "Mozilla/5.0 (Windows NT 10.0; ARM64)" })).resolves.toBe("arm64");
    await expect(detectWindowsArch({ userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" })).resolves.toBe("x64");
  });

  it("takes x64 when the hints are refused or nothing tells", async () => {
    const refused = {
      userAgent: "",
      userAgentData: { getHighEntropyValues: async () => { throw new Error("denied"); } }
    };
    await expect(detectWindowsArch(refused)).resolves.toBe("x64");
    await expect(detectWindowsArch(undefined)).resolves.toBe("x64");
  });
});
