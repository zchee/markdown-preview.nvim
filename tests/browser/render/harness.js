// Development harness: drives web/preview.js with a fixture file instead of the
// event stream, under the contract CSP (set as a meta tag in index.html).
// Query parameters: fixture (path under tests/fixtures), theme, contrast, cursor.

import { loadCore } from '/web/libs.js';
import { Preview } from '/web/preview.js';

const params = new URLSearchParams(location.search);
const cdn = params.get('cdn') ?? 'https://cdn.jsdelivr.net/npm';
const fixture = params.get('fixture') ?? 'github-features.md';
const errors = [];
const opened = [];

const libs = await loadCore(cdn);
const preview = new Preview({
  root: document.getElementById('mp-body'),
  band: document.getElementById('mp-cursor'),
  libs,
  cdn,
  config: {
    theme: { name: params.get('theme') ?? 'light', high_contrast: params.get('contrast') === 'high' },
  },
  onOpen: (path) => opened.push(path),
  onError: (err) => errors.push(String(err?.message ?? err)),
});
const text = await (await fetch(`/tests/fixtures/${fixture}`)).text();
const cursor = params.get('cursor');
preview.setDocument(fixture, text.replace(/\n$/, '').split('\n'), cursor === null ? null : Number(cursor));
window.__mp = { preview, errors, opened };
