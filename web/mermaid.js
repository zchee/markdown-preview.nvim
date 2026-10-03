import { VERSIONS, cdnUrl, importFrom } from './libs.js';
import { ownBlocks } from './scope.js';

export const mermaidSource = new WeakMap();
export const mermaidKey = (el) => el.textContent;

let mermaidPromise;
let currentTheme;
let counter = 0;
// Rendering is deterministic for a definition and theme, and `mermaid.render`
// is slow, so SVGs (and failures, as null) are reused across re-renders.
let memo = new Map();

function loadMermaid(cdn) {
  // A failed load is not kept, so the next render tries again.
  mermaidPromise ??= importFrom(cdnUrl(cdn, VERSIONS.mermaid)).then(
    (mod) => mod.default,
    (err) => {
      mermaidPromise = undefined;
      throw err;
    },
  );
  return mermaidPromise;
}

function restoreSource(el) {
  const source = mermaidSource.get(el);
  if (source === undefined) return;
  mermaidSource.delete(el);
  el.classList.remove('mp-mermaid-error');
  el.removeAttribute('title');
  el.textContent = source;
}

export async function renderMermaid(root, cdn, dark) {
  const blocks = ownBlocks(root, '[data-mp-kind=mermaid]');
  if (!blocks.length) return 0;
  const mermaid = await loadMermaid(cdn);
  const theme = dark ? 'dark' : 'default';
  if (theme !== currentTheme) {
    currentTheme = theme;
    memo = new Map();
    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme });
    for (const el of blocks) restoreSource(el);
  }
  let rendered = 0;
  for (const el of blocks) {
    if (!el.isConnected || mermaidSource.has(el)) continue;
    const source = mermaidKey(el);
    let svg = memo.get(source);
    if (svg === undefined) {
      try {
        ({ svg } = await mermaid.render(`mp-mermaid-${++counter}`, source));
      } catch (err) {
        svg = null;
        el.title = String(err?.message ?? err);
      }
      memo.set(source, svg);
    }
    if (!el.isConnected || mermaidKey(el) !== source || theme !== currentTheme) continue;
    if (svg) el.innerHTML = svg;
    else el.classList.add('mp-mermaid-error');
    mermaidSource.set(el, source);
    rendered++;
  }
  // Keep only diagrams still on the page.
  const onPage = new Set(blocks.map((el) => mermaidSource.get(el) ?? mermaidKey(el)));
  for (const source of memo.keys()) if (!onPage.has(source)) memo.delete(source);
  return rendered;
}
