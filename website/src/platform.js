// The visitor's platform: their download goes first, and the Windows button picks the build for their PC's chip.

/** "mac", "windows", or null (another system, or no user agent). */
export function detectOs(userAgent = globalThis.navigator?.userAgent ?? "") {
  if (/Windows/i.test(userAgent)) return "windows";
  if (/Macintosh|Mac OS X/i.test(userAgent)) return "mac";
  return null;
}

/**
 * "arm64" or "x64": the PC's chip from the browser's client hints (Chromium: Edge and Chrome on Windows on Arm report
 * "arm" although their user agent string says x64), else from the user agent string. x64 when neither tells: an Arm PC
 * runs the x64 build too, through Windows' emulation.
 */
export async function detectWindowsArch(nav = globalThis.navigator) {
  try {
    const hints = await nav?.userAgentData?.getHighEntropyValues?.(["architecture"]);
    if (hints?.architecture === "arm") return "arm64";
    if (hints?.architecture === "x86") return "x64";
  } catch {
    // The hints were refused: the user agent string decides.
  }
  return /ARM64|aarch64/i.test(nav?.userAgent ?? "") ? "arm64" : "x64";
}
