const DEFAULT_CONFIG = {
  cursor_line: { disable: false, color: null, opacity: null },
  scroll: { disable: false, top_offset_pct: 35 },
};

// A jump longer than this many viewport heights is made instantly: smooth
// scrolling over a long document takes long enough to feel like lag.
const INSTANT_VIEWPORTS = 3;

// A block that packs many source lines into little height (a closed <details>, a long
// line run rendered as one short element) still gets a band this tall.
const MIN_BAND_HEIGHT = 4;

// How long a suppressNextScroll() request waits for the layout change it was made for.
// The ResizeObserver reports a toggled <details> on the next frame; a request that no
// layout change consumes must not linger and swallow a later, unrelated scroll.
const SUPPRESS_WINDOW_MS = 400;

const MAX_LINES = 500_001;

function isDocumentScroller(el) {
  return el === document.scrollingElement || el === document.documentElement || el === document.body;
}

function mergeConfig(config) {
  const c = config || {};
  return {
    cursor_line: { ...DEFAULT_CONFIG.cursor_line, ...(c.cursor_line || {}) },
    scroll: { ...DEFAULT_CONFIG.scroll, ...(c.scroll || {}) },
  };
}

/**
 * Keeps `scroller` positioned on the editor's cursor line and draws `band` over that line.
 *
 * `content` holds rendered blocks annotated with `data-line-start` / `data-line-end`
 * (0-based, inclusive source lines). `band` must be absolutely positioned and live inside
 * `scroller` but outside `content`. Elements whose lines fall outside the line count given
 * to rebuild(), or whose end precedes their start, are ignored.
 */
