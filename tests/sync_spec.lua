local h = require("helpers")
local uv = vim.uv

describe("event stream and buffer sync", function()
  local t, s, port, base

  before_each(function()
    t = h.tree()
    s = h.start(t.readme, t.web)
    port = s.server.port
    base = "/" .. s.token .. "/"
  end)

  after_each(function()
    h.stop()
    require("markdown-preview.server.sse").PING_INTERVAL_MS = 15000
    vim.cmd("silent! %bwipeout!")
    h.cleanup(t)
  end)

  ---@param body string
  ---@return table
  local function open(body)
    return h.fetch(port, "POST", base .. "api/open", { ["Content-Type"] = "application/json" }, body)
  end

  it("sends init first with path, lines, 0-based cursor line and config", function()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local es = h.events(port, base .. "events")
    local init = es.wait_for("init")
    assert.is_not_nil(init, es.describe())
    assert.are.equal("init", es.events[1].event, es.describe())
    assert.are.equal("text/event-stream; charset=utf-8", es.head.headers["content-type"], es.describe())
    assert.are.same({
      path = "README.md",
      lines = { "# Readme", "", "first paragraph", "second line" },
      cursor_line = 2,
      config = {
        theme = { name = "system", high_contrast = false },
        details_tags_open = true,
        cursor_line = { disable = false, color = "#c86414", opacity = 0.2 },
        scroll = { disable = false, top_offset_pct = 35 },
      },
    }, init.data)
    es.close()
  end)

  it("sends content_change promptly after an edit", function()
    local es = h.events(port, base .. "events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
    local started = uv.hrtime()
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "inserted line" })
    local ev = es.wait_for("content_change")
    local elapsed_ms = (uv.hrtime() - started) / 1e6
    assert.is_not_nil(ev, es.describe())
    assert.are.same(
      { path = "README.md", lines = { "# Readme", "inserted line", "first paragraph", "second line" } },
      ev.data
    )
    -- The design target is debounce_ms + 50 ms. Shared CI machines stall for longer than that, so
    -- the assertion only catches a change that waits for something else (a later edit, a ping);
    -- the measured latency is printed for comparison with the target.
    local debounce = require("markdown-preview.config").options.debounce_ms
    print(string.format("content_change latency: %.1f ms (target %d ms)", elapsed_ms, debounce + 50))
    local limit = 10 * (debounce + 50)
    assert.is_true(elapsed_ms <= limit, string.format("content_change took %.1f ms (limit %d ms)", elapsed_ms, limit))
    es.close()
  end)

  it("folds a burst of edits into one content_change carrying the final text", function()
    local es = h.events(port, base .. "events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
    for i = 1, 50 do
      vim.api.nvim_buf_set_lines(0, 0, 1, false, { "# edit " .. i })
    end
    local ev = es.wait_for("content_change")
    assert.is_not_nil(ev, es.describe())
    assert.are.equal("# edit 50", ev.data.lines[1])
    vim.wait(150)
    assert.are.equal(1, es.count("content_change"), es.describe())
    es.close()
  end)

  it("broadcasts update_config from the public toggles", function()
    local mp = require("markdown-preview")
    local es = h.events(port, base .. "events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
    mp.scroll_off()
    local ev = es.wait_for("update_config", 1)
    assert.is_not_nil(ev, es.describe())
    assert.is_true(ev.data.config.scroll.disable)
    mp.cursorline_toggle()
    ev = es.wait_for("update_config", 2)
    assert.is_true(ev.data.config.cursor_line.disable)
    mp.details_tags_off()
    ev = es.wait_for("update_config", 3)
    assert.is_false(ev.data.config.details_tags_open)
    mp.scroll_toggle()
    mp.cursorline_on()
    mp.details_tags_toggle()
    ev = es.wait_for("update_config", 6)
    assert.is_not_nil(ev, es.describe())
    assert.is_false(ev.data.config.scroll.disable)
    assert.is_false(ev.data.config.cursor_line.disable)
    assert.is_true(ev.data.config.details_tags_open)
    es.close()
  end)

  it("sends a ping comment on the configured interval", function()
    h.stop()
    require("markdown-preview.server.sse").PING_INTERVAL_MS = 40
    s = h.start(t.readme, t.web)
    local es = h.events(s.server.port, "/" .. s.token .. "/events")
    local ok = vim.wait(1000, function()
      return es.raw:find("\n: ping\n\n", 1, true) ~= nil
    end, 5)
    assert.is_true(ok, es.describe())
    es.close()
  end)

  it("drops a client when it disconnects", function()
    local es = h.events(port, base .. "events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
    assert.are.equal(1, s.sse:count())
    es.close()
    assert.is_true(
      vim.wait(1000, function()
        return s.sse:count() == 0
      end, 5),
      "client still registered after EOF"
    )
  end)

  it("sends goodbye and closes the stream on stop", function()
    local es = h.events(port, base .. "events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
    h.stop()
    local ev = es.wait_for("goodbye")
    assert.is_not_nil(ev, es.describe())
    assert.is_truthy(ev.raw:find("\ndata: {}$"), es.describe())
    assert.is_true(
      vim.wait(1000, function()
        return es.closed
      end, 5),
      "stream not closed" .. es.describe()
    )
  end)

  it("switches to a file on disk through api/open and stops following the buffer", function()
    local es = h.events(port, base .. "events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
    local res = open('{"path":"docs/guide.md"}')
    assert.are.equal(204, res.status, h.show(res))
    local ev = es.wait_for("init", 2)
    assert.is_not_nil(ev, es.describe())
    assert.are.equal("docs/guide.md", ev.data.path)
    assert.are.same({ "# Guide", "", "guide body" }, ev.data.lines)
    assert.are.equal(vim.NIL, ev.data.cursor_line)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "# README edited" })
    vim.wait(require("markdown-preview.config").options.debounce_ms + 100)
    assert.are.equal(0, es.count("content_change"), es.describe())
    es.close()
  end)

  it("takes api/open content from a loaded buffer and follows its edits", function()
    local guide_buf = vim.fn.bufadd(t.guide)
    vim.fn.bufload(guide_buf)
    vim.api.nvim_buf_set_lines(guide_buf, 2, 3, false, { "unsaved change" })
    local es = h.events(port, base .. "events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
    local res = open('{"path":"docs/guide.md"}')
    assert.are.equal(204, res.status, h.show(res))
    local ev = es.wait_for("init", 2)
    assert.are.same({ "# Guide", "", "unsaved change" }, ev.data.lines)
    assert.are.equal(vim.NIL, ev.data.cursor_line)
    vim.api.nvim_buf_set_lines(guide_buf, 0, 1, false, { "# Guide edited" })
    ev = es.wait_for("content_change")
    assert.is_not_nil(ev, es.describe())
    assert.are.same({ path = "docs/guide.md", lines = { "# Guide edited", "", "unsaved change" } }, ev.data)
    es.close()
  end)

  it("answers api/open errors with the contract statuses and keeps the current file", function()
    local cases = {
      { "not json", 400 },
      { "[]", 400 },
      { "{}", 400 },
      { '{"path":1}', 400 },
      { '{"path":""}', 400 },
      { '{"path":"../outside/outside.md"}', 403 },
      { '{"path":"escape/outside.md"}', 403 },
      { '{"path":"/etc/hosts"}', 403 },
      { '{"path":"missing.md"}', 404 },
      { '{"path":"docs"}', 404 },
      { '{"path":"docs/notes.txt"}', 415 },
    }
    for _, c in ipairs(cases) do
      local res = open(c[1])
      assert.are.equal(c[2], res.status, c[1] .. h.show(res))
      assert.are.equal("application/json", res.headers["content-type"], c[1] .. h.show(res))
      assert.is_string(vim.json.decode(res.body).error, c[1] .. h.show(res))
      assert.are.equal("README.md", s.target.rel, c[1])
    end
  end)

  it("re-targets the preview when a Markdown buffer is entered", function()
    local es = h.events(port, base .. "events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
    vim.cmd.edit(vim.fn.fnameescape(t.notes))
    vim.cmd.edit(vim.fn.fnameescape(t.guide))
    local ev = es.wait_for("init", 2)
    assert.is_not_nil(ev, es.describe())
    assert.are.equal(2, es.count("init"), "entering a non-Markdown buffer must not re-target" .. es.describe())
    assert.are.equal("docs/guide.md", ev.data.path)
    assert.are.same({ "# Guide", "", "guide body" }, ev.data.lines)
    assert.are.equal(0, ev.data.cursor_line)
    vim.api.nvim_buf_set_lines(0, 2, 3, false, { "changed" })
    ev = es.wait_for("content_change")
    assert.are.equal("docs/guide.md", ev.data.path)
    es.close()
  end)

  it("reports files over 500 kB with an error event instead of content", function()
    local es = h.events(port, base .. "events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
    local big = {}
    for i = 1, 6000 do
      big[i] = string.rep("x", 99) .. (i % 10)
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, big)
    local ev = es.wait_for("error")
    assert.is_not_nil(ev, es.describe())
    assert.are.same({ path = "README.md", message = "file too large (>500kB)" }, ev.data)
    assert.are.equal(0, es.count("content_change"), es.describe())
    es.close()
    local es2 = h.events(port, base .. "events")
    assert.is_not_nil(es2.wait_for("error"), es2.describe())
    assert.are.equal("init", es2.events[1].event)
    assert.are.same({}, es2.events[1].data.lines)
    es2.close()
  end)

  it("reports an oversized file opened through api/open", function()
    h.write_file(vim.fs.joinpath(t.repo, "huge.md"), string.rep("y", 600 * 1000))
    local es = h.events(port, base .. "events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
    local res = open('{"path":"huge.md"}')
    assert.are.equal(204, res.status, h.show(res))
    local ev = es.wait_for("init", 2)
    assert.are.same({}, ev.data.lines)
    assert.is_not_nil(es.wait_for("error"), es.describe())
    es.close()
  end)
end)

describe("event stream limits", function()
  local t, s, port, base
  local sse = require("markdown-preview.server.sse")

  before_each(function()
    t = h.tree()
    s = h.start(t.readme, t.web)
    port = s.server.port
    base = "/" .. s.token .. "/"
  end)

  after_each(function()
    h.stop()
    sse.MAX_CLIENTS = 16
    sse.MAX_QUEUE_BYTES = 4 * 1024 * 1024
    vim.cmd("silent! %bwipeout!")
    h.cleanup(t)
  end)

  it("answers 503 once the client limit is reached and accepts again after one leaves", function()
    sse.MAX_CLIENTS = 2
    local a = h.events(port, base .. "events")
    local b = h.events(port, base .. "events")
    assert.is_not_nil(a.wait_for("init"), a.describe())
    assert.is_not_nil(b.wait_for("init"), b.describe())
    local res = h.fetch(port, "GET", base .. "events")
    assert.are.equal(503, res.status, h.show(res))
    assert.are.equal("application/json", res.headers["content-type"], h.show(res))
    assert.are.equal(2, s.sse:count())
    a.close()
    assert.is_true(
      vim.wait(h.TIMEOUT_MS, function()
        return s.sse:count() == 1
      end, 5),
      "closed client still registered"
    )
    local c = h.events(port, base .. "events")
    assert.is_not_nil(c.wait_for("init"), c.describe())
    b.close()
    c.close()
  end)

  it("drops a client that stops reading once its write queue passes the limit", function()
    sse.MAX_QUEUE_BYTES = 64 * 1024
    -- Sends the request and never reads, so the server's output piles up in its write queue.
    local stalled = assert(vim.uv.new_tcp())
    local connected = false
    stalled:connect("127.0.0.1", port, function(err)
      assert(not err, err)
      stalled:write(h.request(port, "GET", base .. "events"))
      connected = true
    end)
    local reader = h.events(port, base .. "events")
    assert.is_not_nil(reader.wait_for("init"), reader.describe())
    assert.is_true(
      vim.wait(h.TIMEOUT_MS, function()
        return connected and s.sse:count() == 2
      end, 5),
      "stalled client never registered"
    )
    local line = string.rep("z", 999)
    local big = {}
    for i = 1, 400 do
      big[i] = line
    end
    local sent = 0
    -- About 400 kB per edit; the kernel buffers fill after a few, then the queue grows.
    vim.wait(20000, function()
      sent = sent + 1
      big[1] = "edit " .. sent
      vim.api.nvim_buf_set_lines(0, 0, -1, false, big)
      vim.wait(require("markdown-preview.config").options.debounce_ms + 20)
      return s.sse:count() == 1 or sent >= 200
    end, 1)
    assert.are.equal(1, s.sse:count(), "stalled client kept after " .. sent .. " large events")
    -- The reading client is unaffected and still receives events.
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# after the drop" })
    local ev = reader.wait_match("content_change", function(d)
      return d.lines[1] == "# after the drop"
    end, 10000)
    assert.is_not_nil(ev, "reader stopped receiving events")
    reader.close()
    stalled:close()
  end)
end)

describe("session edge cases", function()
  local t, s, port, base
  local http = require("markdown-preview.server.http")

  before_each(function()
    t = h.tree()
    s = h.start(t.readme, t.web)
    port = s.server.port
    base = "/" .. s.token .. "/"
  end)

  after_each(function()
    h.stop()
    http.FINISH_TIMEOUT_MS = 2000
    vim.cmd("silent! %bwipeout!")
    h.cleanup(t)
  end)

  it("does not send the previous buffer's pending change after switching buffers", function()
    h.stop()
    s = h.start(t.readme, t.web, { debounce_ms = 300 })
    local es = h.events(s.server.port, "/" .. s.token .. "/events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "# README edited" })
    vim.cmd.edit(vim.fn.fnameescape(t.guide))
    local init = es.wait_for("init", 2)
    assert.is_not_nil(init, es.describe())
    assert.are.equal("docs/guide.md", init.data.path)
    vim.wait(500)
    assert.are.equal(0, es.count("content_change"), "redundant content_change after the switch" .. es.describe())
    es.close()
  end)

  it("reports a wiped buffer with an error event and keeps reporting it to new pages", function()
    local es = h.events(port, base .. "events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
    vim.cmd("enew")
    vim.cmd("bwipeout! " .. vim.fn.bufnr(t.readme))
    local ev = es.wait_for("error")
    assert.is_not_nil(ev, es.describe())
    assert.are.same({
      path = "README.md",
      message = require("markdown-preview.session").BUFFER_CLOSED_MESSAGE,
    }, ev.data)
    es.close()
    local es2 = h.events(port, base .. "events")
    local init = es2.wait_for("init")
    assert.is_not_nil(init, es2.describe())
    assert.are.same({ "# Readme", "", "first paragraph", "second line" }, init.data.lines)
    assert.is_not_nil(es2.wait_for("error"), es2.describe())
    es2.close()
  end)

  it("runs the ping timer only while a client is connected", function()
    local function pinging()
      return s.sse.timer ~= nil and s.sse.timer:is_active()
    end
    assert.is_false(pinging(), "ping timer runs with no client")
    local es = h.events(port, base .. "events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
    assert.is_true(pinging(), "ping timer idle with a client connected")
    es.close()
    assert.is_true(
      vim.wait(h.TIMEOUT_MS, function()
        return not pinging()
      end, 5),
      "ping timer still running after the last client left"
    )
  end)

  it("abandons the goodbye flush to a client that stopped reading", function()
    http.FINISH_TIMEOUT_MS = 200
    local stalled = assert(vim.uv.new_tcp())
    stalled:connect("127.0.0.1", port, function(err)
      assert(not err, err)
      stalled:write(h.request(port, "GET", base .. "events"))
    end)
    assert.is_true(
      vim.wait(h.TIMEOUT_MS, function()
        return s.sse:count() == 1
      end, 5),
      "stalled client never registered"
    )
    local conn = next(s.sse.clients)
    local line = string.rep("q", 999)
    local big = {}
    for i = 1, 400 do
      big[i] = line
    end
    local n = 0
    vim.wait(20000, function()
      n = n + 1
      big[1] = "fill " .. n
      vim.api.nvim_buf_set_lines(0, 0, -1, false, big)
      vim.wait(require("markdown-preview.config").options.debounce_ms + 20)
      return conn.tcp:get_write_queue_size() > 0 or n >= 200
    end, 1)
    assert.is_true(conn.tcp:get_write_queue_size() > 0, "could not fill the kernel buffers")
    local server = s.server
    require("markdown-preview").stop()
    local started = vim.uv.hrtime()
    assert.is_true(
      vim.wait(3000, function()
        return server:connection_count() == 0
      end, 5),
      "connection kept open while the peer does not read"
    )
    local elapsed = (vim.uv.hrtime() - started) / 1e6
    assert.is_true(elapsed >= 150, string.format("closed after %.0f ms, before the flush deadline", elapsed))
    stalled:close()
  end)
end)
