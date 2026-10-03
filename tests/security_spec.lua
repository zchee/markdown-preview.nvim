-- Hostile and broken input against the local preview server.
--
-- Every group starts a real server on port 0 (tests/helpers.lua) and talks to it through a real
-- vim.uv TCP client that writes raw bytes. Nothing is mocked. After every case the spec also checks
-- that the server raised no Lua error (v:errmsg, messages, notifications), released the connection,
-- and still answers the next valid request. Every response must carry the hardening headers and
-- must never carry a CORS header or the bytes of a file outside the preview root or of a file the
-- server refuses to serve.
--
-- Where the protocol is silent the case name says "assumed" and states the assumption.
local h = require("helpers")
local http = require("markdown-preview.server.http")
local sse_mod = require("markdown-preview.server.sse")
local uv = vim.uv

-- Bound for anything the server has to finish on its own.
local WAIT_MS = 3000
-- Request deadline used by the stalled-client group; the default is exercised once, unchanged.
local STALL_DEADLINE_MS = 700
-- Content that must never appear in any response.
local FORBIDDEN_MARKERS = { "top secret", "# outside", "root:", "hunter2" }
local HOST_LINE = "Host: 127.0.0.1:{port}"
local OPEN_LINE = "POST /{token}/api/open HTTP/1.1"
local README_BODY = '{"path":"README.md"}'
local EVENTS_LINE = "GET /{token}/events HTTP/1.1"

-- Statuses whose responses went through the header check; asserted at the end of the file.
local seen_status = {} ---@type table<integer, true>

---@param cond any
---@param msg string
local function check(cond, msg)
  if not cond then
    error(msg, 0)
  end
end

---@param text string
---@param ctx table
---@return string
local function expand(text, ctx)
  return (
    text:gsub("{(%w+)}", function(key)
      local value = ctx.vars[key]
      if value ~= nil then
        return tostring(value)
      end
    end)
  )
end

--- Resolves a case field: calls functions with ctx, expands placeholders in strings.
---@param value any
---@param ctx table
---@return any
local function resolve(value, ctx)
  if type(value) == "function" then
    value = value(ctx)
  end
  if type(value) == "string" then
    return expand(value, ctx)
  end
  if type(value) == "table" then
    local out = {}
    for i, item in ipairs(value) do
      out[i] = resolve(item, ctx)
    end
    return out
  end
  return value
end

---@param request_line string
---@param headers string[]
---@param body? string
---@return string
local function raw_request(request_line, headers, body)
  local lines = { request_line }
  vim.list_extend(lines, headers)
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or "")
end

---@param s string
---@return string[]
local function split_bytes(s)
  local out = {}
  for i = 1, #s do
    out[i] = s:sub(i, i)
  end
  return out
end

---@param path string
---@return string
local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

--- Sets `mod[key]` to `value` while `fn` runs.
---@param mod table
---@param key string
---@param value any
---@param fn fun()
local function with_field(mod, key, value, fn)
  local saved = mod[key]
  mod[key] = value
  local ok, err = pcall(fn)
  mod[key] = saved
  if not ok then
    error(err, 0)
  end
end

---@param tcp uv.uv_tcp_t
local function drop(tcp)
  if tcp:is_closing() then
    return
  end
  tcp:close_reset()
end

---@class sectest.Exchange
---@field raw string Bytes received from the server.
---@field closed boolean The server closed the connection before the timeout.
---@field elapsed_ms integer

