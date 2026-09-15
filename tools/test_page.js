// Copyright (c) 2026 Guilherme Silva. All rights reserved.
// Runs the home page's script against contributions/contributions.js in a
// minimal DOM and checks what the rows actually render. Usage:
//   node tools/test_page.js            (from the repository root)
"use strict";
const fs = require("fs"), path = require("path"), vm = require("vm");
const root = path.join(__dirname, "..");

// ---- minimal DOM ----------------------------------------------------------
class Node {
  constructor(tag){ this.tag = tag; this.children = []; this.attrs = {}; this.text = ""; this.listeners = {}; this.style = {}; }
  setAttribute(k, v){ this.attrs[k] = String(v); }
  getAttribute(k){ return k in this.attrs ? this.attrs[k] : null; }
  appendChild(c){ this.children.push(c); return c; }
  addEventListener(t, f){ (this.listeners[t] = this.listeners[t] || []).push(f); }
  set textContent(v){ this.text = String(v); this.children = []; }
  get textContent(){ return this.text + this.children.map(c => c.textContent).join(""); }
  get className(){ return this.attrs.class || ""; }
  get offsetHeight(){ return 0; }
  walk(f){ f(this); this.children.forEach(c => c.walk(f)); }
  find(pred){ const out = []; this.walk(n => { if (pred(n)) out.push(n); }); return out; }
}
class TextNode extends Node { constructor(t){ super("#text"); this.text = t; } }
const byId = {};
const doc = {
  createElement: tag => new Node(tag),
  createElementNS: (ns, tag) => new Node(tag),
  createTextNode: t => new TextNode(t),
  getElementById: id => byId[id],
  documentElement: new Node("html"),
};
// Elements the page expects to exist in the HTML.
for (const id of ["chips", "links", "q", "from", "to", "timeline", "login", "updated", "name"]) {
  const n = new Node(id === "q" || id === "from" || id === "to" ? "input" : "div");
  n.value = ""; n.querySelectorAll = () => []; byId[id] = n;
}
byId.chips.querySelectorAll = () => byId.chips.children;

function run(search){
  byId.timeline.children = []; byId.chips.children = []; byId.links.children = [];
  const ctx = {
    document: doc, console,
    window: { matchMedia: () => ({ matches: false }) },
    location: { search, hash: "", pathname: "/" },
    history: { replaceState(){} },
    localStorage: { getItem: () => null, setItem(){} },
    URLSearchParams,
  };
  ctx.window.CONTRIBUTIONS = undefined;
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(root, "contributions/contributions.js"), "utf8"), ctx);
  const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
  const script = html.slice(html.lastIndexOf("<script>") + 8, html.lastIndexOf("</script>"));
  vm.runInContext(script, ctx);
  return byId.timeline;
}

// ---- checks -----------------------------------------------------------------
let failures = 0;
function check(cond, msg){ console.log((cond ? "ok   " : "FAIL ") + msg); if (!cond) failures++; }

const all = run("");
const rows = all.find(n => n.tag === "li" && /\bentry\b/.test(n.className));
const commitRows = rows.filter(n => /\bcommit\b/.test(n.className) && !/\bcommits\b/.test(n.className));
const monthlyRows = rows.filter(n => /\bcommits\b/.test(n.className));
check(commitRows.length > 0, `All: ${commitRows.length} latest-commit rows rendered`);
check(monthlyRows.length === 0, "All: monthly commit totals are hidden");
for (const r of commitRows) {
  const item = r.find(n => n.tag === "a" && n.className === "item")[0];
  const repo = r.find(n => n.tag === "a" && n.className === "repo")[0];
  const login = "erts-sched";
  check(item.textContent === "Show commits", `title is "Show commits" (${repo.textContent})`);
  check(/^https:\/\/github\.com\/[^/]+\/[^/]+\/commits\?author=erts-sched$/.test(item.attrs.href),
        `link is the repository's commit list filtered by author: ${item.attrs.href}`);
  check(item.attrs.target === "_blank" && item.attrs.rel === "noopener", "opens in a new tab");
}

const commitsTab = run("?type=commits");
const tabRows = commitsTab.find(n => n.tag === "li" && /\bentry\b/.test(n.className));
check(tabRows.every(n => /\bcommits\b/.test(n.className)), `Commits tab: only monthly totals (${tabRows.length} rows)`);
check(tabRows.every(n => /^\d+ commits?$/.test(n.find(x => x.className === "item")[0].textContent)),
      "Commits tab: titles are counts");

const profile = byId.links.find(n => n.tag === "a");
check(profile.length >= 1 && profile.every(a => a.attrs.target === "_blank"), `profile links open in a new tab (${profile.length})`);

console.log(failures ? `\n${failures} check(s) failed` : "\nall checks passed");
process.exit(failures ? 1 : 0);
