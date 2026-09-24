// Copyright (c) 2026 Guilherme Silva. All rights reserved.
// Measures the rendered page against the standards in standards.json, at
// every width in the file's range. One test per standard; a failure lists
// each element and width that broke it, with the rule and its source.
import { test, expect } from "@playwright/test";
import fs from "fs";

const spec = JSON.parse(fs.readFileSync(new URL("./standards.json", import.meta.url), "utf8"));
const page_ = process.env.A11Y_PAGE || new URL("../../_site/index.html", import.meta.url).href;
const results = spec.standards.map(s => ({ ...s, failures: [] }));
const r = n => Math.round(n * 10) / 10;

// Runs in the page: boxes of the targets, the frame, the header's air and the page's overflow.
function measure(sel) {
  const R = e => e.getBoundingClientRect();
  const T = n => { const rg = document.createRange(); rg.selectNodeContents(n); return rg.getBoundingClientRect(); };
  const box = e => { const b = R(e); return { x: b.left, y: b.top, w: b.width, h: b.height }; };
  const name = e => (e.id ? "#" + e.id : e.tagName.toLowerCase() + (typeof e.className === "string" && e.className ? "." + e.className.trim().split(/\s+/).join(".") : "")) + (e.textContent.trim() ? " '" + e.textContent.trim().slice(0, 24) + "'" : "");
  const shown = e => { const b = R(e); return b.width > 0 && b.height > 0; };
  const inline = e => getComputedStyle(e).display === "inline" && [...e.parentNode.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
  const targets = {};
  for (const [k, s] of Object.entries(sel)) targets[k] = [...document.querySelectorAll(s)].filter(shown).map(e => ({ name: name(e), inline: inline(e), ...box(e) }));
  const c = document.querySelector(".app-header .container"), cr = R(c), cs = getComputedStyle(c);
  const vw = document.documentElement.clientWidth;
  const frame = { left: cr.left + parseFloat(cs.paddingLeft), right: vw - (cr.right - parseFloat(cs.paddingRight)) };
  const tabs = [...document.querySelectorAll(".tab")].map(t => {
    const b = R(t), a = R(t.querySelector("svg")), x = T(t.querySelector(".tab-text > span"));
    const under = !/rgba\(0, 0, 0, 0\)|transparent/.test(getComputedStyle(t).borderBottomColor);
    return { top: Math.min(a.top, x.top), bottom: under ? b.bottom : Math.max(a.bottom, x.bottom) };
  });
  const icons = [...document.querySelectorAll("#links > * svg")].map(R);
  const iTop = Math.min(...icons.map(b => b.top)), iBot = Math.max(...icons.map(b => b.bottom));
  const nav = document.querySelector(".tabs"), nr = R(nav), line = nr.bottom - parseFloat(getComputedStyle(nav).borderBottomWidth);
  const above = tabs.filter(t => t.bottom <= iTop + 0.5), sameRow = tabs.some(t => Math.abs((t.top + t.bottom) / 2 - (iTop + iBot) / 2) < 4);
  const aboveY = sameRow || !above.length ? null : Math.max(...above.map(t => t.bottom));
  const controls = [...document.querySelectorAll(".toolbar .input")].map(R);
  const month = document.querySelector(".month-title");
  return { vw, overflow: document.documentElement.scrollWidth - vw, targets, frame,
    spacing: { top: Math.min(...tabs.map(t => t.top)), aboveIcons: aboveY === null ? null : iTop - aboveY, belowIcons: line - iBot,
               headerEnd: month ? T(month).top - Math.max(...controls.map(b => b.bottom)) : null } };
}

function judge(s, w, m) {
  const fail = (what, value) => s.failures.push({ width: w, what, value });
  const all = m.targets.any, list = m.targets[s.selector] || [];
  if (s.check === "target-size") for (const t of list) {
    if (t.w >= s.min && t.h >= s.min) continue;
    if (s.id.startsWith("wcag")) {
      if (t.inline) continue;
      const cx = t.x + t.w / 2, cy = t.y + t.h / 2, rad = s.min / 2;
      const hit = all.some(o => {
        if (o.name === t.name && o.x === t.x && o.y === t.y) return false;
        const small = o.w < s.min || o.h < s.min;
        if (small) return Math.hypot(cx - (o.x + o.w / 2), cy - (o.y + o.h / 2)) < s.min;
        const dx = Math.max(o.x - cx, 0, cx - (o.x + o.w)), dy = Math.max(o.y - cy, 0, cy - (o.y + o.h));
        return Math.hypot(dx, dy) < rad;
      });
      if (!hit) continue;
    }
    fail(t.name, `${r(t.w)}x${r(t.h)}`);
  }
  if (s.check === "target-spacing") for (let i = 0; i < list.length; i++) for (let j = i + 1; j < list.length; j++) {
    const a = list[i], b = list[j];
    const gap = Math.max(b.x - (a.x + a.w), a.x - (b.x + b.w), b.y - (a.y + a.h), a.y - (b.y + b.h));
    if (gap >= s.min - 0.5) continue;
    if (gap >= -0.5 && Math.min(a.w, a.h) >= 48 && Math.min(b.w, b.h) >= 48) continue;
    fail(`${a.name} | ${b.name}`, `${r(gap)}px apart`);
  }
  if (s.check === "edge-margins" && (Math.abs(m.frame.left - s.value) > 0.5 || Math.abs(m.frame.right - s.value) > 0.5))
    fail("content edges", `${r(m.frame.left)} / ${r(m.frame.right)}`);
  if (s.check === "consistent-spacing") {
    const sp = m.spacing;
    if (sp.aboveIcons !== null && Math.abs(sp.aboveIcons - sp.belowIcons) > 0.5) fail("air above / below the icon row", `${r(sp.aboveIcons)} / ${r(sp.belowIcons)}`);
    if (Math.abs(sp.top - 16) > 0.5 || Math.abs(sp.headerEnd - 16) > 0.5) fail("top of page / end of header", `${r(sp.top)} / ${r(sp.headerEnd)}`);
  }
  if (s.check === "reflow" && m.overflow > 0) fail("horizontal overflow", `${r(m.overflow)}px`);
}

test.beforeAll(async ({ browser }) => {
  const page = await browser.newPage();
  await page.goto(page_);
  await page.evaluate(() => document.fonts.ready);
  const { from, to, step } = spec.widths;
  for (let w = from; w <= to; w += step) {
    await page.setViewportSize({ width: w, height: 1000 });
    const m = await page.evaluate(measure, spec.targets);
    for (const s of results) if (!s.widths || (w >= s.widths[0] && w <= s.widths[1])) judge(s, w, m);
  }
  await page.close();
});

for (const s of results) test(s.id, () => {
  const seen = new Map();
  for (const f of s.failures) { const k = `${f.what}  ${f.value}`; seen.set(k, [...(seen.get(k) || []), f.width]); }
  const lines = [...seen].map(([k, ws]) => `${k}  at ${ws.length > 4 ? `${ws[0]}-${ws[ws.length - 1]}px (${ws.length} widths)` : ws.map(w => w + "px").join(", ")}`);
  expect(lines, `${s.rule}\n${s.source}`).toEqual([]);
});
