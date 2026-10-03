import { createSync } from "/web/sync.js";

// index.html scrolls a dedicated element; document.html scrolls the page itself.
const scroller = document.getElementById("scroller") ?? document.scrollingElement;
const isDocument = scroller === document.scrollingElement;
const content = document.getElementById("content");
const band = document.getElementById("band");
let sync = null;

function attrs(el, b) {
  el.setAttribute("data-line-start", String(b.start));
  if (b.end !== undefined) el.setAttribute("data-line-end", String(b.end));
}

// Absolute layout: every block gets an exact top (relative to #content) and height,
// so expected offsets are known without depending on font metrics.
function placeAbs(parent, parentTop, blocks) {
  for (const b of blocks) {
    const el = document.createElement(b.tag || "div");
    el.className = "blk";
    attrs(el, b);
    el.style.top = `${b.top - parentTop}px`;
    el.style.height = `${b.h}px`;
    parent.appendChild(el);
    if (b.children) placeAbs(el, b.top, b.children);
  }
}

function fresh(config) {
  if (sync) sync.destroy();
  scroller.scrollTop = 0;
  sync = createSync({ scroller, content, band });
  if (config) sync.setConfig(config);
  return sync;
}

function nextFrames(n) {
  return new Promise((resolve) => {
    const step = (k) => (k === 0 ? resolve() : requestAnimationFrame(() => step(k - 1)));
    step(n);
  });
}

window.T = {
  get sync() {
    return sync;
  },
  scroller,
  content,
  band,
  nextFrames,

  abs(blocks, extra = 2000) {
    content.className = "";
    content.innerHTML = "";
    let bottom = 0;
    for (const b of blocks) bottom = Math.max(bottom, b.top + b.h);
    content.style.height = `${bottom + extra}px`;
    placeAbs(content, 0, blocks);
    return fresh(null);
  },

  flow(html) {
    content.className = "flow";
    content.style.height = "";
    content.innerHTML = html;
    return fresh(null);
  },

  empty() {
    content.className = "";
    content.style.height = "";
    content.innerHTML = "";
    return fresh(null);
  },

  // Band position relative to the content top (y) and in scroller scroll coordinates.
  band() {
    const b = band.getBoundingClientRect();
    const c = content.getBoundingClientRect();
    const base = isDocument ? 0 : scroller.getBoundingClientRect().top + scroller.clientTop;
    return {
      display: getComputedStyle(band).display,
      y: b.top - c.top,
      h: b.height,
      scrollY: b.top - base + scroller.scrollTop,
      styleTop: band.style.top,
      background: band.style.background,
      opacity: band.style.opacity,
    };
  },

  // Moves the cursor with scrolling disabled and returns the band position.
  yOf(line) {
    sync.setConfig({ scroll: { disable: true } });
    sync.setCursor(line);
    return this.band().y;
  },

  // Moves the band and content into a positioned wrapper that is offset inside the
  // scroller, so the band's containing block is not the scroller itself.
  wrap() {
    const w = document.createElement("div");
    w.id = "wrapper";
    w.style.cssText = "position:relative;margin-top:20px;padding-top:7px;border-top:3px solid #888";
    scroller.appendChild(w);
    w.append(band, content);
  },

  unwrap() {
    const w = document.getElementById("wrapper");
    if (!w) return;
    scroller.append(band, content);
    w.remove();
  },

  // Builds a large flow document of `n` blocks, each spanning two source lines followed
  // by one blank line, and times rebuild() after layout is already settled.
  big(n) {
    content.className = "flow";
    content.style.height = "";
    const parts = [];
    for (let i = 0; i < n; i++) {
      const s = i * 3;
      parts.push(`<p data-line-start="${s}" data-line-end="${s + 1}" style="height:20px;margin-bottom:10px">block ${i}</p>`);
    }
    content.innerHTML = parts.join("");
    fresh(null);
    void content.offsetHeight;
    const runs = [];
    for (let k = 0; k < 5; k++) {
      const t0 = performance.now();
      sync.rebuild();
      runs.push(performance.now() - t0);
    }
    const t0 = performance.now();
    const moves = 10000;
    sync.setConfig({ scroll: { disable: true } });
    for (let i = 0; i < moves; i++) sync.setCursor((i * 7919) % (n * 3));
    const perMove = (performance.now() - t0) / moves;
    return { runs, perMove };
  },
};
window.__harnessReady = true;
