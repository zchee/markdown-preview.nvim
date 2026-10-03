local h = require("helpers")
local http = require("markdown-preview.server.http")

describe("request parser", function()
  it("assembles a request fed one byte at a time", function()
    local raw = 'POST /t/api/open HTTP/1.1\r\nHost: a:1\r\nContent-Length: 11\r\nX-A: 1\r\nx-a: 2\r\n\r\n{"path":1}\n'
    local p = http.new_parser()
    local req, err
    for i = 1, #raw do
      assert.is_nil(req, "request completed early at byte " .. (i - 1))
      req, err = p:feed(raw:sub(i, i))
      assert.is_nil(err, vim.inspect(err))
    end
    assert.is_not_nil(req, "request never completed")
    assert.are.equal("POST", req.method)
    assert.are.equal("/t/api/open", req.path)
    assert.are.equal("1.1", req.version)
    assert.are.equal("a:1", req.headers["host"])
    assert.are.equal("1, 2", req.headers["x-a"])
    assert.are.equal('{"path":1}\n', req.body)
  end)

  it("strips the query string from path", function()
    local req = http.new_parser():feed("GET /t/file/a%20b.png?x=1 HTTP/1.1\r\nHost: a\r\n\r\n")
    assert.are.equal("/t/file/a%20b.png", req.path)
    assert.are.equal("/t/file/a%20b.png?x=1", req.target)
  end)

  local errors = {
    { "malformed request line", "GARBAGE\r\n\r\n", 400 },
    { "lower-case method", "get / HTTP/1.1\r\nHost: a\r\n\r\n", 400 },
    { "missing version", "GET /\r\nHost: a\r\n\r\n", 400 },
    { "HTTP/2", "GET / HTTP/2.0\r\nHost: a\r\n\r\n", 505 },
    { "header folding", "GET / HTTP/1.1\r\nHost: a\r\nX: 1\r\n  2\r\n\r\n", 400 },
    { "header without colon", "GET / HTTP/1.1\r\nHost: a\r\nbroken\r\n\r\n", 400 },
    { "space in header name", "GET / HTTP/1.1\r\nHost: a\r\nBad Name: 1\r\n\r\n", 400 },
    { "missing Host on 1.1", "GET / HTTP/1.1\r\nX: 1\r\n\r\n", 400 },
    { "non-numeric Content-Length", "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1x\r\n\r\n", 400 },
    {
      "conflicting Content-Length",
      "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
      400,
    },
    { "chunked body", "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n", 501 },
    { "body over 16 kB", "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 16385\r\n\r\n", 413 },
  }
  for _, case in ipairs(errors) do
    it("rejects " .. case[1] .. " with " .. case[3], function()
      local req, err = http.new_parser():feed(case[2])
      assert.is_nil(req)
      assert.is_not_nil(err, "no error for " .. vim.inspect(case[2]))
      assert.are.equal(case[3], err.status, vim.inspect(err))
    end)
  end

  it("rejects a NUL byte in the request line", function()
    local _, err = http.new_parser():feed("GET /a\0b HTTP/1.1\r\nHost: a\r\n\r\n")
    assert.are.equal(400, err and err.status, vim.inspect(err))
  end)

  it("accepts a body only on POST and only up to 16 kB", function()
    local function feed(method, length)
      return http.new_parser():feed(method .. " / HTTP/1.1\r\nHost: a\r\nContent-Length: " .. length .. "\r\n\r\n")
    end
    local _, err = feed("GET", 5)
    assert.are.equal(400, err and err.status, vim.inspect(err))
    _, err = feed("PUT", 1)
    assert.are.equal(400, err and err.status, vim.inspect(err))
    _, err = feed("GET", 0)
    assert.is_nil(err, vim.inspect(err))
    _, err = feed("POST", http.MAX_BODY_BYTES + 1)
    assert.are.equal(413, err and err.status, vim.inspect(err))
    local req
    req, err = http.new_parser():feed(
      "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: "
        .. http.MAX_BODY_BYTES
        .. "\r\n\r\n"
        .. string.rep("b", http.MAX_BODY_BYTES)
    )
    assert.is_nil(err, vim.inspect(err))
    assert.are.equal(http.MAX_BODY_BYTES, req and #req.body)
  end)

  it("runs the precheck on the header block before any body byte arrives", function()
    local seen
    local p = http.new_parser(function(head)
      seen = head
      return 403, "nope"
    end)
    local req, err = p:feed("POST /x HTTP/1.1\r\nHost: a\r\nContent-Length: 100\r\n\r\n")
    assert.is_nil(req)
    assert.are.same({ status = 403, message = "nope" }, err)
    assert.are.equal("/x", seen and seen.path)
  end)

  it("accepts a header block of exactly 16 kB and rejects one byte more", function()
    local function block(total)
      local prefix = "GET / HTTP/1.1\r\nHost: a\r\nX: "
      return prefix .. string.rep("a", total - #prefix - 4) .. "\r\n\r\n"
    end
    local req, err = http.new_parser():feed(block(http.MAX_HEADER_BYTES))
    assert.is_nil(err, vim.inspect(err))
    assert.is_not_nil(req)
    req, err = http.new_parser():feed(block(http.MAX_HEADER_BYTES + 1))
    assert.is_nil(req)
    assert.are.equal(431, err and err.status)
  end)

  it("rejects an unterminated header block once it passes 16 kB", function()
    local p = http.new_parser()
    local _, err = p:feed("GET / HTTP/1.1\r\nHost: a\r\nX: " .. string.rep("a", 9000))
    assert.is_nil(err)
    _, err = p:feed(string.rep("a", 9000))
    assert.are.equal(431, err and err.status)
  end)
end)

describe("http server", function()
  local t, s

  before_each(function()
    t = h.tree()
    s = h.start(t.readme, t.web)
  end)

  after_each(function()
    h.stop()
    http.MAX_CONNECTIONS = 64
    http.REQUEST_TIMEOUT_MS = 10000
    h.cleanup(t)
  end)

  it("serves a request whose line, headers and body arrive in separate reads", function()
    local port = s.server.port
    local body = '{"path":"docs/guide.md"}'
    local raw = h.request(port, "POST", "/" .. s.token .. "/api/open", { ["Content-Type"] = "application/json" }, body)
    local cut1 = 9 -- inside the request line
    local cut2 = raw:find("\r\n", 1, true) + 5 -- inside the first header
    local cut3 = raw:find("\r\n\r\n", 1, true) + 1 -- between the CR LF pairs of the terminator
    local cut4 = #raw - 5 -- inside the body
    local chunks = {
      raw:sub(1, cut1),
      raw:sub(cut1 + 1, cut2),
      raw:sub(cut2 + 1, cut3),
      raw:sub(cut3 + 1, cut4),
      raw:sub(cut4 + 1),
    }
    local res = h.parse((h.raw(port, chunks, { gap_ms = 30 })))
    assert.are.equal(204, res.status, h.show(res))
    assert.are.equal("docs/guide.md", s.target.rel)
  end)

  it("answers oversized headers with 431 and closes the connection", function()
    local port = s.server.port
    local raw, closed = h.raw(port, {
      "GET /" .. s.token .. "/ HTTP/1.1\r\nHost: 127.0.0.1:" .. port .. "\r\nX-Big: ",
      string.rep("a", http.MAX_HEADER_BYTES),
    })
    local res = h.parse(raw)
    assert.are.equal(431, res.status, h.show(res))
    assert.is_true(closed, "connection left open" .. h.show(res))
  end)

  it("answers a malformed request line with 400 and closes the connection", function()
    local raw, closed = h.raw(s.server.port, "HELLO WORLD\r\n\r\n")
    local res = h.parse(raw)
    assert.are.equal(400, res.status, h.show(res))
    assert.are.equal("application/json", res.headers["content-type"], h.show(res))
    assert.is_truthy(res.body:find('"error"', 1, true), h.show(res))
    assert.is_true(closed, "connection left open" .. h.show(res))
  end)

  it("answers a body over the 16 kB limit with 413 before reading it", function()
    local port = s.server.port
    local raw, closed = h.raw(
      port,
      "POST /" .. s.token .. "/api/open HTTP/1.1\r\nHost: 127.0.0.1:" .. port .. "\r\nContent-Length: 2000000\r\n\r\n"
    )
    local res = h.parse(raw)
    assert.are.equal(413, res.status, h.show(res))
    assert.is_true(closed)
  end)

  it("rejects a foreign Host or token before reading a pending body", function()
    local port = s.server.port
    local cases = {
      { "/" .. s.token .. "/api/open", "evil.example:" .. port },
      { "/" .. string.rep("0", 32) .. "/api/open", "127.0.0.1:" .. port },
    }
    for _, c in ipairs(cases) do
      local started = vim.uv.hrtime()
      -- The body is announced but never sent; the answer must not wait for it.
      local raw, closed = h.raw(
        port,
        "POST " .. c[1] .. " HTTP/1.1\r\nHost: " .. c[2] .. "\r\nContent-Length: 10000\r\n\r\n",
        { timeout_ms = 1000 }
      )
      local res = h.parse(raw)
      assert.are.equal(403, res.status, h.show(res))
      assert.is_true(closed, "connection left open" .. h.show(res))
      assert.is_true((vim.uv.hrtime() - started) / 1e6 < 900, "403 waited for the body")
    end
  end)

  it("closes connections beyond the concurrent limit", function()
    h.stop()
    http.MAX_CONNECTIONS = 3
    s = h.start(t.readme, t.web)
    local port = s.server.port
    local idle = {}
    for i = 1, 3 do
      idle[i] = assert(vim.uv.new_tcp())
      idle[i]:connect("127.0.0.1", port, function() end)
    end
    assert.is_true(
      vim.wait(h.TIMEOUT_MS, function()
        return s.server:connection_count() == 3
      end, 5),
      "idle connections not accepted"
    )
    local raw, closed = h.raw(port, h.request(port, "GET", "/" .. s.token .. "/"), { timeout_ms = 1000 })
    assert.are.equal("", raw, "a connection over the limit got a response")
    assert.is_true(closed, "a connection over the limit was kept open")
    for _, c in ipairs(idle) do
      c:close()
    end
    assert.is_true(vim.wait(h.TIMEOUT_MS, function()
      return s.server:connection_count() == 0
    end, 5))
    local res = h.fetch(port, "GET", "/" .. s.token .. "/")
    assert.are.equal(200, res.status, "server did not recover after idle connections left" .. h.show(res))
  end)

  it("closes a connection that does not complete its request in time, but not the event stream", function()
    h.stop()
    http.REQUEST_TIMEOUT_MS = 150
    s = h.start(t.readme, t.web)
    local port = s.server.port
    local started = vim.uv.hrtime()
    local raw, closed = h.raw(port, "GET /" .. s.token .. "/ HTTP/1.1\r\nHost: 127.0.0.1:" .. port, {
      timeout_ms = 2000,
    })
    local elapsed = (vim.uv.hrtime() - started) / 1e6
    assert.is_true(closed, "slow request still open after 2 s")
    assert.are.equal("", raw)
    assert.is_true(elapsed >= 140 and elapsed < 1500, string.format("closed after %.0f ms", elapsed))
    local es = h.events(port, "/" .. s.token .. "/events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
    vim.wait(400)
    assert.is_false(es.closed, "event stream closed by the request deadline")
    require("markdown-preview").scroll_off()
    assert.is_not_nil(es.wait_for("update_config"), es.describe())
    es.close()
  end)

  it("closes ordinary responses after sending them", function()
    local raw, closed = h.raw(s.server.port, h.request(s.server.port, "GET", "/" .. s.token .. "/"))
    local res = h.parse(raw)
    assert.are.equal(200, res.status, h.show(res))
    assert.are.equal("close", res.headers["connection"], h.show(res))
    assert.are.equal(tostring(#res.body), res.headers["content-length"], h.show(res))
    assert.is_true(closed)
  end)
end)

describe("half-closed clients", function()
  local t, s, port

  before_each(function()
    t = h.tree()
    s = h.start(t.readme, t.web)
    port = s.server.port
  end)

  after_each(function()
    h.stop()
    h.cleanup(t)
  end)

  ---@param target string
  ---@return string raw
  local function get_then_half_close(target)
    local tcp = assert(vim.uv.new_tcp())
    local out, done = {}, false
    tcp:connect("127.0.0.1", port, function(err)
      assert(not err, err)
      tcp:read_start(function(rerr, data)
        if rerr or not data then
          done = true
          return
        end
        out[#out + 1] = data
      end)
      tcp:write(h.request(port, "GET", target), function()
        -- FIN right after the request, as `curl` or a proxy may do; reading continues.
        tcp:shutdown()
      end)
    end)
    vim.wait(h.TIMEOUT_MS, function()
      return done
    end, 5)
    tcp:close()
    return table.concat(out)
  end

  it("still receives an asynchronously streamed response after sending FIN", function()
    local parts = {}
    for i = 1, 30000 do
      parts[i] = string.format("/* %06d */\n", i)
    end
    local content = table.concat(parts)
    h.write_file(vim.fs.joinpath(t.web, "big.css"), content)
    h.write_file(vim.fs.joinpath(t.repo, "media", "big.mp4"), content)
    for _, target in ipairs({ "assets/big.css", "file/media/big.mp4", "file/media/pic.png", "" }) do
      local res = h.parse(get_then_half_close("/" .. s.token .. "/" .. target))
      assert.are.equal(200, res.status, target .. "\n" .. res.raw:sub(1, 300))
      assert.are.equal(tonumber(res.headers["content-length"]), #res.body, target .. ": truncated body")
    end
    local res = h.parse(get_then_half_close("/" .. s.token .. "/assets/big.css"))
    assert.is_true(res.body == content, "body differs from the file")
    assert.is_true(
      vim.wait(h.TIMEOUT_MS, function()
        return s.server:connection_count() == 0
      end, 5),
      "half-closed connections left open after their responses"
    )
  end)
end)
