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
for (const id of ["chips", "links", "q", "from", "to", "timeline", "login", "updated", "owner"]) {
  const n = new Node(id === "q" || id === "from" || id === "to" ? "input" : "div");
  n.value = ""; n.querySelectorAll = () => []; byId[id] = n;
}
byId.chips.querySelectorAll = () => byId.chips.children;

function run(search, navigator = {}){
  byId.timeline.children = []; byId.chips.children = []; byId.links.children = [];
  const ctx = {
    document: doc, console, navigator, setTimeout, clearTimeout,
    window: { matchMedia: () => ({ matches: false }) },
    location: { search, hash: "", pathname: "/", href: "https://nonesilva.github.io/" + search },
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
// Newest first, by the instant: the times of the rows in All never increase.
const times = all.find(n => n.tag === "time").map(n => n.attrs.datetime);
check(times.every((t, i) => !i || times[i - 1] >= t),
      `All: ${times.length} rows in descending time (${times[0]} … ${times[times.length - 1]})`);
const commitRows = rows.filter(n => /\bcommit\b/.test(n.className) && !/\bcommits\b/.test(n.className));
const monthlyRows = rows.filter(n => /\bcommits\b/.test(n.className));
check(commitRows.length > 0, `All: ${commitRows.length} latest-commit rows rendered`);
check(monthlyRows.length === 0, "All: monthly commit totals are hidden");
for (const r of commitRows) {
  const item = r.find(n => n.tag === "a" && n.className === "item")[0];
  const repo = r.find(n => n.tag === "a" && n.className === "repo")[0];
  const login = "NoneSilva";
  check(item.textContent === "Latest commit", `title is "Latest commit" (${repo.textContent})`);
  check(/^https:\/\/github\.com\/[^/]+\/[^/]+\/commits\?author=NoneSilva$/.test(item.attrs.href),
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

// Dates render in the viewer's time zone: a pull request opened at
// 2026-09-10T01:21:08Z is Sep 9 in America/Sao_Paulo and Sep 10 in UTC.
function dateOf(number, tz){
  process.env.TZ = tz;
  const tl = run("?type=pr");
  const row = tl.find(n => n.tag === "li" && /\bentry pr\b/.test(n.className) && n.attrs.id === "pr-elixir-lsp-elixir-ls-1275")[0];
  return row ? row.find(n => n.tag === "time")[0].textContent : null;
}
const inBrazil = dateOf(1275, "America/Sao_Paulo"), inUtc = dateOf(1275, "UTC");
check(inBrazil === "Sep 9, 2026" && inUtc === "Sep 10, 2026", `PR #1275 shows ${inBrazil} in America/Sao_Paulo and ${inUtc} in UTC`);
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
// Nothing takes focus on load, as on GitHub: the visitor navigates first.
check(!/autofocus/.test(html), "no autofocus on load");
// Cache busting: the page loads the data file with exactly one version stamp.
const stamps = html.match(/contributions\/contributions\.js\?v=\d+/g) || [];
check(stamps.length === 1 && !/contributions\.js\?v=\d+\?v=/.test(html), `data file linked with one version stamp: ${stamps[0]}`);
// The account names the heading, the footer and the tab, and all three read
// the same field, so a rename cannot leave one of them behind.
check(byId.login.textContent === "NoneSilva" && byId.owner.textContent === "NoneSilva",
      `heading and footer name the account: ${byId.owner.textContent}`);
check(doc.title === "NoneSilva's contributions" && /<title>NoneSilva&#39;s contributions<\/title>/.test(html.replace(/'/g, "&#39;")),
      `tab title follows the account, in the page and in the HTML: ${doc.title}`);
check(!/Guilherme/.test(byId.owner.textContent + doc.title), "no display name on the page");

// Open Graph: the preview repeats the page's own title and description, and
// its image is a file of the site, of the size the tags declare.
const tag = prop => (html.match(new RegExp(`<meta (?:property|name)="${prop}" content="([^"]*)">`)) || [])[1];
const description = (html.match(/<meta name="description" content="([^"]*)">/) || [])[1];
check(tag("og:title") === "NoneSilva's contributions" && tag("og:title") === (html.match(/<title>([^<]*)<\/title>/) || [])[1],
      `og:title is the page title: ${tag("og:title")}`);
check(!!description && tag("og:description") === description && tag("og:image:alt") === description, "og:description and og:image:alt are the meta description");
check(tag("og:type") === "website" && tag("twitter:card") === "summary", "og:type website, summary card");
const img = /^https:\/\/nonesilva\.github\.io\/(contributions\/og-image\.png)$/.exec(tag("og:image") || "");
const png = img && fs.existsSync(path.join(root, img[1])) ? fs.readFileSync(path.join(root, img[1])) : null;
check(!!png && png.readUInt32BE(16) === +tag("og:image:width") && png.readUInt32BE(20) === +tag("og:image:height"),
      `og:image is an absolute URL to a file of the site, ${tag("og:image:width")}x${tag("og:image:height")} as declared`);
// No og:url: it would send a shared link to the bare page, without its view.
check(tag("og:url") === undefined, "no og:url");

// No translation offer, on every page of the site: Chrome looks for the
// google/notranslate meta among the head's children; translate="no" on
// <html> is the standard for the other translators.
for (const page of ["index.html", "404.html"]) {
  const src = fs.readFileSync(path.join(root, page), "utf8");
  const head = src.slice(src.indexOf("<head>"), src.indexOf("</head>"));
  check(/<html lang="en" translate="no">/.test(src) && /\n<meta name="google" content="notranslate">\n/.test(head),
        `${page}: no translation offer (translate="no", google notranslate meta in the head)`);
}

// Share: the button sits between the profile links and the theme switch and
// shares the address with its view: through the system's share sheet when
// there is one, otherwise by copying it, confirmed for two seconds.
async function shareChecks(){
  const flush = () => new Promise(r => setImmediate(r));
  const button = () => byId.links.children.find(n => n.attrs.id === "share");
  const tip = b => b.find(n => n.className === "tooltip");
  const drawn = b => b.find(n => n.tag === "path")[0].attrs.d.slice(0, 12);
  const SHARE = "M3.75 6.5a.2", COPY = "M0 6.75C0 5.", CHECK = "M13.78 4.22a";
  let shared = null, copied = null;
  run("?type=pr&q=elixir", { share: data => { shared = data; return Promise.resolve(); },
                             clipboard: { writeText: t => { copied = t; return Promise.resolve(); } } });
  const order = byId.links.children.map(n => n.attrs.id || n.textContent);
  check(order[0] === "share" && order[order.length - 1] === "theme" && button().textContent === "Share" && drawn(button()) === SHARE && tip(button()).length === 0,
        `with a share sheet the button is Share, first in the group: ${order.join(", ")}`);
  button().listeners.click[0]();
  await flush();
  check(shared && shared.url === "https://nonesilva.github.io/?type=pr&q=elixir" && copied === null,
        `share sheet gets the address with its view: ${shared && shared.url}`);

  for (const name of ["AbortError", "NotAllowedError"]) {
    shared = null; copied = null;
    run("?from=2026-09-01", { share: () => Promise.reject(Object.assign(new Error(name), { name })),
                              clipboard: { writeText: t => { copied = t; return Promise.resolve(); } } });
    button().listeners.click[0]();
    await flush();
    check(copied === null && tip(button()).length === 0, `Share only shares: ${name} copies nothing`);
  }

  run("?type=review", { clipboard: { writeText: t => { copied = t; return Promise.resolve(); } } });
  check(button().textContent === "Copy" && drawn(button()) === COPY && button().attrs["aria-label"] === "Copy link",
        "without a share sheet the button is Copy: copy icon, named Copy link");
  button().listeners.click[0]();
  await flush();
  const b = button();
  check(copied === "https://nonesilva.github.io/?type=review", `without a share sheet the address is copied: ${copied}`);
  check(b.className === "share share--copied" && drawn(b) === CHECK && b.textContent === "CopyCopied!" && tip(b).length === 1 && tip(b)[0].attrs.role === "status",
        "the button confirms: check, label unchanged, \"Copied!\" tooltip announced as a status");
  await new Promise(r => setTimeout(r, 2100));
  check(tip(button()).length === 0 && button().className === "share" && drawn(button()) === COPY, "after two seconds it is Copy again");
}

shareChecks().then(() => {
  console.log(failures ? `\n${failures} check(s) failed` : "\nall checks passed");
  process.exit(failures ? 1 : 0);
});
