-- Shared helpers for the specs: a real TCP client on vim.uv, response parsing, an event-stream
-- reader and temporary preview trees. Nothing here replaces server code with test doubles.
local uv = vim.uv

local M = {}

M.TIMEOUT_MS = 3000

--- Writes `content` to `path`, creating parent directories.
---@param path string
---@param content string
function M.write_file(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

--- Creates a temporary preview tree and returns the paths of interest.
--- Layout: <base>/repo/.git, repo/README.md, repo/docs/guide.md, repo/docs/notes.txt,
--- repo/media/blob.mp4 (1000 bytes 0..255 repeating), repo/media/pic.png, repo/escape -> <base>/outside
--- (symlink), <base>/outside/secret.txt and secret.png, <base>/web/index.html (stand-in page with the
--- bootstrap placeholder) and <base>/web/app.js.
---@return table
function M.tree()
  local base = vim.fs.normalize(assert(uv.fs_realpath(vim.fn.tempname():match("^(.*)/") or "/tmp")))
  base = vim.fs.joinpath(base, "mp-spec-" .. vim.fn.rand())
  local t = {
    base = base,
    repo = vim.fs.joinpath(base, "repo"),
    web = vim.fs.joinpath(base, "web"),
    outside = vim.fs.joinpath(base, "outside"),
  }
  vim.fn.mkdir(vim.fs.joinpath(t.repo, ".git"), "p")
  t.readme = vim.fs.joinpath(t.repo, "README.md")
  t.guide = vim.fs.joinpath(t.repo, "docs", "guide.md")
  t.notes = vim.fs.joinpath(t.repo, "docs", "notes.txt")
  t.blob = vim.fs.joinpath(t.repo, "media", "blob.mp4")
  t.pic = vim.fs.joinpath(t.repo, "media", "pic.png")
  M.write_file(t.pic, "\137PNG fake image bytes")
  M.write_file(t.readme, "# Readme\n\nfirst paragraph\nsecond line\n")
  M.write_file(t.guide, "# Guide\n\nguide body\n")
  M.write_file(t.notes, "plain text\n")
  local bytes = {}
  for i = 0, 999 do
    bytes[#bytes + 1] = string.char(i % 256)
  end
  t.blob_content = table.concat(bytes)
  M.write_file(t.blob, t.blob_content)
  M.write_file(vim.fs.joinpath(t.outside, "secret.txt"), "top secret\n")
  M.write_file(vim.fs.joinpath(t.outside, "secret.png"), "top secret\n")
  M.write_file(vim.fs.joinpath(t.outside, "outside.md"), "# outside\n")
  assert(uv.fs_symlink(t.outside, vim.fs.joinpath(t.repo, "escape")))
  M.write_file(
    vim.fs.joinpath(t.web, "index.html"),
    '<!doctype html><script type="application/json" id="mp-bootstrap">__MP_BOOTSTRAP__</script>\n'
  )
  M.write_file(vim.fs.joinpath(t.web, "app.js"), "console.log('stand-in');\n")
  return t
end

--- Removes a tree created by tree().
---@param t table
function M.cleanup(t)
  vim.fn.delete(t.base, "rf")
end

--- Connects, writes `chunks` one by one with `gap_ms` between them (so the server sees separate
--- reads), and collects bytes until the server closes the connection.
---@param port integer
---@param chunks string|string[]
---@param opts? { gap_ms?: integer, timeout_ms?: integer, addr?: string } addr defaults to 127.0.0.1.
---@return string raw, boolean closed
function M.raw(port, chunks, opts)
  opts = opts or {}
  if type(chunks) == "string" then
    chunks = { chunks }
  end
  local tcp = assert(uv.new_tcp())
  local out, closed, connected, failed = {}, false, false, nil
  tcp:connect(opts.addr or "127.0.0.1", port, function(err)
    if err then
      failed = err
      closed = true
      return
    end
    connected = true
    tcp:read_start(function(rerr, data)
      if rerr or not data then
        closed = true
        return
      end
      out[#out + 1] = data
    end)
  end)
  vim.wait(opts.timeout_ms or M.TIMEOUT_MS, function()
    return connected or failed ~= nil
  end, 5)
  assert(connected, "could not connect to port " .. port .. ": " .. tostring(failed))
  for i, chunk in ipairs(chunks) do
    if not tcp:is_closing() then
      tcp:write(chunk)
    end
    if i < #chunks then
      vim.wait(opts.gap_ms or 20)
    end
  end
  vim.wait(opts.timeout_ms or M.TIMEOUT_MS, function()
    return closed
  end, 5)
  if not tcp:is_closing() then
    tcp:close()
  end
  return table.concat(out), closed
end

--- Splits a raw HTTP response.
---@param raw string
---@return { status?: integer, headers: table<string, string>, body: string, raw: string }
function M.parse(raw)
  local head, body = raw:match("^(.-)\r\n\r\n(.*)$")
  local res = { headers = {}, body = body or "", raw = raw }
  if not head then
    return res
  end
  local lines = vim.split(head, "\r\n", { plain = true })
  res.status = tonumber(lines[1]:match("^HTTP/1%.1 (%d%d%d)"))
  for i = 2, #lines do
    local k, v = lines[i]:match("^([^:]+):%s*(.*)$")
    if k then
      res.headers[k:lower()] = v
    end
  end
  return res
end

--- Builds a request with Host defaulting to 127.0.0.1:<port>.
---@param port integer
---@param method string
---@param target string
---@param headers? table<string, string|false>
---@param body? string
---@return string
function M.request(port, method, target, headers, body)
  local h = { Host = "127.0.0.1:" .. port }
  for k, v in pairs(headers or {}) do
    h[k] = v or nil
  end
  if body then
    h["Content-Length"] = tostring(#body)
  end
  local lines = { method .. " " .. target .. " HTTP/1.1" }
  for k, v in pairs(h) do
    lines[#lines + 1] = k .. ": " .. v
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or "")
end

--- Sends one request and returns the parsed response.
---@param port integer
---@param method string
---@param target string
---@param headers? table<string, string|false>
---@param body? string
---@return table
function M.fetch(port, method, target, headers, body)
  return M.parse((M.raw(port, M.request(port, method, target, headers, body))))
end

--- Formats a response for assertion messages.
---@param res table
---@return string
function M.show(res)
  return "\n--- raw response ---\n" .. tostring(res.raw) .. "\n--------------------"
end

---@class markdown_preview.test.EventStream
---@field events { event: string, data: any, raw: string }[]
---@field head? table Parsed response head.
---@field closed boolean
---@field buf string

--- Opens an event stream and parses events as they arrive.
---@param port integer
---@param target string
---@return markdown_preview.test.EventStream
function M.events(port, target)
  local s = { events = {}, closed = false, buf = "", raw = "" }
  local tcp = assert(uv.new_tcp())
  s.tcp = tcp
  tcp:connect("127.0.0.1", port, function(err)
    if err then
      s.closed = true
      return
    end
    tcp:write(M.request(port, "GET", target))
    tcp:read_start(function(rerr, data)
      if rerr or not data then
        s.closed = true
        return
      end
      s.raw = s.raw .. data
      s.buf = s.buf .. data
      if not s.head then
        local head, rest = s.buf:match("^(.-\r\n\r\n)(.*)$")
        if not head then
          return
        end
        s.head = M.parse(head)
        s.buf = rest
      end
      while true do
        local block, rest = s.buf:match("^(.-)\n\n(.*)$")
        if not block then
          break
        end
        s.buf = rest
        local ev = block:match("^event: ([^\n]+)")
        local data_line = block:match("\ndata: ([^\n]*)")
        if ev then
          s.events[#s.events + 1] = { event = ev, data = vim.json.decode(data_line), raw = block }
        end
      end
    end)
  end)

  --- Waits for the n-th event of `kind` (counting from 1) and returns it.
  function s.wait_for(kind, n, timeout_ms)
    n = n or 1
    local found
    vim.wait(timeout_ms or M.TIMEOUT_MS, function()
      local count = 0
      for _, e in ipairs(s.events) do
        if e.event == kind then
          count = count + 1
          if count == n then
            found = e
            return true
          end
        end
      end
      return false
    end, 2)
    return found
  end

  --- Waits for the first event of `kind` whose data satisfies `pred`; returns it and its index.
  function s.wait_match(kind, pred, timeout_ms)
    local found, index
    vim.wait(timeout_ms or M.TIMEOUT_MS, function()
      for i, e in ipairs(s.events) do
        if e.event == kind and pred(e.data) then
          found, index = e, i
          return true
        end
      end
      return false
    end, 2)
    return found, index
  end

  function s.count(kind)
    local c = 0
    for _, e in ipairs(s.events) do
      if e.event == kind then
        c = c + 1
      end
    end
    return c
  end

  function s.describe()
    return "\n--- raw event stream ---\n" .. s.raw .. "\n------------------------"
  end

  function s.close()
    if not tcp:is_closing() then
      tcp:close()
    end
  end

  return s
end

--- Edits `file`, applies options (browser disabled) and starts a preview against `web`.
---@param file string
---@param web string
---@param opts? table
---@return table session
function M.start(file, web, opts)
  require("markdown-preview.server.static").set_web_root(web)
  require("markdown-preview").setup(vim.tbl_deep_extend("force", { browser = false }, opts or {}))
  vim.cmd.edit(vim.fn.fnameescape(file))
  local url = assert(require("markdown-preview").start(), "start() returned nil")
  local s = require("markdown-preview.session").current
  assert(s and s.url == url)
  return s
end

--- Stops the preview and waits until every socket it owned is closed.
function M.stop()
  local s = require("markdown-preview.session").current
  require("markdown-preview").stop()
  if s then
    vim.wait(M.TIMEOUT_MS, function()
      return s.server:connection_count() == 0 and s.server.tcp:is_closing()
    end, 5)
  end
end

return M
