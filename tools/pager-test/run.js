#!/usr/bin/env node
/*
 * Renders entries through the pager in headless Chromium, the way the
 * Android WebView bridge drives it, and saves one screenshot per page.
 *
 *   node tools/pager-test/run.js --res <dict res dir> --out <dir> [--w 575 --h 550 --dpr 2]
 *        [--writing auto|horizontal|vertical] [--font kind=Name]... [--find term]
 *        [--anchor id] [--max-pages N] [--pagination auto|columns|slices]
 *        [--tap-selector css] [--user-font file[:all|latin|cjk]] [--skip-script name.js]...
 *        [--cpu-slowdown N] [--zoom N] [--cdp url] entry.html...
 *
 * --tap-selector taps the first matching element on the page where it starts
 * (e.g. an expandable section's summary) and saves the pages again as
 * *-tap-pN.png. It prints that page as tapPage, and as replayPages the pages
 * of the entry laid out again with the tap replayed (as after a nested lookup).
 *
 * --zoom is the text size setting (1.25 for 125 %).
 *
 * --cdp drives the first tab of a Chromium that is already running, such as an
 * older one like those of e-readers: Chrome on an Android emulator, after
 * `adb forward tcp:9222 localabstract:chrome_devtools_remote`, is http://127.0.0.1:9222.
 *
 * --cpu-slowdown throttles the page's CPU N times, roughly like a slow e-reader.
 *
 * Prints one JSON line per entry with the pager results.
 */
"use strict";
const { chromium } = require("playwright");
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "../..");
const opts = { w: 575, h: 550, dpr: 2, writing: "auto", fonts: [], skipScripts: [], entries: [], maxPages: 6 };
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  const next = () => process.argv[++i];
  if (a === "--res") opts.res = next();
  else if (a === "--out") opts.out = next();
  else if (a === "--w") opts.w = +next();
  else if (a === "--h") opts.h = +next();
  else if (a === "--dpr") opts.dpr = +next();
  else if (a === "--writing") opts.writing = next();
  else if (a === "--font") opts.fonts.push(next());
  else if (a === "--find") opts.find = next();
  else if (a === "--anchor") opts.anchor = next();
  else if (a === "--max-pages") opts.maxPages = +next();
  else if (a === "--eink") opts.eink = true;
  else if (a === "--pagination") opts.pagination = next();
  else if (a === "--tap-selector") opts.tapSelector = next();
  else if (a === "--user-font") opts.userFont = next();
  else if (a === "--skip-script") opts.skipScripts.push(next());
  else if (a === "--cpu-slowdown") opts.cpuSlowdown = +next();
  else if (a === "--zoom") opts.zoom = +next();
  else if (a === "--cdp") opts.cdp = next();
  else opts.entries.push(a);
}

const types = { css: "text/css", js: "text/javascript", png: "image/png", jpg: "image/jpeg", svg: "image/svg+xml",
  otf: "font/otf", ttf: "font/ttf", woff: "font/woff", woff2: "font/woff2", gif: "image/gif", html: "text/html" };

