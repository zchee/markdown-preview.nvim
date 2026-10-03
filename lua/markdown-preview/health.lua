local M = {}

local CDN_TIMEOUT_SECONDS = 3

local function check_neovim()
  local v = vim.version()
  local version = string.format("%d.%d.%d", v.major, v.minor, v.patch)
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim " .. version)
  else
    vim.health.error("Neovim " .. version .. " is too old", { "Neovim 0.11 or newer is required." })
  end
end

local function check_web_assets()
  local static = require("markdown-preview.server.static")
  local index = vim.fs.joinpath(static.web_root(), "index.html")
  if vim.uv.fs_stat(index) then
    vim.health.ok("page found: " .. index)
  else
    vim.health.error("page not found: " .. index, { "Reinstall the plugin; the web/ directory is part of it." })
  end
end

local function check_config()
  local config = require("markdown-preview.config")
  local ok, err = pcall(config.resolve, config.options)
  if ok then
    vim.health.ok("configuration is valid")
  else
    vim.health.error(tostring(err))
  end
  local host = config.options.host
  if not config.is_loopback(host) then
    vim.health.warn(
      string.format("host %q is not a loopback address", host),
      { "Other machines on the network can reach the preview server. Use 127.0.0.1 unless that is intended." }
    )
  end
end

-- The browser loads its renderer from the CDN. Reachability from Neovim's host is a hint only (the
-- browser may use a proxy), so failures are warnings.
local function check_cdn()
  local cdn = require("markdown-preview.config").options.cdn
  if vim.fn.executable("curl") ~= 1 then
    vim.health.warn("curl not found; CDN reachability not checked (" .. cdn .. ")")
    return
  end
  local url = cdn:gsub("/+$", "") .. "/markdown-it@15.0.2/package.json"
  local done = vim
    .system({
      "curl",
      "--silent",
      "--show-error",
      "--location",
      "--output",
      "/dev/null",
      "--write-out",
      "%{http_code}",
      "--max-time",
      tostring(CDN_TIMEOUT_SECONDS),
      url,
    }, { text = true })
    :wait((CDN_TIMEOUT_SECONDS + 1) * 1000)
  local code = vim.trim(done.stdout or "")
  if done.code == 0 and code:match("^2") then
    vim.health.ok("CDN reachable: " .. cdn)
  else
    local reason = done.code == 0 and ("HTTP " .. code) or vim.trim(done.stderr or "")
    if reason == "" then
      reason = "timed out"
    end
    vim.health.warn(
      "CDN not reachable: " .. cdn .. " (" .. reason .. ")",
      { "The preview page needs the CDN to render. Check the network or set the `cdn` option to a mirror." }
    )
  end
end

local function check_server()
  local mp = require("markdown-preview")
  if mp.is_running() then
    vim.health.info("preview running at " .. mp.url())
  else
    vim.health.info("preview not running")
  end
end

function M.check()
  vim.health.start("markdown-preview")
  check_neovim()
  check_config()
  check_web_assets()
  check_cdn()
  check_server()
end

return M
