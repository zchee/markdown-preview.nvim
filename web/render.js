// Markdown source -> sanitized DocumentFragment, configured to match how
// github.com renders a Markdown file. Nothing here touches the live page.

import { mathPlugin } from './math.js';

export const MARKDOWN_FILE = /\.(md|markdown|mdown|mkd)$/i;
export const VIDEO_FILE = /\.(mp4|mov|webm|m4v|ogv)$/i;
// The only extensions the server's file/ route serves.
const MEDIA_FILE = /\.(png|jpe?g|gif|webp|avif|svg|bmp|ico|mp4|webm|ogv|mov|m4v|mp3|m4a|oga|ogg|wav|flac)$/i;

const SINGLE_TILDE = 0x1007e;
const TILDE = 0x7e;

// GitHub's user-content sanitizer allowlist (html-pipeline), plus the elements
// the Markdown extensions emit (task-list checkboxes, footnote section,
// <picture>/<source>). Form controls, media players, SVG, MathML and style are
// not on it.
const ALLOWED_TAGS = [
  'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'br', 'b', 'i', 'strong', 'em', 'a', 'pre', 'code', 'img',
  'tt', 'div', 'ins', 'del', 'sup', 'sub', 'p', 'ol', 'ul', 'table', 'thead', 'tbody', 'tfoot',
  'blockquote', 'dl', 'dt', 'dd', 'kbd', 'q', 'samp', 'var', 'hr', 'ruby', 'rt', 'rp', 'li', 'tr',
  'td', 'th', 's', 'strike', 'summary', 'details', 'caption', 'figure', 'figcaption', 'abbr',
  'bdo', 'cite', 'dfn', 'mark', 'small', 'span', 'time', 'wbr', 'picture', 'source', 'input',
  'section', 'col', 'colgroup',
];
const ALLOWED_ATTR = [
  'abbr', 'align', 'alt', 'aria-describedby', 'aria-hidden', 'aria-label', 'aria-labelledby',
  'axis', 'border', 'cellpadding', 'cellspacing', 'char', 'charoff', 'checked', 'cite', 'class',
  'clear', 'cols', 'colspan', 'color', 'compact', 'coords', 'datetime', 'dir', 'disabled', 'headers',
  'height', 'href', 'hreflang', 'hspace', 'id', 'itemprop', 'lang', 'longdesc', 'media', 'name',
  'nowrap', 'open', 'rel', 'rev', 'role', 'rows', 'rowspan', 'scope', 'sizes', 'span', 'src',
  'srcset', 'start', 'summary', 'tabindex', 'title', 'type', 'valign', 'value', 'vspace', 'width',
];

const ABSOLUTE_URL = /^[a-z][a-z\d+.-]*:|^\/\//i;

