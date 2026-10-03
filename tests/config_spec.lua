local config = require("markdown-preview.config")

describe("config", function()
  after_each(function()
    config.set({})
  end)

  it("defaults to the documented values", function()
    local o = config.resolve()
    assert.are.same({
      host = "127.0.0.1",
      port = 0,
      theme = { name = "system", high_contrast = false },
      details_tags_open = true,
      cursor_line = { disable = false, color = "#c86414", opacity = 0.2 },
      scroll = { disable = false, top_offset_pct = 35 },
      debounce_ms = 30,
      cdn = "https://cdn.jsdelivr.net/npm",
    }, o)
    assert.is_nil(o.browser)
    assert.is_nil(o.log_level)
  end)

  it("deep-merges nested tables and replaces lists", function()
    local o = config.resolve({ scroll = { top_offset_pct = 10 }, browser = { "firefox", "--new-tab" } })
    assert.are.same({ disable = false, top_offset_pct = 10 }, o.scroll)
    assert.are.same({ "firefox", "--new-tab" }, o.browser)
    assert.is_false(config.resolve({ browser = false }).browser)
  end)

  local cdn_msg = "cdn: expected https:// URL (http:// only for a loopback host) without whitespace, ';' or ','"
  local invalid = {
    { { port = -1 }, "port: expected integer between 0 and 65535, got -1" },
    { { port = 70000 }, "port: expected integer between 0 and 65535" },
    { { port = 1.5 }, "port: expected integer between 0 and 65535" },
    { { host = "" }, "host: expected non-empty string" },
    { { browser = 1 }, "browser: expected nil, false, a command string or a non-empty list of strings" },
    { { browser = {} }, "browser: expected nil, false" },
    { { browser = { "x", 2 } }, "browser: expected nil, false" },
    { { browser = true }, "browser: expected nil, false" },
    { { theme = { name = "blue" } }, 'theme.name: expected "system", "light" or "dark"' },
    { { theme = "dark" }, "theme: expected table, got string" },
    { { theme = { high_contrast = "yes" } }, "theme.high_contrast: expected boolean, got string" },
    { { details_tags_open = 1 }, "details_tags_open: expected boolean, got number" },
    { { cursor_line = { opacity = 1.5 } }, "cursor_line.opacity: expected number between 0 and 1" },
    { { cursor_line = { color = 1 } }, "cursor_line.color: expected string, got number" },
    { { scroll = { top_offset_pct = 101 } }, "scroll.top_offset_pct: expected number between 0 and 100" },
    { { debounce_ms = -5 }, "debounce_ms: expected non-negative integer" },
    { { cdn = "ftp://example.com" }, cdn_msg },
    { { cdn = "http://cdn.example.com/npm" }, cdn_msg },
    { { cdn = "http://10.0.0.1:8080/npm" }, cdn_msg },
    { { cdn = "https://cdn.example.com/npm; script-src *" }, cdn_msg },
    { { cdn = "https://a.example, https://b.example" }, cdn_msg },
    { { cdn = "https://cdn.example.com/n pm" }, cdn_msg },
    { { cdn = "https://cdn.example.com/\r\nX: 1" }, cdn_msg },
    { { cdn = "https://cdn.example.com/\tx" }, cdn_msg },
    { { log_level = "verbose" }, 'log_level: expected nil, "error", "warn", "info" or "debug"' },
    { { prot = 1 }, 'unknown option "prot"' },
    { { scroll = { offset = 1 } }, 'unknown option "scroll.offset"' },
    { "x", "options must be a table" },
  }
  for _, case in ipairs(invalid) do
    it("rejects " .. vim.inspect(case[1], { newline = " ", indent = "" }), function()
      local ok, err = pcall(config.resolve, case[1])
      assert.is_false(ok, "accepted " .. vim.inspect(case[1]))
      err = tostring(err)
      assert.is_truthy(err:find("markdown-preview: invalid config: ", 1, true), err)
      assert.is_truthy(err:find(case[2], 1, true), "message " .. err .. " lacks " .. case[2])
    end)
  end

  it("accepts https CDNs and http CDNs on a loopback host", function()
    for _, cdn in ipairs({
      "https://cdn.jsdelivr.net/npm",
      "https://mirror.example:8443/npm/",
      "http://127.0.0.1:8080/npm",
      "http://localhost/npm",
      "http://[::1]:9000",
      "http://127.1.2.3/npm",
    }) do
      local ok, err = pcall(config.resolve, { cdn = cdn })
      assert.is_true(ok, cdn .. ": " .. tostring(err))
    end
  end)

  it("recognises loopback hosts", function()
    for _, host in ipairs({ "127.0.0.1", "127.9.9.9", "localhost", "LOCALHOST", "::1", "[::1]" }) do
      assert.is_true(config.is_loopback(host), host)
    end
    for _, host in ipairs({ "0.0.0.0", "10.0.0.1", "::", "example.com", "localhost.example.com", "128.0.0.1" }) do
      assert.is_false(config.is_loopback(host), host)
    end
  end)

  it("keeps the previous options when setup() fails", function()
    require("markdown-preview").setup({ debounce_ms = 5 })
    assert.is_false(pcall(require("markdown-preview").setup, { debounce_ms = "fast" }))
    assert.are.equal(5, config.options.debounce_ms)
  end)

  it("exposes the browser subset and the cdn origin", function()
    config.set({ cdn = "https://mirror.example:8443/npm/", theme = { name = "dark" } })
    assert.are.equal("https://mirror.example:8443", config.cdn_origin())
    assert.are.same({
      theme = { name = "dark", high_contrast = false },
      details_tags_open = true,
      cursor_line = { disable = false, color = "#c86414", opacity = 0.2 },
      scroll = { disable = false, top_offset_pct = 35 },
    }, config.browser_view())
  end)
end)
