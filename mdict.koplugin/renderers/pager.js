/*
 * Pager for MDict entries, running inside the offscreen WebView (or any
 * Chromium for tests). The page size is the viewport size; pages are CSS
 * columns of exactly one viewport, laid out side by side for horizontal text
 * and stacked top to bottom for vertical-rl text.
 *
 * The host talks to it through window.MDict.<op>(opId). Arguments are read
 * with KOBridge.arg(opId) (a JSON string) and results are returned with
 * KOBridge.done(opId, json). Coordinates exchanged with the host are device
 * pixels relative to the page.
 *
 * Two pagination modes:
 *  - columns: CSS multi-column layout, one column per page. Lines never
 *    straddle pages and images avoid breaks.
 *  - slices: the entry is laid out as one long strip and shown a page at a
 *    time, with page breaks moved back to line boundaries and the part of
 *    the next line below the break clipped. It is the fallback for layouts
 *    multi-column fragmentation cannot split (monolithic boxes taller than a
 *    page), chosen automatically when columns would lose text.
 */
(function () {
  "use strict";

  var state = {
    vertical: false,
    page: 0,
    pages: 1,
    W: 0,
    H: 0,
    dpr: 1,
    mode: "columns",
    slices: null, // slices mode: page start offsets along the reading axis, plus the extent
    loadedScripts: {},
  };

  function el(id) { return document.getElementById(id); }
  function arg(opId) { return JSON.parse(KOBridge.arg(opId) || "{}"); }
  function done(opId, result) { KOBridge.done(opId, JSON.stringify(result === undefined ? null : result)); }
  function fail(opId, e) {
    KOBridge.done(opId, JSON.stringify({ error: String(e && e.stack || e) }));
  }

  function frame() {
    return new Promise(function (resolve) { requestAnimationFrame(function () { resolve(); }); });
  }
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function withTimeout(promise, ms) {
    return Promise.race([promise, sleep(ms)]);
  }

  function measureViewport() {
    state.W = window.innerWidth;
    state.H = window.innerHeight;
    state.dpr = window.devicePixelRatio || 1;
    var root = document.documentElement;
    root.style.setProperty("--mdict-page-w", state.W + "px");
    root.style.setProperty("--mdict-page-h", state.H + "px");
  }

  // Runs the entry's scripts in document order. innerHTML does not execute
  // them, so each one is re-created. External scripts run once per document.
  function runScripts(container, opts) {
    var skip = opts.skipScripts || [];
    var scripts = Array.prototype.slice.call(container.querySelectorAll("script"));
    var chain = Promise.resolve();
    scripts.forEach(function (old) {
      var src = old.getAttribute("src");
      old.parentNode.removeChild(old);
      if (!opts.runScripts) return;
      if (src) {
        var name = src.split(/[\\/]/).pop().split(/[?#]/)[0];
        if (skip.indexOf(name) >= 0) return;
        if (state.loadedScripts[src]) return;
        state.loadedScripts[src] = true;
        chain = chain.then(function () {
          return withTimeout(new Promise(function (resolve) {
            var s = document.createElement("script");
            s.src = src;
            s.onload = s.onerror = function () { resolve(); };
            document.head.appendChild(s);
          }), 1500);
        });
      } else {
        var code = old.textContent;
        chain = chain.then(function () {
          try {
            var s = document.createElement("script");
            s.textContent = code;
            document.head.appendChild(s);
            document.head.removeChild(s);
          } catch (e) { /* a broken inline script must not stop the entry */ }
        });
      }
    });
    return chain;
  }

  function waitForImages(container, ms) {
    var imgs = Array.prototype.slice.call(container.querySelectorAll("img"));
    return withTimeout(Promise.all(imgs.map(function (img) {
      if (img.complete) return null;
      return new Promise(function (r) { img.onload = img.onerror = function () { r(); }; });
    })), ms);
  }

  // Scroll containers are monolithic in multi-column layout: an entry root with
  // overflow:auto would be clipped to one page. Make them fragmentable while
  // keeping clipping where the entry asked for it.
  var CLIP = (window.CSS && CSS.supports && CSS.supports("overflow", "clip")) ? "clip" : "visible";
  function unscroll(zoom) {
    var all = zoom.getElementsByTagName("*");
    for (var i = 0; i < all.length; i++) {
      var e = all[i], cs = getComputedStyle(e);
      var ox = cs.overflowX, oy = cs.overflowY;
      if (ox === "visible" && oy === "visible" || ox === "clip" && oy === "clip") continue;
      var fix = function (o) { return o === "auto" || o === "scroll" ? "visible" : o === "hidden" ? CLIP : o; };
      e.style.setProperty("overflow-x", fix(ox), "important");
      e.style.setProperty("overflow-y", fix(oy), "important");
      // overflow other than visible made it a block formatting context (contains floats)
      if (cs.display === "block") e.style.setProperty("display", "flow-root", "important");
    }
  }

  // Detects vertical writing from what the entry's own CSS computes for its
  // main content, before the pager's axis is chosen.
  function detectVertical(zoom) {
    // Text inside the outermost vertical boxes, against all text: a record
    // can hold several entries, each in its own vertical root.
    var verticalLen = 0;
    var queue = Array.prototype.slice.call(zoom.children);
    for (var depth = 0; depth < 5 && queue.length; depth++) {
      var next = [];
      for (var i = 0; i < queue.length; i++) {
        var node = queue[i];
        var wm = getComputedStyle(node).writingMode;
        if (wm && (wm.indexOf("vertical") === 0 || wm.indexOf("tb") === 0 || wm.indexOf("sideways") === 0)) {
          verticalLen += (node.textContent || "").length;
        } else {
          next = next.concat(Array.prototype.slice.call(node.children));
        }
      }
      queue = next;
    }
    var total = (zoom.textContent || "").length;
    return total > 0 && verticalLen >= total * 0.5;
  }

  function content() { return el("mdict-content"); }

  var ATOMIC = { IMG: true, svg: true, VIDEO: true, CANVAS: true, IFRAME: true, OBJECT: true, EMBED: true };

  // False for content the entry keeps out of view, such as closed <details>
  // sections: it still reports boxes, at positions that mean nothing.
  function shown(node) {
    var e = node.nodeType === 1 ? node : node.parentElement;
    if (!e) return false;
    if (e.checkVisibility) return e.checkVisibility();
    for (var n = e; n; n = n.parentElement) {
      if (n.tagName === "DETAILS" && !n.open) {
        var s = e.closest("summary");
        if (!s || s.parentElement !== n) return false;
      }
    }
    return true;
  }

  // columns -----------------------------------------------------------------

  function countColumns() {
    var c = content();
    var size = state.vertical ? state.H : state.W;
    var extent = state.vertical ? c.scrollHeight : c.scrollWidth;
    // Trailing empty columns can appear when the last fragment ends exactly
    // on a page edge; trim pages that contain no rendered boxes.
    var pages = Math.max(1, Math.ceil((extent - 1) / size));
    while (pages > 1 && !pageHasContent(pages - 1)) pages--;
    return pages;
  }

  function pageHasContent(n) {
    var save = state.page;
    state.page = n;
    applyTransform(n);
    var found = false;
    var walker = document.createTreeWalker(el("mdict-zoom"), NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    var range = document.createRange();
    for (var node = walker.nextNode(); node && !found; node = walker.nextNode()) {
      var rects;
      if (node.nodeType === 3) {
        if (!node.data.trim() || !shown(node)) continue;
        range.selectNodeContents(node);
        rects = range.getClientRects();
      } else if (ATOMIC[node.tagName] && shown(node)) {
        rects = node.getClientRects();
      } else {
        continue;
      }
      for (var i = 0; i < rects.length; i++) {
        if (visible(rects[i])) { found = true; break; }
      }
    }
    state.page = save;
    applyTransform(save);
    return found;
  }

  // Ancestors that clip or take content out of flow on purpose.
  function hiddenOnPurpose(e) {
    var zoom = el("mdict-zoom");
    for (; e && e !== zoom; e = e.parentElement) {
      var cs = getComputedStyle(e);
      if (cs.position === "absolute" || cs.position === "fixed" || cs.visibility === "hidden") return true;
      if (cs.overflowX !== "visible" || cs.overflowY !== "visible") return true;
    }
    return false;
  }

  // True when columns leave text outside every page: a box that cannot be
  // fragmented and is taller (wider, for vertical text) than a page overflows
  // its column and is cut off.
  function columnsLoseText() {
    var walker = document.createTreeWalker(el("mdict-zoom"), NodeFilter.SHOW_TEXT);
    var range = document.createRange();
    var lost = 0, total = 0, slack = 4;
    for (var node = walker.nextNode(); node; node = walker.nextNode()) {
      var len = node.data.trim().length;
      if (!len || !shown(node)) continue;
      total += len;
      range.selectNodeContents(node);
      var rects = range.getClientRects(), out = false;
      for (var i = 0; i < rects.length && !out; i++) {
        var r = rects[i];
        if (!(r.width > 0 && r.height > 0)) continue;
        out = state.vertical ? (r.left < -slack || r.right > state.W + slack)
                             : (r.top < -slack || r.bottom > state.H + slack);
      }
      if (out && !hiddenOnPurpose(node.parentElement)) lost += len;
    }
    return lost > 0 && (lost >= 20 || lost >= total * 0.02);
  }

  // slices ------------------------------------------------------------------

  // Position along the reading axis, from the start edge of the content:
  // top down for horizontal text, right to left for vertical-rl.
  function axisSpan(r, c) {
    return state.vertical ? [c.right - r.right, c.right - r.left] : [r.top - c.top, r.bottom - c.top];
  }

  // Page start offsets: a page ends where the next one would cut a line or
  // an image in two, unless that line alone is longer than a page.
  function sliceOffsets() {
    var c = content().getBoundingClientRect();
    var extent = state.vertical ? c.width : c.height;
    var size = state.vertical ? state.W : state.H;
    var spans = [];
    var walker = document.createTreeWalker(el("mdict-zoom"), NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    var range = document.createRange();
    for (var node = walker.nextNode(); node; node = walker.nextNode()) {
      var rects;
      if (node.nodeType === 3) {
        if (!node.data.trim() || !shown(node)) continue;
        range.selectNodeContents(node);
        rects = range.getClientRects();
      } else if (ATOMIC[node.tagName] && shown(node)) {
        rects = [node.getBoundingClientRect()];
      } else {
        continue;
      }
      for (var i = 0; i < rects.length; i++) {
        if (rects[i].width > 0 && rects[i].height > 0) spans.push(axisSpan(rects[i], c));
      }
    }
    spans.sort(function (a, b) { return a[0] - b[0]; });
    var merged = [];
    for (var j = 0; j < spans.length; j++) {
      var sp = spans[j], last = merged[merged.length - 1];
      if (last && sp[0] < last[1] - 0.5) {
        if (sp[1] > last[1]) last[1] = sp[1];
      } else {
        merged.push([sp[0], sp[1]]);
      }
    }
    var offs = [0], start = 0, k = 0;
    while (start + size < extent - 1) {
      var end = start + size, brk = end;
      while (k < merged.length && merged[k][1] <= end) k++;
      if (k < merged.length && merged[k][0] < end && merged[k][0] > start + 1) brk = Math.floor(merged[k][0]);
      offs.push(brk);
      start = brk;
    }
    return { offs: offs, extent: extent };
  }

  function sliceEnd(n) {
    var sl = state.slices;
    return n + 1 < sl.offs.length ? sl.offs[n + 1] : sl.extent;
  }

  // both modes --------------------------------------------------------------

  function applyTransform(n) {
    var c = content();
    if (state.mode === "slices") {
      var sl = state.slices, off = sl.offs[n] || 0, cut = sl.extent - sliceEnd(n);
      if (state.vertical) {
        c.style.transform = "translateX(" + (state.W - sl.extent + off) + "px)";
        c.style.clipPath = "inset(0 " + off + "px 0 " + cut + "px)";
      } else {
        c.style.transform = "translateY(" + (-off) + "px)";
        c.style.clipPath = "inset(" + off + "px 0 " + cut + "px 0)";
      }
      return;
    }
    c.style.clipPath = "";
    c.style.transform = state.vertical
      ? "translateY(" + (-n * state.H) + "px)"
      : "translateX(" + (-n * state.W) + "px)";
  }

  // Lays the entry out in the requested pagination mode ("auto" tries columns first).
  function layout(mode) {
    state.page = 0;
    state.mode = "columns";
    state.slices = null;
    document.body.classList.remove("mdict-slices");
    applyTransform(0);
    if (mode !== "slices") {
      state.pages = countColumns();
      if (mode === "columns" || !columnsLoseText()) return;
    }
    state.mode = "slices";
    document.body.classList.add("mdict-slices");
    state.slices = sliceOffsets();
    state.pages = state.slices.offs.length;
    applyTransform(0);
  }

  // Page index of a client rect measured while page `state.page` is shown.
  function pageOfRect(r) {
    if (state.mode === "slices") {
      var pos = axisSpan(r, content().getBoundingClientRect())[0] + 0.5;
      var offs = state.slices.offs, lo = 0, hi = offs.length - 1;
      while (lo < hi) {
        var mid = (lo + hi + 1) >> 1;
        if (offs[mid] <= pos) lo = mid; else hi = mid - 1;
      }
      return lo;
    }
    if (state.vertical) {
      return Math.floor((r.top + state.page * state.H + 0.5) / state.H);
    }
    return Math.floor((r.left + state.page * state.W + 0.5) / state.W);
  }

  // How far a rect measured on the shown page moves when page p is shown.
  function shiftTo(p) {
    if (state.mode === "slices") {
      var d = state.slices.offs[state.page] - state.slices.offs[p];
      return state.vertical ? { x: -d, y: 0 } : { x: 0, y: d };
    }
    return state.vertical ? { x: 0, y: (state.page - p) * state.H } : { x: (state.page - p) * state.W, y: 0 };
  }

  function toDevice(r) {
    var d = state.dpr;
    return {
      x0: Math.round(r.left * d), y0: Math.round(r.top * d),
      x1: Math.round(r.right * d), y1: Math.round(r.bottom * d),
    };
  }

  // The part of the viewport the shown page covers (a slice can be shorter than the viewport).
  function viewBox() {
    if (state.mode === "slices") {
      var len = sliceEnd(state.page) - state.slices.offs[state.page];
      return state.vertical ? { left: Math.max(0, state.W - len), top: 0, right: state.W, bottom: state.H }
                            : { left: 0, top: 0, right: state.W, bottom: Math.min(state.H, len) };
    }
    return { left: 0, top: 0, right: state.W, bottom: state.H };
  }

  function visible(r) {
    var v = viewBox();
    return r.width > 0 && r.height > 0 && r.right > v.left && r.bottom > v.top && r.left < v.right && r.top < v.bottom;
  }

  function findAnchor(id) {
    if (!id) return null;
    var zoom = el("mdict-zoom");
    var target = null;
    try { target = zoom.querySelector("#" + CSS.escape(id)); } catch (e) { target = null; }
    if (!target) target = zoom.querySelector('[name="' + id.replace(/"/g, '\\"') + '"]');
    return target;
  }

  function pageOfElement(target) {
    if (!target) return -1;
    var rects = target.getClientRects();
    for (var i = 0; i < rects.length; i++) {
      if (rects[i].width > 0 || rects[i].height > 0) return pageOfRect(rects[i]);
    }
    // An empty anchor: use the first rendered box after it.
    var walker = document.createTreeWalker(el("mdict-zoom"), NodeFilter.SHOW_TEXT);
    walker.currentNode = target;
    for (var node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!node.data.trim()) continue;
      var range = document.createRange();
      range.selectNodeContents(node);
      var rr = range.getClientRects();
      if (rr.length) return pageOfRect(rr[0]);
    }
    return -1;
  }

  // Taps ---------------------------------------------------------------------

  function isRealLink(a) {
    var href = (a.getAttribute("href") || "").trim();
    return href !== "" && href !== "#" && !/^javascript:/i.test(href);
  }

  // The element a tap activates, when it looks interactive (links are KOReader's).
  function clickTarget(node) {
    var zoom = el("mdict-zoom");
    for (var n = node; n && n !== zoom && n.nodeType === 1; n = n.parentElement) {
      var tag = n.tagName;
      if (tag === "A" && n.hasAttribute("href")) return isRealLink(n) ? null : n;
      if (tag === "SUMMARY" || tag === "BUTTON" || tag === "LABEL" || tag === "INPUT" || tag === "SELECT") return n;
      if (n.hasAttribute("onclick") || n.getAttribute("role") === "button") return n;
      if (getComputedStyle(n).cursor === "pointer") return n;
    }
    return null;
  }

  // Child indexes from the entry root, so a tap can be replayed after a re-layout.
  function pathOf(e) {
    var zoom = el("mdict-zoom"), path = [];
    for (; e && e !== zoom; e = e.parentElement) {
      if (!e.parentElement) return null;
      path.unshift(Array.prototype.indexOf.call(e.parentElement.children, e));
    }
    return e === zoom ? path : null;
  }

  function byPath(path) {
    var e = el("mdict-zoom");
    for (var i = 0; e && i < path.length; i++) e = e.children[path[i]];
    return e || null;
  }

  function activate(target, x, y) {
    // pages are captured as still images: no animations
    if (window.jQuery && window.jQuery.fx) window.jQuery.fx.off = true;
    var hit = x === undefined ? null : document.elementFromPoint(x, y);
    if (!hit || !target.contains(hit)) {
      var r = target.getBoundingClientRect();
      hit = target;
      x = r.left + r.width / 2;
      y = r.top + r.height / 2;
    }
    var init = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y, button: 0 };
    if (typeof PointerEvent === "function") {
      hit.dispatchEvent(new PointerEvent("pointerdown", init));
      hit.dispatchEvent(new PointerEvent("pointerup", init));
    }
    hit.dispatchEvent(new MouseEvent("mousedown", init));
    hit.dispatchEvent(new MouseEvent("mouseup", init));
    hit.dispatchEvent(new MouseEvent("click", init));
  }

  // Runs fn and resolves to true when it changed the entry, once the changes stop.
  function watchChanges(fn) {
    var zoom = el("mdict-zoom");
    var changed = false, last = Date.now(), start = last;
    var mo = new MutationObserver(function () { changed = true; last = Date.now(); });
    mo.observe(zoom, { subtree: true, childList: true, attributes: true, characterData: true });
    fn();
    return (async function () {
      await frame();
      while (Date.now() - last < 60 && Date.now() - start < 600) await sleep(20);
      mo.disconnect();
      return changed;
    })();
  }

  async function settleLayout(opts) {
    var zoom = el("mdict-zoom");
    unscroll(zoom);
    await waitForImages(zoom, opts.imageTimeout || 1500);
    if (document.fonts && document.fonts.ready) {
      await withTimeout(document.fonts.ready, opts.fontTimeout || 2000);
    }
    await frame();
    layout(state.pagination);
  }

  var MDict = {};

  MDict.setEntry = function (opId) {
    var opts;
    try { opts = arg(opId); } catch (e) { return fail(opId, e); }
    (async function () {
      measureViewport();
      var body = document.body;
      var zoom = el("mdict-zoom");
      body.classList.remove("mdict-vertical", "mdict-slices");
      body.classList.toggle("mdict-eink", !!opts.eink);
      state.mode = "columns";
      state.slices = null;
      content().style.transform = "";
      content().style.clipPath = "";
      zoom.style.zoom = String(opts.zoom || 1);
      zoom.innerHTML = opts.html || "";
      await runScripts(zoom, opts);
      // sections the reader opened before (the entry is laid out again after a nested lookup)
      var clicks = opts.clicks || [];
      for (var i = 0; i < clicks.length; i++) {
        var t = byPath(clicks[i]);
        if (t) await watchChanges(function () { activate(t); });
      }

      var vertical = opts.writing === "vertical" ? true
        : opts.writing === "horizontal" ? false
        : detectVertical(zoom);
      state.vertical = vertical;
      state.pagination = opts.pagination || "auto";
      body.classList.toggle("mdict-vertical", vertical);
      await settleLayout(opts);
      var anchorPage = -1;
      if (opts.anchor) anchorPage = pageOfElement(findAnchor(opts.anchor));
      done(opId, { pages: state.pages, vertical: vertical, mode: state.mode, anchorPage: anchorPage,
                   width: Math.round(state.W * state.dpr), height: Math.round(state.H * state.dpr) });
    })().catch(function (e) { fail(opId, e); });
  };

  MDict.showPage = function (opId) {
    var n = arg(opId).page | 0;
    n = Math.max(0, Math.min(state.pages - 1, n));
    state.page = n;
    applyTransform(n);
    frame().then(frame).then(function () { done(opId, { page: n }); });
  };

  // A tap that is not on a link: activates expandable sections and the like.
  // When the entry changes it is laid out again, staying on the tapped
  // element's page. Taps that change nothing are left to KOReader.
  MDict.tap = function (opId) {
    var a = arg(opId), d = state.dpr, x = a.x / d, y = a.y / d;
    var zoom = el("mdict-zoom");
    var hit = document.elementFromPoint(x, y);
    var target = hit && zoom.contains(hit) ? clickTarget(hit) : null;
    if (!target) return done(opId, { handled: false });
    var path = pathOf(target);
    var shown = state.page;
    (async function () {
      var changed = await watchChanges(function () { activate(target, x, y); });
      if (!changed) return done(opId, { handled: false });
      await settleLayout({ imageTimeout: 1000 });
      var p = target.isConnected ? pageOfElement(target) : -1;
      state.page = Math.max(0, Math.min(state.pages - 1, p >= 0 ? p : shown));
      applyTransform(state.page);
      done(opId, { handled: true, path: path, pages: state.pages, page: state.page, mode: state.mode });
    })().catch(function (e) { fail(opId, e); });
  };

  // Links visible on the current page, with their raw href.
  MDict.links = function (opId) {
    var out = [];
    var anchors = el("mdict-zoom").querySelectorAll("a[href]");
    for (var i = 0; i < anchors.length; i++) {
      var a = anchors[i];
      if (!isRealLink(a) || !shown(a)) continue; // script links are taps
      var rects = a.getClientRects();
      for (var j = 0; j < rects.length; j++) {
        if (!visible(rects[j])) continue;
        var d = toDevice(rects[j]);
        d.uri = a.getAttribute("href");
        d.text = linkText(a);
        out.push(d);
      }
    }
    done(opId, out);
  };

  // A link's words without its decorations: boxed marks (an "A" badge), smaller
  // text such as homograph numbers and furigana, and hidden parts. KOReader shows
  // the text as the title of the entry the link opens.
  function transparent(color) {
    return !color || color === "transparent" || /^rgba\(.*,\s*0\)$/.test(color);
  }

  function isDecoration(e, size, bg) {
    var cs = getComputedStyle(e);
    if (cs.display === "none" || cs.visibility === "hidden") return true;
    if (e.tagName === "RT" || e.tagName === "RP" || e.tagName === "SUP" || e.tagName === "SUB") return true;
    var boxed = cs.borderTopStyle !== "none" && parseFloat(cs.borderTopWidth) > 0 &&
                cs.borderBottomStyle !== "none" && parseFloat(cs.borderBottomWidth) > 0;
    var tinted = !transparent(cs.backgroundColor) && cs.backgroundColor !== bg;
    return boxed || tinted || parseFloat(cs.fontSize) < size * 0.85;
  }

  function linkText(a) {
    var acs = getComputedStyle(a);
    var size = parseFloat(acs.fontSize) || 0, bg = acs.backgroundColor;
    var parts = [];
    (function walk(n) {
      for (var c = n.firstChild; c; c = c.nextSibling) {
        if (c.nodeType === 3) parts.push(c.nodeValue);
        else if (c.nodeType === 1 && !isDecoration(c, size, bg)) walk(c);
      }
    })(a);
    var text = parts.join("").replace(/\s+/g, " ").trim();
    if (!text) text = (a.textContent || "").replace(/\s+/g, " ").trim();
    return text.slice(0, 80);
  }

  function caretAt(x, y) {
    if (document.caretRangeFromPoint) return document.caretRangeFromPoint(x, y);
    var p = document.caretPositionFromPoint && document.caretPositionFromPoint(x, y);
    if (!p) return null;
    var r = document.createRange();
    r.setStart(p.offsetNode, p.offset);
    return r;
  }

  function segmenterFor(node) {
    var lang = "";
    for (var n = node.nodeType === 1 ? node : node.parentElement; n && !lang; n = n.parentElement) {
      lang = n.getAttribute && n.getAttribute("lang") || "";
    }
    if (typeof Intl === "undefined" || !Intl.Segmenter) return null;
    try { return new Intl.Segmenter(lang || undefined, { granularity: "word" }); } catch (e) { return null; }
  }

  function charClass(c) {
    if (!c) return null;
    if (/[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\u3005-\u3007\u30F6]/.test(c)) return "kanji";
    if (/[\u3041-\u309F]/.test(c)) return "hira";
    if (/[\u30A0-\u30FF\u31F0-\u31FF\uFF66-\uFF9F]/.test(c)) return "kata";
    if (/[0-9A-Za-z_\u00C0-\u024F\u0370-\u03FF\u0400-\u04FF'\u2019-]/.test(c)) return "word";
    return null;
  }

  // Without Intl.Segmenter (WebView before Chromium 87): a run of one script.
  // Kanji take up to three following hiragana (okurigana); the dictionary
  // lookup tries shorter prefixes of Japanese text when the whole run is not
  // a headword.
  function scriptRun(text, off) {
    var cls = charClass(text[off]);
    if (!cls && off > 0) cls = charClass(text[--off]);
    if (!cls) return null;
    var start = off, end = off + 1;
    var max = cls === "word" ? 64 : 12;
    while (start > 0 && off - start < max && charClass(text[start - 1]) === cls) start--;
    while (end < text.length && end - start < max && charClass(text[end]) === cls) end++;
    if (cls === "kanji") {
      var tail = 0;
      while (end < text.length && tail < 3 && charClass(text[end]) === "hira") { end++; tail++; }
    }
    if (cls === "word") {
      while (end > start && /['\u2019-]/.test(text[end - 1])) end--;
      while (start < end && /['\u2019-]/.test(text[start])) start++;
    }
    return [start, end];
  }

  // Word under a point: the segment that contains the caret offset.
  function wordRange(x, y) {
    var caret = caretAt(x, y);
    if (!caret || caret.startContainer.nodeType !== 3) return null;
    var node = caret.startContainer, text = node.data, off = caret.startOffset;
    // caretRangeFromPoint returns the nearest boundary; prefer the character under the point
    var seg = segmenterFor(node);
    var start = off, end = off;
    if (seg) {
      var it = seg.segment(text);
      var s = it.containing(Math.min(off, text.length - 1));
      if (s && !s.isWordLike && off > 0) {
        var s2 = it.containing(off - 1);
        if (s2 && s2.isWordLike) s = s2;
      }
      if (!s) return null;
      start = s.index; end = s.index + s.segment.length;
    } else {
      var span = scriptRun(text, off);
      if (!span) return null;
      start = span[0]; end = span[1];
    }
    if (end <= start) return null;
    var r = document.createRange();
    r.setStart(node, start);
    r.setEnd(node, end);
    return r;
  }

  function rangeResult(range) {
    var rects = [];
    var rr = range.getClientRects();
    for (var i = 0; i < rr.length; i++) {
      if (visible(rr[i])) rects.push(toDevice(rr[i]));
    }
    return { text: range.toString().replace(/\s+/g, " ").trim(), rects: rects };
  }

  // Text under a hold (x0,y0) or between a hold and a pan end (x1,y1).
  MDict.textAt = function (opId) {
    var a = arg(opId), d = state.dpr;
    var r0 = wordRange(a.x0 / d, a.y0 / d);
    if (!r0) return done(opId, { text: "", rects: [] });
    if (a.x1 === undefined || (a.x1 === a.x0 && a.y1 === a.y0)) return done(opId, rangeResult(r0));
    var r1 = wordRange(a.x1 / d, a.y1 / d) || r0;
    var range = document.createRange();
    if (r0.compareBoundaryPoints(Range.START_TO_START, r1) <= 0) {
      range.setStart(r0.startContainer, r0.startOffset);
      range.setEnd(r1.endContainer, r1.endOffset);
    } else {
      range.setStart(r1.startContainer, r1.startOffset);
      range.setEnd(r0.endContainer, r0.endOffset);
    }
    done(opId, rangeResult(range));
  };

  // Case-insensitive search in the entry text. Returns matches grouped by page.
  // The element whose text flows together with this node's (its nearest non-inline ancestor).
  function blockOf(node, root) {
    for (var e = node.parentElement; e && e !== root; e = e.parentElement) {
      var d = getComputedStyle(e).display;
      if (d !== "inline" && d !== "contents" && d.indexOf("ruby") !== 0) return e;
    }
    return root;
  }

  MDict.find = function (opId) {
    var term = (arg(opId).term || "").toLowerCase();
    var byPage = {};
    if (term) {
      // matches may span markup (<b>こと</b>ば), so search each block's text as one string
      var root = el("mdict-zoom");
      var runs = [], run = null;
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      for (var node = walker.nextNode(); node; node = walker.nextNode()) {
        if (!shown(node)) continue;
        var block = blockOf(node, root);
        if (!run || run.block !== block) {
          run = { block: block, nodes: [], starts: [], text: "" };
          runs.push(run);
        }
        run.nodes.push(node);
        run.starts.push(run.text.length);
        run.text += node.data;
      }
      var nodeAt = function (rn, pos, isEnd) {
        var k = rn.starts.length - 1;
        while (k > 0 && (isEnd ? rn.starts[k] >= pos : rn.starts[k] > pos)) k--;
        return k;
      };
      for (var ri = 0; ri < runs.length; ri++) {
        var rn = runs[ri];
        var hay = rn.text.toLowerCase();
        for (var at = hay.indexOf(term); at >= 0; at = hay.indexOf(term, at + term.length)) {
          var s = nodeAt(rn, at, false), e = nodeAt(rn, at + term.length, true);
          var range = document.createRange();
          range.setStart(rn.nodes[s], at - rn.starts[s]);
          range.setEnd(rn.nodes[e], at + term.length - rn.starts[e]);
          var rr = range.getClientRects();
          for (var i = 0; i < rr.length; i++) {
            if (rr[i].width === 0 && rr[i].height === 0) continue;
            var p = pageOfRect(rr[i]);
            var shift = shiftTo(p);
            var r = rr[i];
            var dev = toDevice({ left: r.left + shift.x, top: r.top + shift.y, right: r.right + shift.x, bottom: r.bottom + shift.y });
            (byPage[p] = byPage[p] || []).push(dev);
          }
        }
      }
    }
    done(opId, byPage);
  };

  MDict.pageOfAnchor = function (opId) {
    done(opId, { page: pageOfElement(findAnchor(arg(opId).id)) });
  };

  MDict.ping = function (opId) { measureViewport(); done(opId, { ok: true, w: state.W, h: state.H, dpr: state.dpr }); };

  window.MDict = MDict;
  measureViewport();
  // Focus and hash changes could scroll the pager; pages are placed by transform only.
  document.addEventListener("scroll", function (e) {
    var t = e.target === document ? document.scrollingElement : e.target;
    if (t && (t.scrollTop || t.scrollLeft)) {
      t.scrollTop = 0;
      t.scrollLeft = 0;
    }
  }, true);
  window.addEventListener("resize", measureViewport);
})();
