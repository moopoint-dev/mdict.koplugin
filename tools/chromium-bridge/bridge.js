#!/usr/bin/env node
/*
 * Desktop stand-in for the Android HtmlRenderer: the same slots, ops and
 * events, served by headless Chromium through Playwright. Used by the KOReader
 * emulator and by the integration tests.
 *
 * Commands arrive as JSON lines on stdin; events leave as JSON lines on stdout:
 *   {"cmd":"open","slot":1,"w":1150,"h":1100,"dpr":2}      -> {"ev":"opened","slot":1}
 *   {"cmd":"load","slot":1,"base":"https://x.mdict.local/","html":"...","root":"/cache/x","files":{...}}
 *                                                          -> {"ev":"loaded","slot":1}
 *   {"cmd":"call","slot":1,"id":7,"op":"setEntry","args":"{...}"} -> {"ev":"done","slot":1,"id":7,"r":...}
 *   {"cmd":"provide","rid":3,"path":"/cache/x/style.css"}
 *   {"cmd":"capture","slot":1,"id":8,"w":1150,"h":1100,"file":"/tmp/page.rgba"} -> {"ev":"captured",...}
 *   {"cmd":"close","slot":1} / {"cmd":"closeAll"}
 * Resource requests missing from the cache emit {"ev":"need","slot":1,"rid":3,"path":"style.css"}.
 */
"use strict";
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const readline = require("readline");

const types = { css: "text/css", js: "text/javascript", png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg",
  svg: "image/svg+xml", otf: "font/otf", ttf: "font/ttf", woff: "font/woff", woff2: "font/woff2", gif: "image/gif",
  webp: "image/webp", html: "text/html" };

function emit(ev) { process.stdout.write(JSON.stringify(ev) + "\n"); }

// Minimal PNG decoder for Chromium screenshots (8-bit RGB/RGBA, not interlaced) -> RGBA.
function decodePng(buf) {
  let pos = 8, w = 0, h = 0, ctype = 0;
  const idat = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos), type = buf.toString("ascii", pos + 4, pos + 8);
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === "IHDR") { w = data.readUInt32BE(0); h = data.readUInt32BE(4); ctype = data[9]; }
    else if (type === "IDAT") idat.push(data);
    pos += 12 + len;
  }
  const bpp = ctype === 6 ? 4 : 3;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = w * bpp, out = Buffer.alloc(w * h * 4);
  let prev = Buffer.alloc(stride), cur = Buffer.alloc(stride);
  for (let y = 0; y < h; y++) {
    const f = raw[y * (stride + 1)], line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0, b = prev[x], c = x >= bpp ? prev[x - bpp] : 0;
      let v = line[x];
      if (f === 1) v += a; else if (f === 2) v += b; else if (f === 3) v += (a + b) >> 1;
      else if (f === 4) { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c; }
      cur[x] = v & 255;
    }
    for (let x = 0; x < w; x++) {
      const o = (y * w + x) * 4;
      out[o] = cur[x * bpp]; out[o + 1] = cur[x * bpp + 1]; out[o + 2] = cur[x * bpp + 2];
      out[o + 3] = bpp === 4 ? cur[x * bpp + 3] : 255;
    }
    [prev, cur] = [cur, prev];
  }
  return { w, h, data: out };
}

