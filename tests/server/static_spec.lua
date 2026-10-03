local h = require("helpers")
local static = require("markdown-preview.server.static")

describe("static helpers", function()
  it("decodes percent escapes and rejects malformed ones", function()
    assert.are.equal("a b/../c", static.percent_decode("a%20b%2F%2e%2E/c"))
    assert.is_nil(static.percent_decode("a%2"))
    assert.is_nil(static.percent_decode("a%zz"))
    assert.is_nil(static.percent_decode("%"))
  end)

  it("maps extensions to MIME types case-insensitively", function()
    assert.are.equal("video/mp4", static.mime_type("x/clip.MP4"))
    assert.are.equal("image/svg+xml", static.mime_type("a.svg"))
    assert.are.equal("text/javascript; charset=utf-8", static.mime_type("app.js"))
    assert.are.equal("application/octet-stream", static.mime_type("Makefile"))
  end)

  it("interprets Range headers", function()
    local cases = {
      { nil, 1000, "ignore" },
      { "bytes=0-99", 1000, { first = 0, last = 99 } },
      { "bytes=990-", 1000, { first = 990, last = 999 } },
      { "bytes=-100", 1000, { first = 900, last = 999 } },
      { "bytes=-5000", 1000, { first = 0, last = 999 } },
      { "bytes=900-5000", 1000, { first = 900, last = 999 } },
      { "bytes=1000-", 1000, "unsatisfiable" },
      { "bytes=-0", 1000, "unsatisfiable" },
      { "bytes=0-0", 0, "unsatisfiable" },
      { "bytes=5-1", 1000, "ignore" },
      { "bytes=0-1,5-9", 1000, "ignore" },
      { "items=0-1", 1000, "ignore" },
      { "bytes=a-b", 1000, "ignore" },
      { "bytes=-", 1000, "ignore" },
    }
    for _, c in ipairs(cases) do
      assert.are.same(c[3], static.parse_range(c[1], c[2]), vim.inspect(c))
    end
  end)
end)

