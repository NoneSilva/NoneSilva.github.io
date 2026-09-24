// Copyright (c) 2026 Guilherme Silva. All rights reserved.
// Measures a rendered page against the standards in standards.json, at
// every width in the file's range, through the Chrome DevTools Protocol.
//   node tools/a11y/run.mjs <page url> [standards.json] [--ws <page websocket>]
// Without --ws it launches the Chromium named by $CHROME (headless).
import fs from "fs";
import { spawn } from "child_process";

const args = process.argv.slice(2);
const wsArg = args.includes("--ws") ? args[args.indexOf("--ws") + 1] : null;
const [pageUrl, standardsPath = new URL("./standards.json", import.meta.url).pathname] = args.filter((a, i) => a !== "--ws" && args[i - 1] !== "--ws");
const spec = JSON.parse(fs.readFileSync(standardsPath, "utf8"));

async function connect() {
  if (wsArg) return { ws: new WebSocket(wsArg), stop: () => {} };
  const chrome = spawn(process.env.CHROME || "chromium-browser", ["--headless=new", "--no-sandbox", "--disable-gpu", "--remote-debugging-port=9222", "about:blank"], { stdio: "ignore" });
  for (let i = 0; i < 100; i++) {
    try { const t = await (await fetch("http://127.0.0.1:9222/json/new?about:blank", { method: "PUT" })).json(); return { ws: new WebSocket(t.webSocketDebuggerUrl), stop: () => chrome.kill() }; }
    catch { await new Promise(r => setTimeout(r, 100)); }
  }
  throw new Error("Chromium did not answer on port 9222");
}

const { ws, stop } = await connect();
let id = 0; const pending = new Map(), events = [];
const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } else if (m.method) events.push(m.method); };
await new Promise(r => ws.onopen = r);
await send("Page.enable");
await send("Page.navigate", { url: pageUrl });
for (let i = 0; i < 100 && !events.includes("Page.loadEventFired"); i++) await new Promise(r => setTimeout(r, 100));
await send("Runtime.evaluate", { expression: "document.fonts.ready", awaitPromise: true });

// Runs in the page: boxes of the targets, the frame, the header's air and the page's overflow.
const measure = `(sel => {
  const R = e => e.getBoundingClientRect();
  const T = n => { const r = document.createRange(); r.selectNodeContents(n); return r.getBoundingClientRect(); };
  const box = e => { const r = R(e); return { x: r.left, y: r.top, w: r.width, h: r.height }; };
  const name = e => (e.id ? "#" + e.id : e.tagName.toLowerCase() + (e.className && typeof e.className === "string" ? "." + e.className.trim().split(/\\s+/).join(".") : "")) + (e.textContent.trim() ? " '" + e.textContent.trim().slice(0, 24) + "'" : "");
  const shown = e => { const r = R(e); return r.width > 0 && r.height > 0; };
  const inline = e => getComputedStyle(e).display === "inline" && [...e.parentNode.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
  const targets = {};
  for (const [k, s] of Object.entries(sel)) targets[k] = [...document.querySelectorAll(s)].filter(shown).map(e => ({ name: name(e), inline: inline(e), ...box(e) }));
  const c = document.querySelector(".app-header .container"), cr = R(c), cs = getComputedStyle(c);
  const vw = document.documentElement.clientWidth;
  const frame = { left: cr.left + parseFloat(cs.paddingLeft), right: vw - (cr.right - parseFloat(cs.paddingRight)) };
  const tabs = [...document.querySelectorAll(".tab")].map(t => { const b = R(t), a = R(t.querySelector("svg")), x = T(t.querySelector(".tab-text > span")); const under = !/rgba\\(0, 0, 0, 0\\)|transparent/.test(getComputedStyle(t).borderBottomColor); return { top: Math.min(a.top, x.top), bottom: under ? b.bottom : Math.max(a.bottom, x.bottom) }; });
  const icons = [...document.querySelectorAll("#links > * svg")].map(R);
  const iTop = Math.min(...icons.map(r => r.top)), iBot = Math.max(...icons.map(r => r.bottom));
  const nav = document.querySelector(".tabs"), nr = R(nav), line = nr.bottom - parseFloat(getComputedStyle(nav).borderBottomWidth);
  const above = tabs.filter(t => t.bottom <= iTop + 0.5), sameRow = tabs.some(t => Math.abs((t.top + t.bottom) / 2 - (iTop + iBot) / 2) < 4);
  const aboveY = sameRow || !above.length ? null : Math.max(...above.map(t => t.bottom));
  const controls = [...document.querySelectorAll(".toolbar .input")].map(R);
  const month = document.querySelector(".month-title");
  return JSON.stringify({ vw, overflow: document.documentElement.scrollWidth - vw, targets, frame,
    spacing: { top: Math.min(...tabs.map(t => t.top)), aboveIcons: aboveY === null ? null : iTop - aboveY, belowIcons: line - iBot,
               headerEnd: month ? T(month).top - Math.max(...controls.map(r => r.bottom)) : null } });
})(${JSON.stringify(spec.targets)})`;

