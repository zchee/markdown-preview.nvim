local h = require("helpers")
local router = require("markdown-preview.server.router")

describe("router", function()
  local t, s, port, base

  before_each(function()
    t = h.tree()
    s = h.start(t.readme, t.web)
    port = s.server.port
    base = "/" .. s.token .. "/"
  end)

  after_each(function()
    h.stop()
    h.cleanup(t)
  end)

  ---@return { method: string, path: string, body?: string }[]
  local function every_route(prefix)
    return {
      { method = "GET", path = prefix },
      { method = "GET", path = prefix .. "events" },
      { method = "GET", path = prefix .. "assets/app.js" },
      { method = "GET", path = prefix .. "file/README.md" },
      { method = "POST", path = prefix .. "api/open", body = '{"path":"docs/guide.md"}' },
    }
  end

  ---@param res table
  local function assert_no_cors(res)
    for name in pairs(res.headers) do
      assert.is_nil(name:match("^access%-control%-"), "CORS header present" .. h.show(res))
    end
  end

  it("uses a 32-character lower-case hex token", function()
    assert.is_truthy(s.token:match("^%x+$") and #s.token == 32 and s.token == s.token:lower(), s.token)
  end)

  it("rejects a foreign Host header on every route", function()
    for _, r in ipairs(every_route(base)) do
      for _, host in ipairs({ "evil.example", "evil.example:" .. port, "127.0.0.1:1", "127.0.0.1" }) do
        local res = h.fetch(port, r.method, r.path, { Host = host }, r.body)
        assert.are.equal(403, res.status, r.method .. " " .. r.path .. " Host " .. host .. h.show(res))
        assert_no_cors(res)
      end
    end
  end)

  it("accepts the loopback names in the Host header", function()
    for _, host in ipairs({ "127.0.0.1:" .. port, "localhost:" .. port, "LOCALHOST:" .. port, "[::1]:" .. port }) do
      local res = h.fetch(port, "GET", base, { Host = host })
      assert.are.equal(200, res.status, "Host " .. host .. h.show(res))
    end
  end)

  it("rejects a missing or wrong token on every route", function()
    local wrong = string.rep("0", 32)
    local prefixes = { "/", "/" .. wrong .. "/", "/" .. s.token .. "x/", "/" .. s.token:upper() .. "/" }
    for _, prefix in ipairs(prefixes) do
      for _, r in ipairs(every_route(prefix)) do
        local res = h.fetch(port, r.method, r.path, nil, r.body)
        assert.are.equal(403, res.status, r.method .. " " .. r.path .. h.show(res))
        assert_no_cors(res)
      end
    end
    for _, path in ipairs({ "/favicon.ico", "/" .. wrong, "/?token=" .. s.token }) do
      local res = h.fetch(port, "GET", path)
      assert.are.equal(403, res.status, path .. h.show(res))
    end
    assert.are.equal("README.md", s.target.rel, "a rejected api/open switched the file")
  end)

  it("redirects the bare token path to the directory form", function()
    local res = h.fetch(port, "GET", "/" .. s.token)
    assert.are.equal(301, res.status, h.show(res))
    assert.are.equal(base, res.headers["location"], h.show(res))
  end)

  it("serves index.html with the bootstrap JSON, escaped for a script element", function()
    require("markdown-preview").setup({ browser = false, cursor_line = { color = "</script><b>&amp;" } })
    local res = h.fetch(port, "GET", base)
    assert.are.equal(200, res.status, h.show(res))
    assert.are.equal("text/html; charset=utf-8", res.headers["content-type"], h.show(res))
    assert.are.equal("no-store", res.headers["cache-control"], h.show(res))
    assert.are.equal("no-referrer", res.headers["referrer-policy"], h.show(res))
    assert.are.equal("nosniff", res.headers["x-content-type-options"], h.show(res))
    assert.is_nil(res.body:find("__MP_BOOTSTRAP__", 1, true), h.show(res))
    local json = res.body:match('id="mp%-bootstrap">(.-)</script>')
    assert.is_not_nil(json, h.show(res))
    assert.is_nil(json:find("[<>&]"), "unescaped <, > or & in " .. json)
    local boot = vim.json.decode(json)
    assert.are.equal("https://cdn.jsdelivr.net/npm", boot.cdn)
    assert.are.same({
      theme = { name = "system", high_contrast = false },
      details_tags_open = true,
      cursor_line = { disable = false, color = "</script><b>&amp;", opacity = 0.2 },
      scroll = { disable = false, top_offset_pct = 35 },
    }, boot.config)
  end)

  it("sends a CSP whose scripts come only from the token's assets directory and the cdn", function()
    local function expected(host, origin)
      return "default-src 'none'; script-src http://"
        .. host
        .. "/"
        .. s.token
        .. "/assets/ "
        .. origin
        .. " 'wasm-unsafe-eval'; style-src 'self' "
        .. origin
        .. " 'unsafe-inline'; img-src 'self' https: data:; media-src 'self' https:; font-src "
        .. origin
        .. " data:; connect-src 'self' "
        .. origin
        .. "; base-uri 'none'; form-action 'none'"
    end
    local res = h.fetch(port, "GET", base)
    assert.are.equal(
      expected("127.0.0.1:" .. port, "https://cdn.jsdelivr.net"),
      res.headers["content-security-policy"],
      h.show(res)
    )
    res = h.fetch(port, "GET", base, { Host = "LocalHost:" .. port })
    assert.are.equal(
      expected("localhost:" .. port, "https://cdn.jsdelivr.net"),
      res.headers["content-security-policy"],
      h.show(res)
    )
    assert.are.equal(
      expected("127.0.0.1:1", "https://mirror.example:8443"),
      router.csp("https://mirror.example:8443", "127.0.0.1:1", s.token)
    )
  end)

  it("answers 500 with a JSON error when index.html is missing", function()
    require("markdown-preview.server.static").set_web_root(t.outside)
    local res = h.fetch(port, "GET", base)
    assert.are.equal(500, res.status, h.show(res))
    assert.are.same({ error = "web/index.html not found" }, vim.json.decode(res.body))
  end)

  it("answers unknown routes with 404 and wrong methods with 405", function()
    local res = h.fetch(port, "GET", base .. "nope")
    assert.are.equal(404, res.status, h.show(res))
    for _, r in ipairs({ { "POST", "api/open/" }, { "PUT", "nope" }, { "DELETE", "api" } }) do
      res = h.fetch(port, r[1], base .. r[2])
      assert.are.equal(404, res.status, r[1] .. " " .. r[2] .. h.show(res))
    end
    for _, path in ipairs({ "assets/app.js/", "assets/app.js//", "assets/" }) do
      res = h.fetch(port, "GET", base .. path)
      assert.are.equal(404, res.status, path .. " (a file named with a trailing slash)" .. h.show(res))
    end
    res = h.fetch(port, "GET", base .. "api/open")
    assert.are.equal(405, res.status, h.show(res))
    assert.are.equal("POST", res.headers["allow"], h.show(res))
    res = h.fetch(port, "DELETE", base .. "file/README.md")
    assert.are.equal(405, res.status, h.show(res))
    assert.are.equal("GET", res.headers["allow"], h.show(res))
  end)

  it("checks Origin on POST", function()
    local body = '{"path":"docs/guide.md"}'
    for _, origin in ipairs({ "http://evil.example", "https://127.0.0.1:" .. port, "null", "http://127.0.0.1:1" }) do
      local res = h.fetch(port, "POST", base .. "api/open", { Origin = origin }, body)
      assert.are.equal(403, res.status, "Origin " .. origin .. h.show(res))
      assert_no_cors(res)
    end
    assert.are.equal("README.md", s.target.rel)
    local res = h.fetch(port, "POST", base .. "api/open", { Origin = "http://localhost:" .. port }, body)
    assert.are.equal(204, res.status, h.show(res))
    assert.is_nil(res.headers["content-length"], h.show(res))
    assert.are.equal("docs/guide.md", s.target.rel)
    res = h.fetch(port, "POST", base .. "api/open", nil, '{"path":"README.md"}')
    assert.are.equal(204, res.status, "POST without Origin" .. h.show(res))
  end)
end)
