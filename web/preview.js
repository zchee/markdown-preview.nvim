// The live preview: renders a document into the page, keeps rendered code,
// math and diagrams across re-renders, applies the theme, and hands layout
// changes to the scroll/cursor-line sync. It knows nothing about the
// transport; app.js and the test harness drive it.

import { VERSIONS, cdnUrl, loadStylesheet } from './libs.js';
import { createRenderer } from './render.js';
import { createSync } from './sync.js';
import { highlightCode, highlightSource, codeKey } from './highlight.js';
import { typesetMath, mathSource, mathKey } from './math.js';
import { renderMermaid, mermaidSource, mermaidKey } from './mermaid.js';

const DEFAULT_CONFIG = {
  theme: { name: 'system', high_contrast: false },
  details_tags_open: true,
  cursor_line: { disable: false, color: '#c86414', opacity: 0.2 },
  scroll: { disable: false, top_offset_pct: 35 },
};

// Elements whose content was replaced by a library, with the source text it
// was rendered from. A re-render keeps them when their source is unchanged.
const RENDERED = [
  { kind: 'code', done: highlightSource, key: codeKey },
  { kind: 'math', done: mathSource, key: mathKey },
  { kind: 'mermaid', done: mermaidSource, key: mermaidKey },
];

const LINE_ATTRS = ['data-line-start', 'data-line-end'];

function soleElement(nodes) {
  let el = null;
  for (const node of nodes) {
    if (node.nodeType === Node.ELEMENT_NODE) {
      if (el) return null;
      el = node;
    } else if (node.nodeType !== Node.TEXT_NODE || node.data.trim()) {
      return null;
    }
  }
  return el;
}

// Moves the line attributes of a reused segment to its new first line.
function shiftLines(seg, base) {
  const delta = base - seg.base;
  if (delta) {
    for (const node of seg.nodes) {
      if (node.nodeType !== Node.ELEMENT_NODE) continue;
      const marked = node.hasAttribute('data-line-start') ? [node] : [];
      for (const el of [...marked, ...node.querySelectorAll('[data-line-start]')]) {
        for (const name of LINE_ATTRS) el.setAttribute(name, String(Number(el.getAttribute(name)) + delta));
      }
    }
  }
  return seg.nodes;
}
const darkQuery = matchMedia('(prefers-color-scheme: dark)');

function mergeConfig(base, patch) {
  const out = structuredClone(base);
  for (const [key, value] of Object.entries(patch ?? {})) {
    out[key] = value && typeof value === 'object' && !Array.isArray(value)
      ? { ...out[key], ...value }
      : value;
  }
  return out;
}

export class Preview {
  constructor({ root, band, libs, cdn, config, onOpen, onError }) {
    this.root = root;
    this.cdn = cdn;
    this.Idiomorph = libs.Idiomorph;
    this.renderer = createRenderer(libs);
    this.onOpen = onOpen;
    this.onError = onError;
    this.config = mergeConfig(DEFAULT_CONFIG, config);
    this.path = '';
    this.source = '';
    // Rendered segments in document order: { html, base, nodes }.
    this.segments = [];
    this.segmentsPath = null;
    this.generation = 0;
    this.stats = {};
    this.sync = createSync({ scroller: document.scrollingElement, content: root, band });
    this.sync.setConfig(this.config);

    this.morphConfig = {
      morphStyle: 'outerHTML',
      callbacks: {
        beforeNodeMorphed: (oldNode, newNode) => this.keepRendered(oldNode, newNode),
        // A <details> the reader opened or closed stays that way.
        beforeAttributeUpdated: (name, el) => !(name === 'open' && el.nodeName === 'DETAILS'),
      },
    };

    root.addEventListener('click', (event) => this.onClick(event), { capture: true });
    darkQuery.addEventListener('change', () => {
      if (this.config.theme.name === 'system') this.applyTheme();
    });
    this.applyTheme();
  }

  keepRendered(oldNode, newNode) {
    if (oldNode.nodeType !== Node.ELEMENT_NODE || newNode.nodeType !== Node.ELEMENT_NODE) return true;
    for (const kind of RENDERED) {
      if (oldNode.dataset.mpKind !== kind.kind || !kind.done.has(oldNode)) continue;
      if (newNode.dataset.mpKind === kind.kind && kind.done.get(oldNode) === kind.key(newNode)) {
        for (const name of LINE_ATTRS) {
          const value = newNode.getAttribute(name);
          if (value === null) oldNode.removeAttribute(name);
          else oldNode.setAttribute(name, value);
        }
        return false;
      }
      kind.done.delete(oldNode);
    }
    return true;
  }

