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
    scripts: false, // a script of an entry ran in this document (its listeners stay)
    overlays: [], // viewers scripts opened over the entry (see markOverlays)
    rectScale: 1, // see scaled()
  };

  // CSS pixels left and right of a page of horizontal text (scaled with the entry), where what
  // an entry hangs outside its lines stays in view: LDELC sets its sense numbers 0.2rem to the left.
  var GUTTER = 4;

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
    // a bridge can keep a strip below the pages for itself (KOBridge.reserve CSS pixels)
    state.H = window.innerHeight - ((window.KOBridge && KOBridge.reserve) | 0);
    state.dpr = window.devicePixelRatio || 1;
    var root = document.documentElement;
    root.style.setProperty("--mdict-page-w", state.W + "px");
    root.style.setProperty("--mdict-page-h", state.H + "px");
  }

  // Handlers an entry's scripts set for the page's DOMContentLoaded or load (Chambers 13th
  // shows its entries only once its DOMContentLoaded handler has run). Entries are swapped
  // into a page that loaded long before, so these events never come: the pager calls the
  // handlers itself once the entry's scripts have run, as a browser would for each page.
  // A handler an external script set is kept and called for each entry that has that script
  // (the script runs once per document); one an inline script set is called once.
  var READY_EVENTS = { DOMContentLoaded: true, load: true };
  var ready = { handlers: [], src: undefined }; // src: the script running (null: inline)
  function hookReady(target) {
    var add = target.addEventListener;
    target.addEventListener = function (type, fn) {
      if (ready.src !== undefined && READY_EVENTS[type] === true && fn) {
        ready.handlers.push({ type: type, fn: fn, target: this, src: ready.src });
        return;
      }
      return add.apply(this, arguments);
    };
  }
  hookReady(document);
  hookReady(window);

  // Runs fn as part of the script src (null: inline), catching the handlers it sets.
  function asScript(src, fn) {
    var onload = window.onload;
    ready.src = src;
    try { fn(); } finally {
      ready.src = undefined;
      if (window.onload !== onload && typeof window.onload === "function") {
        ready.handlers.push({ type: "load", fn: window.onload, target: window, src: src });
        window.onload = onload;
      }
    }
  }

  // Calls the ready handlers for an entry whose external scripts are srcs.
  function fireReady(srcs) {
    var all = ready.handlers.filter(function (h) { return h.src === null || srcs[h.src]; });
    var kept = ready.handlers.filter(function (h) { return h.src !== null; });
    ready.handlers = [];
    ["DOMContentLoaded", "load"].forEach(function (type) {
      // a handler may set more: they run once, in turn
      for (var i = 0; i < all.length; i++) {
        var h = all[i];
        if (h.type !== type) continue;
        try {
          asScript(null, function () {
            if (typeof h.fn === "function") h.fn.call(h.target, new Event(type));
            else if (h.fn && typeof h.fn.handleEvent === "function") h.fn.handleEvent(new Event(type));
          });
        } catch (e) { /* a broken handler must not stop the entry */ }
        if (ready.handlers.length) {
          all = all.concat(ready.handlers.map(function (n) { n.src = null; return n; }));
          ready.handlers = [];
        }
      }
    });
    ready.handlers = kept;
  }

  // Runs the entry's scripts in document order. innerHTML does not execute
  // them, so each one is re-created. External scripts run once per document.
  function runScripts(container, opts) {
    var skip = Array.isArray(opts.skipScripts) ? opts.skipScripts : [];
    var scripts = Array.prototype.slice.call(container.querySelectorAll("script"));
    var chain = Promise.resolve();
    var srcs = {}, any = false;
    scripts.forEach(function (old) {
      var src = old.getAttribute("src");
      old.parentNode.removeChild(old);
      if (!opts.runScripts) return;
      if (src) {
        var name = src.split(/[\\/]/).pop().split(/[?#]/)[0];
        if (skip.indexOf(name) >= 0) return;
        srcs[src] = any = true;
        if (state.loadedScripts[src]) return;
        state.loadedScripts[src] = true;
        state.scripts = true;
        chain = chain.then(function () {
          return withTimeout(new Promise(function (resolve) {
            var s = document.createElement("script");
            s.src = src;
            // it runs just before onload: its handlers are caught from now until then
            var onload = window.onload;
            ready.src = src;
            s.onload = s.onerror = function () {
              ready.src = undefined;
              if (window.onload !== onload && typeof window.onload === "function") {
                ready.handlers.push({ type: "load", fn: window.onload, target: window, src: src });
                window.onload = onload;
              }
              resolve();
            };
            document.head.appendChild(s);
          }), 1500).then(function () { ready.src = undefined; });
        });
      } else {
        var code = old.textContent;
        state.scripts = any = true;
        chain = chain.then(function () {
          try {
            asScript(null, function () {
              var s = document.createElement("script");
              s.textContent = code;
              document.head.appendChild(s);
              document.head.removeChild(s);
            });
          } catch (e) { /* a broken inline script must not stop the entry */ }
        });
      }
    });
    return chain.then(function () { if (any) fireReady(srcs); });
  }

  function waitForImages(container, ms) {
    var imgs = Array.prototype.slice.call(container.querySelectorAll("img"));
    return withTimeout(Promise.all(imgs.map(function (img) {
      if (img.complete) return null;
      return new Promise(function (r) { img.onload = img.onerror = function () { r(); }; });
    })), ms);
  }

  // Lets multi-column layout break the entry where a reader would expect.
  //  - Scroll containers are monolithic: an entry root with overflow:auto would be
  //    clipped to one page. Make them fragmentable while keeping clipping where the
  //    entry asked for it.
  //  - An inline element holding blocks (a span around a definition and its examples)
  //    is split around them, and the layout then only breaks before the whole run of
  //    blocks: an entry a little taller than the page moved all of it to the next
  //    page. Such an element is left out of the layout (display: contents), so its
  //    blocks break like any others and its text stays on the lines it was on; not
  //    links, and not elements that draw something of their own.
  var CLIP = (window.CSS && CSS.supports && CSS.supports("overflow", "clip")) ? "clip" : "visible";
  var BLOCK_LEVEL = { block: 1, "flow-root": 1, "list-item": 1, table: 1, flex: 1, grid: 1 };
  var RUBY_PARTS = { RT: 1, RP: 1, RB: 1, RTC: 1 };
  var CONTENTS = "data-mdict-contents";
  function fragmentable(zoom) {
    var all = zoom.getElementsByTagName("*"), styles = new Map(), unwrap = new Set(), fixes = [];
    function style(e) {
      var cs = styles.get(e);
      if (!cs) styles.set(e, cs = getComputedStyle(e));
      return cs;
    }
    var fix = function (o) { return o === "auto" || o === "scroll" ? "visible" : o === "hidden" ? CLIP : o; };
    // reads every style first: a write in between would make each read lay out again
    for (var i = 0; i < all.length; i++) {
      var e = all[i], cs = style(e);
      // Chromium before 121 lays ruby text out as a block (ruby > rt { display: block }):
      // it is part of its ruby, which must stay whole.
      if (BLOCK_LEVEL[cs.display] && !RUBY_PARTS[e.tagName] && cs.float === "none" && cs.position !== "absolute"
          && cs.position !== "fixed") {
        for (var p = e.parentElement; p && p !== zoom && !unwrap.has(p); p = p.parentElement) {
          var ps = style(p);
          if (ps.display !== "inline" || !plainInline(p, ps, style(p.parentElement))) break;
          unwrap.add(p);
        }
      }
      var ox = cs.overflowX, oy = cs.overflowY;
      if (ox === "visible" && oy === "visible" || ox === "clip" && oy === "clip") continue;
      // overflow other than visible made it a block formatting context (contains floats)
      fixes.push([e, fix(ox), fix(oy), cs.display === "block"]);
    }
    unwrap.forEach(function (u) {
      u.setAttribute(CONTENTS, "");
      u.style.setProperty("display", "contents", "important");
    });
    for (var k = 0; k < fixes.length; k++) {
      var f = fixes[k];
      f[0].style.setProperty("overflow-x", f[1], "important");
      f[0].style.setProperty("overflow-y", f[2], "important");
      if (f[3]) f[0].style.setProperty("display", "flow-root", "important");
    }
  }

  // An inline element that is only a container for its text: nothing it draws or
  // sets for itself alone (as opposed to what its content inherits) is lost when it
  // is left out of the layout.
  function plainInline(e, cs, parent) {
    if (e.tagName === "A" || e.tagName === "RUBY" || ATOMIC[e.tagName]) return false;
    if (cs.position !== "static" || cs.verticalAlign !== "baseline" || cs.unicodeBidi !== "normal") return false;
    if (cs.writingMode !== parent.writingMode || cs.textCombineUpright && cs.textCombineUpright !== "none") return false;
    if (cs.textDecorationLine !== "none" || cs.backgroundImage !== "none" || !clear(cs.backgroundColor)) return false;
    if (cs.boxShadow !== "none" || cs.outlineStyle !== "none" || cs.opacity !== "1") return false;
    if (cs.transform !== "none" || cs.filter !== "none" || cs.clipPath !== "none") return false;
    if (cs.counterReset !== "none" || cs.counterIncrement !== "none") return false;
    var sides = ["Top", "Right", "Bottom", "Left"];
    for (var i = 0; i < 4; i++) {
      var s = sides[i];
      if (parseFloat(cs["border" + s + "Width"]) || parseFloat(cs["padding" + s]) || parseFloat(cs["margin" + s])) return false;
    }
    return true;
  }

  function clear(color) { return color === "transparent" || /,\s*0\)$/.test(color); }

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

  // Boxes of what the entry holds, in viewport pixels. Chromium before 128 gives them in the
  // pixels of the zoomed element that holds them (the viewport's divided by the text size):
  // taps then found their target pages too early, and links were missed.
  function scaled(r) {
    var s = state.rectScale;
    if (s === 1) return r;
    return { left: r.left * s, top: r.top * s, right: r.right * s, bottom: r.bottom * s,
             width: r.width * s, height: r.height * s };
  }
  function rectsOf(node) {
    var list = node.getClientRects();
    return state.rectScale === 1 ? list : Array.prototype.map.call(list, scaled);
  }
  function boxOf(node) { return scaled(node.getBoundingClientRect()); }

  // Whether this Chromium does that: a 10 px box in an element zoomed twice measures 10, not 20.
  var zoomedBoxes = null;
  function boxesZoomed() {
    if (zoomedBoxes === null) {
      var probe = document.createElement("mdict-probe");
      probe.style.cssText = "display: block !important; position: absolute !important;"
        + " visibility: hidden !important; zoom: 2 !important";
      probe.innerHTML = '<mdict-probe style="display: block !important; width: 10px !important;'
        + ' height: 10px !important; padding: 0 !important; border: 0 !important; zoom: 1 !important"></mdict-probe>';
      document.body.appendChild(probe);
      zoomedBoxes = probe.firstChild.getBoundingClientRect().width < 15;
      document.body.removeChild(probe);
    }
    return zoomedBoxes;
  }

  var ATOMIC = { IMG: true, svg: true, VIDEO: true, CANVAS: true, IFRAME: true, OBJECT: true, EMBED: true };

  // False for content the entry keeps out of view, such as closed <details>
  // sections: it still reports boxes, at positions that mean nothing.
  function shown(node) {
    var e = node.nodeType === 1 ? node : node.parentElement;
    // an element left out of the layout has no box of its own to check
    while (e && e.hasAttribute(CONTENTS)) e = e.parentElement;
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
        rects = rectsOf(range);
      } else if (ATOMIC[node.tagName] && shown(node)) {
        rects = rectsOf(node);
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
      var rects = rectsOf(range), out = false;
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
        rects = rectsOf(range);
      } else if (ATOMIC[node.tagName] && shown(node)) {
        rects = [boxOf(node)];
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

  // A viewer an entry's script opened over the entry (position: fixed), if one is shown.
  // It covers the page, so while it is open the pages are not moved under it: a
  // transformed ancestor would carry it off screen.
  function openOverlay() {
    var zoom = el("mdict-zoom"), list = state.overlays;
    for (var i = list.length - 1; i >= 0; i--) {
      var e = list[i];
      if (!zoom.contains(e)) { list.splice(i, 1); continue; }
      if (shown(e) && getComputedStyle(e).position === "fixed") return e;
    }
    return null;
  }

  function present() {
    applyTransform(state.page);
    if (openOverlay()) {
      content().style.transform = "none";
      content().style.clipPath = "";
    }
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
    var rects = rectsOf(target);
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
      var rr = rectsOf(range);
      if (rr.length) return pageOfRect(rr[0]);
    }
    return -1;
  }

  function pageOfRange(range) {
    var rr = range ? rectsOf(range) : [];
    for (var i = 0; i < rr.length; i++) {
      if (rr[i].width > 0 || rr[i].height > 0) return pageOfRect(rr[i]);
    }
    return -1;
  }

  // Taps ---------------------------------------------------------------------

  // The character under a point on page `page`, as a range: the one after the caret
  // there, or the one before it (at the end of a line).
  function charAt(x, y, page) {
    var r = caretAt(x, y), node = r && r.startContainer;
    if (!node || node.nodeType !== 3) return null;
    for (var off = Math.min(r.startOffset, node.data.length - 1); off >= 0 && off >= r.startOffset - 1; off--) {
      r.setStart(node, off);
      r.setEnd(node, off + 1);
      if (pageOfRange(r) === page) return r;
    }
    return null;
  }

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

  // Clicks target like a finger would. With guard, the click's default action
  // (following a link) is cancelled after the entry's own listeners ran; returns
  // whether one of them cancelled it, i.e. took the click over.
  function activate(target, x, y, guard) {
    // pages are captured as still images: no animations
    if (window.jQuery && window.jQuery.fx) window.jQuery.fx.off = true;
    var hit = x === undefined ? null : document.elementFromPoint(x, y);
    if (!hit || !target.contains(hit)) {
      var r = boxOf(target);
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
    var click = new MouseEvent("click", init), taken = null;
    var keep = function (e) {
      if (e !== click) return;
      taken = e.defaultPrevented;
      e.preventDefault();
    };
    if (guard) window.addEventListener("click", keep);
    var notCancelled = hit.dispatchEvent(click);
    if (guard) window.removeEventListener("click", keep);
    return taken === null ? !notCancelled : taken;
  }

  // Whether each checkbox and radio button is checked. A tap that toggles one changes
  // nothing the observer sees, yet a :checked rule can open a section.
  function checkedState(root) {
    var inputs = root.querySelectorAll('input[type="checkbox"], input[type="radio"]'), s = "";
    for (var i = 0; i < inputs.length; i++) s += inputs[i].checked ? "1" : "0";
    return s;
  }

  // Watches the entry for changes. settle() resolves to whether it changed, once
  // the changes stop; elements added meanwhile are pushed to `added`.
  function watch(added) {
    var zoom = el("mdict-zoom");
    var changed = false, last = Date.now(), start = last, checked = checkedState(zoom);
    var seen = function (records) {
      if (!records.length) return;
      changed = true;
      last = Date.now();
      if (!added) return;
      for (var i = 0; i < records.length; i++) {
        var nodes = records[i].addedNodes;
        for (var j = 0; j < nodes.length; j++) if (nodes[j].nodeType === 1) added.push(nodes[j]);
      }
    };
    var mo = new MutationObserver(seen);
    mo.observe(zoom, { subtree: true, childList: true, attributes: true, characterData: true });
    return {
      cancel: function () { mo.disconnect(); },
      settle: async function () {
        // a click usually changes the entry at once; only when it did not, give the
        // entry's scripts a frame (animation frames can take a third of a second on e-readers)
        seen(mo.takeRecords());
        if (!changed && checkedState(zoom) === checked) await withTimeout(frame(), 400);
        while (Date.now() - last < 60 && Date.now() - start < 600) await sleep(20);
        seen(mo.takeRecords());
        mo.disconnect();
        return changed || checkedState(zoom) !== checked;
      },
    };
  }

  // Runs fn and resolves to true when it changed the entry, once the changes stop.
  function watchChanges(fn, added) {
    var w = watch(added);
    fn();
    return w.settle();
  }

  // Elements a script added that sit over the page (an image viewer): kept so the
  // pages stay put under them, and marked for e-ink mode to give them a background
  // (again after each tap: scripts may rewrite their attributes).
  function markOverlays(added) {
    for (var i = 0; i < added.length; i++) {
      var e = added[i];
      if (e.isConnected && getComputedStyle(e).position === "fixed" && state.overlays.indexOf(e) < 0) {
        state.overlays.push(e);
      }
    }
    for (var j = 0; j < state.overlays.length; j++) state.overlays[j].setAttribute("data-mdict-overlay", "");
  }

  // Milliseconds spent in each step, reported with the result for the log.
  function timer() {
    var t0 = performance.now(), last = t0, out = {};
    return {
      mark: function (name) { var n = performance.now(); out[name] = Math.round(n - last); last = n; },
      done: function () { out.total = Math.round(performance.now() - t0); return out; },
    };
  }

  // Waits for the fonts the entry's text needs. A font starts loading when laying out
  // text first needs it: lay out, and wait again until laying out asks for no more.
  // Not with document.fonts.ready, which only settles after the page next renders: on
  // e-readers the WebView can go seconds without rendering.
  async function fontsLoaded(zoom, ms) {
    if (!document.fonts || !document.fonts.forEach) return;
    var deadline = Date.now() + ms;
    for (var i = 0; i < 5; i++) {
      void zoom.offsetHeight;
      var loading = [];
      document.fonts.forEach(function (f) {
        if (f.status === "loading") loading.push(f.loaded.catch(function () {}));
      });
      if (!loading.length || Date.now() >= deadline) return;
      await withTimeout(Promise.all(loading), Math.max(0, deadline - Date.now()));
    }
  }

  async function settleLayout(opts, t) {
    var zoom = el("mdict-zoom");
    t = t || { mark: function () {} };
    fragmentable(zoom);
    t.mark("fragmentable");
    await waitForImages(zoom, opts.imageTimeout || 1500);
    t.mark("images");
    await fontsLoaded(zoom, opts.fontTimeout || 2000);
    t.mark("fonts");
    layout(state.pagination);
    t.mark("layout");
  }

  var MDict = {};

  MDict.setEntry = function (opId) {
    var opts;
    try { opts = arg(opId); } catch (e) { return fail(opId, e); }
    (async function () {
      var t = timer();
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
      state.rectScale = boxesZoomed() ? (opts.zoom || 1) : 1;
      document.documentElement.style.setProperty("--mdict-gutter", GUTTER * (opts.zoom || 1) + "px");
      zoom.innerHTML = opts.html || "";
      state.overlays = [];
      t.mark("html");
      await runScripts(zoom, opts);
      t.mark("scripts");
      // sections the reader opened before (the entry is laid out again after a nested lookup)
      var clicks = opts.clicks || [];
      for (var i = 0; i < clicks.length; i++) {
        var c = byPath(clicks[i]);
        if (c) await watchChanges(function () { activate(c); });
      }
      t.mark("clicks");
      // scripts may finish their work in an animation frame or a resize observer
      if (state.scripts) await withTimeout(frame(), 400);
      t.mark("scriptFrame");

      var vertical = opts.writing === "vertical" ? true
        : opts.writing === "horizontal" ? false
        : detectVertical(zoom);
      state.vertical = vertical;
      state.pagination = opts.pagination || "auto";
      body.classList.toggle("mdict-vertical", vertical);
      t.mark("writing");
      await settleLayout(opts, t);
      var anchorPage = -1;
      if (opts.anchor) anchorPage = pageOfElement(findAnchor(opts.anchor));
      t.mark("anchor");
      done(opId, { pages: state.pages, vertical: vertical, mode: state.mode, anchorPage: anchorPage,
                   scripts: state.scripts, ms: t.done(),
                   width: Math.round(state.W * state.dpr), height: Math.round(state.H * state.dpr) });
    })().catch(function (e) { fail(opId, e); });
  };

  MDict.showPage = function (opId) {
    var n = arg(opId).page | 0;
    n = Math.max(0, Math.min(state.pages - 1, n));
    state.page = n;
    present();
    // the capture waits until the WebView has drawn this state
    done(opId, { page: n });
  };

  // A tap that is not on a link: activates expandable sections and the like.
  // When the entry changes it is laid out again, staying on the page of what
  // was under the finger. Taps that change nothing are left to KOReader.
  // With link: a tap on a link, offered to the entry's scripts first. It is
  // handled only when a script takes the click over (a picture link that opens
  // a viewer); otherwise KOReader follows the link.
  // The element of a viewer under a point: the last one in document order whose box holds it.
  function hitInside(root, x, y) {
    var all = root.getElementsByTagName("*"), best = root;
    for (var i = 0; i < all.length; i++) {
      var r = boxOf(all[i]);
      if (r.width > 0 && r.height > 0 && x >= r.left && x < r.right && y >= r.top && y < r.bottom && shown(all[i])) {
        best = all[i];
      }
    }
    return best;
  }

  MDict.tap = function (opId) {
    var a = arg(opId), d = state.dpr, x = a.x / d, y = a.y / d;
    var zoom = el("mdict-zoom");
    var hit = document.elementFromPoint(x, y);
    var overlay = openOverlay();
    // Chromium before LayoutNG (the Kindle's 75) can miss a fixed viewer inside the
    // columns when hit testing: a tap within its box is on it
    if (overlay && !(hit && overlay.contains(hit))) {
      var o = boxOf(overlay);
      if (x >= o.left && x < o.right && y >= o.top && y < o.bottom) hit = hitInside(overlay, x, y);
    }
    if (hit && !zoom.contains(hit)) hit = null;
    var inOverlay = !!(hit && overlay && overlay.contains(hit));
    var target;
    if (a.link) target = hit && hit.closest("a[href]");
    else target = hit && (clickTarget(hit) || (inOverlay ? hit : null));
    if (!target || !zoom.contains(target)) {
      // taps on a viewer stay in it
      return done(opId, inOverlay ? { handled: true, same: true } : { handled: false });
    }
    // sections opened on the entry itself are opened again after a re-layout; viewers are not
    var path = a.link || inOverlay ? null : pathOf(target);
    var shownPage = state.page;
    // after a re-layout, the page shown is that of the character tapped: the target can
    // start pages earlier (a definition that shows or hides its translation)
    var spot = charAt(x, y, shownPage);
    if (spot && !target.contains(spot.startContainer)) spot = null;
    (async function () {
      var t = timer(), added = [];
      var w = watch(added);
      var taken = activate(target, x, y, !!a.link);
      if (a.link && !taken) {
        w.cancel();
        return done(opId, { handled: false });
      }
      var changed = await w.settle();
      t.mark("watch");
      // pages are still images: no focus rings on what a script focused
      var focused = document.activeElement;
      if (focused && focused !== document.body && focused.blur) focused.blur();
      if (!changed) {
        return done(opId, inOverlay || a.link ? { handled: true, same: true } : { handled: false });
      }
      markOverlays(added);
      if (openOverlay()) {
        // the entry under a viewer has not moved: keep its pages
        state.page = shownPage;
        present();
        return done(opId, { handled: true, pages: state.pages, page: state.page, mode: state.mode, ms: t.done() });
      }
      await settleLayout({ imageTimeout: 1000 }, t);
      var p = pageOfRange(spot);
      if (p < 0 && target.isConnected) p = pageOfElement(target);
      state.page = Math.max(0, Math.min(state.pages - 1, p >= 0 ? p : shownPage));
      present();
      t.mark("page");
      var res = { handled: true, pages: state.pages, page: state.page, mode: state.mode, ms: t.done() };
      if (path) res.path = path;
      done(opId, res);
    })().catch(function (e) { fail(opId, e); });
  };

  // The boxes a tap on a link can hit: its line boxes, and the boxes of pictures
  // and blocks inside it, which can be much taller than its line.
  function linkRects(a) {
    var rects = Array.prototype.slice.call(rectsOf(a));
    var inner = a.getElementsByTagName("*");
    for (var i = 0; i < inner.length; i++) {
      var e = inner[i];
      if (!ATOMIC[e.tagName] && getComputedStyle(e).display === "inline") continue;
      if (!shown(e)) continue;
      rects = rects.concat(Array.prototype.slice.call(rectsOf(e)));
    }
    return rects;
  }

  // Links visible on the current page, with their raw href. While a viewer is
  // open, only its own links.
  MDict.links = function (opId) {
    var out = [];
    var overlay = openOverlay();
    var anchors = (overlay || el("mdict-zoom")).querySelectorAll("a[href]");
    for (var i = 0; i < anchors.length; i++) {
      var a = anchors[i];
      if (!isRealLink(a) || !shown(a)) continue; // script links are taps
      var rects = linkRects(a), text = null;
      for (var j = 0; j < rects.length; j++) {
        if (!visible(rects[j])) continue;
        var d = toDevice(rects[j]);
        d.uri = a.getAttribute("href");
        d.text = text === null ? (text = linkText(a)) : text;
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
    var rr = rectsOf(range);
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
          var rr = rectsOf(range);
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
