local M = {}

local levels = { error = 1, warn = 2, info = 3, debug = 4 }
local vim_levels = {
  error = vim.log.levels.ERROR,
  warn = vim.log.levels.WARN,
  info = vim.log.levels.INFO,
  debug = vim.log.levels.DEBUG,
}

--- Notifies when `level` is enabled by `log_level`. Safe to call from fast-event callbacks.
---@param level "error"|"warn"|"info"|"debug"
---@param fmt string
---@param ... any
function M.log(level, fmt, ...)
  local configured = require("markdown-preview.config").options.log_level
  -- Errors are always shown; other levels only when log_level enables them.
  if level ~= "error" and (configured == nil or levels[level] > levels[configured]) then
    return
  end
  local msg = "markdown-preview: " .. string.format(fmt, ...)
  vim.schedule(function()
    vim.notify(msg, vim_levels[level])
  end)
end

return M