  // `cursorLine` is applied after the render so the first paint lands on it.
  setDocument(path, lines, cursorLine) {
    this.path = path;
    this.source = lines.join('\n');
    this.render();
    if (cursorLine !== undefined) this.sync.setCursor(cursorLine);
  }

  setCursor(line) {
    this.sync.setCursor(line);
  }

  setConfig(config) {
    const previous = this.config;
    this.config = mergeConfig(DEFAULT_CONFIG, config);
    if (this.config.details_tags_open !== previous.details_tags_open) {
      for (const details of this.root.querySelectorAll('details')) {
        details.open = this.config.details_tags_open;
      }
    }
    this.sync.setConfig(this.config);
    this.applyTheme();
  }

  // Only segments whose rendered HTML changed are sanitized and patched into
  // the page; the unchanged ones before and after them keep their nodes (and
  // so their highlighting, math, diagrams and <details> state) and only get
  // their line attributes moved when lines were inserted or removed above.
  render() {
    const started = performance.now();
    const generation = ++this.generation;
    document.documentElement.dataset.mpRender = 'pending';
    let lineCount = 1;
    for (let at = this.source.indexOf('\n'); at !== -1; at = this.source.indexOf('\n', at + 1)) lineCount++;
    const next = this.renderer.segments(this.source, { path: this.path });
    if (this.segmentsPath !== this.path) {
      this.root.replaceChildren();
      this.segments = [];
      this.segmentsPath = this.path;
    }
    const prev = this.segments;
    let head = 0;
    while (head < prev.length && head < next.length && prev[head].html === next[head].html) head++;
    let tail = 0;
    while (
      tail < prev.length - head &&
      tail < next.length - head &&
      prev[prev.length - 1 - tail].html === next[next.length - 1 - tail].html
    ) {
      tail++;
    }
    for (let i = 0; i < head; i++) next[i].nodes = shiftLines(prev[i], next[i].base);
    for (let k = 1; k <= tail; k++) {
      next[next.length - k].nodes = shiftLines(prev[prev.length - k], next[next.length - k].base);
    }
    const oldMid = prev.slice(head, prev.length - tail);
    const newMid = next.slice(head, next.length - tail);
    const anchor = prev.slice(prev.length - tail).find((seg) => seg.nodes.length)?.nodes[0] ?? null;
    for (const seg of newMid) {
      const fragment = this.renderer.sanitize(seg.html, {
        path: this.path,
        base: seg.base,
        stamps: seg.stamps,
        lineCount,
        detailsOpen: this.config.details_tags_open,
      });
      this.applyPictureTheme(fragment);
      seg.nodes = [...fragment.childNodes];
    }
    if (oldMid.length === newMid.length) {
      // Back to front, so `ref` is always the first node after the segment.
      let ref = anchor;
      for (let i = oldMid.length - 1; i >= 0; i--) {
        this.patch(oldMid[i], newMid[i], ref);
        ref = newMid[i].nodes[0] ?? ref;
      }
    } else {
      for (const old of oldMid) for (const node of old.nodes) node.remove();
      const fragment = document.createDocumentFragment();
      for (const seg of newMid) fragment.append(...seg.nodes);
      this.root.insertBefore(fragment, anchor);
    }
    this.segments = next;
    this.sync.rebuild(lineCount);
    this.stats = {
      paintMs: performance.now() - started,
      segments: next.length,
      rerendered: newMid.length,
    };
    document.documentElement.dataset.mpRender = 'painted';
    this.decorate(generation, started);
  }

  // Replaces one changed segment in place. A segment that is a single element
  // before and after is morphed, so rendered blocks and <details> state inside
  // it survive; anything else is swapped wholesale.
  patch(old, seg, ref) {
    const oldEl = soleElement(old.nodes);
    const newEl = soleElement(seg.nodes);
    if (oldEl && newEl && oldEl.nodeName === newEl.nodeName) {
      for (const node of old.nodes) if (node !== oldEl) node.remove();
      const morphed = this.Idiomorph.morph(oldEl, newEl, this.morphConfig);
      seg.nodes = morphed?.length ? [...morphed] : [newEl];
      return;
    }
    const fragment = document.createDocumentFragment();
    fragment.append(...seg.nodes);
    this.root.insertBefore(fragment, ref);
    for (const node of old.nodes) node.remove();
  }

