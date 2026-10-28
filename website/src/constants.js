export const SITE_URL = "https://pg.dinhanhthi.com";
export const GITHUB_URL = "https://github.com/dinhanhthi/PopGuy";
export const RELEASES_URL = `${GITHUB_URL}/releases`;
export const DOWNLOAD_URL = `${RELEASES_URL}/latest`;

// PopGuy for Windows: its own windows-v<version> releases (the macOS release stays "latest"), one Setup.exe and one
// Portable.zip per architecture, named by Velopack (vpk pack --channel win-<arch>).
// Written out in full, so the built site holds each link as one literal.
export const WINDOWS_RELEASE_URL = `${GITHUB_URL}/releases/tag/windows-v${__WINDOWS_VERSION__}`;
export const WINDOWS_DOWNLOAD_X64 =
  `${GITHUB_URL}/releases/download/windows-v${__WINDOWS_VERSION__}/PopGuy-win-x64-Setup.exe`;
export const WINDOWS_DOWNLOAD_ARM64 =
  `${GITHUB_URL}/releases/download/windows-v${__WINDOWS_VERSION__}/PopGuy-win-arm64-Setup.exe`;
export const WINDOWS_PORTABLE_X64 =
  `${GITHUB_URL}/releases/download/windows-v${__WINDOWS_VERSION__}/PopGuy-win-x64-Portable.zip`;
export const WINDOWS_PORTABLE_ARM64 =
  `${GITHUB_URL}/releases/download/windows-v${__WINDOWS_VERSION__}/PopGuy-win-arm64-Portable.zip`;

