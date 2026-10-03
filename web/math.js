// Math has to be cut out of the source before inline parsing: otherwise
// `$a_1 * b_2$` turns into emphasis before MathJax ever sees it. The TeX is kept
// as the text of a placeholder element and handed to MathJax's conversion API,
// so MathJax never scans the page for delimiters.

import { VERSIONS, cdnUrl, loadClassicScript } from './libs.js';
import { ownBlocks } from './scope.js';

const DOLLAR = 0x24;
const BACKTICK = 0x60;
const BACKSLASH = 0x5c;

const isSpace = (code) => code === 0x20 || code === 0x09 || code === 0x0a || code === 0x0d;
const isDigit = (code) => code >= 0x30 && code <= 0x39;

function pushMath(state, content, display, markup) {
  const token = state.push('math_inline', 'math', 0);
  token.content = content;
  token.markup = markup;
  token.meta = { display };
}

// $`…`$ with any number of backticks, closed by the same number of backticks
// followed by `$`.
function backtickMath(state, silent) {
  const { src, posMax: max } = state;
  const tickStart = state.pos + 1;
  let tickEnd = tickStart;
  while (tickEnd < max && src.charCodeAt(tickEnd) === BACKTICK) tickEnd++;
  const ticks = tickEnd - tickStart;
  const fence = '`'.repeat(ticks);
  for (let at = src.indexOf(fence, tickEnd); at !== -1 && at < max; at = src.indexOf(fence, at)) {
    let runEnd = at;
    while (runEnd < max && src.charCodeAt(runEnd) === BACKTICK) runEnd++;
    if (runEnd - at === ticks && src.charCodeAt(runEnd) === DOLLAR) {
      if (!silent) pushMath(state, src.slice(tickEnd, at).trim(), false, `$${fence}`);
      state.pos = runEnd + 1;
      return true;
    }
    at = runEnd;
  }
  return false;
}

// The closing `$` is the next unescaped one, so `\$` stays inside the formula
// and `<span>$</span>100 … $100/2$` does not swallow the text in between.
function nextDollar(src, from, max) {
  for (let i = from; i < max; i++) {
    const code = src.charCodeAt(i);
    if (code === BACKSLASH) i++;
    else if (code === DOLLAR) return i;
  }
  return -1;
}

function inlineMath(state, silent) {
  const { src, pos, posMax: max } = state;
  if (src.charCodeAt(pos) !== DOLLAR) return false;
  if (src.charCodeAt(pos + 1) === BACKTICK) return backtickMath(state, silent);

  if (src.charCodeAt(pos + 1) === DOLLAR) {
    const close = src.indexOf('$$', pos + 2);
    if (close === -1 || close >= max) return false;
    const content = src.slice(pos + 2, close);
    if (!content.trim()) return false;
    if (!silent) pushMath(state, content.trim(), true, '$$');
    state.pos = close + 2;
    return true;
  }

  const start = pos + 1;
  if (start >= max || isSpace(src.charCodeAt(start))) return false;
  const close = nextDollar(src, start, max);
  if (close === -1 || isSpace(src.charCodeAt(close - 1)) || isDigit(src.charCodeAt(close + 1))) {
    return false;
  }
  if (!silent) pushMath(state, src.slice(start, close), false, '$');
  state.pos = close + 1;
  return true;
}

// `$$` at the start of a block, ending on the first line that ends with `$$`.
function blockMath(state, startLine, endLine, silent) {
  if (state.sCount[startLine] - state.blkIndent >= 4) return false;
  const begin = state.bMarks[startLine] + state.tShift[startLine];
  const firstMax = state.eMarks[startLine];
  if (!state.src.startsWith('$$', begin)) return false;

  const first = state.src.slice(begin + 2, firstMax).trimEnd();
  let body;
  let last = startLine;
  if (first.endsWith('$$') && first.length >= 2) {
    body = first.slice(0, -2);
    // `$$a$$ more text` is a paragraph with inline display math.
    if (body.includes('$$')) return false;
  } else {
    const parts = [first];
    let found = false;
    for (let line = startLine + 1; line < endLine; line++) {
      const lineStart = state.bMarks[line] + state.tShift[line];
      const lineMax = state.eMarks[line];
      if (lineStart < lineMax && state.sCount[line] < state.blkIndent) break;
      const text = state.src.slice(lineStart, lineMax).trimEnd();
      if (text.endsWith('$$')) {
        parts.push(text.slice(0, -2));
        last = line;
        found = true;
        break;
      }
      parts.push(state.src.slice(state.bMarks[line] + Math.min(state.tShift[line], state.blkIndent), lineMax));
    }
    if (!found) return false;
    body = parts.join('\n');
  }
  if (silent) return true;

  const token = state.push('math_block', 'math', 0);
  token.block = true;
  token.content = body.trim();
  token.markup = '$$';
  token.map = [startLine, last + 1];
  state.line = last + 1;
  return true;
}

