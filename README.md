# markdown-preview.nvim

A live GitHub-style Markdown preview for Neovim. The HTTP and Server-Sent Events server is written in
Lua and runs inside Neovim, so no Node, Bun or other runtime is needed. The browser renders the
Markdown, loading its libraries from a CDN.

## Requirements

- Neovim 0.11 or newer. The `vim.pack` install method below needs Neovim 0.12.
- A web browser.
- Network access from the browser to the CDN (`https://cdn.jsdelivr.net` by default) while previewing.
  Neovim itself makes no network requests.
- Optional: `curl`, used only by `:checkhealth markdown-preview` to probe the CDN.

## Installation

The module name is `markdown-preview` and the command is `:MarkdownPreview`. Both collide with
[iamcco/markdown-preview.nvim](https://github.com/iamcco/markdown-preview.nvim), so the two plugins
cannot be installed together.

### lazy.nvim

```lua
{
  "zchee/markdown-preview.nvim",
  cmd = "MarkdownPreview",
  opts = {},
}
```

### vim.pack (Neovim 0.12 or newer)

```lua
vim.pack.add({ "https://github.com/zchee/markdown-preview.nvim" })
require("markdown-preview").setup({})
```

`setup()` is optional. Without it the defaults below apply.

## Quick start

1. Open a Markdown file.
2. Run `:MarkdownPreview`. The server starts, Neovim shows the preview URL in a notification, and the
   default browser opens it.
3. Edit the buffer. The page updates `debounce_ms` after a change, shows the cursor line, and scrolls
   to follow it. Unsaved changes are previewed because the content comes from the buffer.
4. Run `:MarkdownPreview` again to stop the server.

Example mapping:

```lua
vim.keymap.set("n", "<leader>mp", "<Cmd>MarkdownPreview toggle<CR>", { desc = "Markdown preview" })
```

## Configuration

Every option with its default value:

```lua
require("markdown-preview").setup({
  host = "127.0.0.1", -- Address the server binds to.
  port = 0, -- 0 lets the OS pick a free port at every start.
  browser = nil, -- nil: vim.ui.open. false: do not open a browser, only report the URL.
  --              A string is a program name; a list is a program followed by its arguments.
  --              The path of a temporary redirect file (see below) is appended as the last
  --              argument, not the URL. No shell is involved.
  theme = {
    name = "system", -- "system" follows the browser, "light" or "dark" forces one.
    high_contrast = false, -- Use GitHub's high-contrast colors for the theme.
  },
  details_tags_open = true, -- Render <details> elements open.
  cursor_line = {
    disable = false, -- true hides the band that marks the cursor line.
    color = "#c86414", -- CSS color of the band.
    opacity = 0.2, -- 0 to 1.
  },
  scroll = {
    disable = false, -- true stops the page from following the cursor.
    top_offset_pct = 35, -- 0 to 100: cursor line position, in % of the window height from the top.
  },
  debounce_ms = 30, -- Delay between a buffer change and the update sent to the browser.
  cdn = "https://cdn.jsdelivr.net/npm", -- Base URL the page loads its libraries from (https).
  log_level = nil, -- nil: errors only. Otherwise "error", "warn", "info" or "debug".
})
```

- `setup()` merges your options over the defaults. It raises an error naming the offending option for an
  unknown key or an invalid value, and keeps the previous options in place.
- A `browser` list replaces the default as a whole; it is not merged element by element.
- `host`, `port` and `cdn` are read when the preview starts. Run `:MarkdownPreview stop` and start it
  again after changing them.
- `setup()` does not update a page that is already open. The `scroll_*`, `cursorline_*` and
  `details_tags_*` functions below do.
- Examples for `browser`: `{ "firefox", "--new-window" }`, `{ "open", "-a", "Safari" }`. A string such
  as `"firefox --new-window"` is treated as one program name and will fail to start.
- The browser is opened through a redirect file so that the token in the URL never appears on another
  process's command line, where `ps` would show it. The plugin writes a small HTML page that redirects
  to the preview into a new directory (mode 0700) under the system temporary directory, as a file with
  mode 0600. `vim.ui.open` or your `browser` command opens that file. The file is deleted 10 seconds
  later, and when the preview stops. A custom `browser` command must therefore be able to open a local
  `.html` file. The URL itself is still shown in a Neovim notification.
- `cdn` must be an `https://` URL. `http://` is accepted only for a loopback host (`localhost`,
  `127.x.x.x` or `::1`). The value may not contain whitespace, control characters, `;` or `,`, because
  its origin is copied into the Content-Security-Policy header.
- A `host` that is not a loopback address (`localhost`, `127.x.x.x` or `::1`) is accepted, but
  `start()` then shows a warning and `:checkhealth` reports one.
- If `host` is a name such as `"localhost"`, the server resolves it once, when it starts, and binds to
  the first address returned. The preview URL contains that literal address, for example
  `http://[::1]:<port>/<token>/`, not the name, because a name can resolve to `::1` while the browser
  tries `127.0.0.1` first, or the reverse. If the name cannot be resolved, `start()` fails with an
  error.

## Command and Lua API

| Command | Effect |
| --- | --- |
| `:MarkdownPreview` | Same as `:MarkdownPreview toggle`. |
| `:MarkdownPreview start` | Start previewing the current buffer and open the browser. |
| `:MarkdownPreview stop` | Stop the server and close every connection. |
| `:MarkdownPreview toggle` | Stop a running preview, otherwise start one. |

The subcommands complete with `<Tab>`.

| Function | Effect |
| --- | --- |
| `setup(opts?)` | Set the options. |
| `start()` | Start previewing the current buffer and open the browser. Returns the URL, or `nil` if the server could not start. If a preview is already running, it opens the browser on it again. |
| `stop()` | Stop the preview. Returns `false` if none was running. |
| `toggle()` | `stop()` if running, otherwise `start()`. |
| `is_running()` | Whether a preview server is running. |
| `url()` | URL of the running preview, `nil` when stopped. |
| `scroll_on()`, `scroll_off()`, `scroll_toggle()` | Set `scroll.disable` and update open pages. |
| `cursorline_on()`, `cursorline_off()`, `cursorline_toggle()` | Set `cursor_line.disable` and update open pages. |
| `details_tags_on()`, `details_tags_off()`, `details_tags_toggle()` | Set `details_tags_open` and update open pages. |

The on, off and toggle functions change the live options only; they are not written anywhere.

## Which file is previewed

- `start()` previews the current buffer, which must have a file name.
- The preview root is the directory that contains `.git`, found by searching upward from the file.
  Without a `.git`, it is the file's directory. Only image, video and audio files are served from under
  the root: `avif`, `bmp`, `flac`, `gif`, `ico`, `jpeg`, `jpg`, `m4a`, `m4v`, `mov`, `mp3`, `mp4`, `oga`,
  `ogg`, `ogv`, `png`, `svg`, `wav`, `webm` and `webp`. A request for any other extension, or for a
  path with a segment that starts with a dot (such as `.git/` or `.env`), gets 403.
- Entering another named Markdown buffer (`filetype=markdown`) switches the preview to it.
- Clicking a relative link to a `.md`, `.markdown`, `.mdown` or `.mkd` file inside the root switches the
  preview to that file. The content comes from the loaded buffer if there is one, otherwise from disk.
  The cursor follows only while the previewed file is the current buffer.
- Content over 500,000 bytes is not sent. The page shows an error instead.
- One preview runs per Neovim instance. Each open page holds one event stream. The server accepts at
  most 16 event streams and answers further ones with 503. Browsers also limit HTTP/1.1 connections
  per origin (six in Chrome and Firefox), so a few tabs of the same preview can already stall.
- When the preview stops, or Neovim exits, the page tries to close itself. If the browser does not
  allow that, the page shows "Preview stopped".

### Headless and SSH use

Set `browser = false` to start the server without opening a browser. `start()` returns the URL and
the URL is also shown as an `info` notification. This prints it from a headless Neovim:

```sh
nvim --headless --clean --cmd 'set rtp^=/path/to/markdown-preview.nvim' \
  -c 'lua require("markdown-preview").setup({browser=false}); io.stdout:write(require("markdown-preview").start().."\n")' \
  FILE 2>/dev/null
```

Neovim keeps running and serving the preview until the process is stopped.

Over SSH, set a fixed `port` and forward the same port number locally, for example
`ssh -L 8080:127.0.0.1:8080 host` with `port = 8080`. The server rejects a request whose `Host`
header port differs from its own.

## Supported Markdown

Rendering happens in the browser with markdown-it and GitHub-compatible extensions. The resulting HTML
is sanitized with DOMPurify using GitHub's allowlist.

- Tables, read-only task lists, strikethrough with one or two tildes, footnotes, and the five alert
  types (`> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`).
- Emoji shortcodes such as `:smile:`. Text emoticons such as `:)` stay text.
- Heading IDs generated the way github.com does, with anchor links. `#fragment` links scroll within the
  page.
- Autolinks for URLs with a scheme, `www.` addresses and email addresses. A bare `example.com` is not
  linked, as on github.com.
- Math rendered by MathJax: `$…$`, `$$…$$` (inline and block), `` ```math `` blocks and `` $`…`$ ``.
- Mermaid diagrams in `` ```mermaid `` blocks. A diagram that fails to render stays as source text.
- Syntax highlighting with the starry-night grammars and GitHub's `pl-*` token classes. The common
  grammar set loads with the first highlighted block.
- Raw HTML, including `<details>`, `<sub>`, `<sup>`, `<ins>` and `<kbd>`. HTML comments are hidden.
  Scripts, `style` attributes, event-handler attributes, `<svg>`, `<iframe>` and form elements are
  removed.
- Images with relative paths, served from the preview root. `<picture>` sources that use
  `prefers-color-scheme`, and images whose URL ends in `#gh-dark-mode-only` or `#gh-light-mode-only`,
  follow the selected theme.
- Links to `.mp4`, `.mov`, `.webm`, `.m4v` and `.ogv` files, relative or external, are shown as a video
  player.
- Relative links to Markdown files switch the preview. Relative links to image, video and audio files
  under the root open in a new tab. A relative link to any other kind of file (a PDF, a source file) is
  shown as text without a link target, with a tooltip saying that only Markdown and media files open
  from the preview.
- Light, dark and high-contrast themes, from github-markdown-css and Primer.
- A `<details>` element that you open or close in the page keeps its state across edits.

Not supported:

- GeoJSON and TopoJSON maps and STL 3D models. These code blocks are shown as plain code.
- Autolinks that depend on a repository: `@user`, `#123`, `GH-26`, `owner/repo#123` and commit SHAs.
  github.com resolves them only in issues, pull requests and discussions.
- GitHub-only emoji shortcodes such as `:octocat:` and `:shipit:`. They stay text.
- Color chips for color values in inline code. github.com shows them only in issues, pull requests and
  discussions.
- The file-header outline menu, copy buttons on code blocks and the mermaid pan and zoom controls.

Known differences from github.com:

- markdown-it parses the Markdown, not GitHub's cmark-gfm. Rare edge cases in list indentation, tables
  and HTML blocks can render differently.
- YAML front matter is not rendered as GitHub's table. It is parsed as Markdown, so the opening `---`
  line becomes a horizontal rule and the lines up to the closing `---` can become a setext heading.
- Any link whose URL ends in `.mp4`, `.mov`, `.webm`, `.m4v` or `.ogv` becomes a video player, including
  links to other sites. github.com does this only for its own uploaded-asset URLs.
- A code-fence language outside the common grammar set is highlighted only if the CDN has a grammar with
  the scope `source.<name>` or `text.<name>`. `latex`, `tex`, `jsonc` and `shell-session` stay
  uncolored. Each such miss shows as two failed (404) requests in the browser console.
- The `user-content-` prefix of heading IDs is on the heading element. github.com puts it on the anchor
  inside the heading. `#fragment` links work the same way.
- MathJax's `\href` and `\style` are removed, and the names given to `\class` and `\cssId` have no
  effect.
- A relative link to a repository file that is neither Markdown nor media is shown as text without a
  link target.
- The page shows the text first. Code highlighting, math and diagrams are added after it, so they appear
  a moment later.
- The styles come from github-markdown-css 5.9.0, a snapshot of GitHub's stylesheet. Later changes on
  github.com are not reflected.
- If the libraries cannot be loaded from the CDN, the page shows the file as plain text and an error.

Libraries, loaded from the CDN at these exact versions. MathJax, mermaid and starry-night load only
when a document needs them.

| Purpose | Package |
| --- | --- |
| Markdown parser | markdown-it 15.0.2 |
| Plugins | markdown-it-footnote 4.0.0, markdown-it-task-lists 2.1.1, markdown-it-github-alerts 1.0.1, markdown-it-emoji 3.1.0 |
| Sanitizer | DOMPurify 3.4.16 |
| DOM update | idiomorph 0.8.0 |
| Styles | github-markdown-css 5.9.0, @primer/primitives 11.10.0 (light high-contrast colors only) |
| Math | MathJax 4.1.3 with @mathjax/mathjax-newcm-font 4.1.3 |
| Diagrams | mermaid 12.1.0 |
| Code highlighting | @wooorm/starry-night 3.11.0, vscode-textmate 9.3.2, vscode-oniguruma 2.0.1 |

## How it works

1. `:MarkdownPreview start` binds a TCP server on `host` with `vim.uv` and prints
   `http://<host>:<port>/<token>/`.
2. The page at that URL opens an event stream (`GET events`, Server-Sent Events). The server sends
   `init` with the whole file, then `content_change`, `cursor_move` and `update_config` events as you
   edit and move, and `goodbye` when it stops.
3. Neovim sends all lines of the buffer, `debounce_ms` after the last change. The browser renders them
   and updates the page in place.
4. The browser asks the server for the page's own assets (`assets/`), local images and videos
   (`file/`), and, when you click a relative Markdown link, to switch files (`POST api/open`).

## Security model

The server serves local files, so access is restricted:

- It binds to `127.0.0.1` by default.
- A random 32-character token is created at every start and is the first path segment of every URL.
  A request without the current token gets 403, including `/` and `/favicon.ico`.
- A request is rejected with 403 unless its `Host` header is `127.0.0.1`, `localhost` or `[::1]`, or the
  configured `host`, or the literal address that `host` resolved to, each followed by the server's
  port. A `POST` with an `Origin` header must carry one of the same origins. The `Host` and token checks
  run on the request headers, before any request body is read.
- Files under `file/` are resolved with `realpath`. A path outside the preview root, including one
  reached through a symbolic link, gets 403. Only the image, video and audio extensions listed under
  "Which file is previewed" are served, and a path with a segment that starts with a dot gets 403.
  They are sent with a `sandbox` Content-Security-Policy so an SVG file opened directly cannot run
  script in the page's origin.
- The page sanitizes the HTML in Markdown and is sent with a Content-Security-Policy. Scripts are
  limited to the page's own `assets/` directory and the `cdn` origin, so no file from the preview root
  can run as script.
- The browser is opened through a short-lived redirect file, so the token never appears on a command
  line.
- No response carries `Access-Control-Allow-*` headers. Every response carries
  `X-Content-Type-Options: nosniff` and `Cache-Control: no-store`.
- Request headers over 16 kB and request bodies over 16 kB are refused. The server holds at most 64
  connections, of which at most 16 are event streams. An event-stream client that stops reading is
  dropped once more than 4 MiB of output is waiting for it.

Set `host` to a non-loopback address only if you accept that the previewed text and the media files
under the preview root are then reachable from that network over plain HTTP, with the token as the only
credential. A client must use the configured `host` in its `Host` header; reaching a server bound to
`0.0.0.0` through another address of the machine gets 403.

Residual risks:

- The libraries are loaded from the CDN at fixed versions, but without Subresource Integrity checks. A
  compromised CDN could serve script that runs in the preview page. That script could read the
  previewed text, switch the preview to any Markdown file under the preview root and read it, and fetch
  the media files under the root.
- Any local process can keep the server's 64 connection slots busy without knowing the token, which
  blocks the preview's own browser connection. The server closes a connection that has not finished
  its request after 10 seconds, so such a process has to keep reconnecting. This degrades the preview
  only, not the editor.
- A Markdown file can embed images and media from external `https:` servers, and the page allows them.
  Opening such a file in the preview tells that server the viewer's IP address and that the file was
  opened. github.com proxies images; this plugin does not.
- The preview URL, including the token, stays in the browser's history and in session restore for as
  long as the browser keeps it. `stop()` ends the server and the token is never valid again; the next
  `start()` creates a new token.

## Using a CDN mirror

`cdn` is the base URL the page loads its libraries from. The Content-Security-Policy is built from its
origin, so a mirror needs no other change.

The mirror must serve jsDelivr's npm layout. The page imports most libraries as
`<cdn>/<package>@<version>/+esm`, jsDelivr's endpoint that bundles a package into one ES module, and
requests other files as `<cdn>/<package>@<version>/<path>`. A plain file mirror of the npm registry does
not serve `+esm` and does not work. `:checkhealth markdown-preview` requests
`<cdn>/markdown-it@15.0.2/package.json` to test reachability.

## Health check

`:checkhealth markdown-preview` reports the Neovim version, whether the configuration is valid, whether
the page assets are present, whether the CDN is reachable (a warning, not an error, because the browser
may reach it through a proxy that Neovim does not use), and whether a preview is running.

## Development

Run these from the repository root.

| Command | Effect |
| --- | --- |
| `make lint` | `stylua --check` and `luacheck` on `lua`, `plugin` and `tests`. |
| `make format` | `stylua` on the same paths. |
| `make test` | The Lua specs, run headless in Neovim with plenary.nvim. |
| `make test-browser` | Renderer and editor-sync checks in headless Chrome, run with `uv`. |
| `make check` | `make lint` and `make test`. |

- Tools: Neovim, `stylua` and `luacheck`. `make test-browser` also needs Chrome and `uv`; set
  `MP_CHROME` to the Chrome binary if it is not found.
- The specs use plenary.nvim from `$PLENARY_DIR`, then from lazy.nvim's data directory. If neither
  exists, `tests/minimal_init.lua` clones it into the temporary directory.
- The specs start the server on a real port and connect to it with a TCP client. They use no mocks.
- `.github/workflows/ci.yaml` runs the same targets, with the Lua specs on Neovim stable and nightly.

## Acknowledgements

[wallpants/github-preview.nvim](https://github.com/wallpants/github-preview.nvim) is the reference for
the feature set and for the event types sent from the editor to the browser.

## License

Apache License 2.0. See [LICENSE](LICENSE).
