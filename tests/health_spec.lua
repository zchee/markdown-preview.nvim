local h = require("helpers")

---@return string
local function run_health()
  vim.cmd("checkhealth markdown-preview")
  local text = ""
  -- Neovim 0.12+ fills the report asynchronously; the server line is the last one written.
  vim.wait(10000, function()
    text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    return text:find("preview not running", 1, true) ~= nil or text:find("preview running", 1, true) ~= nil
  end, 20)
  vim.cmd("bwipeout!")
  return text
end

describe(":checkhealth markdown-preview", function()
  local t

  before_each(function()
    t = h.tree()
  end)

  after_each(function()
    require("markdown-preview.server.static").set_web_root(nil)
    require("markdown-preview").setup({})
    h.cleanup(t)
  end)

  it("reports the Neovim version, the page and an unreachable CDN as a warning", function()
    require("markdown-preview.server.static").set_web_root(t.web)
    -- Port 1 on loopback refuses connections, so the CDN probe fails fast and deterministically.
    require("markdown-preview").setup({ cdn = "http://127.0.0.1:1/npm" })
    local text = run_health()
    local v = vim.version()
    assert.is_truthy(text:find(string.format("Neovim %d.%d.%d", v.major, v.minor, v.patch), 1, true), text)
    assert.is_truthy(text:find("configuration is valid", 1, true), text)
    assert.is_truthy(text:find("page found: " .. t.web .. "/index.html", 1, true), text)
    assert.is_truthy(text:find("WARNING CDN not reachable: http://127.0.0.1:1/npm", 1, true), text)
    assert.is_nil(text:find("ERROR", 1, true), text)
  end)

  it("reports a missing page as an error", function()
    require("markdown-preview.server.static").set_web_root(t.outside)
    require("markdown-preview").setup({ cdn = "http://127.0.0.1:1/npm" })
    local text = run_health()
    assert.is_truthy(text:find("ERROR page not found", 1, true), text)
  end)

  it("warns about a host that is not a loopback address", function()
    require("markdown-preview.server.static").set_web_root(t.web)
    require("markdown-preview").setup({ host = "0.0.0.0", cdn = "http://127.0.0.1:1/npm" })
    local text = run_health()
    assert.is_truthy(text:find('WARNING host "0.0.0.0" is not a loopback address', 1, true), text)
    require("markdown-preview").setup({ host = "127.0.0.1", cdn = "http://127.0.0.1:1/npm" })
    text = run_health()
    assert.is_nil(text:find("not a loopback address", 1, true), text)
  end)
end)