export function mathPlugin(md) {
  md.inline.ruler.before('escape', 'math_inline', inlineMath);
  md.block.ruler.before('fence', 'math_block', blockMath, { alt: [] });
  const esc = md.utils.escapeHtml;
  md.renderer.rules.math_inline = (tokens, idx) => {
    const { content, meta } = tokens[idx];
    const display = meta.display ? ' class="mp-math-display"' : '';
    // `meta.stamp` is set by the renderer so the sanitizer keeps data-mp-kind.
    const stamp = meta.stamp ? ` data-mp-trust="${meta.stamp}"` : '';
    return `<span${stamp} data-mp-kind="math"${display}>${esc(content)}</span>`;
  };
  md.renderer.rules.math_block = (tokens, idx, options, env, self) =>
    `<div${self.renderAttrs(tokens[idx])} data-mp-kind="math" class="mp-math-display">${esc(tokens[idx].content)}</div>\n`;
}

// ui/safe does not filter TeX's \data{name=value} (its TeX filter matches
// attribute names exactly; the data- prefix rule exists only for MathML input),
// so authored data-* attributes are removed here. MathJax's own data-*
// attributes stay: its stylesheet selects on several of them (merror
// backgrounds, table lines and frames).
const MATHJAX_DATA = /^data-(mjx|sre|semantic)-|^data-(mml-node|c|latex|background|line|table|frame|toggle|bgcolor|look|variant|hitbox)$/;

function dropAuthoredData(root) {
  for (const el of [root, ...root.querySelectorAll('*')]) {
    for (const { name } of [...el.attributes]) {
      if (name.startsWith('data-') && !MATHJAX_DATA.test(name)) el.removeAttribute(name);
    }
  }
}

let mathjaxReady;

function loadMathJax(cdn) {
  mathjaxReady ??= (async () => {
    window.MathJax = {
      // ui/safe strips URLs (\href), style declarations (\style) and
      // non-MathJax classes and ids (\class, \cssId) from authored TeX.
      loader: {
        load: ['ui/safe'],
        paths: {
          mathjax: cdnUrl(cdn, VERSIONS.mathjax, '').replace(/\/$/, ''),
          'mathjax-newcm': cdnUrl(cdn, VERSIONS.mathjaxFont, '').replace(/\/$/, ''),
        },
      },
      startup: { typeset: false },
      // Speech and Braille generation run in a worker created from a blob:
      // URL, which the page CSP does not allow; enrichment only feeds them.
      options: {
        enableMenu: false,
        enableEnrichment: false,
        enableSpeech: false,
        enableBraille: false,
        safeOptions: { allow: { URLs: 'none', classes: 'safe', cssIDs: 'safe', styles: 'none' } },
        menuOptions: {
          settings: { enrich: false, speech: false, braille: false, collapsible: false, assistiveMml: false },
        },
      },
      svg: { fontCache: 'local' },
    };
    await loadClassicScript(cdnUrl(cdn, VERSIONS.mathjax, 'tex-svg.js'));
    await window.MathJax.startup.promise;
    document.head.append(window.MathJax.svgStylesheet());
    return window.MathJax;
  })();
  return mathjaxReady;
}

export const mathSource = new WeakMap();

// The DOM morph keeps a typeset element when the incoming placeholder has the
// same key as the one recorded in `mathSource`.
export const mathKey = (el) =>
  `${el.classList.contains('mp-math-display') ? 'D' : 'I'}${el.textContent}`;

export async function typesetMath(root, cdn) {
  const pending = ownBlocks(root, '[data-mp-kind=math]').filter((el) => !mathSource.has(el));
  if (!pending.length) return 0;
  const MathJax = await loadMathJax(cdn);
  for (const el of pending) {
    if (!el.isConnected || mathSource.has(el)) continue;
    const key = mathKey(el);
    const tex = el.textContent;
    try {
      const node = await MathJax.tex2svgPromise(tex, { display: key[0] === 'D' });
      if (!el.isConnected || mathKey(el) !== key) continue;
      dropAuthoredData(node);
      el.replaceChildren(node);
      el.title = tex;
    } catch (err) {
      el.classList.add('mp-math-error');
      el.title = String(err?.message ?? err);
    }
    mathSource.set(el, key);
  }
  return pending.length;
}
