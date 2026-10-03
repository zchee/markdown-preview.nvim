local config = require("markdown-preview.config")

local M = {}

--- Sets the options. Raises an error describing the first invalid option.
---@param opts? table
function M.setup(opts)
  config.set(opts)
end

---@return markdown_preview.Session?
local function session()
  local s = require("markdown-preview.session").current
  if s and not s.stopped then
    return s
  end
  return nil
end

--- Whether a preview server is running.
---@return boolean
function M.is_running()
  return session() ~= nil
end

--- URL of the running preview, nil when stopped.
---@return string?
function M.url()
  local s = session()
  return s and s.url or nil
end

--- Starts previewing the current buffer and opens the browser. When a preview is already running,
--- the browser is opened on it again. Returns the URL, or nil when the server could not start.
---@return string?
function M.start()
  local s = session()
  if not s then
    local err
    s, err = require("markdown-preview.session").start(vim.api.nvim_get_current_buf())
    if not s then
      vim.notify("markdown-preview: " .. tostring(err), vim.log.levels.ERROR)
      return nil
    end
    require("markdown-preview.session").current = s
    vim.notify("markdown-preview: " .. s.url, vim.log.levels.INFO)
    -- Judged on the bound address, so a name that resolves off the loopback interface also warns.
    if not config.is_loopback(s.server.ip) then
      vim.notify(
        string.format(
          "markdown-preview: host %q (%s) is not a loopback address; other machines can reach the preview",
          config.options.host,
          s.server.ip
        ),
        vim.log.levels.WARN
      )
    end
  end
  require("markdown-preview.browser").open(s.url, config.options.browser)
  return s.url
end

--- Stops the preview: sends goodbye to every page and closes all sockets and timers.
--- Returns false when nothing was running.
---@return boolean
function M.stop()
  local s = session()
  if not s then
    return false
  end
  s:stop()
  require("markdown-preview.session").current = nil
  require("markdown-preview.browser").cleanup()
  return true
end

--- Stops a running preview, otherwise starts one.
function M.toggle()
  if not M.stop() then
    M.start()
  end
end

---@param apply fun(o: markdown_preview.Config)
local function update(apply)
  apply(config.options)
  local s = session()
  if s then
    s:broadcast_config()
  end
end

function M.scroll_on()
  update(function(o)
    o.scroll.disable = false
  end)
end

function M.scroll_off()
  update(function(o)
    o.scroll.disable = true
  end)
end

function M.scroll_toggle()
  update(function(o)
    o.scroll.disable = not o.scroll.disable
  end)
end

function M.cursorline_on()
  update(function(o)
    o.cursor_line.disable = false
  end)
end

function M.cursorline_off()
  update(function(o)
    o.cursor_line.disable = true
  end)
end

function M.cursorline_toggle()
  update(function(o)
    o.cursor_line.disable = not o.cursor_line.disable
  end)
end

--- Renders <details> elements open.
function M.details_tags_on()
  update(function(o)
    o.details_tags_open = true
  end)
end

--- Renders <details> elements closed.
function M.details_tags_off()
  update(function(o)
    o.details_tags_open = false
  end)
end

function M.details_tags_toggle()
  update(function(o)
    o.details_tags_open = not o.details_tags_open
  end)
end

return M