describe("file and asset serving", function()
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

  it("serves a media file under the root with its MIME type and a sandbox CSP", function()
    local res = h.fetch(port, "GET", base .. "file/media/pic.png")
    assert.are.equal(200, res.status, h.show(res))
    assert.are.equal("\137PNG fake image bytes", res.body)
    assert.are.equal("image/png", res.headers["content-type"], h.show(res))
    assert.are.equal("bytes", res.headers["accept-ranges"], h.show(res))
    assert.are.equal(
      "sandbox; default-src 'none'; img-src 'self' data:; media-src 'self'; style-src 'unsafe-inline'",
      res.headers["content-security-policy"],
      h.show(res)
    )
    for name in pairs(res.headers) do
      assert.is_nil(name:match("^access%-control%-"), "CORS header present" .. h.show(res))
    end
  end)

  it("serves only media extensions and never dot-segments", function()
    h.write_file(vim.fs.joinpath(t.repo, ".env"), "SECRET=1\n")
    h.write_file(vim.fs.joinpath(t.repo, ".git", "config"), "[core]\n")
    h.write_file(vim.fs.joinpath(t.repo, "media", ".hidden.png"), "hidden")
    h.write_file(vim.fs.joinpath(t.repo, ".cache", "pic.png"), "hidden dir")
    h.write_file(vim.fs.joinpath(t.repo, "src", "evil.js"), "alert(1)")
    h.write_file(vim.fs.joinpath(t.repo, "docs", "page.html"), "<script>alert(1)</script>")
    local forbidden = {
      "file/README.md",
      "file/docs/notes.txt",
      "file/src/evil.js",
      "file/docs/page.html",
      "file/.env",
      "file/.git/config",
      "file/%2egit/config",
      "file/media/.hidden.png",
      "file/.cache/pic.png",
      "file/media/pic.png.js",
      "file/media/pic",
    }
    for _, path in ipairs(forbidden) do
      local res = h.fetch(port, "GET", base .. path)
      assert.are.equal(403, res.status, path .. h.show(res))
    end
    h.write_file(vim.fs.joinpath(t.repo, "media", "UPPER.PNG"), "upper")
    local res = h.fetch(port, "GET", base .. "file/media/UPPER.PNG")
    assert.are.equal(200, res.status, h.show(res))
  end)

  it("percent-decodes the path and never expands environment variables in it", function()
    h.write_file(vim.fs.joinpath(t.repo, "media", "a b#.png"), "png")
    local res = h.fetch(port, "GET", base .. "file/media/a%20b%23.png?cache=1")
    assert.are.equal(200, res.status, h.show(res))
    assert.are.equal("png", res.body)
    assert.are.equal("image/png", res.headers["content-type"])
    h.write_file(vim.fs.joinpath(t.repo, "$HOME", "env.png"), "literal dollar directory")
    res = h.fetch(port, "GET", base .. "file/%24HOME/env.png")
    assert.are.equal(200, res.status, h.show(res))
    assert.are.equal("literal dollar directory", res.body)
  end)

  it("rejects paths that leave the root, encoded or through a symlink", function()
    local cases = {
      "file/../../outside/secret.png",
      "file/docs/../../outside/secret.png",
      "file/%2e%2e/outside/secret.png",
      "file/%2E%2E%2Foutside%2Fsecret.png",
      "file/..%2f..%2f..%2f..%2f..%2f..%2fetc%2fpasswd",
      "file/../../../../../../../../etc/passwd",
      "file/%2fetc%2fpasswd",
      "file/%2f" .. t.outside:gsub("/", "%%2f") .. "%2fsecret.png",
      "file/escape/secret.png",
      "file/escape/does-not-exist.png",
      "file/escape/missing-dir/does-not-exist.png",
      "file/../../outside/does-not-exist.png",
    }
    for _, path in ipairs(cases) do
      local res = h.fetch(port, "GET", base .. path)
      assert.are.equal(403, res.status, path .. h.show(res))
      assert.is_nil(res.body:find("secret", 1, true), path .. h.show(res))
    end
  end)

  it("answers 404 for missing files and directories, 400 for bad encodings", function()
    vim.fn.mkdir(vim.fs.joinpath(t.repo, "media", "folder.png"), "p")
    for _, path in ipairs({ "file/missing.png", "file/media/folder.png", "assets/missing.js", "assets/" }) do
      local res = h.fetch(port, "GET", base .. path)
      assert.are.equal(404, res.status, path .. h.show(res))
    end
    for _, path in ipairs({ "file/a%2.png", "file/a%00b.png", "file/a%5cb.png", "file/a%0ab.png" }) do
      local res = h.fetch(port, "GET", base .. path)
      assert.are.equal(400, res.status, path .. h.show(res))
    end
  end)

  it("serves assets from the web root only", function()
    local res = h.fetch(port, "GET", base .. "assets/app.js")
    assert.are.equal(200, res.status, h.show(res))
    assert.are.equal("text/javascript; charset=utf-8", res.headers["content-type"])
    assert.are.equal("console.log('stand-in');\n", res.body)
    local escapes = { "assets/../repo/README.md", "assets/%2e%2e/repo/README.md", "assets/../outside/secret.txt" }
    for _, path in ipairs(escapes) do
      res = h.fetch(port, "GET", base .. path)
      assert.are.equal(403, res.status, path .. h.show(res))
    end
  end)

  it("answers single ranges with 206 and Content-Range", function()
    local cases = {
      { "bytes=0-99", 0, 99 },
      { "bytes=-100", 900, 999 },
      { "bytes=990-", 990, 999 },
      { "bytes=500-5000", 500, 999 },
    }
    for _, c in ipairs(cases) do
      local res = h.fetch(port, "GET", base .. "file/media/blob.mp4", { Range = c[1] })
      assert.are.equal(206, res.status, c[1] .. h.show(res))
      assert.are.equal(string.format("bytes %d-%d/1000", c[2], c[3]), res.headers["content-range"], c[1])
      assert.are.equal(tostring(c[3] - c[2] + 1), res.headers["content-length"], c[1])
      assert.are.equal(t.blob_content:sub(c[2] + 1, c[3] + 1), res.body, c[1])
    end
  end)

  it("answers unsatisfiable ranges with 416 and ignores multiple ranges", function()
    for _, r in ipairs({ "bytes=1000-", "bytes=5000-6000", "bytes=-0" }) do
      local res = h.fetch(port, "GET", base .. "file/media/blob.mp4", { Range = r })
      assert.are.equal(416, res.status, r .. h.show(res))
      assert.are.equal("bytes */1000", res.headers["content-range"], r .. h.show(res))
    end
    local res = h.fetch(port, "GET", base .. "file/media/blob.mp4", { Range = "bytes=0-1,4-5" })
    assert.are.equal(200, res.status, h.show(res))
    assert.are.equal(t.blob_content, res.body)
  end)

  it("streams a file larger than one read chunk intact", function()
    local parts = {}
    for i = 1, 40000 do
      parts[#parts + 1] = string.format("%07d\n", i)
    end
    local content = table.concat(parts) -- 320,000 bytes, several 64 kB chunks
    h.write_file(vim.fs.joinpath(t.repo, "media", "big.mp4"), content)
    local res = h.fetch(port, "GET", base .. "file/media/big.mp4")
    assert.are.equal(200, res.status, res.raw:sub(1, 400))
    assert.are.equal("video/mp4", res.headers["content-type"])
    assert.are.equal(tostring(#content), res.headers["content-length"])
    assert.are.equal(#content, #res.body)
    assert.is_true(content == res.body, "body differs from the file")
    res = h.fetch(port, "GET", base .. "file/media/big.mp4", { Range = "bytes=100000-299999" })
    assert.are.equal(206, res.status, res.raw:sub(1, 400))
    assert.is_true(content:sub(100001, 300000) == res.body, "range body differs from the file")
  end)
end)

describe("file swapped between check and open", function()
  local t

  before_each(function()
    t = h.tree()
  end)

  after_each(function()
    h.cleanup(t)
  end)

  it("answers 403 when the opened file is not the inode that was checked", function()
    local http = require("markdown-preview.server.http")
    local root = assert(vim.uv.fs_realpath(t.repo))
    local replacement = vim.fs.joinpath(t.repo, "media", "replacement.png")
    -- The handler is the same sequence the router runs (resolve, then serve), with the file
    -- replaced by a different inode in between, which is what a racing writer would do.
    local server = assert(http.listen({ host = "127.0.0.1", port = 0 }, function(conn, req)
      local r = static.resolve_media(root, req.path:sub(2))
      assert(r.path, vim.inspect(r))
      h.write_file(replacement, "swapped in")
      assert(vim.uv.fs_rename(replacement, r.path))
      static.serve_file(conn, r, req)
    end))
    local res = h.fetch(server.port, "GET", "/media/pic.png")
    server:close()
    assert.are.equal(403, res.status, h.show(res))
    assert.is_nil(res.body:find("swapped in", 1, true), h.show(res))
  end)
end)
