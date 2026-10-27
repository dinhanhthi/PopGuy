import { readFileSync } from "node:fs";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// App version shown in the header, read from the Xcode project so it never drifts.
function appVersion() {
  try {
    const pbxproj = readFileSync(new URL("../macos/PopGuy.xcodeproj/project.pbxproj", import.meta.url), "utf8");
    return pbxproj.match(/MARKETING_VERSION = ([^;]+);/)?.[1] ?? "";
  } catch {
    return "";
  }
}

// The Windows app's version, read from its csproj: the Windows download links point at that release. A missing or
// malformed version fails the build rather than shipping broken download links.
function windowsVersion() {
  const csproj = readFileSync(new URL("../windows/src/PopGuy.App/PopGuy.App.csproj", import.meta.url), "utf8");
  const version = csproj.match(/<Version>(\d+\.\d+\.\d+)<\/Version>/)?.[1];
  if (!version) throw new Error("windows/src/PopGuy.App/PopGuy.App.csproj has no <major>.<minor>.<patch> <Version>.");
  return version;
}

export default defineConfig({
  plugins: [react()],
  define: {
    __APP_VERSION__: JSON.stringify(appVersion()),
    __WINDOWS_VERSION__: JSON.stringify(windowsVersion())
  },
  test: {
    environment: "jsdom",
    setupFiles: "./src/test/setup.js",
    css: true
  }
});