--- Connects, writes `chunks` (with `gap_ms` between them so the server sees separate reads) and
--- collects bytes until the server closes the connection or `timeout_ms` passes.
--- `half_close` sends FIN after the last chunk; `abort` resets the connection without reading.
---@param port integer
---@param chunks string|string[]
---@param opts? { gap_ms?: integer, timeout_ms?: integer, half_close?: boolean, abort?: boolean }
---@return sectest.Exchange
local function exchange(port, chunks, opts)
  opts = opts or {}
  if type(chunks) == "string" then
    chunks = { chunks }
  end
  local tcp = assert(uv.new_tcp())
  local out, st = {}, { connected = false, closed = false, failed = nil }
  local started = uv.hrtime()
  tcp:connect("127.0.0.1", port, function(err)
    if err then
      st.failed = err
      st.closed = true
      return
    end
    st.connected = true
    tcp:nodelay(true)
    tcp:read_start(function(rerr, data)
      if rerr or not data then
        st.closed = true
        return
      end
      out[#out + 1] = data
    end)
  end)
  vim.wait(WAIT_MS, function()
    return st.connected or st.failed ~= nil
  end, 2)
  check(st.connected, "cannot connect to 127.0.0.1:" .. port .. ": " .. tostring(st.failed))

  local pending = 0
  for i, chunk in ipairs(chunks) do
    if st.closed or tcp:is_closing() then
      break
    end
    pending = pending + 1
    tcp:write(chunk, function()
      pending = pending - 1
    end)
    if i < #chunks and (opts.gap_ms or 0) > 0 then
      vim.wait(opts.gap_ms)
    end
  end
  if opts.abort or opts.half_close then
    vim.wait(WAIT_MS, function()
      return pending == 0 or st.closed
    end, 1)
  end
  if opts.abort then
    drop(tcp)
    return { raw = table.concat(out), closed = false, elapsed_ms = 0 }
  end
  if opts.half_close and not st.closed then
    tcp:shutdown()
  end
  vim.wait(opts.timeout_ms or WAIT_MS, function()
    return st.closed
  end, 2)
  local elapsed = math.floor((uv.hrtime() - started) / 1e6)
  if not tcp:is_closing() then
    tcp:close()
  end
  return { raw = table.concat(out), closed = st.closed, elapsed_ms = elapsed }
end

---@class sectest.Client
---@field tcp uv.uv_tcp_t
---@field connected boolean
---@field bytes integer Bytes read so far.
---@field seen string First bytes read.

--- Opens a connection that writes `request` and, when `read` is set, reads the answer.
--- A client without `read` never drains its socket.
---@param port integer
---@param request? string
---@param read? boolean
---@return sectest.Client
local function open_client(port, request, read)
  local c = { tcp = assert(uv.new_tcp()), connected = false, bytes = 0, seen = "" }
  c.tcp:connect("127.0.0.1", port, function(err)
    if err then
      return
    end
    c.connected = true
    if read then
      c.tcp:read_start(function(_, data)
        if data then
          c.bytes = c.bytes + #data
          if #c.seen < 16384 then
            c.seen = c.seen .. data
          end
        end
      end)
    end
    if request then
      c.tcp:write(request)
    end
  end)
  return c
end

---@param clients sectest.Client[]
local function wait_connected(clients)
  local ok = vim.wait(WAIT_MS, function()
    for _, c in ipairs(clients) do
      if not c.connected then
        return false
      end
    end
    return true
  end, 2)
  check(ok, "not every client connected")
end

---@param clients sectest.Client[]
---@param reset? boolean
local function close_clients(clients, reset)
  for _, c in ipairs(clients) do
    if reset then
      drop(c.tcp)
    elseif not c.tcp:is_closing() then
      c.tcp:close()
    end
  end
end

--- Files, directories and links the specs need beyond what helpers.tree() creates.
---@param t table
local function add_fixtures(t)
  local join = vim.fs.joinpath
  local function link(target, path)
    assert(uv.fs_symlink(target, path))
  end
  h.write_file(join(t.repo, "media", "empty.mp4"), "")
  h.write_file(join(t.repo, "media", "pic.md"), "# pic\n")
  vim.fn.mkdir(join(t.repo, "media", "dir.png"), "p")
  h.write_file(join(t.repo, "evil.html"), "<script>alert(1)</script>\n")
  h.write_file(join(t.repo, "evil.svg"), '<svg xmlns="http://www.w3.org/2000/svg"><script>1</script></svg>\n')
  h.write_file(join(t.repo, "script.js"), "alert('script');\n")
  h.write_file(join(t.repo, "module.mjs"), "export default 1;\n")
  h.write_file(join(t.repo, ".env"), "TOKEN=hunter2\n")
  h.write_file(join(t.repo, ".git", "config"), "[core]\n\trepositoryformatversion = 0\n")
  h.write_file(join(t.repo, "sub", ".hidden", "a.png"), "hidden image\n")
  h.write_file(join(t.base, "repo-evil", "secret.png"), "top secret (sibling directory)\n")
  -- A tree that mirrors $HOME inside the root: it is served only if `$HOME` is expanded.
  local home = vim.env.HOME
  assert(home and home:match("^/[^/]"), "HOME must be an absolute path for the environment-expansion cases")
  h.write_file(join(t.repo, home:sub(2), "x.png"), "home mirror\n")

  link(t.outside, join(t.repo, "escape-dir.png"))
  link(join(t.outside, "secret.png"), join(t.repo, "leak.png"))
  link(join("..", "outside", "outside.md"), join(t.repo, "escape.md"))
  link(join("..", "repo-evil"), join(t.repo, "sibling"))
  link("/etc", join(t.repo, "etc-link"))
  link("chain-b.png", join(t.repo, "chain-a.png"))
  link(join("..", "outside", "secret.png"), join(t.repo, "chain-b.png"))
  link("loop-b.png", join(t.repo, "loop-a.png"))
  link("loop-a.png", join(t.repo, "loop-b.png"))
  link(join("media", "pic.png"), join(t.repo, "inside-link.png"))
  link(join("..", "outside", "missing.png"), join(t.repo, "dangling-out.png"))
  link(join("..", "outside", "secret.txt"), join(t.web, "leak.txt"))
  link(join("..", "outside"), join(t.web, "linkdir"))
end

---@class sectest.Ctx
---@field tree table
---@field session markdown_preview.Session
---@field port integer
---@field token string
---@field vars table<string, string|integer>

--- Starts a server previewing <tree>/repo/README.md.
---@return sectest.Ctx
local function start_server()
  local t = h.tree()
  add_fixtures(t)
  -- Both names expand to existing files if the server ever expands environment variables.
  uv.os_setenv("MP_SPEC_VAR", "media/pic")
  uv.os_setenv("MP_SPEC_UP", "..")
  local session = h.start(t.readme, t.web)
  local token, port = session.token, session.server.port
  return {
    tree = t,
    session = session,
    port = port,
    token = token,
    vars = {
      token = token,
      port = port,
      other_port = port == 65535 and 65534 or port + 1,
      wrong = (token:sub(1, 1) == "0" and "1" or "0") .. token:sub(2),
      short = token:sub(1, -2),
      long = token .. "0",
      upper = token:upper(),
      token_pct = string.format("%%%02X", token:byte(1)) .. token:sub(2),
      outside = t.outside,
    },
  }
end

---@param ctx sectest.Ctx
local function cleanup_server(ctx)
  uv.os_unsetenv("MP_SPEC_VAR")
  uv.os_unsetenv("MP_SPEC_UP")
  h.cleanup(ctx.tree)
end

---@param ctx sectest.Ctx
---@return { raw: string, status?: integer, headers: table<string, string>, body: string }
local function canary(ctx)
  local ex = exchange(ctx.port, h.request(ctx.port, "GET", "/" .. ctx.token .. "/"))
  return h.parse(ex.raw)
end

--- Installs the collectors for server-side problems and returns the function that evaluates them.
---@param ctx sectest.Ctx
---@return fun(): string[] problems
local function guard(ctx)
  local notes = {}
  local original_notify = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = tostring(msg), level = level or vim.log.levels.INFO }
  end
  vim.v.errmsg = ""
  vim.cmd("messages clear")
  return function()
    local problems = {}
    local server = ctx.session.server
    local released = vim.wait(WAIT_MS, function()
      return server:connection_count() == 0
    end, 5)
    if not released then
      problems[#problems + 1] =
        string.format("server still holds %d connection(s) after the client left", server:connection_count())
    end
    local res = canary(ctx)
    if res.status ~= 200 or not res.body:find("mp-bootstrap", 1, true) then
      problems[#problems + 1] = "server cannot answer the next valid request: " .. vim.inspect(res.raw:sub(1, 300))
    end
    vim.wait(5)
    vim.notify = original_notify
    for _, n in ipairs(notes) do
      if n.level >= vim.log.levels.WARN then
        problems[#problems + 1] = "server notified: " .. n.msg
      end
    end
    if vim.v.errmsg ~= "" then
      problems[#problems + 1] = "v:errmsg is set: " .. vim.v.errmsg
    end
    local messages = vim.fn.execute("messages")
    if messages:find("Error executing", 1, true) or messages:find("stack traceback", 1, true) then
      problems[#problems + 1] = "Lua error reported by Neovim: " .. messages
    end
    return problems
  end
end

--- Registers one `it` that runs `fn` under the server-health guard.
---@param ctx sectest.Ctx
---@param name string
---@param fn fun()
local function guarded_it(ctx, name, fn)
  it(name, function()
    local finish = guard(ctx)
    local ok, err = pcall(fn)
    local problems = finish()
    if not ok then
      error(err, 0)
    end
    check(#problems == 0, "server unhealthy after the case:\n  " .. table.concat(problems, "\n  "))
  end)
end

--- Registers one guarded `it` per entry of `cases`, in name order.
---@param ctx sectest.Ctx
---@param cases table<string, any>
---@param run fun(ctx: sectest.Ctx, case: any)
local function each_case(ctx, cases, run)
  local names = vim.tbl_keys(cases)
  table.sort(names)
  for _, name in ipairs(names) do
    guarded_it(ctx, name, function()
      run(ctx, cases[name])
    end)
  end
end

---@param want integer|integer[]
---@param got integer
---@return boolean
local function status_matches(want, got)
  if type(want) == "table" then
    return vim.list_contains(want, got)
  end
  return want == got
end

---@param want integer|integer[]
---@return string
local function describe_status(want)
  if type(want) == "table" then
    return table.concat(vim.tbl_map(tostring, want), " or ")
  end
  return tostring(want)
end

--- Properties every response of this server must have, whatever the request was.
---@param res table
---@param why fun(msg: string): string
local function check_hygiene(res, why)
  check(res.status ~= nil, why("no parsable status line"))
  seen_status[res.status] = true
  for name in pairs(res.headers) do
    check(not name:find("^access%-control%-"), why("response carries " .. name))
  end
  check(res.headers["x-content-type-options"] == "nosniff", why("X-Content-Type-Options: nosniff is missing"))
  check(res.headers["cache-control"] == "no-store", why("Cache-Control: no-store is missing"))
  check(res.headers["connection"] == "close", why("Connection: close is missing"))
  local length = res.headers["content-length"]
  if length then
    check(tonumber(length) == #res.body, why(string.format("Content-Length %s but %d body bytes", length, #res.body)))
  end
  if res.status == 204 then
    check(length == nil and res.body == "", why("204 must have no Content-Length and no body"))
  end
  local documented = { [501] = true, [503] = true, [505] = true }
  check(res.status < 500 or documented[res.status], why("server error status " .. res.status))
  check(not res.raw:lower():find("set-cookie", 1, true), why("response sets a cookie"))
  for _, marker in ipairs(FORBIDDEN_MARKERS) do
    check(not res.raw:find(marker, 1, true), why("response leaks protected content: " .. marker))
  end
end

---@param ctx sectest.Ctx
---@param case table
---@return string|string[]
local function build_send(ctx, case)
  local send = resolve(case.send, ctx)
  if send ~= nil then
    return send
  end
  local headers = {}
  for name, value in pairs(case.headers or {}) do
    headers[name] = value and resolve(value, ctx) or false
  end
  return h.request(ctx.port, case.method or "GET", resolve(case.target, ctx), headers, resolve(case.body, ctx))
end

--- Sends one request described by `case` and checks the response against it.
---@param ctx sectest.Ctx
---@param case table
local function run_http(ctx, case)
  local send = build_send(ctx, case)
  local ex = exchange(ctx.port, send, case.exchange)
  local res = h.parse(ex.raw)
  local function why(msg)
    local sent = type(send) == "table" and table.concat(send) or tostring(send)
    return string.format(
      "%s\n--- request (%d bytes) ---\n%s\n--- raw response (%d bytes, closed=%s, %d ms) ---\n%s\n---",
      msg,
      #sent,
      vim.inspect(sent:sub(1, 600)),
      #ex.raw,
      tostring(ex.closed),
      ex.elapsed_ms,
      vim.inspect(ex.raw:sub(1, 900))
    )
  end
  check_hygiene(res, why)
  local want = case.status
  check(
    status_matches(want, res.status),
    why(string.format("expected status %s, got %d", describe_status(want), res.status))
  )
  if case.max_ms then
    check(
      ex.elapsed_ms <= case.max_ms,
      why(string.format("answered after %d ms, limit %d ms", ex.elapsed_ms, case.max_ms))
    )
  end
  for name, expected in pairs(case.expect_headers or {}) do
    local value = res.headers[name]
    if expected == false then
      check(value == nil, why(name .. " must be absent, got " .. tostring(value)))
    elseif type(expected) == "function" then
      local ok, reason = expected(value, ctx)
      check(ok, why(string.format("header %s: %s (value %s)", name, tostring(reason), vim.inspect(value))))
    else
      local want_value = resolve(expected, ctx)
      check(value == want_value, why(string.format("header %s expected %q, got %q", name, want_value, tostring(value))))
    end
  end
  if case.body_is ~= nil then
    local want_body = resolve(case.body_is, ctx)
    check(
      res.body == want_body,
      why(string.format("body expected %d bytes %s", #want_body, vim.inspect(want_body:sub(1, 60))))
    )
  end
  for _, needle in ipairs(resolve(case.body_has or {}, ctx)) do
    check(res.body:find(needle, 1, true), why("body does not contain " .. vim.inspect(needle)))
  end
  for _, needle in ipairs(resolve(case.body_not_has or {}, ctx)) do
    check(not res.raw:find(needle, 1, true), why("response contains " .. vim.inspect(needle)))
  end
  if case.after then
    case.after(ctx, res, why)
  end
end

---@param ctx sectest.Ctx
local function target_unchanged(ctx)
  local target = ctx.session.target
  check(target.rel == "README.md", "the request changed the previewed file to " .. tostring(target.rel))
end

--- Registers the closing check of a group: stop() releases the listener and every connection.
---@param ctx sectest.Ctx
local function stop_it(ctx)
  it("stops: closes the listener and every connection within a bound", function()
    local server = ctx.session.server
    h.stop()
    check(server.tcp:is_closing(), "listening socket is still open after stop()")
    check(server:connection_count() == 0, "connections remain after stop(): " .. server:connection_count())
  end)
end

--- Registers a group of table-driven HTTP cases on a fresh server.
---@param title string
---@param build fun(ctx: sectest.Ctx): table<string, table>
local function http_group(title, build)
  describe(title, function()
    local ctx = start_server()
    each_case(ctx, build(ctx), run_http)
    stop_it(ctx)
    cleanup_server(ctx)
  end)
end

local function pad_header_block(ctx, total)
  local head = expand("GET /{token}/ HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nX-Pad: ", ctx)
  local tail = "\r\n\r\n"
  return head .. string.rep("a", total - #head - #tail) .. tail
end

---@param body string|fun(ctx: sectest.Ctx): string
---@param status integer|integer[]
---@param extra? table
local function json_open(body, status, extra)
  return vim.tbl_extend("force", {
    method = "POST",
    target = "/{token}/api/open",
    body = body,
    status = status,
    after = target_unchanged,
  }, extra or {})
end

---@param target string
---@param from string
---@param to string
---@return string
local function swap(target, from, to)
  return (target:gsub(from, to))
end

local MAX_BODY = http.MAX_BODY_BYTES
local function pic_body(ctx)
  return read_file(ctx.tree.pic)
end
local function blob_body(ctx)
  return ctx.tree.blob_content
end

http_group("request framing", function()
  local cases = {
    ["rejects: request line without HTTP version"] = {
      send = raw_request("GET /{token}/", { HOST_LINE }),
      status = 400,
    },
    ["rejects: request line with two spaces"] = {
      send = raw_request("GET  /{token}/ HTTP/1.1", { HOST_LINE }),
      status = 400,
    },
    ["rejects: request line with a tab separator"] = {
      send = raw_request("GET\t/{token}/ HTTP/1.1", { HOST_LINE }),
      status = 400,
    },
    ["rejects: lower-case method"] = { send = raw_request("get /{token}/ HTTP/1.1", { HOST_LINE }), status = 400 },
    ["rejects: empty method"] = { send = raw_request(" /{token}/ HTTP/1.1", { HOST_LINE }), status = 400 },
    ["rejects: empty request target"] = { send = raw_request("GET  HTTP/1.1", { HOST_LINE }), status = 400 },
    ["rejects: HTTP/2.0 request line"] = { send = raw_request("GET /{token}/ HTTP/2.0", { HOST_LINE }), status = 505 },
    ["rejects: HTTP/9.9 request line"] = { send = raw_request("GET /{token}/ HTTP/9.9", { HOST_LINE }), status = 505 },
    ["rejects: version HTTP/1.10"] = { send = raw_request("GET /{token}/ HTTP/1.10", { HOST_LINE }), status = 400 },
    ["rejects: version with trailing garbage"] = {
      send = raw_request("GET /{token}/ HTTP/1.1x", { HOST_LINE }),
      status = 400,
    },
    ["rejects: lower-case protocol name"] = {
      send = raw_request("GET /{token}/ http/1.1", { HOST_LINE }),
      status = 400,
    },
    ["rejects: HTTP/1.1 request without Host"] = { send = raw_request("GET /{token}/ HTTP/1.1", {}), status = 400 },
    ["rejects: HTTP/1.0 request without Host"] = { send = raw_request("GET /{token}/ HTTP/1.0", {}), status = 403 },
    ["rejects: unknown method on a valid route with 405 and Allow"] = {
      send = raw_request("BREW /{token}/ HTTP/1.1", { HOST_LINE }),
      status = 405,
      expect_headers = { allow = "GET" },
    },
    ["rejects: CONNECT with an authority-form target"] = {
      send = raw_request("CONNECT 127.0.0.1:{port} HTTP/1.1", { HOST_LINE }),
      status = 403,
    },
    ["rejects: asterisk-form target (assumed: only origin-form targets reach a route)"] = {
      send = raw_request("OPTIONS * HTTP/1.1", { HOST_LINE }),
      status = 403,
    },
    ["rejects: absolute-form target naming this server (assumed: only origin-form targets reach a route)"] = {
      send = raw_request("GET http://127.0.0.1:{port}/{token}/ HTTP/1.1", { HOST_LINE }),
      status = 403,
    },
    ["rejects: absolute-form target naming another authority"] = {
      send = raw_request("GET http://evil.example/{token}/ HTTP/1.1", { "Host: evil.example" }),
      status = 403,
    },
    ["rejects: NUL byte inside the token segment of the request line"] = {
      send = raw_request("GET /{token}\0/ HTTP/1.1", { HOST_LINE }),
      status = 400,
    },
    ["rejects: NUL byte at the end of a file path in the request line"] = {
      send = raw_request("GET /{token}/file/media/pic.png\0 HTTP/1.1", { HOST_LINE }),
      status = 400,
      body_not_has = { "PNG" },
    },
    ["rejects: NUL byte as the first byte of the request line"] = {
      send = raw_request("\0GET /{token}/ HTTP/1.1", { HOST_LINE }),
      status = 400,
    },
    ["rejects: bare LF inside the target"] = {
      send = raw_request("GET /{token}/a\nb HTTP/1.1", { HOST_LINE }),
      status = 400,
    },
    ["rejects: bare CR inside the target"] = {
      send = raw_request("GET /{token}/a\rb HTTP/1.1", { HOST_LINE }),
      status = 400,
    },
    ["rejects: header block over 16 kB that is terminated"] = {
      send = function(ctx)
        return pad_header_block(ctx, 17 * 1024)
      end,
      status = 431,
    },
    ["rejects: header block over 16 kB that never ends"] = {
      send = "GET /{token}/ HTTP/1.1\r\n" .. HOST_LINE .. "\r\nX-Pad: " .. string.rep("a", 40 * 1024),
      status = 431,
    },
    ["rejects: request line of 20 kB"] = {
      send = "GET /{token}/file/" .. string.rep("a", 20 * 1024) .. ".png HTTP/1.1\r\n" .. HOST_LINE .. "\r\n\r\n",
      status = 431,
    },
    ["rejects: header block one byte over the 16 kB limit"] = {
      send = function(ctx)
        return pad_header_block(ctx, 16 * 1024 + 1)
      end,
      status = 431,
    },
    ["accepts: header block exactly at the 16 kB limit"] = {
      send = function(ctx)
        return pad_header_block(ctx, 16 * 1024)
      end,
      status = 200,
    },
    ["rejects: Content-Length over the body limit with no body sent (answered without waiting)"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: " .. (MAX_BODY + 1) }),
      status = 413,
      max_ms = 1500,
    },
    ["rejects: Content-Length over the body limit with the whole body sent"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: " .. (MAX_BODY + 1) }, string.rep("x", MAX_BODY + 1)),
      status = 413,
    },
    ["rejects: Content-Length of 1 GB with no body sent"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: 1073741824" }),
      status = 413,
      max_ms = 1500,
    },
    ["accepts: Content-Length of exactly the body limit (answered by the route, not by the size limit)"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: " .. MAX_BODY }, string.rep("x", MAX_BODY)),
      status = 400,
      body_has = { "JSON body" },
      after = target_unchanged,
    },
    ["rejects: GET with a Content-Length and no body (answered without waiting)"] = {
      send = raw_request("GET /{token}/ HTTP/1.1", { HOST_LINE, "Content-Length: 5" }),
      status = 400,
      max_ms = 1500,
    },
    ["rejects: GET with a Content-Length and the body"] = {
      send = raw_request("GET /{token}/ HTTP/1.1", { HOST_LINE, "Content-Length: 5" }, "hello"),
      status = 400,
    },
    ["rejects: GET on the event stream with a body"] = {
      send = raw_request(EVENTS_LINE, { HOST_LINE, "Content-Length: 2" }, "{}"),
      status = 400,
    },
    ["rejects: GET on a file with a body"] = {
      send = raw_request("GET /{token}/file/media/pic.png HTTP/1.1", { HOST_LINE, "Content-Length: 2" }, "{}"),
      status = 400,
    },
    ["rejects: PUT with a body"] = {
      send = raw_request("PUT /{token}/api/open HTTP/1.1", { HOST_LINE, "Content-Length: 2" }, "{}"),
      status = 400,
    },
    ["rejects: negative Content-Length"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: -1" }, "{}"),
      status = 400,
    },
    ["rejects: non-numeric Content-Length"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: abc" }, "{}"),
      status = 400,
    },
    ["rejects: empty Content-Length"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length:" }, "{}"),
      status = 400,
    },
    ["rejects: Content-Length in exponent form"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: 1e1" }, "{}"),
      status = 400,
    },
    ["rejects: Content-Length with a plus sign"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: +2" }, "{}"),
      status = 400,
    },
    ["rejects: hexadecimal Content-Length"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: 0x2" }, "{}"),
      status = 400,
    },
    ["rejects: Content-Length list in one header"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: 2, 2" }, "{}"),
      status = 400,
    },
    ["rejects: Content-Length with 20 digits"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: 99999999999999999999" }, "{}"),
      status = 400,
    },
    ["rejects: Content-Length with 16 digits"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: 0000000000000002" }, "{}"),
      status = 400,
    },
    ["rejects: duplicate Content-Length headers with different values"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: 2", "Content-Length: 3" }, "{}"),
      status = 400,
      body_has = { "conflicting Content-Length" },
    },
    ["accepts: duplicate Content-Length headers with the same value (answered by the route)"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: 2", "Content-Length: 2" }, "{}"),
      status = 400,
      body_has = { "JSON body" },
    },
    ["rejects: whitespace between header name and colon"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length : 2" }, "{}"),
      status = 400,
    },
    ["rejects: obsolete line folding"] = {
      send = raw_request("GET /{token}/ HTTP/1.1", { HOST_LINE, "X-Fold: a", " b" }),
      status = 400,
    },
    ["rejects: header line without a colon"] = {
      send = raw_request("GET /{token}/ HTTP/1.1", { HOST_LINE, "X-Broken" }),
      status = 400,
    },
    ["rejects: header name with a space"] = {
      send = raw_request("GET /{token}/ HTTP/1.1", { HOST_LINE, "X Bad: 1" }),
      status = 400,
    },
    ["rejects: empty header name"] = {
      send = raw_request("GET /{token}/ HTTP/1.1", { HOST_LINE, ": 1" }),
      status = 400,
    },
    ["rejects: NUL byte in a header value"] = {
      send = raw_request("GET /{token}/ HTTP/1.1", { HOST_LINE, "X-Nul: a\0b" }),
      status = 400,
    },
    ["rejects: bare CR in a header value"] = {
      send = raw_request("GET /{token}/ HTTP/1.1", { HOST_LINE, "X-Cr: a\rb" }),
      status = 400,
    },
    ["rejects: bare LF in a header value"] = {
      send = raw_request("GET /{token}/ HTTP/1.1", { HOST_LINE, "X-Lf: a\nb" }),
      status = 400,
    },
    ["rejects: Transfer-Encoding chunked on POST without processing the body"] = {
      send = raw_request(
        OPEN_LINE,
        { HOST_LINE, "Transfer-Encoding: chunked" },
        '18\r\n{"path":"docs/guide.md"}\r\n0\r\n\r\n'
      ),
      status = 501,
      after = target_unchanged,
    },
    ["rejects: Transfer-Encoding together with Content-Length (request smuggling shape)"] = {
      send = raw_request(
        OPEN_LINE,
        { HOST_LINE, "Content-Length: 24", "Transfer-Encoding: chunked" },
        '{"path":"docs/guide.md"}'
      ),
      status = 501,
      after = target_unchanged,
    },
    ["rejects: Transfer-Encoding identity"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Transfer-Encoding: identity", "Content-Length: 2" }, "{}"),
      status = 501,
    },
    ["rejects: Transfer-Encoding on GET"] = {
      send = raw_request("GET /{token}/ HTTP/1.1", { HOST_LINE, "Transfer-Encoding: chunked" }, "0\r\n\r\n"),
      status = 501,
    },
    ["answers: exactly one request per connection when two are pipelined"] = {
      send = raw_request("GET /{token}/ HTTP/1.1", { HOST_LINE })
        .. raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: 24" }, '{"path":"docs/guide.md"}'),
      status = 200,
      after = function(ctx, res, why)
        local _, count = res.raw:gsub("HTTP/1%.1 %d%d%d", "")
        check(count == 1, why("expected one response for two pipelined requests, got " .. count))
        target_unchanged(ctx)
      end,
    },
  }
  for _, method in ipairs({ "PUT", "DELETE", "PATCH", "TRACE", "HEAD", "OPTIONS" }) do
    cases["rejects: " .. method .. " on a valid route with 405 and Allow"] = {
      send = raw_request(method .. " /{token}/ HTTP/1.1", { HOST_LINE }),
      status = 405,
      expect_headers = { allow = "GET" },
    }
  end
  return cases
end)

describe("slow and broken clients", function()
  local ctx = start_server()
  local get_index = h.request(ctx.port, "GET", "/" .. ctx.token .. "/")
  local host = "Host: 127.0.0.1:" .. ctx.port

  local function expect_status(raw, want, label)
    local res = h.parse(raw)
    check(
      res.status == want,
      string.format("%s: expected %d, got %s\n%s", label, want, tostring(res.status), vim.inspect(raw:sub(1, 400)))
    )
    return res
  end

  guarded_it(ctx, "answers: valid GET sent one byte at a time", function()
    local ex = exchange(ctx.port, split_bytes(get_index), { gap_ms = 1 })
    local res = expect_status(ex.raw, 200, "one byte at a time")
    check(res.body:find("mp-bootstrap", 1, true), "page body is missing")
  end)

  guarded_it(ctx, "rejects: malformed request sent one byte at a time with the same status as unsplit", function()
    local raw = raw_request("GET /" .. ctx.token .. "/ HTTP", { host })
    expect_status(exchange(ctx.port, split_bytes(raw), { gap_ms = 1 }).raw, 400, "one byte at a time")
  end)

  guarded_it(ctx, "rejects: oversized Content-Length announced one byte at a time", function()
    local raw = raw_request(expand(OPEN_LINE, ctx), { host, "Content-Length: " .. (MAX_BODY + 1) })
    expect_status(exchange(ctx.port, split_bytes(raw), { gap_ms = 1 }).raw, 413, "one byte at a time")
  end)

  guarded_it(ctx, "rejects: wrong token on a POST announced one byte at a time", function()
    local raw = raw_request("POST /" .. ctx.vars.wrong .. "/api/open HTTP/1.1", { host, "Content-Length: 24" })
    expect_status(exchange(ctx.port, split_bytes(raw), { gap_ms = 1 }).raw, 403, "one byte at a time")
  end)

  guarded_it(ctx, "answers: POST whose body arrives one byte at a time", function()
    local head = raw_request(expand(OPEN_LINE, ctx), { host, "Content-Length: " .. #README_BODY })
    local chunks = { head }
    vim.list_extend(chunks, split_bytes(README_BODY))
    expect_status(exchange(ctx.port, chunks, { gap_ms = 1 }).raw, 204, "body one byte at a time")
  end)

  guarded_it(ctx, "answers: request split between CR and LF and inside the final CRLF CRLF", function()
    local raw = get_index
    local chunks = { raw:sub(1, #raw - 3), raw:sub(#raw - 2, #raw - 2), raw:sub(#raw - 1, #raw - 1), raw:sub(#raw) }
    expect_status(exchange(ctx.port, chunks, { gap_ms = 15 }).raw, 200, "split at the terminator")
  end)

  guarded_it(
    ctx,
    "answers: complete request followed by half-close (assumed: FIN after a request is not an abort)",
    function()
      expect_status(
        exchange(ctx.port, get_index, { half_close = true }).raw,
        200,
        "half-close after a complete request"
      )
    end
  )

  local abandoned = {
    ["releases: half a request line then FIN"] = { chunks = { "GET /to" }, half_close = true },
    ["releases: half a request line then reset"] = { chunks = { "GET /to" }, abort = true },
    ["releases: half a header block then FIN"] = { chunks = { "GET /x HTTP/1.1\r\nHost: 127.0" }, half_close = true },
    ["releases: half a header block then reset"] = { chunks = { "GET /x HTTP/1.1\r\nHost: 127.0" }, abort = true },
    ["releases: half a body then FIN"] = {
      chunks = { raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: 100" }, "{}") },
      half_close = true,
    },
    ["releases: half a body then reset"] = {
      chunks = { raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: 100" }, "{}") },
      abort = true,
    },
    ["releases: complete request then reset before reading the response"] = { chunks = { get_index }, abort = true },
    ["releases: connect then FIN without a byte"] = { chunks = {}, half_close = true },
    ["releases: connect then reset without a byte"] = { chunks = {}, abort = true },
  }
  each_case(ctx, abandoned, function(c, spec)
    local ex = exchange(c.port, resolve(spec.chunks, c), { half_close = spec.half_close, abort = spec.abort })
    if spec.half_close then
      check(ex.closed, "server did not close its side after the client sent FIN mid-request")
    end
  end)

  guarded_it(ctx, "answers: the next valid request while 60 idle connections are open", function()
    local clients = {}
    for i = 1, 60 do
      clients[i] = open_client(ctx.port)
    end
    wait_connected(clients)
    local res = canary(ctx)
    close_clients(clients)
    check(res.status == 200, "server did not answer while 60 connections idled: " .. vim.inspect(res.raw:sub(1, 200)))
  end)

  stop_it(ctx)
  cleanup_server(ctx)
end)

describe("stalled clients", function()
  local ctx = start_server()

  local stalled = {
    ["closes: client that connects and sends nothing"] = {},
    ["closes: request terminated by bare LF instead of CRLF"] = {
      "GET /{token}/ HTTP/1.1\nHost: 127.0.0.1:{port}\n\n",
    },
    ["closes: half a request line that never continues"] = { "GET /{token}/ HT" },
    ["closes: header block that never ends"] = { "GET /{token}/ HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nX-Slow: 1\r\n" },
    ["closes: body shorter than Content-Length"] = {
      raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: 100" }, "{}"),
    },
  }
  with_field(http, "REQUEST_TIMEOUT_MS", STALL_DEADLINE_MS, function()
    each_case(ctx, stalled, function(c, chunks)
      local ex = exchange(c.port, resolve(chunks, c), { timeout_ms = STALL_DEADLINE_MS + 2000 })
      check(
        ex.closed,
        string.format(
          "stalled connection stayed open %d ms (no request deadline); received %s",
          ex.elapsed_ms,
          vim.inspect(ex.raw)
        )
      )
      check(ex.raw == "", "server answered a request that never completed: " .. vim.inspect(ex.raw))
    end)

    guarded_it(
      ctx,
      "closes: client that drips one header byte at a time (activity does not extend the deadline)",
      function()
        local head = expand("GET /{token}/ HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nX-Drip: ", ctx)
        local chunks = split_bytes(head .. string.rep("a", 40))
        local ex = exchange(ctx.port, chunks, { gap_ms = 100, timeout_ms = STALL_DEADLINE_MS + 2000 })
        check(ex.closed, "server kept a dripping connection open for " .. ex.elapsed_ms .. " ms")
        check(
          ex.elapsed_ms < #chunks * 100,
          string.format("deadline did not cut the drip: closed after %d ms", ex.elapsed_ms)
        )
      end
    )

    guarded_it(ctx, "answers: a request completed just inside the deadline", function()
      local raw = h.request(ctx.port, "GET", "/" .. ctx.token .. "/")
      local chunks = { raw:sub(1, 20), raw:sub(21) }
      local ex = exchange(ctx.port, chunks, { gap_ms = STALL_DEADLINE_MS - 400 })
      check(
        h.parse(ex.raw).status == 200,
        "late but complete request was not answered: " .. vim.inspect(ex.raw:sub(1, 200))
      )
    end)

    guarded_it(ctx, "keeps: event stream open past the request deadline", function()
      local s = h.events(ctx.port, "/" .. ctx.token .. "/events")
      check(s.wait_for("init", 1, WAIT_MS) ~= nil, "no init event" .. s.describe())
      vim.wait(STALL_DEADLINE_MS * 2)
      check(not s.closed, "event stream was closed by the request deadline")
      ctx.session:broadcast_config()
      local update = s.wait_for("update_config", 1, WAIT_MS)
      s.close()
      check(update ~= nil, "event stream did not receive an event after the deadline" .. s.describe())
    end)
  end)

  stop_it(ctx)
  cleanup_server(ctx)
end)

describe("request deadline at its default", function()
  local ctx = start_server()

  guarded_it(ctx, "closes: client that sends half a header block and stalls, within about 10 s", function()
    local request = expand("GET /{token}/ HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nX-Slow: 1\r\n", ctx)
    local ex = exchange(ctx.port, request, { timeout_ms = 12000 })
    check(
      ex.closed,
      string.format(
        "stalled connection still open after %d ms (deadline %d ms)",
        ex.elapsed_ms,
        http.REQUEST_TIMEOUT_MS
      )
    )
    check(ex.raw == "", "server answered a request that never completed: " .. vim.inspect(ex.raw))
  end)

  stop_it(ctx)
  cleanup_server(ctx)
end)

describe("connection limit", function()
  local ctx = start_server()

  guarded_it(ctx, "closes: connections beyond the limit without a byte, then answers once they are released", function()
    local limit = http.MAX_CONNECTIONS
    local server = ctx.session.server
    local held = {}
    for i = 1, limit do
      held[i] = open_client(ctx.port, nil, true)
    end
    wait_connected(held)
    local full = vim.wait(WAIT_MS, function()
      return server:connection_count() == limit
    end, 2)
    check(full, string.format("server registered %d of %d connections", server:connection_count(), limit))

    local extra = {}
    for i = 1, 3 do
      extra[i] = open_client(ctx.port, h.request(ctx.port, "GET", "/" .. ctx.token .. "/"), true)
    end
    wait_connected(extra)
    vim.wait(300)
    for i, c in ipairs(extra) do
      check(
        c.bytes == 0,
        string.format(
          "connection %d beyond the limit received %d bytes: %s",
          i,
          c.bytes,
          vim.inspect(c.seen:sub(1, 100))
        )
      )
    end
    check(server:connection_count() <= limit, "server holds more than the limit: " .. server:connection_count())

    close_clients(extra)
    close_clients(held)
    local released = vim.wait(WAIT_MS, function()
      return server:connection_count() == 0
    end, 5)
    check(released, "connections were not released: " .. server:connection_count())
    local res = canary(ctx)
    check(res.status == 200, "server did not answer after release: " .. vim.inspect(res.raw:sub(1, 200)))
  end)

  guarded_it(ctx, "closes: a connection beyond the limit is closed by the server (EOF, no response)", function()
    local limit = http.MAX_CONNECTIONS
    local held = {}
    for i = 1, limit do
      held[i] = open_client(ctx.port)
    end
    wait_connected(held)
    vim.wait(WAIT_MS, function()
      return ctx.session.server:connection_count() == limit
    end, 2)
    local ex = exchange(ctx.port, h.request(ctx.port, "GET", "/" .. ctx.token .. "/"), { timeout_ms = WAIT_MS })
    close_clients(held)
    check(ex.closed, "connection beyond the limit was kept open")
    check(ex.raw == "", "connection beyond the limit was answered: " .. vim.inspect(ex.raw:sub(1, 200)))
  end)

  stop_it(ctx)
  cleanup_server(ctx)
end)

http_group("host, origin and token", function()
  local cases = {}
  local routes = {
    ["page"] = { method = "GET", target = "/{token}/" },
    ["event stream"] = { method = "GET", target = "/{token}/events" },
    ["file"] = { method = "GET", target = "/{token}/file/media/pic.png" },
    ["asset"] = { method = "GET", target = "/{token}/assets/app.js" },
    ["api/open"] = { method = "POST", target = "/{token}/api/open", body = '{"path":"docs/guide.md"}' },
  }
  for route, spec in pairs(routes) do
    local function with(headers)
      return {
        method = spec.method,
        target = spec.target,
        body = spec.body,
        headers = headers,
        after = target_unchanged,
      }
    end
    cases["rejects: wrong Host on the " .. route] =
      vim.tbl_extend("force", with({ Host = "evil.example:{port}" }), { status = 403 })
    cases["rejects: Host with a different port on the " .. route] =
      vim.tbl_extend("force", with({ Host = "127.0.0.1:{other_port}" }), { status = 403 })
    cases["rejects: Host without a port on the " .. route] =
      vim.tbl_extend("force", with({ Host = "127.0.0.1" }), { status = 403 })
    cases["rejects: wrong token on the " .. route] = {
      method = spec.method,
      target = swap(spec.target, "{token}", "{wrong}"),
      body = spec.body,
      status = 403,
      body_not_has = { "{token}" },
      after = target_unchanged,
    }
    cases["rejects: token of the wrong length on the " .. route] = {
      method = spec.method,
      target = swap(spec.target, "{token}", "{short}"),
      body = spec.body,
      status = 403,
      after = target_unchanged,
    }
  end

  cases["rejects: wrong-token POST with a large Content-Length and no body (answered without waiting)"] = {
    send = raw_request("POST /{wrong}/api/open HTTP/1.1", { HOST_LINE, "Content-Length: " .. MAX_BODY }),
    status = 403,
    max_ms = 1500,
  }
  cases["rejects: wrong-token POST with a 1 GB Content-Length and no body (answered without waiting)"] = {
    send = raw_request("POST /{wrong}/api/open HTTP/1.1", { HOST_LINE, "Content-Length: 1073741824" }),
    status = 403,
    max_ms = 1500,
  }
  cases["rejects: wrong-Host POST with a large Content-Length and no body (answered without waiting)"] = {
    send = raw_request(OPEN_LINE, { "Host: evil.example", "Content-Length: " .. MAX_BODY }),
    status = 403,
    max_ms = 1500,
  }
  cases["rejects: wrong-token POST with a body is not parsed as JSON"] = {
    send = raw_request(
      "POST /{wrong}/api/open HTTP/1.1",
      { HOST_LINE, "Content-Length: 24" },
      '{"path":"docs/guide.md"}'
    ),
    status = 403,
    after = target_unchanged,
  }

  local host_rejections = {
    ["rejects: Host with a host name that only starts like this server"] = "127.0.0.1:{port}.evil.example",
    ["rejects: Host with a host name that only ends like this server"] = "evil.127.0.0.1:{port}",
    ["rejects: Host with user info before the real authority"] = "evil.example@127.0.0.1:{port}",
    ["rejects: Host with user info after the real authority"] = "127.0.0.1:{port}@evil.example",
    ["rejects: Host with a path appended"] = "127.0.0.1:{port}/evil",
    ["rejects: Host with a space and a second host"] = "127.0.0.1:{port} evil.example",
    ["rejects: empty Host"] = "",
    ["rejects: Host with a trailing dot on the name"] = "localhost.:{port}",
    ["rejects: Host with a leading zero in the port"] = "127.0.0.1:0{port}",
    ["rejects: IPv6 literal without brackets"] = "::1:{port}",
    ["rejects: IPv6 literal without a port"] = "[::1]",
    ["rejects: IPv6 literal with a different port"] = "[::1]:{other_port}",
    ["rejects: IPv6 literal of another address"] = "[::2]:{port}",
    ["rejects: IPv4-mapped IPv6 literal of the loopback address"] = "[::ffff:127.0.0.1]:{port}",
    ["rejects: decimal form of the loopback address"] = "2130706433:{port}",
    ["rejects: hexadecimal form of the loopback address"] = "0x7f000001:{port}",
    ["rejects: dotted hexadecimal form of the loopback address"] = "0x7f.0.0.1:{port}",
    ["rejects: short form of the loopback address"] = "127.1:{port}",
    ["rejects: wildcard address"] = "0.0.0.0:{port}",
    ["rejects: the name of a local machine other than localhost"] = "localhost.localdomain:{port}",
  }
  for name, host in pairs(host_rejections) do
    cases[name] = { target = "/{token}/", headers = { Host = host }, status = 403 }
  end
  cases["rejects: forwarded host header cannot override a wrong Host"] = {
    target = "/{token}/",
    headers = { Host = "evil.example:{port}", ["X-Forwarded-Host"] = "127.0.0.1:{port}" },
    status = 403,
  }
  cases["rejects: duplicate Host headers with different values"] = {
    send = raw_request("GET /{token}/ HTTP/1.1", { HOST_LINE, "Host: evil.example" }),
    status = 403,
  }
  cases["rejects: duplicate Host headers with the same value"] = {
    send = raw_request("GET /{token}/ HTTP/1.1", { HOST_LINE, HOST_LINE }),
    status = 403,
  }
  cases["accepts: IPv6 literal Host named by the protocol"] =
    { target = "/{token}/", headers = { Host = "[::1]:{port}" }, status = 200 }
  cases["accepts: localhost Host"] = { target = "/{token}/", headers = { Host = "localhost:{port}" }, status = 200 }
  cases["accepts: upper-case Host (assumed: host names are case-insensitive)"] = {
    target = "/{token}/",
    headers = { Host = "LOCALHOST:{port}" },
    status = 200,
  }

  local origin_rejections = {
    ["rejects: POST with a foreign Origin"] = "http://evil.example",
    ["rejects: POST with Origin null"] = "null",
    ["rejects: POST with an empty Origin (assumed: a present header is not an absent one)"] = "",
    ["rejects: POST with an https Origin on this host and port"] = "https://127.0.0.1:{port}",
    ["rejects: POST with this host and another port as Origin"] = "http://127.0.0.1:{other_port}",
    ["rejects: POST with an Origin without a port"] = "http://127.0.0.1",
    ["rejects: POST with an Origin that only starts like this server"] = "http://127.0.0.1:{port}.evil.example",
    ["rejects: POST with user info in the Origin"] = "http://evil.example@127.0.0.1:{port}",
    ["rejects: POST with a file Origin"] = "file://",
    ["rejects: POST with an extension Origin"] = "chrome-extension://abcdefghijklmnop",
    ["rejects: POST with two Origins, one of them this server"] = "http://127.0.0.1:{port}, http://evil.example",
  }
  for name, origin in pairs(origin_rejections) do
    cases[name] = json_open('{"path":"docs/guide.md"}', 403, { headers = { Origin = origin } })
  end
  cases["rejects: cross-site form post with text/plain and a foreign Origin"] =
    json_open('{"path":"docs/guide.md"}', 403, {
      headers = { Origin = "http://evil.example", ["Content-Type"] = "text/plain" },
    })

  local token_rejections = {
    ["rejects: token only in the query string of the root"] = "/?token={token}",
    ["rejects: token only in the query string of a wrong path"] = "/x/?token={token}",
    ["rejects: token only in the query string of the event stream"] = "/events?token={token}",
    ["rejects: token only in the query string of a file"] = "/file/media/pic.png?token={token}",
    ["rejects: empty first segment"] = "//{token}/",
    ["rejects: empty first segment on a file"] = "//{token}/file/media/pic.png",
    ["rejects: root without a token"] = "/",
    ["rejects: favicon without a token"] = "/favicon.ico",
    ["rejects: token as the second segment"] = "/x/{token}/",
    ["rejects: token followed by extra characters"] = "/{token}x/",
    ["rejects: token preceded by extra characters"] = "/x{token}/",
    ["rejects: token longer by one character"] = "/{long}/",
    ["rejects: token shorter by one character"] = "/{short}/",
    ["rejects: upper-case token"] = "/{upper}/",
    ["rejects: token with a percent-encoded first character"] = "/{token_pct}/",
    ["rejects: token followed by an encoded slash"] = "/{token}%2f",
    ["rejects: token followed by an encoded slash and a route"] = "/{token}%2fevents",
  }
  for name, target in pairs(token_rejections) do
    cases[name] = { target = target, status = 403, body_not_has = { "{token}" } }
  end

  local not_a_route = {
    ["rejects: token followed by // (assumed: 403 or 404, never the page)"] = "/{token}//",
    ["rejects: token followed by // and the event route"] = "/{token}//events",
    ["rejects: token followed by // and a file"] = "/{token}//file/media/pic.png",
    ["rejects: dot segment after the token"] = "/{token}/./",
    ["rejects: event route with a trailing slash"] = "/{token}/events/",
    ["rejects: unknown route under the token"] = "/{token}/nothing-here",
  }
  for name, target in pairs(not_a_route) do
    cases[name] = { target = target, status = { 403, 404 }, body_not_has = { "mp-bootstrap", "PNG" } }
  end
  cases["redirects: token without the trailing slash goes to the slash form"] = {
    target = "/{token}",
    status = 301,
    expect_headers = { location = "/{token}/" },
  }
  cases["redirects: token with a query string and no slash goes to the slash form"] = {
    target = "/{token}?x=1",
    status = 301,
    expect_headers = { location = "/{token}/" },
  }
  return cases
end)

describe("api/open accepts only same-origin requests", function()
  local ctx = start_server()
  local cases = {
    ["accepts: POST without Origin"] = {},
    ["accepts: POST from this origin by address"] = { Origin = "http://127.0.0.1:{port}" },
    ["accepts: POST from this origin by name"] = { Origin = "http://localhost:{port}" },
    ["accepts: POST from this origin by IPv6 literal"] = { Origin = "http://[::1]:{port}" },
  }
  each_case(ctx, cases, function(c, headers)
    run_http(c, json_open(README_BODY, 204, { headers = headers }))
  end)

  guarded_it(ctx, "accepts: switching to another Markdown file changes the target and nothing else", function()
    run_http(ctx, { method = "POST", target = "/{token}/api/open", body = '{"path":"docs/guide.md"}', status = 204 })
    check(ctx.session.target.rel == "docs/guide.md", "target is " .. tostring(ctx.session.target.rel))
    run_http(ctx, { method = "POST", target = "/{token}/api/open", body = README_BODY, status = 204 })
    check(ctx.session.target.rel == "README.md", "target is " .. tostring(ctx.session.target.rel))
  end)

  stop_it(ctx)
  cleanup_server(ctx)
end)

http_group("file/ route", function()
  local base = "/{token}/file/"
  -- { path after file/, expected status }
  local rejected = {
    -- Traversal, encoded in every way a client or a proxy might. A segment starting with a dot is refused.
    ["rejects: .. segments leaving the root"] = { "../outside/secret.png", 403 },
    ["rejects: .. segments after a directory"] = { "docs/../../outside/secret.png", 403 },
    ["rejects: .. segments that stay inside the root (assumed: any dot segment is refused)"] = {
      "docs/../media/pic.png",
      403,
    },
    ["rejects: lone .. as the whole path"] = { "..", 403 },
    ["rejects: .. with a trailing slash"] = { "../", 403 },
    ["rejects: %2e%2e segments"] = { "%2e%2e/outside/secret.png", 403 },
    ["rejects: %2E%2E segments in upper case"] = { "%2E%2E/outside/secret.png", 403 },
    ["rejects: half-encoded .%2e segments"] = { ".%2e/outside/secret.png", 403 },
    ["rejects: half-encoded %2e. segments"] = { "%2e./outside/secret.png", 403 },
    ["rejects: encoded slash between .. and the rest"] = { "..%2foutside%2fsecret.png", 403 },
    ["rejects: encoded slash in upper case"] = { "..%2Foutside%2Fsecret.png", 403 },
    ["rejects: encoded slashes after a directory"] = { "docs/..%2f..%2foutside/secret.png", 403 },
    ["rejects: 3000 .. segments (long traversal)"] = { string.rep("../", 3000) .. "outside/secret.png", 403 },
    ["rejects: double-encoded %252e%252e (decoded once, a literal name that does not exist)"] = {
      "%252e%252e/outside/secret.png",
      404,
    },
    ["rejects: double-encoded slash %252f behind a leading dot segment"] = { "..%252foutside%252fsecret.png", 403 },
    ["rejects: backslash separators encoded behind a leading dot segment (assumed: 400 or 403)"] = {
      "..%5coutside%5csecret.png",
      { 400, 403 },
    },
    ["rejects: backslash separators raw behind a leading dot segment (assumed: 400 or 403)"] = {
      "..\\outside\\secret.png",
      { 400, 403 },
    },
    ["rejects: backslash in the name of an existing media file"] = { "media%5cpic.png", 400 },
    ["rejects: NUL byte encoded inside a media name"] = { "media/pic%00.png", 400 },
    ["rejects: NUL byte encoded after a valid name (truncation attempt)"] = { "README.md%00.png", 400 },
    ["rejects: NUL byte encoded after the extension (assumed: 400 or 403)"] = { "media/pic.png%00", { 400, 403 } },
    ["rejects: NUL byte encoded alone (assumed: 400 or 403)"] = { "%00", { 400, 403 } },
    ["rejects: line feed encoded in the name"] = { "media/pic%0a.png", 400 },
    ["rejects: header injection through %0d%0a"] = { "media/pic%0d%0aSet-Cookie:%20a=b.png", 400 },
    ["rejects: control character 0x1f"] = { "media/pic%1f.png", 400 },
    ["rejects: DEL character"] = { "media/pic%7f.png", 400 },
    ["rejects: absolute path after the prefix"] = { "/outside/secret.png", 403 },
    ["rejects: absolute path of the real outside file"] = { "{outside}/secret.png", 403 },
    ["rejects: encoded leading slash"] = { "%2foutside/secret.png", 403 },
    ["rejects: encoded absolute path without a media extension"] = { "%2fetc%2fpasswd", 403 },
    ["rejects: two encoded leading slashes"] = { "%2f%2fetc/passwd.png", 403 },
    -- Not a regular media file.
    ["rejects: empty path (the root directory)"] = { "", 403 },
    ["rejects: dot path (the root directory)"] = { ".", 403 },
    ["rejects: directory"] = { "docs", 403 },
    ["rejects: directory with a trailing slash"] = { "docs/", 403 },
    ["rejects: directory named like an image"] = { "media/dir.png", 404 },
    ["rejects: directory named like an image with a trailing slash (assumed: 403 or 404)"] = {
      "media/dir.png/",
      { 403, 404 },
    },
    ["rejects: media file with a trailing slash (assumed: 403 or 404)"] = { "media/pic.png/", { 403, 404 } },
    ["rejects: missing media file"] = { "missing.png", 404 },
    -- Symlinks.
    ["rejects: file below a symlink to a directory outside the root"] = { "escape/secret.png", 403 },
    ["rejects: symlink to a directory outside the root, named like an image"] = { "escape-dir.png", 403 },
    ["rejects: symlink to a directory outside the root, without a media extension"] = { "escape", 403 },
    ["rejects: missing file below a symlink to a directory outside the root (no existence oracle)"] = {
      "escape/missing.png",
      403,
    },
    ["rejects: symlink to a file outside the root"] = { "leak.png", 403 },
    ["rejects: chain of symlinks ending outside the root"] = { "chain-a.png", 403 },
    ["rejects: symlink to a directory whose name only starts like the root"] = { "sibling/secret.png", 403 },
    ["rejects: missing file below a symlink to an absolute system directory"] = { "etc-link/passwd.png", 403 },
    ["rejects: symlink loop"] = { "loop-a.png", 404 },
    ["rejects: dangling symlink to a missing file outside the root (assumed: 403 or 404)"] = {
      "dangling-out.png",
      { 403, 404 },
    },
    -- Broken and unusual encodings.
    ["rejects: invalid percent escape %zz"] = { "media/pic.png%zz", 400 },
    ["rejects: percent sign alone at the end"] = { "media/pic.png%", 400 },
    ["rejects: truncated percent escape at the end"] = { "media/pic.png%2", 400 },
    ["rejects: percent followed by one hex digit and a non-hex"] = { "media/pic.png%2g", 400 },
    ["rejects: percent followed by a percent"] = { "%%41", 400 },
    ["rejects: invalid percent escape in front of a refused extension (decoded first)"] = { "script.js%zz", 400 },
    ["rejects: overlong UTF-8 encoding of .. (never a traversal)"] = {
      "%c0%ae%c0%ae/outside/secret.png",
      { 400, 403, 404 },
    },
    ["rejects: overlong UTF-8 encoding of / (never a traversal)"] = {
      "..%c0%afoutside%c0%afsecret.png",
      { 400, 403, 404 },
    },
    ["rejects: three-byte overlong encoding of . (never a traversal)"] = {
      "%e0%80%ae%e0%80%ae/outside/secret.png",
      { 400, 403, 404 },
    },
    ["rejects: four-byte overlong encoding of . (never a traversal)"] = {
      "%f0%80%80%ae%f0%80%80%ae/outside/secret.png",
      { 400, 403, 404 },
    },
    ["rejects: raw invalid UTF-8 bytes in the target (never a traversal)"] = {
      "\xc0\xae\xc0\xae/outside/secret.png",
      { 400, 403, 404 },
    },
    ["rejects: file name of 300 characters"] = { string.rep("a", 300) .. ".png", 404 },
    ["rejects: 5000 missing directories deep (long path)"] = { string.rep("a/", 5000) .. "x.png", 404 },
    -- Only media is served.
    ["rejects: JavaScript file"] = { "script.js", 403 },
    ["rejects: JavaScript module file"] = { "module.mjs", 403 },
    ["rejects: HTML file"] = { "evil.html", 403 },
    ["rejects: Markdown file"] = { "README.md", 403 },
    ["rejects: text file"] = { "docs/notes.txt", 403 },
    ["rejects: dotfile with credentials"] = { ".env", 403 },
    ["rejects: file below .git"] = { ".git/config", 403 },
    ["rejects: media file below a hidden directory"] = { "sub/.hidden/a.png", 403 },
    ["rejects: hidden media file name"] = { "media/.pic.png", 403 },
    ["rejects: .well-known directory"] = { ".well-known/x.png", 403 },
    ["rejects: missing JavaScript file (refused before the lookup)"] = { "missing.js", 403 },
    ["rejects: missing HTML file (refused before the lookup)"] = { "missing.html", 403 },
    ["rejects: JavaScript extension in upper case"] = { "script.JS", 403 },
    ["rejects: media extension followed by a script extension"] = { "media/pic.png.js", 403 },
    ["rejects: no extension at all"] = { "media/pic", 403 },
    -- Environment variables must not be expanded in request paths; the fixtures exist only if they are.
    ["rejects: $HOME is looked up literally (the mirror of $HOME inside the root exists)"] = { "$HOME/x.png", 404 },
    ["rejects: encoded $HOME is looked up literally"] = { "%24HOME/x.png", 404 },
    ["rejects: encoded $HOME alone has no media extension"] = { "%24HOME", 403 },
    ["rejects: custom variable naming an existing image ($MP_SPEC_VAR=media/pic)"] = { "$MP_SPEC_VAR.png", 404 },
    ["rejects: encoded custom variable naming an existing image"] = { "%24MP_SPEC_VAR.png", 404 },
    ["rejects: custom variable expanding to .. (looked up literally)"] = { "$MP_SPEC_UP/outside/secret.png", 404 },
  }
  local cases = {}
  for name, spec in pairs(rejected) do
    cases[name] = {
      target = base .. spec[1],
      status = spec[2],
      body_not_has = {
        "# Readme",
        "guide body",
        "home mirror",
        "fake image",
        "alert(",
        "<script",
        "repositoryformatversion",
        "hidden image",
      },
    }
  end
  cases["accepts: plain media file"] = { target = base .. "media/pic.png", status = 200, body_is = pic_body }
  cases["accepts: media file with its mime type"] = {
    target = base .. "media/pic.png",
    status = 200,
    expect_headers = { ["content-type"] = "image/png" },
  }
  cases["accepts: video file"] = { target = base .. "media/blob.mp4", status = 200, body_is = blob_body }
  cases["accepts: percent-encoded separator inside the root"] =
    { target = base .. "media%2Fpic.png", status = 200, body_is = pic_body }
  cases["accepts: symlink that stays inside the root"] =
    { target = base .. "inside-link.png", status = 200, body_is = pic_body }
  cases["accepts: query string is ignored for the file lookup"] = {
    target = base .. "media/pic.png?x=../../outside/secret.png",
    status = 200,
    body_is = pic_body,
  }
  cases["accepts: SVG is served with the sandbox policy"] = {
    target = base .. "evil.svg",
    status = 200,
    expect_headers = { ["content-type"] = "image/svg+xml" },
  }
  return cases
end)

http_group("assets/ route", function()
  local base = "/{token}/assets/"
  local rejected = {
    ["rejects: .. into the sibling repository directory"] = { "../repo/README.md", 403 },
    ["rejects: .. into the outside directory"] = { "../outside/secret.txt", 403 },
    ["rejects: %2e%2e into the sibling repository directory"] = { "%2e%2e/repo/README.md", 403 },
    ["rejects: %2E%2E segments in upper case"] = { "%2E%2E/outside/secret.txt", 403 },
    ["rejects: encoded slashes after .."] = { "..%2f..%2foutside%2fsecret.txt", 403 },
    ["rejects: double-encoded %252e%252e (decoded once, a literal name that does not exist)"] = {
      "%252e%252e/outside/secret.txt",
      404,
    },
    ["rejects: backslash separators"] = { "..%5couter%5csecret.txt", 400 },
    ["rejects: NUL byte after a valid name"] = { "app.js%00.png", 400 },
    ["rejects: absolute path after the prefix"] = { "/outside/secret.txt", 403 },
    ["rejects: encoded absolute path"] = { "%2fetc%2fpasswd", 403 },
    ["rejects: empty path (the web directory)"] = { "", 404 },
    ["rejects: file with a trailing slash (assumed: a file is not a directory)"] = { "app.js/", 404 },
    ["rejects: symlink to a file outside the web directory"] = { "leak.txt", 403 },
    ["rejects: file below a symlink to a directory outside the web directory"] = { "linkdir/secret.txt", 403 },
    ["rejects: missing file below a symlink to a directory outside the web directory"] = { "linkdir/missing.txt", 403 },
    ["rejects: invalid percent escape %zz"] = { "app.js%zz", 400 },
    ["rejects: overlong UTF-8 encoding of .. (never a traversal)"] = {
      "%c0%ae%c0%ae/outside/secret.txt",
      { 400, 404 },
    },
    ["rejects: 3000 .. segments (long traversal)"] = { string.rep("../", 3000) .. "outside/secret.txt", 403 },
    ["rejects: file name of 300 characters"] = { string.rep("a", 300), 404 },
    ["rejects: $HOME is looked up literally"] = { "$HOME/app.js", 404 },
  }
  local cases = {}
  for name, spec in pairs(rejected) do
    cases[name] = {
      target = base .. spec[1],
      status = spec[2],
      body_not_has = { "console.log", "# Readme" },
    }
  end
  cases["accepts: stand-in asset"] = { target = base .. "app.js", status = 200, body_is = "console.log('stand-in');\n" }
  return cases
end)

http_group("range requests", function()
  local target = "/{token}/file/media/blob.mp4"
  local function slice(first, last)
    return function(ctx)
      return ctx.tree.blob_content:sub(first + 1, last + 1)
    end
  end
  local function ranged(value, spec)
    return vim.tbl_extend("force", { target = target, headers = { Range = value } }, spec)
  end
  local function partial(value, first, last)
    return ranged(value, {
      status = 206,
      body_is = slice(first, last),
      expect_headers = { ["content-range"] = string.format("bytes %d-%d/1000", first, last) },
    })
  end
  local function full(value)
    return ranged(value, { status = 200, body_is = blob_body, expect_headers = { ["content-range"] = false } })
  end
  local function unsatisfiable(value, size)
    return ranged(value, { status = 416, expect_headers = { ["content-range"] = "bytes */" .. size } })
  end

  local cases = {
    ["accepts: single range of ten bytes"] = partial("bytes=0-9", 0, 9),
    ["accepts: open-ended range"] = partial("bytes=990-", 990, 999),
    ["accepts: suffix range"] = partial("bytes=-10", 990, 999),
    ["accepts: suffix range longer than the file (whole file as 206)"] = partial("bytes=-5000", 0, 999),
    ["accepts: suffix range of 20 digits (whole file as 206)"] = partial("bytes=-99999999999999999999", 0, 999),
    ["accepts: end beyond the file is clamped"] = partial("bytes=0-99999", 0, 999),
    ["accepts: end of 20 digits is clamped"] = partial("bytes=0-99999999999999999999", 0, 999),
    ["accepts: last byte only"] = partial("bytes=999-999", 999, 999),
    ["accepts: spaces around the equals sign and the spec"] = partial("bytes = 0-9 ", 0, 9),
    ["rejects: multiple ranges (assumed: ignored, whole file, no multipart)"] = full("bytes=0-1,5-6"),
    ["rejects: 3000 tiny ranges (no response amplification)"] = full("bytes=" .. string.rep("0-0,", 3000)),
    ["rejects: reversed range (invalid spec, ignored)"] = full("bytes=5-2"),
    ["rejects: unit other than bytes"] = full("items=0-5"),
    ["rejects: garbage after the unit"] = full("bytes=abc"),
    ["rejects: empty range spec"] = full("bytes="),
    ["rejects: lone dash"] = full("bytes=-"),
    ["rejects: double dash"] = full("bytes=--5"),
    ["rejects: three-part range"] = full("bytes=1-2-3"),
    ["rejects: trailing garbage after the end"] = full("bytes=0-1x"),
    ["rejects: spaces around the dash"] = full("bytes=1 - 2"),
    ["rejects: no unit"] = full("0-5"),
    ["rejects: unit without a value"] = full("bytes"),
    ["rejects: double equals sign"] = full("bytes==0-5"),
    ["rejects: negative suffix with a dash"] = full("bytes=-1-"),
    ["rejects: start beyond the end of the file with 416"] = unsatisfiable("bytes=1000-", 1000),
    ["rejects: start and end beyond the end of the file with 416"] = unsatisfiable("bytes=1000-2000", 1000),
    ["rejects: start far beyond the end of the file with 416"] = unsatisfiable("bytes=5000-", 1000),
    ["rejects: start of 20 digits with 416"] = unsatisfiable("bytes=99999999999999999999-", 1000),
    ["rejects: zero-length suffix with 416"] = unsatisfiable("bytes=-0", 1000),
  }
  cases["rejects: two Range headers (joined, therefore a multiple range, ignored)"] = {
    send = raw_request("GET " .. target .. " HTTP/1.1", { HOST_LINE, "Range: bytes=0-1", "Range: bytes=2-3" }),
    status = 200,
    body_is = blob_body,
  }
  cases["accepts: no Range header gives the whole file"] =
    { target = target, status = 200, body_is = blob_body, expect_headers = { ["accept-ranges"] = "bytes" } }
  local empty = "/{token}/file/media/empty.mp4"
  cases["rejects: any range on an empty file with 416 (open-ended)"] = {
    target = empty,
    headers = { Range = "bytes=0-" },
    status = 416,
    expect_headers = { ["content-range"] = "bytes */0" },
  }
  cases["rejects: any range on an empty file with 416 (suffix)"] = {
    target = empty,
    headers = { Range = "bytes=-5" },
    status = 416,
    expect_headers = { ["content-range"] = "bytes */0" },
  }
  cases["accepts: empty file without Range"] = { target = empty, status = 200, body_is = "" }
  return cases
end)

http_group("api/open input", function()
  local function over_limit()
    return '{"path":"' .. string.rep("a", MAX_BODY) .. '.md"}'
  end
  local cases = {
    ["rejects: body that is not JSON"] = json_open("not json", 400, { body_has = { "JSON body" } }),
    ["rejects: empty body"] = json_open("", 400),
    ["rejects: truncated JSON"] = json_open('{"path":', 400),
    ["rejects: JSON with single quotes"] = json_open("{'path': 'README.md'}", 400),
    ["rejects: JSON with a NaN value"] = json_open('{"path": NaN}', 400),
    ["rejects: JSON array"] = json_open("[]", 400),
    ["rejects: JSON array holding the path"] = json_open('["README.md"]', 400),
    ["rejects: JSON string"] = json_open('"README.md"', 400),
    ["rejects: JSON number"] = json_open("42", 400),
    ["rejects: JSON true"] = json_open("true", 400),
    ["rejects: JSON null"] = json_open("null", 400),
    ["rejects: object without a path"] = json_open("{}", 400),
    ["rejects: path with a different key case"] = json_open('{"Path":"README.md"}', 400),
    ["rejects: path that is a number"] = json_open('{"path":5}', 400),
    ["rejects: path that is null"] = json_open('{"path":null}', 400),
    ["rejects: path that is true"] = json_open('{"path":true}', 400),
    ["rejects: path that is an array"] = json_open('{"path":["README.md"]}', 400),
    ["rejects: path that is an object"] = json_open('{"path":{"a":1}}', 400),
    ["rejects: empty path"] = json_open('{"path":""}', 400),
    ["rejects: 10000 nested arrays under the body limit"] = json_open(string.rep("[", 10000), 400),
    ["rejects: 200000 nested arrays over the body limit"] = json_open(string.rep("[", 200000), 413),
    ["rejects: path that pushes the body over the limit"] = json_open(over_limit, 413),
    ["rejects: NUL byte escaped in the path"] = json_open([[{"path":"a\u0000b.md"}]], 400),
    ["rejects: NUL byte escaped after a valid name"] = json_open([[{"path":"README.md\u0000.txt"}]], 400),
    ["rejects: backslash in the path"] = json_open([[{"path":"..\\outside\\outside.md"}]], 400),
    ["rejects: path leaving the root with .."] = json_open('{"path":"../outside/outside.md"}', 403),
    ["rejects: path leaving the root after a directory"] = json_open('{"path":"docs/../../outside/outside.md"}', 403),
    ["rejects: absolute path"] = json_open('{"path":"/etc/passwd.md"}', 403),
    ["rejects: absolute path of the real outside file"] = json_open(function(ctx)
      return vim.json.encode({ path = ctx.tree.outside .. "/outside.md" })
    end, 403),
    ["rejects: path below a symlink to a directory outside the root"] = json_open('{"path":"escape/outside.md"}', 403),
    ["rejects: Markdown symlink to a file outside the root"] = json_open('{"path":"escape.md"}', 403),
    ["rejects: outside path is refused before the extension is judged"] = json_open(
      '{"path":"../outside/secret.txt"}',
      403
    ),
    ["rejects: missing Markdown file"] = json_open('{"path":"missing.md"}', 404),
    ["rejects: missing file is reported before the extension is judged"] = json_open('{"path":"missing.txt"}', 404),
    ["rejects: directory"] = json_open('{"path":"docs"}', 404),
    ["rejects: directory with a trailing slash"] = json_open('{"path":"docs/"}', 404),
    ["rejects: root directory"] = json_open('{"path":"."}', 404),
    ["rejects: path with percent escapes (the JSON string is not decoded again)"] = json_open(
      '{"path":"docs%2Fguide.md"}',
      404
    ),
    ["rejects: encoded traversal (the JSON string is not decoded again)"] = json_open(
      '{"path":"%2e%2e/outside/outside.md"}',
      404
    ),
    ["rejects: environment variable naming an existing file ($MP_SPEC_VAR=media/pic)"] = json_open(
      '{"path":"$MP_SPEC_VAR.md"}',
      404
    ),
    ["rejects: $HOME is looked up literally"] = json_open('{"path":"$HOME/missing.md"}', 404),
    ["rejects: text file"] = json_open('{"path":"docs/notes.txt"}', 415),
    ["rejects: binary file"] = json_open('{"path":"media/blob.mp4"}', 415),
    ["rejects: HTML file"] = json_open('{"path":"evil.html"}', 415),
    ["rejects: GET to the route with 405 and Allow"] = {
      target = "/{token}/api/open",
      status = 405,
      expect_headers = { allow = "POST" },
    },
    ["rejects: POST without a body"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE }),
      status = 400,
      after = target_unchanged,
    },
    ["rejects: POST to the route with a trailing slash (assumed: 404 or 405, the route does not exist)"] = json_open(
      README_BODY,
      { 404, 405 },
      { target = "/{token}/api/open/" }
    ),
    ["rejects: POST to the page"] = json_open(
      README_BODY,
      405,
      { target = "/{token}/", expect_headers = { allow = "GET" } }
    ),
    ["rejects: POST to the event stream"] = json_open(
      README_BODY,
      405,
      { target = "/{token}/events", expect_headers = { allow = "GET" } }
    ),
    ["rejects: POST to a file"] = json_open(
      README_BODY,
      405,
      { target = "/{token}/file/media/pic.png", expect_headers = { allow = "GET" } }
    ),
  }
  for _, method in ipairs({ "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS" }) do
    cases["rejects: " .. method .. " to the route with 405 and Allow"] = {
      method = method,
      target = "/{token}/api/open",
      status = 405,
      expect_headers = { allow = "POST" },
    }
  end
  return cases
end)

http_group("response headers per response class", function()
  local function sandbox_csp(value)
    if value == nil then
      return false, "missing"
    end
    local ok = value:find("^sandbox;") ~= nil
      and value:find("default-src 'none'", 1, true) ~= nil
      and value:find("script-src", 1, true) == nil
    return ok, "file/ responses need a sandbox policy without script-src"
  end

  --- Policy of the HTML response for a request carrying `host`.
  local function page_csp(host)
    return function(value, ctx)
      if value == nil then
        return false, "missing"
      end
      local script_src = value:match("script%-src ([^;]*)") or ""
      local assets = "http://" .. expand(host, ctx) .. "/" .. ctx.token .. "/assets/"
      if script_src:find("'self'", 1, true) then
        return false, "script-src still allows 'self'"
      end
      if not script_src:find(assets, 1, true) then
        return false, "script-src does not name " .. assets
      end
      if script_src:find("'unsafe-inline'", 1, true) or script_src:find("'unsafe-eval'", 1, true) then
        return false, "script-src allows inline or eval"
      end
      if script_src:find("evil", 1, true) then
        return false, "script-src names a foreign host"
      end
      for _, directive in ipairs({ "default-src 'none'", "base-uri 'none'", "form-action 'none'" }) do
        if not value:find(directive, 1, true) then
          return false, "policy lacks " .. directive
        end
      end
      return true
    end
  end
  local hostile = { Origin = "http://evil.example", ["Access-Control-Request-Method"] = "POST" }
  local cases = {
    ["200 page names the assets path in script-src and has no 'self' there"] = {
      target = "/{token}/",
      status = 200,
      expect_headers = {
        ["content-security-policy"] = page_csp("127.0.0.1:{port}"),
        ["referrer-policy"] = "no-referrer",
        ["content-type"] = "text/html; charset=utf-8",
      },
    },
    ["200 page for a localhost Host names that host in script-src"] = {
      target = "/{token}/",
      headers = { Host = "localhost:{port}" },
      status = 200,
      expect_headers = { ["content-security-policy"] = page_csp("localhost:{port}") },
    },
    ["200 page for an upper-case Host names the lower-case host in script-src"] = {
      target = "/{token}/",
      headers = { Host = "LOCALHOST:{port}" },
      status = 200,
      expect_headers = { ["content-security-policy"] = page_csp("localhost:{port}") },
    },
    ["200 page for an IPv6 literal Host names that literal in script-src"] = {
      target = "/{token}/",
      headers = { Host = "[::1]:{port}" },
      status = 200,
      expect_headers = { ["content-security-policy"] = page_csp("[::1]:{port}") },
    },
    ["200 page requested with a foreign Origin"] = { target = "/{token}/", headers = hostile, status = 200 },
    ["200 asset"] = { target = "/{token}/assets/app.js", status = 200 },
    ["200 file (image)"] = {
      target = "/{token}/file/media/pic.png",
      status = 200,
      expect_headers = { ["content-security-policy"] = sandbox_csp },
    },
    ["200 file (SVG is sandboxed)"] = {
      target = "/{token}/file/evil.svg",
      status = 200,
      expect_headers = { ["content-security-policy"] = sandbox_csp, ["content-type"] = "image/svg+xml" },
    },
    ["200 file requested with a foreign Origin"] = {
      target = "/{token}/file/media/pic.png",
      headers = hostile,
      status = 200,
    },
    ["206 partial file"] = {
      target = "/{token}/file/media/blob.mp4",
      headers = { Range = "bytes=0-9" },
      status = 206,
      expect_headers = { ["content-security-policy"] = sandbox_csp },
    },
    ["204 api/open"] = { method = "POST", target = "/{token}/api/open", body = README_BODY, status = 204 },
    ["301 token without the trailing slash"] = { target = "/{token}", status = 301 },
    ["400 invalid JSON"] = json_open("nope", 400),
    ["400 malformed request line"] = { send = "GARBAGE\r\n\r\n", status = 400 },
    ["403 wrong token"] = { target = "/{wrong}/", status = 403 },
    ["403 wrong Host"] = { target = "/{token}/", headers = { Host = "evil.example" }, status = 403 },
    ["403 foreign Origin"] = json_open(README_BODY, 403, { headers = { Origin = "http://evil.example" } }),
    ["403 file outside the root"] = { target = "/{token}/file/../outside/secret.png", status = 403 },
    ["403 file with a refused extension"] = { target = "/{token}/file/script.js", status = 403 },
    ["404 missing file"] = { target = "/{token}/file/missing.png", status = 404 },
    ["404 unknown route"] = { target = "/{token}/nothing", status = 404 },
    ["405 wrong method"] = { method = "DELETE", target = "/{token}/", status = 405 },
    ["405 CORS preflight on api/open"] = {
      method = "OPTIONS",
      target = "/{token}/api/open",
      headers = hostile,
      status = 405,
    },
    ["405 CORS preflight on a file"] = {
      method = "OPTIONS",
      target = "/{token}/file/media/pic.png",
      headers = hostile,
      status = 405,
    },
    ["403 CORS preflight with a foreign Host"] = {
      method = "OPTIONS",
      target = "/{token}/api/open",
      headers = vim.tbl_extend("force", hostile, { Host = "evil.example" }),
      status = 403,
    },
    ["413 body over the limit"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Content-Length: 2000000" }),
      status = 413,
    },
    ["415 non-Markdown file"] = json_open('{"path":"docs/notes.txt"}', 415),
    ["416 unsatisfiable range"] = {
      target = "/{token}/file/media/blob.mp4",
      headers = { Range = "bytes=5000-" },
      status = 416,
      expect_headers = { ["content-security-policy"] = sandbox_csp },
    },
    ["431 header block over 16 kB"] = {
      send = "GET / HTTP/1.1\r\nX: " .. string.rep("a", 20000) .. "\r\n\r\n",
      status = 431,
    },
    ["501 Transfer-Encoding"] = {
      send = raw_request(OPEN_LINE, { HOST_LINE, "Transfer-Encoding: chunked" }),
      status = 501,
    },
    ["505 HTTP/2.0"] = { send = raw_request("GET /{token}/ HTTP/2.0", { HOST_LINE }), status = 505 },
  }
  return cases
end)

describe("event stream", function()
  local ctx = start_server()
  local get_events = raw_request(expand(EVENTS_LINE, ctx), { "Host: 127.0.0.1:" .. ctx.port })
  local cap = sse_mod.MAX_CLIENTS

  guarded_it(ctx, "sends text/event-stream, nosniff, no-store and no CORS header", function()
    local s = h.events(ctx.port, "/" .. ctx.token .. "/events")
    local init = s.wait_for("init", 1, WAIT_MS)
    check(init ~= nil, "no init event" .. s.describe())
    local headers = s.head.headers
    s.close()
    check(s.head.status == 200, "status " .. tostring(s.head.status))
    check(headers["content-type"]:find("^text/event%-stream"), "content-type " .. tostring(headers["content-type"]))
    check(headers["x-content-type-options"] == "nosniff", "nosniff is missing")
    check(headers["cache-control"] == "no-store", "no-store is missing")
    for name in pairs(headers) do
      check(not name:find("^access%-control%-"), "event stream carries " .. name)
    end
  end)

  guarded_it(
    ctx,
    "rejects: a client beyond the limit gets 503 with the hardening headers; a freed slot is reusable",
    function()
      local streams = {}
      for i = 1, cap do
        streams[i] = h.events(ctx.port, "/" .. ctx.token .. "/events")
        check(
          streams[i].wait_for("init", 1, WAIT_MS) ~= nil,
          "stream " .. i .. " got no init event" .. streams[i].describe()
        )
      end
      check(
        ctx.session.sse:count() == cap,
        "server registered " .. ctx.session.sse:count() .. " of " .. cap .. " streams"
      )

      local ex = exchange(ctx.port, get_events)
      local res = h.parse(ex.raw)
      local function why(msg)
        return msg .. "\n--- raw response ---\n" .. vim.inspect(ex.raw:sub(1, 500))
      end
      check_hygiene(res, why)
      check(res.status == 503, why("stream number " .. (cap + 1) .. " expected 503, got " .. tostring(res.status)))
      check(res.body:find("too many", 1, true), why("503 body does not explain the limit"))
      check(ctx.session.sse:count() == cap, "the refused client was registered: " .. ctx.session.sse:count())

      streams[1].close()
      local freed = vim.wait(WAIT_MS, function()
        return ctx.session.sse:count() == cap - 1
      end, 2)
      check(freed, "closing a stream did not free its slot: " .. ctx.session.sse:count())
      local again = h.events(ctx.port, "/" .. ctx.token .. "/events")
      local init = again.wait_for("init", 1, WAIT_MS)
      again.close()
      for i = 2, cap do
        streams[i].close()
      end
      check(init ~= nil, "a client was refused although a slot was free" .. again.describe())
    end
  )

  guarded_it(
    ctx,
    "drops: a client that stops reading once its write queue passes the limit; a reading client stays",
    function()
      with_field(sse_mod, "MAX_QUEUE_BYTES", 64 * 1024, function()
        local reader = open_client(ctx.port, get_events, true)
        local stalled = open_client(ctx.port, get_events, false)
        wait_connected({ reader, stalled })
        local both = vim.wait(WAIT_MS, function()
          return ctx.session.sse:count() == 2
        end, 2)
        check(both, "server registered " .. ctx.session.sse:count() .. " of 2 stream clients")

        local comment = ": " .. string.rep("x", 256 * 1024) .. "\n\n"
        local sent = 0
        local dropped = vim.wait(20000, function()
          ctx.session.sse:send_raw(comment)
          sent = sent + 1
          return ctx.session.sse:count() == 1
        end, 20)
        local reader_bytes = reader.bytes
        close_clients({ reader, stalled })
        check(dropped, string.format("stalled client was not dropped after %d x 256 kB of output", sent))
        check(reader_bytes > 0, "the reading client received nothing")
      end)
      local released = vim.wait(WAIT_MS, function()
        return ctx.session.sse:count() == 0
      end, 5)
      check(released, "stream clients remain registered: " .. ctx.session.sse:count())
    end
  )

  local modes = {
    ["drops: reset after the init event was read"] = { read = true, reset = true },
    ["drops: FIN after the init event was read"] = { read = true, reset = false },
    ["drops: reset by clients that never read"] = { read = false, reset = true, registered = true },
    ["drops: reset immediately after the request without reading"] = { read = false, reset = true },
    ["drops: reset right after connecting"] = { connect_only = true, reset = true },
    ["drops: reset in the middle of the request line"] = { partial = true, reset = true },
  }
  each_case(ctx, modes, function(c, mode)
    local clients = {}
    for i = 1, cap do
      if mode.connect_only then
        clients[i] = open_client(c.port)
      elseif mode.partial then
        clients[i] = open_client(c.port, get_events:sub(1, 20))
      else
        clients[i] = open_client(c.port, get_events, mode.read)
      end
    end
    wait_connected(clients)
    local sse = c.session.sse
    if mode.read then
      local ok = vim.wait(WAIT_MS, function()
        for _, cl in ipairs(clients) do
          if not cl.seen:find("event: init", 1, true) then
            return false
          end
        end
        return true
      end, 2)
      check(ok, "not every client received the init event")
      check(sse:count() == cap, "server registered " .. sse:count() .. " of " .. cap .. " stream clients")
    elseif mode.registered then
      local ok = vim.wait(WAIT_MS, function()
        return sse:count() == cap
      end, 2)
      check(ok, "server registered " .. sse:count() .. " of " .. cap .. " stream clients")
    else
      vim.wait(50)
    end
    close_clients(clients, mode.reset)
    local released = vim.wait(WAIT_MS, function()
      return sse:count() == 0 and c.session.server:connection_count() == 0
    end, 5)
    check(
      released,
      string.format(
        "leaked: %d stream clients and %d connections remain",
        sse:count(),
        c.session.server:connection_count()
      )
    )
  end)

  stop_it(ctx)
  cleanup_server(ctx)
end)

describe("event stream shutdown", function()
  local ctx = start_server()

  it("stops: sends goodbye to every open stream and closes it, with the maximum number of streams open", function()
    local streams = {}
    for i = 1, sse_mod.MAX_CLIENTS do
      streams[i] = h.events(ctx.port, "/" .. ctx.token .. "/events")
    end
    for i, s in ipairs(streams) do
      check(s.wait_for("init", 1, WAIT_MS) ~= nil, "stream " .. i .. " got no init event")
    end
    local server = ctx.session.server
    h.stop()
    local closed = vim.wait(WAIT_MS, function()
      for _, s in ipairs(streams) do
        if not s.closed then
          return false
        end
      end
      return true
    end, 5)
    for _, s in ipairs(streams) do
      s.close()
    end
    check(closed, "some streams were still open after stop()")
    for i, s in ipairs(streams) do
      check(s.count("goodbye") == 1, "stream " .. i .. " saw no goodbye" .. s.describe())
    end
    check(server.tcp:is_closing(), "listening socket is still open after stop()")
    check(server:connection_count() == 0, "connections remain after stop(): " .. server:connection_count())
  end)

  cleanup_server(ctx)
end)

describe("response classes", function()
  it("checked the hardening headers on a response of every documented status", function()
    local documented = { 200, 204, 206, 301, 400, 403, 404, 405, 413, 415, 416, 431, 501, 503, 505 }
    local missing = {}
    for _, status in ipairs(documented) do
      if not seen_status[status] then
        missing[#missing + 1] = status
      end
    end
    check(#missing == 0, "no response was checked for status " .. table.concat(vim.tbl_map(tostring, missing), ", "))
  end)
end)
