export const SITE_URL = "https://pg.dinhanhthi.com";
export const GITHUB_URL = "https://github.com/dinhanhthi/PopGuy";
export const RELEASES_URL = `${GITHUB_URL}/releases`;
export const DOWNLOAD_URL = `${RELEASES_URL}/latest`;

// PopGuy for Windows: the Latest release (one vX.Y.Z release for macOS and Windows) holds one Setup.exe and one
// Portable.zip per architecture, named by Velopack (vpk pack --channel win-<arch>).
// Written out in full, so the built site holds each link as one literal.
export const WINDOWS_RELEASE_URL = `${RELEASES_URL}/latest`;
export const WINDOWS_DOWNLOAD_X64 = `${RELEASES_URL}/latest/download/PopGuy-win-x64-Setup.exe`;
export const WINDOWS_DOWNLOAD_ARM64 = `${RELEASES_URL}/latest/download/PopGuy-win-arm64-Setup.exe`;
export const WINDOWS_PORTABLE_X64 = `${RELEASES_URL}/latest/download/PopGuy-win-x64-Portable.zip`;
export const WINDOWS_PORTABLE_ARM64 = `${RELEASES_URL}/latest/download/PopGuy-win-arm64-Portable.zip`;

