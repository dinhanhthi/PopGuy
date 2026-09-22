import { readFileSync } from "node:fs";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// App version shown in the header, read from the Xcode project so it never drifts.
function appVersion() {
  try {
    const pbxproj = readFileSync(new URL("../PopGuy.xcodeproj/project.pbxproj", import.meta.url), "utf8");
    return pbxproj.match(/MARKETING_VERSION = ([^;]+);/)?.[1] ?? "";
  } catch {
    return "";
  }
}

export default defineConfig({
  plugins: [react()],
  define: {
    __APP_VERSION__: JSON.stringify(appVersion())
  },
  test: {
    environment: "jsdom",
    setupFiles: "./src/test/setup.js",
    css: true
  }
});