  // Code highlighting, math and diagrams run on the sanitized DOM after the
  // text is on screen. Their output is library-generated and not sanitized.
  async decorate(generation, started) {
    const dark = document.documentElement.dataset.mpTheme === 'dark';
    const jobs = [
      highlightCode(this.root, this.cdn),
      typesetMath(this.root, this.cdn),
      renderMermaid(this.root, this.cdn, dark),
    ].map((job) =>
      job.then(
        (count) => {
          if (count) this.sync.rebuild();
        },
        (err) => this.onError?.(err),
      ),
    );
    await Promise.all(jobs);
    if (generation !== this.generation) return;
    this.stats.completeMs = performance.now() - started;
    document.documentElement.dataset.mpRender = 'complete';
    document.documentElement.dataset.mpRenders = String(generation);
  }

  applyTheme() {
    const { name, high_contrast: high } = this.config.theme;
    const theme = name === 'system' ? (darkQuery.matches ? 'dark' : 'light') : name;
    const html = document.documentElement;
    const changed = html.dataset.mpTheme !== theme;
    html.dataset.mpTheme = theme;
    html.dataset.mpContrast = high ? 'high' : 'normal';
    const file = theme === 'dark'
      ? high ? 'github-markdown-dark-high-contrast.css' : 'github-markdown-dark.css'
      : 'github-markdown-light.css';
    const sheets = [loadStylesheet(cdnUrl(this.cdn, VERSIONS.css, file), { id: 'mp-markdown-css' })];
    // github-markdown-css has no light high-contrast file; Primer's own token
    // sheet supplies those values for elements carrying its theme attributes.
    if (theme === 'light' && high) {
      sheets.push(
        loadStylesheet(cdnUrl(this.cdn, VERSIONS.primer, 'dist/css/functional/themes/light-high-contrast.css'), {
          id: 'mp-primer-hc',
        }),
      );
      this.root.dataset.colorMode = 'light';
      this.root.dataset.lightTheme = 'light_high_contrast';
    } else {
      delete this.root.dataset.colorMode;
      delete this.root.dataset.lightTheme;
    }
    Promise.all(sheets).then(() => this.sync.rebuild(), (err) => this.onError?.(err));
    this.applyPictureTheme(this.root);
    if (changed && this.root.querySelector('[data-mp-kind=mermaid]')) {
      renderMermaid(this.root, this.cdn, theme === 'dark').then(
        () => this.sync.rebuild(),
        (err) => this.onError?.(err),
      );
    }
  }

  // <source media="(prefers-color-scheme: …)"> reads the OS setting, so with a
  // forced theme the condition is rewritten to what that theme implies.
  applyPictureTheme(root) {
    const { name } = this.config.theme;
    for (const source of root.querySelectorAll('source[data-mp-media]')) {
      const media = source.dataset.mpMedia;
      if (name === 'system') {
        source.media = media;
        continue;
      }
      source.media = media.replace(/\(\s*prefers-color-scheme\s*:\s*(dark|light)\s*\)/gi, (_, want) =>
        want.toLowerCase() === name ? '(min-width: 0px)' : '(max-width: 0px)',
      );
    }
  }

  onClick(event) {
    const target = event.target;
    if (!(target instanceof Element)) return;
    if (target.closest('details')) this.sync.suppressNextScroll();
    const link = target.closest('a[href]');
    if (!link || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey) return;
    const href = link.getAttribute('href');
    if (href.startsWith('#')) {
      const id = decodeURIComponent(href.slice(1));
      const dest = document.getElementById(`user-content-${id}`) ?? document.getElementById(id);
      if (dest) {
        event.preventDefault();
        dest.scrollIntoView({ behavior: 'smooth', block: 'start' });
        history.replaceState(null, '', href);
      }
    } else if (link.dataset.mpOpen) {
      event.preventDefault();
      this.onOpen?.(link.dataset.mpOpen);
    }
  }
}
