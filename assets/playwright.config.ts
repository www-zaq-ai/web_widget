import { defineConfig, devices } from "@playwright/test";
import path from "node:path";

export default defineConfig({
  testDir: "./tests",
  testMatch: "**/*.spec.ts",
  workers: 1,
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    baseURL: "http://127.0.0.1:4019",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: {
        ...devices["Desktop Chrome"],
        launchOptions: process.env.PLAYWRIGHT_CHROMIUM_BIN
          ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_BIN }
          : {},
      },
    },
    { name: "firefox", use: { ...devices["Desktop Firefox"] } },
    { name: "webkit", use: { ...devices["Desktop Safari"] } },
  ],
  webServer: {
    command: "MIX_ENV=dev mix run --no-start --no-halt assets/tests/server.exs",
    cwd: path.resolve(import.meta.dirname, ".."),
    url: "http://127.0.0.1:4019/web_widget/assets/embed.js",
    reuseExistingServer: false,
    timeout: 60000,
  },
});
