local uv = vim.uv
local log = require("markdown-preview.log")

local M = {}

-- The browser reads the redirect file within this time; afterwards it only keeps the token.
M.CLEANUP_MS = 10000

---@class markdown_preview.RedirectFile
---@field dir string
---@field file string
---@field timer? uv.uv_timer_t

---@type table<markdown_preview.RedirectFile, true>
local pending = {}

---@param s string
---@return string
local function html_escape(s)
  return (
    s:gsub("[&<>\"']", {
      ["&"] = "&amp;",
      ["<"] = "&lt;",
      [">"] = "&gt;",
      ['"'] = "&quot;",
      ["'"] = "&#39;",
    })
  )
end

---@param r markdown_preview.RedirectFile
local function remove(r)
  if not pending[r] then
    return
  end
  pending[r] = nil
  if r.timer and not r.timer:is_closing() then
    r.timer:stop()
    r.timer:close()
  end
  uv.fs_unlink(r.file)
  uv.fs_rmdir(r.dir)
end

--- Writes a page that redirects to `url` into a fresh mode-0700 directory as a mode-0600 file.
--- The token in `url` then never appears on another process's command line.
---@param url string
---@return markdown_preview.RedirectFile? redirect, string? err
function M.write_redirect(url)
  local dir, derr = uv.fs_mkdtemp(vim.fs.joinpath(uv.os_tmpdir(), "markdown-preview-XXXXXX"))
  if not dir then
    return nil, "cannot create temporary directory: " .. tostring(derr)
  end
  local file = vim.fs.joinpath(dir, "open.html")
  local fd, oerr = uv.fs_open(file, "wx", 384)
  if not fd then
    uv.fs_rmdir(dir)
    return nil, "cannot create redirect file: " .. tostring(oerr)
  end
  local escaped = html_escape(url)
  local html = table.concat({
    "<!doctype html>",
    '<meta charset="utf-8">',
    '<meta name="referrer" content="no-referrer">',
    '<meta http-equiv="refresh" content="0;url=' .. escaped .. '">',
    "<title>markdown-preview</title>",
    '<a href="' .. escaped .. '">Open the preview</a>',
    "",
  }, "\n")
  local ok, werr = uv.fs_write(fd, html, 0)
  uv.fs_close(fd)
  local r = { dir = dir, file = file }
  pending[r] = true
  if not ok then
    remove(r)
    return nil, "cannot write redirect file: " .. tostring(werr)
  end
  local timer = uv.new_timer()
  if timer then
    r.timer = timer
    timer:start(M.CLEANUP_MS, 0, function()
      remove(r)
    end)
  end
  return r
end

--- Deletes every redirect file that is still on disk.
function M.cleanup()
  for r in pairs(pending) do
    remove(r)
  end
end

--- Opens the preview in a browser through a temporary redirect file: vim.ui.open when `browser`
--- is nil, a command (string or argv list, run without a shell) otherwise, nothing when false.
---@param url string
---@param browser nil|false|string|string[]
function M.open(url, browser)
  if browser == false then
    return
  end
  local r, err = M.write_redirect(url)
  if not r then
    log.log("error", "%s", err)
    return
  end
  if browser == nil then
    local _, oerr = vim.ui.open(r.file)
    if oerr then
      log.log("error", "cannot open browser: %s", oerr)
    end
    return
  end
  local cmd ---@type string[]
  if type(browser) == "string" then
    cmd = { browser }
  else
    cmd = vim.deepcopy(browser)
  end
  cmd[#cmd + 1] = r.file
  local ok, serr = pcall(vim.system, cmd, { detach = true })
  if not ok then
    log.log("error", "cannot run browser command %q: %s", cmd[1], tostring(serr))
  end
end

return M