export function createSync({ scroller, content, band }) {
  let config = mergeConfig(null);
  // offsets[line] is the line's top in scroller scroll coordinates; heights[line] is the
  // distance to the next line, measured to the bottom of the line's own block.
  let offsets = new Float64Array(0);
  let heights = new Float64Array(0);
  let bandOrigin = 0;
  let cursor = null;
  let suppressUntil = -Infinity;
  let frame = 0;
  let destroyed = false;
  // Line values are read from the DOM, so they bound array sizes only after being
  // checked against the document's line count. Until rebuild() is given one, the
  // server's 500,000-byte file limit bounds it: no document has more lines than that.
  let lineCount = MAX_LINES;

  // Converts a viewport rect top into scroller scroll coordinates.
  function frameOf() {
    if (isDocumentScroller(scroller)) {
      return { base: 0, scrollTop: document.scrollingElement.scrollTop };
    }
    const r = scroller.getBoundingClientRect();
    return { base: r.top + scroller.clientTop, scrollTop: scroller.scrollTop };
  }

  function containingBlock(el) {
    for (let p = el.parentElement; p; p = p.parentElement) {
      const s = getComputedStyle(p);
      if (s.position !== "static" || s.transform !== "none" || /layout|paint|strict|content/.test(s.contain)) return p;
    }
    return null;
  }

  function computeBandOrigin(f) {
    const cb = containingBlock(band);
    if (!cb || cb === scroller) return 0;
    return cb.getBoundingClientRect().top + cb.clientTop - f.base + f.scrollTop;
  }

  // `lines`, when given, is the source line count of the rendered document and is
  // kept for later rebuilds (ResizeObserver ones pass nothing).
  function rebuild(lines) {
    if (destroyed) return;
    if (Number.isInteger(lines) && lines >= 0) lineCount = Math.min(lines, MAX_LINES);
    const f = frameOf();
    bandOrigin = computeBandOrigin(f);

    const elements = content.querySelectorAll("[data-line-start]");
    const starts = [];
    const ends = [];
    const tops = [];
    const bottoms = [];
    let maxEnd = -1;
    for (const el of elements) {
      const start = Number.parseInt(el.getAttribute("data-line-start"), 10);
      if (!Number.isFinite(start) || start < 0 || start >= lineCount) continue;
      const endAttr = el.getAttribute("data-line-end");
      let end = start;
      if (endAttr !== null) {
        end = Number.parseInt(endAttr, 10);
        if (!Number.isFinite(end)) end = start;
        else if (end < start || end >= lineCount) continue;
      }
      // Library output (MathJax, mermaid) can carry author-chosen attributes.
      if (el.parentElement?.closest("[data-mp-kind], svg, mjx-container")) continue;
      // Children of a closed <details> are laid out with zero size at the top of the
      // details element; their lines must interpolate across the visible summary instead.
      if (!el.checkVisibility()) continue;
      const r = el.getBoundingClientRect();
      const top = r.top - f.base + f.scrollTop;
      starts.push(start);
      ends.push(end);
      tops.push(top);
      bottoms.push(top + r.height);
      if (end > maxEnd) maxEnd = end;
    }

    const size = maxEnd + 2;
    // Per anchor line: innermost/outermost top of the elements starting there, and
    // innermost/outermost bottom of the elements ending on the line before it. Geometric
    // containment makes "innermost" the largest top and the smallest bottom.
    const topIn = new Float64Array(size).fill(Number.NaN);
    const topOut = new Float64Array(size).fill(Number.NaN);
    const botIn = new Float64Array(size).fill(Number.NaN);
    const botOut = new Float64Array(size).fill(Number.NaN);
    for (let i = 0; i < starts.length; i++) {
      const s = starts[i];
      const e = ends[i] + 1;
      const t = tops[i];
      const b = bottoms[i];
      if (!(topIn[s] >= t)) topIn[s] = t;
      if (!(topOut[s] <= t)) topOut[s] = t;
      if (!(botIn[e] <= b)) botIn[e] = b;
      if (!(botOut[e] >= b)) botOut[e] = b;
    }

    const table = new Float64Array(maxEnd + 1);
    const lineHeights = new Float64Array(maxEnd + 1);
    let prevLine = -1;
    let prevValue = 0;
    for (let line = 0; line < size; line++) {
      const hasStart = !Number.isNaN(topIn[line]);
      const hasEnd = !Number.isNaN(botIn[line]);
      if (!hasStart && !hasEnd) continue;
      // Value approaching this anchor from the lines above it.
      const left = hasEnd ? botIn[line] : topOut[line];
      if (prevLine < 0) {
        // Lines before the first annotated element (front matter, leading blank lines)
        // sit at the first element's top.
        for (let l = 0; l < line; l++) table[l] = left;
      } else {
        const span = line - prevLine;
        const step = (left - prevValue) / span;
        for (let l = prevLine; l < line && l <= maxEnd; l++) {
          table[l] = prevValue + step * (l - prevLine);
          lineHeights[l] = step;
        }
      }
      prevLine = line;
      // Value leaving this anchor towards the lines below it.
      prevValue = hasStart ? topIn[line] : botOut[line];
    }
    offsets = table;
    heights = lineHeights;
    apply(true);
  }

  function applyBandStyle() {
    const cl = config.cursor_line;
    // Config values reach the page only as single property values, never as CSS text.
    if (cl.color == null) band.style.removeProperty("background");
    else band.style.setProperty("background", String(cl.color));
    if (cl.opacity == null) band.style.removeProperty("opacity");
    else band.style.setProperty("opacity", String(cl.opacity));
  }

  // Moves the band to the current cursor line and scrolls to it. `fromLayout` marks a
  // re-scroll caused by a layout change, the only kind suppressNextScroll() can skip.
  function apply(fromLayout = false) {
    if (destroyed) return;
    if (cursor === null || offsets.length === 0) {
      band.style.setProperty("display", "none");
      return;
    }
    const at = Math.min(cursor, offsets.length - 1);
    const y = offsets[at];
    const h = Math.max(heights[at], MIN_BAND_HEIGHT);

    let target = null;
    let behavior = "smooth";
    if (!config.scroll.disable) {
      if (fromLayout && performance.now() <= suppressUntil) {
        suppressUntil = -Infinity;
      } else {
        const el = isDocumentScroller(scroller) ? document.scrollingElement : scroller;
        const height = el.clientHeight;
        target = y - (height * Number(config.scroll.top_offset_pct)) / 100;
        if (Math.abs(target - el.scrollTop) > INSTANT_VIEWPORTS * height) behavior = "instant";
      }
    }

    band.style.setProperty("top", `${y - bandOrigin}px`);
    band.style.setProperty("height", `${h}px`);
    band.style.setProperty("display", config.cursor_line.disable ? "none" : "block");
    if (target !== null) {
      const el = isDocumentScroller(scroller) ? window : scroller;
      el.scrollTo({ top: Math.max(0, target), behavior });
    }
  }

  function setCursor(line) {
    cursor = line === null || line === undefined || !Number.isFinite(Number(line)) ? null : Math.max(0, Math.trunc(Number(line)));
    apply();
  }

  function setConfig(next) {
    config = mergeConfig(next);
    applyBandStyle();
    apply();
  }

  function suppressNextScroll() {
    suppressUntil = performance.now() + SUPPRESS_WINDOW_MS;
  }

  const observer = new ResizeObserver(() => {
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      rebuild();
    });
  });
  observer.observe(content);

  function destroy() {
    destroyed = true;
    observer.disconnect();
    if (frame) cancelAnimationFrame(frame);
    frame = 0;
    band.style.setProperty("display", "none");
  }

  band.style.setProperty("display", "none");
  rebuild();

  return { rebuild, setCursor, setConfig, suppressNextScroll, destroy };
}