const r = (n) => Math.round(n * 10) / 10;
const results = spec.standards.map(s => ({ ...s, failures: [] }));
const ws_ = spec.widths;
for (let w = ws_.from; w <= ws_.to; w += ws_.step) {
  await send("Emulation.setDeviceMetricsOverride", { width: w, height: 1000, deviceScaleFactor: 1, mobile: false });
  const m = JSON.parse((await send("Runtime.evaluate", { expression: measure, returnByValue: true })).result.result.value);
  for (const s of results) {
    if (s.widths && (w < s.widths[0] || w > s.widths[1])) continue;
    const fail = (what, value) => s.failures.push({ width: w, what, value });
    const all = m.targets.any, list = m.targets[s.selector] || [];
    if (s.check === "target-size") {
      for (const t of list) {
        if (t.w >= s.min && t.h >= s.min) continue;
        if (s.id.startsWith("wcag")) {
          if (t.inline) continue;
          const cx = t.x + t.w / 2, cy = t.y + t.h / 2, rad = s.min / 2;
          const hit = all.some(o => { if (o === t) return false; const small = o.w < s.min || o.h < s.min;
            if (small) return Math.hypot(cx - (o.x + o.w / 2), cy - (o.y + o.h / 2)) < s.min;
            const dx = Math.max(o.x - cx, 0, cx - (o.x + o.w)), dy = Math.max(o.y - cy, 0, cy - (o.y + o.h)); return Math.hypot(dx, dy) < rad; });
          if (!hit) continue;
        }
        fail(t.name, `${r(t.w)}x${r(t.h)}`);
      }
    }
    if (s.check === "target-spacing") {
      for (let i = 0; i < list.length; i++) for (let j = i + 1; j < list.length; j++) {
        const a = list[i], b = list[j];
        const gx = Math.max(b.x - (a.x + a.w), a.x - (b.x + b.w)), gy = Math.max(b.y - (a.y + a.h), a.y - (b.y + b.h));
        const gap = Math.max(gx, gy);
        if (gap >= s.min - 0.5) continue;
        if (gap >= -0.5 && Math.min(a.w, a.h) >= 48 && Math.min(b.w, b.h) >= 48) continue;
        fail(`${a.name} | ${b.name}`, `${r(gap)}px apart`);
      }
    }
    if (s.check === "edge-margins") {
      if (Math.abs(m.frame.left - s.value) > 0.5 || Math.abs(m.frame.right - s.value) > 0.5) fail("content edges", `${r(m.frame.left)} / ${r(m.frame.right)}`);
    }
    if (s.check === "consistent-spacing") {
      const sp = m.spacing;
      if (sp.aboveIcons !== null && Math.abs(sp.aboveIcons - sp.belowIcons) > 0.5) fail("air above / below the icon row", `${r(sp.aboveIcons)} / ${r(sp.belowIcons)}`);
      if (Math.abs(sp.top - 16) > 0.5 || Math.abs(sp.headerEnd - 16) > 0.5) fail("top of page / end of header", `${r(sp.top)} / ${r(sp.headerEnd)}`);
    }
    if (s.check === "reflow" && m.overflow > 0) fail("horizontal overflow", `${r(m.overflow)}px`);
  }
}
ws.close(); stop();

let failed = 0;
for (const s of results) {
  const n = s.failures.length; failed += n;
  console.log(`${n ? "FAIL" : "ok  "} ${s.id}${n ? ` (${n})` : ""}\n     ${s.rule}\n     ${s.source}`);
  const seen = new Map();
  for (const f of s.failures) { const k = f.what + " " + f.value; seen.set(k, [...(seen.get(k) || []), f.width]); }
  for (const [k, widths] of seen) console.log(`     ${k}  at ${widths.length > 4 ? widths[0] + "-" + widths[widths.length - 1] + "px (" + widths.length + " widths)" : widths.map(w => w + "px").join(", ")}`);
}
console.log(failed ? `\n${failed} failure(s)` : "\nall standards met at every width");
process.exit(failed ? 1 : 0);
