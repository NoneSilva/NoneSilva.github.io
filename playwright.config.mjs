// Copyright (c) 2026 Guilherme Silva. All rights reserved.
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "tools/a11y",
  reporter: "list",
  use: { browserName: "chromium" },
});
