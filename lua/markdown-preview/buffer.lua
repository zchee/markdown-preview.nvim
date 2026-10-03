local uv = vim.uv
local normalize = require("markdown-preview.server.static").normalize

local M = {}

M.MAX_CONTENT_BYTES = 500 * 1000

local markdown_extensions = { md = true, markdown = true, mdown = true, mkd = true }

--- Whether a file name has one of the Markdown extensions the preview accepts.
---@param path string
---@return boolean
function M.is_markdown_path(path)
  local ext = path:match("%.([%w]+)$")
  return ext ~= nil and markdown_extensions[ext:lower()] == true
end

---@param lines string[]
---@return integer
function M.byte_size(lines)
  local n = 0
  for _, l in ipairs(lines) do
    n = n + #l + 1
  end
  return n
end

--- Splits file content into lines without trailing newlines.
---@param content string
---@return string[]
function M.split_lines(content)
  content = content:gsub("\r\n", "\n")
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

--- Real absolute path for a buffer name. A file that does not exist yet keeps its name under the
--- real path of its directory.
---@param name string
---@return string
function M.real_path(name)
  local abs = normalize(vim.fn.fnamemodify(name, ":p"))
  local real = uv.fs_realpath(abs)
  if real then
    return normalize(real)
  end
  local dir = uv.fs_realpath(vim.fs.dirname(abs))
  if dir then
    return vim.fs.joinpath(normalize(dir), vim.fs.basename(abs))
  end
  return abs
end

--- Preview root for a file: the directory holding `.git` above it, else the file's directory.
---@param real string
---@return string
function M.root_for(real)
  local found = vim.fs.root(real, ".git")
  local root = found and uv.fs_realpath(found) or vim.fs.dirname(real)
  return normalize(root)
end

--- Loaded buffer whose file is `real`, if any.
---@param real string
---@return integer?
function M.find_loaded_buffer(real)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.bo[buf].buftype == "" and M.real_path(name) == real then
        return buf
      end
    end
  end
  return nil
end

--- Attaches change tracking to `buf` for `session`. Any earlier attachment of the session stops
--- delivering events because its generation no longer matches.
---@param session markdown_preview.Session
---@param buf integer
function M.attach(session, buf)
  session.generation = session.generation + 1
  local gen = session.generation
  local function changed()
    if session.stopped or session.generation ~= gen then
      return true
    end
    -- Called for every change, including inside macros and :substitute; only arm the timer here.
    session:schedule_content()
  end
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = changed,
    on_reload = changed,
    on_detach = function()
      if session.generation == gen then
        -- Detach runs while the buffer is being unloaded; send from the main loop afterwards.
        vim.schedule(function()
          session:buffer_closed(buf)
        end)
      end
    end,
  })
end

--- Releases the current attachment without attaching another buffer.
---@param session markdown_preview.Session
function M.detach(session)
  session.generation = session.generation + 1
end

--- Creates the autocommands that drive cursor sync, buffer switching and shutdown.
---@param session markdown_preview.Session
---@return integer augroup
function M.create_autocmds(session)
  local group = vim.api.nvim_create_augroup("markdown-preview", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(args)
      session:cursor_moved(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      local buf = args.buf
      if vim.bo[buf].buftype ~= "" or vim.bo[buf].filetype ~= "markdown" then
        return
      end
      if vim.api.nvim_buf_get_name(buf) == "" then
        return
      end
      session:enter_buffer(buf)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      require("markdown-preview").stop()
      -- Neovim may not run the event loop again after this autocmd; give the goodbye event and the
      -- socket shutdowns a bounded chance to reach the browser.
      vim.wait(200, function()
        return session.server:connection_count() == 0
      end, 10)
    end,
  })
  return group
end

return M