(async () => {
  const browser = await chromium.launch();
  const slots = new Map();
  const needs = new Map();
  let nextRid = 1;

  async function openSlot(cmd) {
    let s = slots.get(cmd.slot);
    const dpr = cmd.dpr || 2;
    const viewport = { width: Math.round(cmd.w / dpr), height: Math.round(cmd.h / dpr) };
    if (s && s.dpr === dpr) {
      await s.page.setViewportSize(viewport);
    } else {
      if (s) await s.context.close();
      const context = await browser.newContext({ viewport, deviceScaleFactor: dpr });
      const page = await context.newPage();
      s = { context, page, dpr, host: "", root: "", files: {}, args: new Map(), doc: "" };
      slots.set(cmd.slot, s);
      const slot = s, slotId = cmd.slot;
      await page.exposeBinding("__koArg", (_src, id) => { const a = slot.args.get(id); slot.args.delete(id); return a || "{}"; });
      await page.exposeBinding("__koDone", (_src, id, json) => emit({ ev: "done", slot: slotId, id, r: JSON.parse(json) }));
      await page.addInitScript(() => {
        // Synchronous arg() like the Android bridge: args are pushed before the op is called.
        window.KOBridge = {
          _args: {},
          arg(id) { const a = this._args[id]; delete this._args[id]; return a || "{}"; },
          done(id, json) { window.__koDone(id, json); },
          log(msg) { console.log(msg); },
        };
      });
      page.on("pageerror", (e) => emit({ ev: "error", slot: slotId, msg: String(e.message) }));
      await page.route("**/*", async (route) => {
        const url = new URL(route.request().url());
        if (url.protocol !== "https:" || url.hostname !== slot.host) return route.fulfill({ status: 404, body: "" });
        const p = decodeURIComponent(url.pathname);
        if (p === "/__pager__.html") return route.fulfill({ status: 200, contentType: "text/html", body: slot.doc });
        // like the Android bridge: entries never navigate the pager away
        if (route.request().isNavigationRequest()) return route.abort();
        let file;
        if (p.startsWith("/__file__/")) file = slot.files[p.slice(10)];
        else {
          const rel = p.replace(/^\/+/, "");
          if (!rel || rel.includes("..")) return route.fulfill({ status: 404, body: "" });
          file = path.join(slot.root, rel);
          if (!fs.existsSync(file)) {
            const rid = nextRid++;
            file = await new Promise((resolve) => {
              const timer = setTimeout(() => { needs.delete(rid); resolve(""); }, 4000);
              needs.set(rid, (f) => { clearTimeout(timer); resolve(f); });
              emit({ ev: "need", slot: slotId, rid, path: rel });
            });
          }
        }
        if (!file || !fs.existsSync(file)) return route.fulfill({ status: 404, body: "" });
        const ext = path.extname(file).slice(1).toLowerCase();
        route.fulfill({ status: 200, contentType: types[ext] || "application/octet-stream", body: fs.readFileSync(file),
          headers: { "Access-Control-Allow-Origin": "*" } });
      });
    }
    emit({ ev: "opened", slot: cmd.slot });
  }

  async function handle(cmd) {
    const s = slots.get(cmd.slot);
    switch (cmd.cmd) {
      case "open": return openSlot(cmd);
      case "load":
        s.host = new URL(cmd.base).hostname; s.root = cmd.root; s.files = cmd.files || {}; s.doc = cmd.html;
        await s.page.goto(cmd.base + "__pager__.html");
        return emit({ ev: "loaded", slot: cmd.slot });
      case "call":
        await s.page.evaluate(({ id, op, args }) => { KOBridge._args[id] = args; MDict[op](id); },
          { id: cmd.id, op: cmd.op, args: cmd.args });
        return;
      case "provide": { const f = needs.get(cmd.rid); if (f) { needs.delete(cmd.rid); f(cmd.path); } return; }
      case "capture": {
        const png = await s.page.screenshot({ type: "png" });
        const img = decodePng(png);
        let ok = img.w === cmd.w && img.h === cmd.h;
        if (ok) fs.writeFileSync(cmd.file, img.data);
        return emit({ ev: "captured", slot: cmd.slot, id: cmd.id, ok, w: img.w, h: img.h });
      }
      case "close": if (s) { await s.context.close(); slots.delete(cmd.slot); } return;
      case "closeAll": for (const [id, x] of slots) { await x.context.close(); slots.delete(id); } return;
      case "quit": await browser.close(); process.exit(0);
    }
  }

  // Commands run in order, except "provide", which must not wait behind a call blocked on it.
  let chain = Promise.resolve();
  const rl = readline.createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    let cmd;
    try { cmd = JSON.parse(line); } catch (e) { return emit({ ev: "error", slot: 0, msg: "bad command" }); }
    const run = () => handle(cmd).catch((e) => emit({ ev: "error", slot: cmd.slot || 0, id: cmd.id, msg: String(e && e.message || e) }));
    if (cmd.cmd === "provide") run(); else chain = chain.then(run);
  });
  rl.on("close", async () => { await chain; await browser.close(); process.exit(0); });
  emit({ ev: "ready" });
})().catch((e) => { emit({ ev: "error", slot: 0, msg: String(e), fatal: true }); process.exit(1); });
