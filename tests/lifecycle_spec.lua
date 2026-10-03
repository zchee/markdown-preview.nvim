local h = require("helpers")
local uv = vim.uv

---@return integer
local function handle_count()
  local n = 0
  uv.walk(function(handle)
    if not handle:is_closing() then
      n = n + 1
    end
  end)
  return n
end

---@param port integer
---@return boolean connected
local function can_connect(port)
  local tcp = assert(uv.new_tcp())
  local result
  tcp:connect("127.0.0.1", port, function(err)
    result = err == nil
  end)
  vim.wait(h.TIMEOUT_MS, function()
    return result ~= nil
  end, 5)
  tcp:close()
  return result == true
end

describe("lifecycle", function()
  local t
  local mp = require("markdown-preview")

  before_each(function()
    t = h.tree()
  end)

  after_each(function()
    h.stop()
    vim.cmd("silent! %bwipeout!")
    h.cleanup(t)
  end)

  it("releases the port and every handle on stop, and starts again on the same port", function()
    local before = handle_count()
    local s = h.start(t.readme, t.web)
    local port = s.server.port
    assert.is_true(port > 0)
    local es = h.events(port, "/" .. s.token .. "/events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
    -- A request still in flight holds a deadline timer that stop() must close too.
    local partial = assert(uv.new_tcp())
    partial:connect("127.0.0.1", port, function()
      partial:write("GET /" .. s.token .. "/ HTTP/1.1\r\n")
    end)
    assert.is_true(
      vim.wait(h.TIMEOUT_MS, function()
        return s.server:connection_count() == 2
      end, 5),
      "partial request not accepted"
    )
    h.stop()
    es.close()
    partial:close()
    vim.wait(100, function()
      return handle_count() == before
    end, 5)
    assert.are.equal(before, handle_count(), "libuv handles left open after stop()")
    assert.is_false(can_connect(port), "port " .. port .. " still accepts connections")
    assert.is_false(mp.is_running())
    assert.is_nil(mp.url())

    local s2 = h.start(t.readme, t.web, { port = port })
    assert.are.equal(port, s2.server.port)
    assert.are_not.equal(s.token, s2.token)
    local res = h.fetch(port, "GET", "/" .. s2.token .. "/")
    assert.are.equal(200, res.status, h.show(res))
    res = h.fetch(port, "GET", "/" .. s.token .. "/")
    assert.are.equal(403, res.status, "the previous token still works" .. h.show(res))
  end)

  it("returns the running URL when start() is called again", function()
    local s = h.start(t.readme, t.web)
    assert.are.equal(s.url, mp.start())
    assert.are.equal(s, require("markdown-preview.session").current)
  end)

  it("toggles between running and stopped", function()
    require("markdown-preview.server.static").set_web_root(t.web)
    mp.setup({ browser = false })
    vim.cmd.edit(vim.fn.fnameescape(t.readme))
    mp.toggle()
    assert.is_true(mp.is_running())
    mp.toggle()
    assert.is_false(mp.is_running())
    assert.is_false(mp.stop())
  end)

  it("provides :MarkdownPreview with completion", function()
    require("markdown-preview.server.static").set_web_root(t.web)
    mp.setup({ browser = false })
    vim.cmd.edit(vim.fn.fnameescape(t.readme))
    assert.are.same({ "start", "stop", "toggle" }, vim.fn.getcompletion("MarkdownPreview ", "cmdline"))
    assert.are.same({ "start", "stop" }, vim.fn.getcompletion("MarkdownPreview st", "cmdline"))
    vim.cmd("MarkdownPreview start")
    assert.is_true(mp.is_running())
    vim.cmd("MarkdownPreview stop")
    assert.is_false(mp.is_running())
    vim.cmd("MarkdownPreview")
    assert.is_true(mp.is_running())
    vim.cmd("MarkdownPreview toggle")
    assert.is_false(mp.is_running())
  end)

  it("refuses to start on a buffer without a file name", function()
    mp.setup({ browser = false })
    vim.cmd("enew")
    local notified
    local orig = vim.notify
    vim.notify = function(msg)
      notified = msg
    end
    local url = mp.start()
    vim.notify = orig
    assert.is_nil(url)
    assert.is_false(mp.is_running())
    assert.are.equal("markdown-preview: the current buffer has no file name", notified)
  end)

  it("reports a port that is already in use without leaking handles", function()
    local s = h.start(t.readme, t.web)
    local busy = s.server.port
    h.stop()
    local before = handle_count()
    local blocker = assert(uv.new_tcp())
    assert.is_truthy(blocker:bind("127.0.0.1", busy))
    assert.is_truthy(blocker:listen(1, function() end))
    mp.setup({ browser = false, port = busy })
    local notified
    local orig = vim.notify
    vim.notify = function(msg)
      notified = msg
    end
    local url = mp.start()
    vim.notify = orig
    blocker:close()
    assert.is_nil(url)
    -- Linux reports the conflict from bind(); macOS (SO_REUSEADDR) reports it from listen().
    assert.is_truthy(notified and notified:find("EADDRINUSE", 1, true), tostring(notified))
    vim.wait(100, function()
      return handle_count() == before
    end, 5)
    assert.are.equal(before, handle_count())
  end)

  it("opens a private redirect file with the browser command, never the URL itself", function()
    local out = vim.fs.joinpath(t.base, "opened.txt")
    local script = vim.fs.joinpath(t.base, "browser.sh")
    -- Records its argv and a copy of the file it was given, as a browser would read it.
    h.write_file(script, '#!/bin/sh\nd="$(dirname "$0")"\ncp "$1" "$d/copy.html"\nprintf %s "$*" > "$d/opened.txt"\n')
    assert(uv.fs_chmod(script, 493))
    for _, browser in ipairs({ script, { "sh", script } }) do
      vim.fn.delete(out)
      require("markdown-preview.server.static").set_web_root(t.web)
      mp.setup({ browser = browser })
      vim.cmd.edit(vim.fn.fnameescape(t.readme))
      local url = assert(mp.start())
      local token = require("markdown-preview.session").current.token
      assert.is_true(
        vim.wait(h.TIMEOUT_MS, function()
          return (uv.fs_stat(out) or { size = 0 }).size > 0
        end, 10),
        "browser command did not run for " .. vim.inspect(browser)
      )
      local f = assert(io.open(out))
      local argv = f:read("*a")
      f:close()
      assert.is_nil(argv:find(token, 1, true), "token on the command line: " .. argv)
      assert.is_truthy(argv:match("open%.html$"), argv)
      local file = argv
      local st = assert(uv.fs_stat(file), "redirect file missing: " .. file)
      assert.are.equal(tonumber("600", 8), bit.band(st.mode, tonumber("777", 8)))
      local dst = assert(uv.fs_stat(vim.fs.dirname(file)))
      assert.are.equal(tonumber("700", 8), bit.band(dst.mode, tonumber("777", 8)))
      f = assert(io.open(vim.fs.joinpath(t.base, "copy.html")))
      local html = f:read("*a")
      f:close()
      assert.is_truthy(html:find('<meta http-equiv="refresh" content="0;url=' .. url .. '">', 1, true), html)
      h.stop()
      assert.is_nil(uv.fs_stat(file), "redirect file left after stop()")
      assert.is_nil(uv.fs_stat(vim.fs.dirname(file)), "redirect directory left after stop()")
    end
  end)

  it("deletes the redirect file on its own after the cleanup delay and escapes the URL", function()
    local browser = require("markdown-preview.browser")
    local saved = browser.CLEANUP_MS
    browser.CLEANUP_MS = 100
    local r = assert(browser.write_redirect('http://127.0.0.1:1/t/"><script>alert(1)</script>&x'))
    browser.CLEANUP_MS = saved
    local f = assert(io.open(r.file))
    local html = f:read("*a")
    f:close()
    assert.is_nil(html:find("<script>", 1, true), html)
    assert.is_truthy(
      html:find("url=http://127.0.0.1:1/t/&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;&amp;x", 1, true),
      html
    )
    assert.is_true(
      vim.wait(2000, function()
        return uv.fs_stat(r.file) == nil and uv.fs_stat(r.dir) == nil
      end, 10),
      "redirect file not deleted after the delay"
    )
  end)

  it("reports only the plain URL when browser is false", function()
    -- A private temp dir, so redirect files from other processes cannot interfere.
    local tmp = vim.fs.joinpath(t.base, "tmp")
    vim.fn.mkdir(tmp, "p")
    local saved = vim.env.TMPDIR
    vim.env.TMPDIR = tmp
    local s = h.start(t.readme, t.web)
    vim.env.TMPDIR = saved
    assert.is_truthy(s.url:find(s.token, 1, true))
    assert.are.same({}, vim.fn.readdir(tmp), "a redirect file was written although browser = false")
  end)

  it("warns at start when the host is not a loopback address", function()
    require("markdown-preview.server.static").set_web_root(t.web)
    mp.setup({ browser = false, host = "0.0.0.0" })
    vim.cmd.edit(vim.fn.fnameescape(t.readme))
    local messages = {}
    local orig = vim.notify
    vim.notify = function(msg, level)
      messages[#messages + 1] = { msg = msg, level = level }
    end
    local url = mp.start()
    vim.notify = orig
    assert.is_not_nil(url)
    local warned = false
    for _, m in ipairs(messages) do
      if m.level == vim.log.levels.WARN and m.msg:find("not a loopback address", 1, true) then
        warned = true
      end
    end
    assert.is_true(warned, vim.inspect(messages))
  end)

  it("binds a host name to its resolved address and puts that literal in the URL", function()
    local resolved = assert(uv.getaddrinfo("localhost", nil, { socktype = "stream" }))[1].addr
    local s = h.start(t.readme, t.web, { host = "localhost" })
    assert.are.equal(resolved, s.server.ip)
    local literal = resolved:find(":", 1, true) and ("[" .. resolved .. "]") or resolved
    local port = s.server.port
    assert.are.equal(string.format("http://%s:%d/%s/", literal, port, s.token), s.url)
    for _, host in ipairs({ literal .. ":" .. port, "localhost:" .. port }) do
      local raw = h.raw(port, h.request(port, "GET", "/" .. s.token .. "/", { Host = host }), { addr = resolved })
      local res = h.parse(raw)
      assert.are.equal(200, res.status, "Host " .. host .. h.show(res))
    end
  end)

  it("registers VimLeavePre so leaving Neovim stops the server", function()
    h.start(t.readme, t.web)
    local cmds = vim.api.nvim_get_autocmds({ group = "markdown-preview", event = "VimLeavePre" })
    assert.are.equal(1, #cmds)
    h.stop()
    -- stop() deletes the group, so a stopped preview leaves no autocommands behind.
    assert.is_false(pcall(vim.api.nvim_get_autocmds, { group = "markdown-preview" }))
  end)
end)
