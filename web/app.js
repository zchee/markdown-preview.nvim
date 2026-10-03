// Page entry point: reads the bootstrap data, connects to the event stream and
// feeds a Preview. All URLs are relative, so they carry the token that is the
// first path segment of the page URL.

import { loadCore } from './libs.js';
import { Preview } from './preview.js';

const html = document.documentElement;
const statusEl = document.getElementById('mp-status');
const errorsEl = document.getElementById('mp-errors');
const body = document.getElementById('mp-body');
const band = document.getElementById('mp-cursor');

function setStatus(state, text = '') {
  html.dataset.mpConnection = state;
  statusEl.textContent = text;
  statusEl.hidden = !text;
}

const errors = new Map();

function showError(key, message) {
  if (message) errors.set(key, message);
  else errors.delete(key);
  errorsEl.replaceChildren(
    ...[...errors.values()].map((text) => {
      const p = document.createElement('p');
      p.textContent = text;
      return p;
    }),
  );
  errorsEl.hidden = errors.size === 0;
}

function readBootstrap() {
  try {
    return JSON.parse(document.getElementById('mp-bootstrap').textContent);
  } catch {
    return null;
  }
}

// Without the CDN libraries the document is still shown, as plain text.
class PlainPreview {
  constructor(root) {
    this.root = root;
  }

  setDocument(_path, lines) {
    const pre = document.createElement('pre');
    pre.textContent = lines.join('\n');
    this.root.replaceChildren(pre);
  }

  setCursor() {}

  setConfig() {}
}

async function openMarkdown(path) {
  try {
    const res = await fetch('api/open', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path }),
    });
    if (!res.ok) {
      const detail = await res.json().catch(() => ({}));
      showError('open', `Could not open ${path}: ${detail.error ?? res.status}`);
      return;
    }
    showError('open', null);
  } catch (err) {
    showError('open', `Could not open ${path}: ${err.message}`);
  }
}

function connect(preview) {
  const events = new EventSource('events');
  let current = null;
  let stopped = false;
  const on = (type, handler) =>
    events.addEventListener(type, (event) => {
      if (event.data !== undefined) handler(JSON.parse(event.data));
    });

  setStatus('connecting', 'Connecting to Neovim…');
  events.addEventListener('open', () => setStatus('connected'));

  on('init', (data) => {
    current = data.path;
    document.title = `${data.path.split('/').pop()} – Markdown Preview`;
    showError('server', null);
    if (data.config) preview.setConfig(data.config);
    preview.setDocument(data.path, data.lines, data.cursor_line ?? null);
  });
  on('content_change', (data) => {
    current = data.path;
    showError('server', null);
    preview.setDocument(data.path, data.lines);
  });
  on('cursor_move', (data) => {
    if (data.path === current) preview.setCursor(data.cursor_line);
  });
  on('update_config', (data) => preview.setConfig(data.config));
  on('goodbye', () => {
    stopped = true;
    events.close();
    window.close();
    setStatus('stopped', 'Preview stopped. Start it again from Neovim to reconnect.');
  });
  // The server's `error` event and the EventSource connection error share a
  // name; only the former carries data.
  events.addEventListener('error', (event) => {
    if (event.data !== undefined) {
      showError('server', JSON.parse(event.data).message);
      return;
    }
    if (stopped) return;
    if (events.readyState === EventSource.CLOSED) {
      setStatus('closed', 'The preview server rejected the connection. It was stopped or restarted; reopen the preview from Neovim.');
    } else {
      setStatus('reconnecting', 'Disconnected from Neovim. Reconnecting…');
    }
  });
}

const RELOAD_KEY = 'mp-core-reload-delay';

function storedDelay() {
  try {
    return Number(sessionStorage.getItem(RELOAD_KEY)) || 0;
  } catch {
    return 0;
  }
}

function storeDelay(ms) {
  try {
    if (ms) sessionStorage.setItem(RELOAD_KEY, String(ms));
    else sessionStorage.removeItem(RELOAD_KEY);
  } catch {
    // Without storage the delay simply restarts at its minimum.
  }
}

// A module that failed to load stays failed until the page reloads, so a
// failed core load is retried by reloading, waiting longer each time
// (5 s doubling up to 60 s). The plain text stays readable meanwhile.
function scheduleReload() {
  const delay = Math.min(Math.max(storedDelay() * 2, 5000), 60000);
  storeDelay(delay);
  setTimeout(() => location.reload(), delay);
  return delay;
}

async function main() {
  const bootstrap = readBootstrap();
  if (!bootstrap) {
    setStatus('closed', 'This page has to be opened through the preview server.');
    html.dataset.mpRender = 'failed';
    return;
  }
  let preview;
  try {
    const libs = await loadCore(bootstrap.cdn);
    storeDelay(0);
    preview = new Preview({
      root: body,
      band,
      libs,
      cdn: bootstrap.cdn,
      config: bootstrap.config,
      onOpen: openMarkdown,
      onError: (key, err) => showError(key, err && (err.message ?? String(err))),
    });
  } catch (err) {
    const delay = scheduleReload();
    showError('core', `${err.message}. Showing the plain text; retrying in ${delay / 1000} s.`);
    html.dataset.mpRender = 'failed';
    preview = new PlainPreview(body);
  }
  connect(preview);
}

main();