function splitSuffix(url) {
  const cut = url.search(/[?#]/);
  return cut === -1 ? [url, ''] : [url.slice(0, cut), url.slice(cut)];
}

function safeDecode(text) {
  try {
    return decodeURIComponent(text);
  } catch {
    return text;
  }
}

// Resolves `url` against the directory of `docPath` (root-relative when it
// starts with `/`). Returns undefined for absolute and fragment-only URLs and
// null when the result would leave the preview root.
export function resolveRelative(url, docPath) {
  if (!url || url.startsWith('#') || ABSOLUTE_URL.test(url)) return undefined;
  const [pathPart, suffix] = splitSuffix(url);
  const segments = pathPart.startsWith('/') ? [] : docPath.split('/').slice(0, -1);
  for (const raw of pathPart.split('/')) {
    const seg = safeDecode(raw);
    if (seg === '' || seg === '.') continue;
    if (seg === '..') {
      if (!segments.length) return null;
      segments.pop();
    } else {
      segments.push(seg);
    }
  }
  return { path: segments.join('/'), suffix };
}

export const fileUrl = (path, suffix = '') =>
  `file/${path.split('/').map(encodeURIComponent).join('/')}${suffix}`;

// github-slugger: lowercase, drop everything but letters, marks, numbers,
// connector punctuation, hyphens and spaces, then spaces -> hyphens.
const SLUG_STRIP = /[^\p{L}\p{M}\p{N}\p{Pc}\- ]/gu;

function slugify(text, seen) {
  const base = text.toLowerCase().replace(SLUG_STRIP, '').replaceAll(' ', '-');
  let slug = base;
  while (seen.has(slug)) {
    const n = seen.get(base) + 1;
    seen.set(base, n);
    slug = `${base}-${n}`;
  }
  seen.set(slug, 0);
  return slug;
}

function plainText(tokens) {
  let out = '';
  for (const t of tokens) {
    if (t.type === 'text' || t.type === 'code_inline' || t.type === 'emoji' || t.type === 'math_inline') {
      out += t.content;
    } else if (t.type === 'softbreak' || t.type === 'hardbreak') {
      out += ' ';
    } else if (t.children) {
      out += plainText(t.children);
    }
  }
  return out;
}

// GFM strikethrough takes one or two tildes, and only runs of the same length
// pair up; markdown-it's built-in rule only knows `~~`.
function strikeTokenize(state, silent) {
  const start = state.pos;
  if (silent || state.src.charCodeAt(start) !== TILDE) return false;
  const scanned = state.scanDelims(start, true);
  const token = state.push('text', '', 0);
  token.content = '~'.repeat(scanned.length);
  if (scanned.length <= 2) {
    state.delimiters.push({
      marker: scanned.length === 1 ? SINGLE_TILDE : TILDE,
      length: 0,
      token: state.tokens.length - 1,
      end: -1,
      open: scanned.can_open,
      close: scanned.can_close,
    });
  }
  state.pos += scanned.length;
  return true;
}

function strikeConvert(state, delimiters) {
  for (const open of delimiters) {
    if ((open.marker !== TILDE && open.marker !== SINGLE_TILDE) || open.end === -1) continue;
    const markup = open.marker === TILDE ? '~~' : '~';
    for (const [index, type, nesting] of [
      [open.token, 's_open', 1],
      [delimiters[open.end].token, 's_close', -1],
    ]) {
      const t = state.tokens[index];
      t.type = type;
      t.tag = 'del';
      t.nesting = nesting;
      t.markup = markup;
      t.content = '';
    }
  }
}

function strikePostProcess(state) {
  strikeConvert(state, state.delimiters);
  for (const meta of state.tokens_meta) {
    if (meta?.delimiters) strikeConvert(state, meta.delimiters);
  }
}

// GFM autolinks bare URLs only with a scheme or a `www.` prefix (and email
// addresses); linkify-it's fuzzy mode also links `example.com`.
function dropFuzzyLinks(state) {
  for (const block of state.tokens) {
    if (block.type !== 'inline' || !block.children) continue;
    const out = [];
    const kids = block.children;
    for (let i = 0; i < kids.length; i++) {
      const t = kids[i];
      if (t.type === 'link_open' && t.markup === 'linkify') {
        const text = kids[i + 1]?.content ?? '';
        const href = t.attrGet('href') ?? '';
        if (!/^(?:[a-z][a-z\d+.-]*:|www\.)/i.test(text) && !href.startsWith('mailto:')) {
          const plain = new state.Token('text', '', 0);
          plain.content = text;
          out.push(plain);
          i += 2;
          continue;
        }
      }
      out.push(t);
    }
    block.children = out;
  }
}

function headingAnchors(state) {
  const seen = (state.env.slugs ??= new Map());
  const tokens = state.tokens;
  for (let i = 0; i < tokens.length; i++) {
    if (tokens[i].type !== 'heading_open') continue;
    const inline = tokens[i + 1];
    const slug = slugify(plainText(inline.children ?? []).trim(), seen);
    tokens[i].attrSet('id', slug);
    const anchor = new state.Token('html_inline', '', 0);
    anchor.content = `<a class="anchor" aria-hidden="true" tabindex="-1" href="#${slug}"><span class="octicon octicon-link"></span></a>`;
    inline.children?.unshift(anchor);
  }
}

// Column alignment as GitHub emits it: an `align` attribute, because the
// sanitizer removes markdown-it's `style="text-align: …"`.
function tableAlign(state) {
  for (const t of state.tokens) {
    if (t.type !== 'th_open' && t.type !== 'td_open') continue;
    const style = t.attrGet('style');
    const align = style?.match(/text-align:\s*(left|center|right)/)?.[1];
    if (!style) continue;
    t.attrs = t.attrs.filter(([name]) => name !== 'style');
    if (align) t.attrSet('align', align);
  }
}

function configure(libs, trust) {
  const md = new libs.MarkdownIt({ html: true, linkify: true, typographer: false });
  md.linkify.set({ fuzzyLink: true, fuzzyEmail: true });
  md.use(mathPlugin, trust)
    .use(libs.footnote)
    .use(libs.taskLists, { enabled: false })
    .use(libs.alerts, {
      icons: { note: '', tip: '', important: '', warning: '', caution: '' },
    })
    // github.com converts :name: shortcodes only, never text emoticons such as :)
    .use(libs.emoji, { shortcuts: {} });
  md.inline.ruler.at('strikethrough', strikeTokenize);
  md.inline.ruler2.at('strikethrough', strikePostProcess);
  md.core.ruler.after('linkify', 'drop_fuzzy_links', dropFuzzyLinks);
  const alertOpen = md.renderer.rules.alert_open;
  md.renderer.rules.alert_open = (tokens, idx, options, env, self) =>
    alertOpen(tokens, idx, options, env, self).replace('<div', `<div${self.renderAttrs(tokens[idx])}`);
  md.core.ruler.push('heading_anchors', headingAnchors);
  md.core.ruler.push('table_align', tableAlign);

  const esc = md.utils.escapeHtml;
  md.renderer.rules.fence = (tokens, idx, options, env, self) => {
    const token = tokens[idx];
    const lang = md.utils.unescapeAll(token.info).trim().split(/\s+/)[0];
    const attrs = self.renderAttrs(token);
    if (lang === 'math') {
      return `<div${attrs} data-mp-kind="math" class="mp-math-display">${esc(token.content.trim())}</div>\n`;
    }
    if (lang === 'mermaid') return `<div${attrs} data-mp-kind="mermaid">${esc(token.content)}</div>\n`;
    if (lang) {
      return `<div${attrs} data-mp-kind="code" class="highlight" data-mp-lang="${esc(lang)}"><pre>${esc(token.content)}</pre></div>\n`;
    }
    return `<pre${attrs}><code>${esc(token.content)}</code></pre>\n`;
  };

  // Footnote markup as github.com emits it; github-markdown-css styles these
  // attributes (bracketed reference numbers, the back-reference arrow).
  const fn = md.renderer.rules;
  fn.footnote_anchor_name = (tokens, idx) => `-${tokens[idx].meta.id + 1}`;
  fn.footnote_caption = (tokens, idx) => String(tokens[idx].meta.id + 1);
  fn.footnote_ref = (tokens, idx, options, env, self) => {
    const id = self.rules.footnote_anchor_name(tokens, idx, options, env, self);
    const sub = tokens[idx].meta.subId > 0 ? `-${tokens[idx].meta.subId}` : '';
    const caption = self.rules.footnote_caption(tokens, idx, options, env, self);
    return `<sup><a href="#fn${id}" id="fnref${id}${sub}" data-footnote-ref>${caption}</a></sup>`;
  };
  fn.footnote_block_open = () =>
    '<section data-footnotes class="footnotes"><h2 id="footnote-label" class="sr-only">Footnotes</h2>\n<ol>\n';
  fn.footnote_block_close = () => '</ol>\n</section>\n';
  fn.footnote_anchor = (tokens, idx, options, env, self) => {
    const id = self.rules.footnote_anchor_name(tokens, idx, options, env, self);
    const sub = tokens[idx].meta.subId > 0 ? `-${tokens[idx].meta.subId}` : '';
    return ` <a href="#fnref${id}${sub}" data-footnote-backref class="data-footnote-backref" aria-label="Back to reference ${tokens[idx].meta.id + 1}">↩</a>`;
  };
  return md;
}

function rewriteSrcset(srcset, docPath) {
  return srcset
    .split(',')
    .map((candidate) => {
      const [url, ...descriptor] = candidate.trim().split(/\s+/);
      const resolved = resolveRelative(url, docPath);
      if (resolved === undefined) return candidate.trim();
      if (resolved === null) return '';
      return [fileUrl(resolved.path, resolved.suffix), ...descriptor].join(' ');
    })
    .filter(Boolean)
    .join(', ');
}

const isControlAttr = (name) => name.startsWith('data-mp-') || name.startsWith('data-line-');

// Control attributes (data-mp-*, data-line-*) steer the page: which links call
// api/open, what gets highlighted or typeset, where scroll sync anchors lines.
// They are kept only on elements the renderer emitted, which carry the
// per-page `data-mp-trust` nonce; authored HTML cannot know it. Line values are
// rebased from segment-relative to absolute and must land inside the document.
function checkControlAttrs(node, trust, state) {
  const trusted = node.getAttribute('data-mp-trust') === trust;
  for (const { name } of [...node.attributes]) {
    if (isControlAttr(name) && !trusted) node.removeAttribute(name);
  }
  if (!trusted) return;
  node.removeAttribute('data-mp-trust');
  const start = node.getAttribute('data-line-start');
  if (start === null) return;
  const abs = [start, node.getAttribute('data-line-end') ?? start].map((v) =>
    /^\d+$/.test(v) ? Number(v) + state.base : Number.NaN,
  );
  if (abs.every((v) => v < state.lineCount) && abs[0] <= abs[1]) {
    node.setAttribute('data-line-start', String(abs[0]));
    node.setAttribute('data-line-end', String(abs[1]));
  } else {
    node.removeAttribute('data-line-start');
    node.removeAttribute('data-line-end');
  }
}

function makeSanitizer(DOMPurify, trust, state) {
  const purify = DOMPurify(window);
  purify.addHook('afterSanitizeAttributes', (node) => {
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    checkControlAttrs(node, trust, state);
    switch (node.nodeName) {
      case 'IMG': {
        const src = node.getAttribute('src');
        const resolved = resolveRelative(src, state.path);
        if (resolved === null) node.removeAttribute('src');
        else if (resolved) node.setAttribute('src', fileUrl(resolved.path, resolved.suffix));
        if (node.hasAttribute('srcset')) {
          node.setAttribute('srcset', rewriteSrcset(node.getAttribute('srcset'), state.path));
        }
        break;
      }
      case 'SOURCE': {
        if (node.hasAttribute('srcset')) {
          node.setAttribute('srcset', rewriteSrcset(node.getAttribute('srcset'), state.path));
        }
        node.removeAttribute('src');
        const media = node.getAttribute('media');
        if (media?.includes('prefers-color-scheme')) node.dataset.mpMedia = media;
        break;
      }
      case 'INPUT':
        // Only the task-list checkbox survives, and it is never interactive.
        if (node.getAttribute('type') !== 'checkbox') node.remove();
        else node.setAttribute('disabled', '');
        break;
      case 'A': {
        const href = node.getAttribute('href');
        if (href === null) break;
        const resolved = resolveRelative(href, state.path);
        if (resolved === undefined) {
          if (!href.startsWith('#')) {
            node.setAttribute('target', '_blank');
            node.setAttribute('rel', 'noreferrer noopener');
            if (VIDEO_FILE.test(splitSuffix(href)[0])) node.dataset.mpVideo = href;
          }
        } else if (resolved === null) {
          node.removeAttribute('href');
        } else if (MARKDOWN_FILE.test(resolved.path)) {
          node.setAttribute('href', fileUrl(resolved.path, resolved.suffix));
          node.dataset.mpOpen = resolved.path;
        } else if (MEDIA_FILE.test(resolved.path)) {
          const url = fileUrl(resolved.path, resolved.suffix);
          node.setAttribute('href', url);
          node.setAttribute('target', '_blank');
          node.setAttribute('rel', 'noreferrer noopener');
          if (VIDEO_FILE.test(resolved.path)) node.dataset.mpVideo = url;
        } else {
          // The server only serves media and Markdown; any other repository file
          // stays visible as link text but leads nowhere.
          node.removeAttribute('href');
          node.setAttribute('title', `${resolved.path} (only Markdown and media files open from the preview)`);
          node.dataset.mpUnavailable = '';
        }
        break;
      }
    }
  });
  return purify;
}

const PURIFY_CONFIG = {
  ALLOWED_TAGS,
  ALLOWED_ATTR,
  ALLOW_DATA_ATTR: true,
  // GitHub prefixes user ids and names with `user-content-` so content cannot
  // clobber page globals; fragment links are mapped back when followed.
  SANITIZE_NAMED_PROPS: true,
  RETURN_DOM_FRAGMENT: true,
};

function videoPlayer(link) {
  const details = document.createElement('details');
  details.open = true;
  details.className = 'mp-video';
  const summary = document.createElement('summary');
  const name = splitSuffix(link.dataset.mpVideo)[0].split('/').pop();
  summary.textContent = safeDecode(name);
  const video = document.createElement('video');
  video.src = link.dataset.mpVideo;
  video.controls = true;
  video.preload = 'metadata';
  details.append(summary, video);
  return details;
}

const VOID_TAGS = new Set([
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr',
]);
const TAG = /<(\/?)([a-zA-Z][a-zA-Z0-9-]*)[^>]*?(\/?)>/g;

// Net count of HTML elements an authored HTML block leaves open (or closes).
function htmlDepth(html) {
  let depth = 0;
  for (const [, close, name, selfClose] of html.matchAll(TAG)) {
    if (selfClose || VOID_TAGS.has(name.toLowerCase())) continue;
    depth += close ? -1 : 1;
  }
  return depth;
}

// Splits the top-level token stream into segments that render to
// self-contained HTML. A top-level block normally is one segment; authored
// HTML that opens an element (`<details>` … `</details>`) pulls the blocks up
// to its matching close into the same segment.
function splitSegments(tokens) {
  const segments = [];
  let current = null;
  let depth = 0;
  for (let i = 0; i < tokens.length; ) {
    let end = i + 1;
    if (tokens[i].nesting === 1) {
      for (let level = 1; level > 0 && end < tokens.length; end++) level += tokens[end].nesting;
    }
    current ??= { from: i, to: end };
    current.to = end;
    if (tokens[i].type === 'html_block') depth = Math.max(0, depth + htmlDepth(tokens[i].content));
    if (depth === 0) {
      segments.push(current);
      current = null;
    }
    i = end;
  }
  if (current) segments.push(current);
  return segments;
}

export function createRenderer(libs) {
  // Marks the elements the renderer emits so the sanitizer can tell them from
  // authored HTML; random per page, never left in the DOM.
  const trust = Array.from(crypto.getRandomValues(new Uint8Array(12)), (b) =>
    b.toString(16).padStart(2, '0'),
  ).join('');
  const md = configure(libs, trust);
  const state = { path: '', base: 0, lineCount: 0 };
  const purify = makeSanitizer(libs.DOMPurify, trust, state);

  // Source -> segments, each with HTML whose line attributes are relative to the
  // segment's first line. Equal HTML means an unchanged rendering wherever the
  // segment moved, so `html` doubles as the reuse key.
  function segments(source, { path }) {
    state.path = path;
    const env = {};
    const tokens = md.parse(source, env);
    const out = [];
    for (const { from, to } of splitSegments(tokens)) {
      const slice = tokens.slice(from, to);
      const base = slice.find((t) => t.map)?.map[0] ?? 0;
      for (const t of slice) {
        if (!t.map || t.type === 'inline' || t.type === 'html_block') continue;
        if (!(t.nesting === 1 || (t.nesting === 0 && t.block))) continue;
        t.attrSet('data-mp-trust', trust);
        t.attrSet('data-line-start', String(t.map[0] - base));
        // markdown-it's map is [start, end); data-line-end is inclusive.
        t.attrSet('data-line-end', String(Math.max(t.map[0], t.map[1] - 1) - base));
      }
      out.push({ html: md.renderer.render(slice, md.options, env), base });
    }
    return out;
  }

  function sanitize(html, { path, base, lineCount, detailsOpen }) {
    Object.assign(state, { path, base, lineCount });
    const fragment = purify.sanitize(html, PURIFY_CONFIG);
    // Built after sanitizing, so these elements are not on the allowlist.
    for (const link of fragment.querySelectorAll('a[data-mp-video]')) {
      link.replaceWith(videoPlayer(link));
    }
    if (detailsOpen) {
      for (const details of fragment.querySelectorAll('details')) details.open = true;
    }
    return fragment;
  }

  return {
    md,
    segments,
    sanitize,
    // Whole-document rendering in one pass; the live page renders by segment.
    render(source, { path, detailsOpen }) {
      const lineCount = source.split('\n').length;
      const fragment = document.createDocumentFragment();
      for (const seg of segments(source, { path })) {
        fragment.append(sanitize(seg.html, { path, base: seg.base, lineCount, detailsOpen }));
      }
      return fragment;
    },
  };
}