(async () => {
  fs.mkdirSync(opts.out, { recursive: true });
  const browser = opts.cdp ? await chromium.connectOverCDP(opts.cdp) : await chromium.launch();
  const context = opts.cdp ? browser.contexts()[0]
    : await browser.newContext({ viewport: { width: opts.w, height: opts.h }, deviceScaleFactor: opts.dpr });
  const requests = [];
  let prep, shared = null;
  // a page that serves the entry being tested
  const setup = async (page) => {
    page.on("console", (m) => { if (m.type() === "error") console.error("console:", m.text()); });
    page.on("pageerror", (e) => console.error("pageerror:", e.message));
    await page.route("**/*", async (route) => {
      const url = new URL(route.request().url());
      if (!url.hostname.endsWith(".mdict.local")) return route.abort();
      let p = decodeURIComponent(url.pathname);
      requests.push(p);
      if (p === "/__pager__.html") return route.fulfill({ status: 200, contentType: "text/html", body: prep.doc });
      let file;
      if (p.startsWith("/__file__/")) file = prep.files[p.slice(10)];
      else file = path.join(opts.res, p);
      if (!file || !fs.existsSync(file)) return route.fulfill({ status: 404, body: "" });
      const ext = path.extname(file).slice(1).toLowerCase();
      route.fulfill({ status: 200, contentType: types[ext] || "application/octet-stream", body: fs.readFileSync(file) });
    });
    await page.addInitScript(() => {
      window.KOBridge = {
        _args: {}, _res: {},
        arg(id) { return this._args[id]; },
        done(id, json) { this._res[id] = json; },
      };
    });
  };
  for (const entry of opts.entries) {
    const args = [path.join(root, "tools/pager-test/prepare.lua"), entry];
    for (const f of opts.fonts) args.push("--font", f);
    if (opts.userFont) args.push("--user-font", opts.userFont);
    if (opts.res) args.push("--res", opts.res);
    prep = JSON.parse(execFileSync("luajit", args, { maxBuffer: 1 << 28 }).toString());
    let page;
    if (opts.cdp) {
      // a browser on Android opens no tabs for a driver: its first one serves every entry
      if (!shared) {
        shared = context.pages()[0];
        await shared.setViewportSize({ width: opts.w, height: opts.h });
        await setup(shared);
      }
      page = shared;
    } else {
      page = await context.newPage();
      await setup(page);
    }
    if (opts.cpuSlowdown > 1) {
      const cdp = await context.newCDPSession(page);
      await cdp.send("Emulation.setCPUThrottlingRate", { rate: opts.cpuSlowdown });
    }
    await page.goto("https://test.mdict.local/__pager__.html");
    let seq = 0;
    const op = async (name, a) => {
      const id = ++seq;
      return page.evaluate(async ({ id, name, a }) => {
        KOBridge._args[id] = JSON.stringify(a || {});
        MDict[name](id);
        for (let t = 0; t < 600 && !(id in KOBridge._res); t++) await new Promise((r) => setTimeout(r, 25));
        return JSON.parse(KOBridge._res[id] || "null");
      }, { id, name, a });
    };
    const dpr = await page.evaluate(() => devicePixelRatio);
    const entryArgs = { html: prep.entry, writing: opts.writing, eink: !!opts.eink, runScripts: true,
      skipScripts: opts.skipScripts, anchor: opts.anchor, pagination: opts.pagination, zoom: opts.zoom };
    const t0 = Date.now();
    const res = await op("setEntry", entryArgs);
    res.ms = Date.now() - t0;
    const base = path.basename(entry, ".html");
    const n = Math.min(res.pages || 1, opts.maxPages);
    for (let p = 0; p < n; p++) {
      await op("showPage", { page: p });
      await page.screenshot({ path: path.join(opts.out, `${base}-p${p}.png`) });
    }
    await op("showPage", { page: 0 });
    const links = await op("links");
    res.links = links.length;
    res.firstLinks = links.slice(0, 3);
    // a hold in the middle-ish of the first page
    res.textAt = await op("textAt", { x0: Math.round(opts.w * dpr * 0.5), y0: Math.round(opts.h * dpr * 0.3) });
    if (opts.find) {
      const f = await op("find", { term: opts.find });
      res.find = Object.fromEntries(Object.entries(f).map(([k, v]) => [k, v.length]));
    }
    if (opts.tapSelector) {
      let at = null;
      for (let p = 0; p < (res.pages || 1) && !at; p++) {
        await op("showPage", { page: p });
        at = await page.evaluate(({ sel, zoom }) => {
          const e = document.querySelector(sel);
          const r = e && e.getClientRects()[0];
          if (!r) return null;
          // Chromium before 128 measures what a zoomed element holds in its own pixels
          const probe = document.createElement("div");
          probe.style.cssText = "position: absolute; zoom: 2";
          probe.innerHTML = '<div style="width: 10px"></div>';
          document.body.appendChild(probe);
          const s = probe.firstChild.getBoundingClientRect().width < 15 ? zoom : 1;
          probe.remove();
          const x = (r.left + Math.min(r.width / 2, 20)) * s, y = (r.top + r.height / 2) * s;
          return x >= 0 && x < innerWidth && y >= 0 && y < innerHeight ? { x, y } : null;
        }, { sel: opts.tapSelector, zoom: opts.zoom || 1 });
        if (at) res.tapPage = p;
      }
      if (at) {
        const t1 = Date.now();
        res.tap = await op("tap", { x: Math.round(at.x * dpr), y: Math.round(at.y * dpr) });
        res.tapMs = Date.now() - t1;
        const m = Math.min((res.tap && res.tap.pages) || 1, opts.maxPages);
        for (let p = 0; p < m; p++) {
          await op("showPage", { page: p });
          await page.screenshot({ path: path.join(opts.out, `${base}-tap-p${p}.png`) });
        }
        if (res.tap && res.tap.path) {
          const again = await op("setEntry", Object.assign({}, entryArgs, { clicks: [res.tap.path] }));
          res.replayPages = again && again.pages;
        }
      } else {
        res.tap = "selector not visible";
      }
    }
    res.entry = base;
    console.log(JSON.stringify(res));
    if (!opts.cdp) await page.close();
  }
  const notFound = requests.filter((p) => !p.startsWith("/__") && !fs.existsSync(path.join(opts.res, p)));
  if (notFound.length) console.error("missing resources:", [...new Set(notFound)].slice(0, 10));
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
