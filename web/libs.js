// Every third-party file comes from the CDN with an exact version, so the page
// renders the same way until the versions here are changed on purpose.

export const VERSIONS = {
  markdownIt: 'markdown-it@15.0.2',
  footnote: 'markdown-it-footnote@4.0.0',
  taskLists: 'markdown-it-task-lists@2.1.1',
  alerts: 'markdown-it-github-alerts@1.0.1',
  emoji: 'markdown-it-emoji@3.1.0',
  dompurify: 'dompurify@3.4.16',
  idiomorph: 'idiomorph@0.8.0',
  css: 'github-markdown-css@5.9.0',
  primer: '@primer/primitives@11.10.0',
  mathjax: 'mathjax@4.1.3',
  mathjaxFont: '@mathjax/mathjax-newcm-font@4.1.3',
  mermaid: 'mermaid@12.1.0',
  starryNight: '@wooorm/starry-night@3.11.0',
  textmate: 'vscode-textmate@9.3.2',
  oniguruma: 'vscode-oniguruma@2.0.1',
};

export class LibraryLoadError extends Error {
  constructor(url, cause) {
    super(`could not load ${url}: ${cause?.message ?? cause}`);
    this.url = url;
    this.cause = cause;
  }
}

export async function importFrom(url) {
  try {
    return await import(url);
  } catch (err) {
    throw new LibraryLoadError(url, err);
  }
}

export function cdnUrl(cdn, pkg, path = '+esm') {
  return `${cdn.replace(/\/+$/, '')}/${pkg}/${path}`;
}

// The parser, plugins, sanitizer and DOM morpher are needed before the first
// paint; everything else is loaded only when a document needs it.
export async function loadCore(cdn) {
  const [md, footnote, taskLists, alerts, emoji, purify, morph] = await Promise.all(
    ['markdownIt', 'footnote', 'taskLists', 'alerts', 'emoji', 'dompurify', 'idiomorph'].map((k) =>
      importFrom(cdnUrl(cdn, VERSIONS[k])),
    ),
  );
  return {
    MarkdownIt: md.default,
    footnote: footnote.default,
    taskLists: taskLists.default,
    alerts: alerts.default,
    emoji: emoji.full,
    DOMPurify: purify.default,
    Idiomorph: morph.Idiomorph,
  };
}

export function loadClassicScript(url) {
  return new Promise((resolve, reject) => {
    const el = document.createElement('script');
    el.src = url;
    el.async = true;
    el.addEventListener('load', () => resolve(), { once: true });
    el.addEventListener('error', () => reject(new LibraryLoadError(url, 'network or CSP error')), {
      once: true,
    });
    document.head.append(el);
  });
}

export function loadStylesheet(url, { id, media } = {}) {
  let link = id ? document.getElementById(id) : null;
  if (!link) {
    link = document.createElement('link');
    link.rel = 'stylesheet';
    if (id) link.id = id;
    document.head.append(link);
  }
  if (media !== undefined) link.media = media;
  if (link.getAttribute('href') === url) return Promise.resolve(link);
  return new Promise((resolve, reject) => {
    link.addEventListener('load', () => resolve(link), { once: true });
    link.addEventListener('error', () => reject(new LibraryLoadError(url, 'stylesheet failed')), {
      once: true,
    });
    link.href = url;
  });
}
