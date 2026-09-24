// Copyright (c) 2026 Guilherme Silva. All rights reserved.
// Runs axe-core, Deque's accessibility rules engine, on the rendered page
// with the WCAG 2.2 AA rule set, at a phone width and a desktop width.
import { test, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

const page_ = process.env.A11Y_PAGE || new URL("../../_site/index.html", import.meta.url).href;

for (const width of [320, 1280]) test(`axe-core WCAG 2.2 AA at ${width}px`, async ({ page }) => {
  await page.setViewportSize({ width, height: 1000 });
  await page.goto(page_);
  const { violations } = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]).analyze();
  const lines = violations.map(v => `${v.id} (${v.impact}): ${v.help}\n  ${v.helpUrl}\n` + v.nodes.map(n => `  ${n.target.join(" ")}`).join("\n"));
  expect(lines, "axe-core violations").toEqual([]);
});
