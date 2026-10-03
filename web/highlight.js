// Syntax highlighting with starry-night's own tokenizer and GitHub `pl-*`
// class table. The package entry point statically imports all of its ~700
// grammars, so the registry is assembled here from starry-night's
// `lib/parse.js` and `lib/theme.js`, vscode-textmate and vscode-oniguruma, and
// grammars are fetched one scope at a time.

import { VERSIONS, cdnUrl, importFrom } from './libs.js';

// starry-night's `common` set.
const COMMON = [
  'source.c', 'source.c++', 'source.cs', 'source.css', 'source.css.less', 'source.css.scss',
  'source.diff', 'source.go', 'source.graphql', 'source.ini', 'source.java', 'source.js',
  'source.json', 'source.kotlin', 'source.lua', 'source.makefile', 'source.objc',
  'source.objc.platform', 'source.perl', 'source.python', 'source.r', 'source.ruby',
  'source.rust', 'source.shell', 'source.sql', 'source.swift', 'source.ts', 'source.vbnet',
  'source.yaml', 'text.html.basic', 'text.html.php', 'text.md', 'text.xml', 'text.xml.svg',
];

export const highlightSource = new WeakMap();

export const codeKey = (block) => `${block.dataset.mpLang}\0${block.textContent}`;

class Engine {
  constructor(cdn, mods) {
    this.cdn = cdn;
    this.textmate = mods.textmate;
    this.oniguruma = mods.oniguruma;
    this.parse = mods.parse;
    this.theme = mods.theme;
    this.grammars = new Map();
    this.names = new Map();
    this.extensions = new Map();
    this.extensionsWithDot = new Map();
    this.missing = new Set();
    this.registry = null;
  }

  add(grammar) {
    const scope = grammar.scopeName;
    for (const ext of grammar.extensions) this.extensions.set(ext, scope);
    for (const ext of grammar.extensionsWithDot ?? []) this.extensionsWithDot.set(ext, scope);
    for (const name of grammar.names) this.names.set(name, scope);
    this.grammars.set(scope, grammar);
    this.registry = null;
  }

  async fetchScopes(scopes) {
    const wanted = scopes.filter((s) => !this.grammars.has(s) && !this.missing.has(s));
    const loaded = await Promise.all(
      wanted.map((scope) =>
        import(cdnUrl(this.cdn, VERSIONS.starryNight, `${scope}/+esm`)).then(
          (mod) => mod.default,
          () => {
            this.missing.add(scope);
            return null;
          },
        ),
      ),
    );
    const deps = [];
    for (const grammar of loaded) {
      if (!grammar) continue;
      this.add(grammar);
      deps.push(...(grammar.dependencies ?? []));
    }
    if (deps.length) await this.fetchScopes(deps);
  }

  // Same lookup order as starry-night's flagToScope: grammar name, then
  // extension, so `js`, `.js` and `path/to/file.js` all resolve.
  flagToScope(flag) {
    const normal = flag.trim().replace(/\/+$/, '').toLowerCase();
    const byName = this.names.get(normal);
    if (byName) return byName;
    const dot = normal.lastIndexOf('.');
    if (dot === -1) return this.extensions.get(`.${normal}`);
    const ext = normal.slice(dot);
    return this.extensions.get(ext) ?? this.extensionsWithDot.get(ext);
  }

  async resolve(flag) {
    let scope = this.flagToScope(flag);
    if (scope) return scope;
    const word = flag.trim().toLowerCase();
    if (!/^[\w+.-]+$/.test(word)) return undefined;
    await this.fetchScopes([`source.${word}`, `text.${word}`]);
    scope = this.flagToScope(flag);
    return scope ?? (this.grammars.has(`source.${word}`) ? `source.${word}` : undefined);
  }

  async grammar(scope) {
    if (!this.registry) {
      const oniguruma = this.oniguruma;
      this.registry = new this.textmate.Registry({
        loadGrammar: async (name) => this.grammars.get(name),
        onigLib: Promise.resolve({
          createOnigScanner: (patterns) => oniguruma.createOnigScanner(patterns),
          createOnigString: (text) => oniguruma.createOnigString(text),
        }),
      });
      this.registry.setTheme(this.theme);
    }
    return this.registry.loadGrammar(scope);
  }
}

let enginePromise;

function loadEngine(cdn) {
  enginePromise ??= (async () => {
    const base = (path) => cdnUrl(cdn, VERSIONS.starryNight, path);
    const [tm, onig, parse, theme] = await Promise.all([
      importFrom(cdnUrl(cdn, VERSIONS.textmate)),
      importFrom(cdnUrl(cdn, VERSIONS.oniguruma)),
      importFrom(base('lib/parse.js')),
      importFrom(base('lib/theme.js')),
    ]);
    const oniguruma = onig.default ?? onig;
    const wasm = cdnUrl(cdn, VERSIONS.oniguruma, 'release/onig.wasm');
    await oniguruma.loadWASM(await fetch(wasm));
    const engine = new Engine(cdn, {
      textmate: tm.default ?? tm,
      oniguruma,
      parse: parse.parse,
      theme: theme.theme,
    });
    await engine.fetchScopes(COMMON);
    return engine;
  })();
  return enginePromise;
}

function toDom(node) {
  if (node.type === 'text') return document.createTextNode(node.value);
  const el = document.createElement(node.tagName);
  el.className = node.properties.className.join(' ');
  for (const child of node.children) el.append(toDom(child));
  return el;
}

const yieldToBrowser = () => new Promise((resolve) => setTimeout(resolve, 0));

export async function highlightCode(root, cdn) {
  const pending = [...root.querySelectorAll('[data-mp-kind=code][data-mp-lang]')].filter(
    (block) => !highlightSource.has(block),
  );
  if (!pending.length) return 0;
  const engine = await loadEngine(cdn);
  // Grammars outside the common set are fetched for all languages at once.
  await Promise.all([...new Set(pending.map((block) => block.dataset.mpLang))].map((flag) => engine.resolve(flag)));
  let sliceStart = performance.now();
  for (const block of pending) {
    if (!block.isConnected || highlightSource.has(block)) continue;
    const key = codeKey(block);
    const scope = await engine.resolve(block.dataset.mpLang);
    const pre = block.querySelector('pre');
    // The block was morphed to new content while the grammar loaded; the
    // highlight pass after that render picks it up.
    if (!block.isConnected || codeKey(block) !== key) continue;
    if (scope && pre) {
      const grammar = await engine.grammar(scope);
      if (grammar && codeKey(block) === key) {
        const tree = engine.parse(pre.textContent, grammar, engine.registry.getColorMap());
        const frag = document.createDocumentFragment();
        for (const child of tree.children) frag.append(toDom(child));
        pre.replaceChildren(frag);
        block.classList.add(`highlight-${scope.replaceAll('.', '-')}`);
      }
    }
    highlightSource.set(block, key);
    if (performance.now() - sliceStart > 12) {
      await yieldToBrowser();
      sliceStart = performance.now();
    }
  }
  return pending.length;
}
