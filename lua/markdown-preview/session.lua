local uv = vim.uv
local buffer = require("markdown-preview.buffer")
local config = require("markdown-preview.config")
local http = require("markdown-preview.server.http")
local router = require("markdown-preview.server.router")
local sse_mod = require("markdown-preview.server.sse")
local static = require("markdown-preview.server.static")

local M = {}

---@class markdown_preview.Target
---@field real string Real absolute path of the previewed file.
---@field root string Real path of the preview root.
---@field rel string `real` relative to `root`, `/`-separated.
---@field bufnr? integer Buffer providing the content; nil when the content came from disk.
---@field lines string[] Last known content (the disk content when bufnr is nil).
---@field too_large? boolean The disk file exceeds the size limit and was not read.

---@class markdown_preview.Session
---@field token string
---@field url string
---@field server markdown_preview.Server
---@field sse markdown_preview.SSE
---@field target markdown_preview.Target
---@field generation integer Incremented on every buffer attachment change.
---@field stopped boolean
---@field augroup integer
---@field timer uv.uv_timer_t Coalesces buffer changes into one content_change.
---@field cursor_pending boolean A cursor move waits for the pending content_change.
local Session = {}
Session.__index = Session

---@type markdown_preview.Session?
M.current = nil

---@return string
local function new_token()
  local bytes = assert(uv.random(16))
  return (bytes:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

---@param real string
---@param root string
---@return string
local function relative(real, root)
  if real == root then
    return vim.fs.basename(real)
  end
  local prefix = root:sub(-1) == "/" and root or root .. "/"
  if real:sub(1, #prefix) == prefix then
    return real:sub(#prefix + 1)
  end
  return vim.fs.basename(real)
end

---@param buf integer
---@return markdown_preview.Target
local function target_for_buffer(buf)
  local real = buffer.real_path(vim.api.nvim_buf_get_name(buf))
  local root = buffer.root_for(real)
  return { real = real, root = root, rel = relative(real, root), bufnr = buf, lines = {} }
end

--- Current content of the previewed file.
---@return string[]
function Session:lines()
  local t = self.target
  if t.bufnr and vim.api.nvim_buf_is_valid(t.bufnr) and vim.api.nvim_buf_is_loaded(t.bufnr) then
    t.lines = vim.api.nvim_buf_get_lines(t.bufnr, 0, -1, false)
  end
  return t.lines
end

--- 0-based cursor line, or vim.NIL when the previewed file is not the current buffer.
---@return integer|vim.NIL
function Session:cursor_line()
  local buf = vim.api.nvim_get_current_buf()
  if self.target.bufnr == buf then
    return vim.api.nvim_win_get_cursor(0)[1] - 1
  end
  return vim.NIL
end

---@return string
local function too_large_message()
  return string.format("file too large (>%dkB)", buffer.MAX_CONTENT_BYTES / 1000)
end

--- Formatted init event, followed by an error event when the file exceeds the size limit.
---@return string
function Session:init_events()
  local lines = self:lines()
  local too_large = self.target.too_large or buffer.byte_size(lines) > buffer.MAX_CONTENT_BYTES
  local out = sse_mod.format("init", {
    path = self.target.rel,
    lines = too_large and {} or lines,
    cursor_line = self:cursor_line(),
    config = config.browser_view(),
  })
  if too_large then
    out = out .. sse_mod.format("error", { path = self.target.rel, message = too_large_message() })
  end
  return out
end

function Session:broadcast_init()
  if self.sse:count() > 0 then
    self.sse:send_raw(self:init_events())
  end
end

--- Arms the change timer. Changes arriving while it is armed are folded into the same send, so a
--- change reaches the browser at most debounce_ms after it was made.
function Session:schedule_content()
  if self.stopped or self.timer:is_active() then
    return
  end
  self.timer:start(
    config.options.debounce_ms,
    0,
    vim.schedule_wrap(function()
      self:send_content()
    end)
  )
end

function Session:send_content()
  if self.stopped or not self.target.bufnr then
    return
  end
  local lines = self:lines()
  if buffer.byte_size(lines) > buffer.MAX_CONTENT_BYTES then
    self.sse:broadcast("error", { path = self.target.rel, message = too_large_message() })
  else
    self.sse:broadcast("content_change", { path = self.target.rel, lines = lines })
  end
  if self.cursor_pending then
    self.cursor_pending = false
    self:send_cursor()
  end
end

function Session:send_cursor()
  local line = self:cursor_line()
  if line ~= vim.NIL then
    self.sse:broadcast("cursor_move", { path = self.target.rel, cursor_line = line })
  end
end

---@param buf integer
function Session:cursor_moved(buf)
  if self.stopped or buf ~= self.target.bufnr then
    return
  end
  if self.timer:is_active() then
    self.cursor_pending = true
    return
  end
  self:send_cursor()
end

--- Re-targets the preview to a Markdown buffer the user entered.
---@param buf integer
function Session:enter_buffer(buf)
  if self.stopped then
    return
  end
  if buf == self.target.bufnr then
    self:send_cursor()
    return
  end
  self.target = target_for_buffer(buf)
  buffer.attach(self, buf)
  self:broadcast_init()
end

--- Switches the previewed file to a root-relative path requested by the browser.
---@param rel string Decoded, root-relative path.
---@return integer status, string? message
function Session:open_path(rel)
  local root = self.target.root
  local r = static.resolve_decoded(root, rel)
  if not r.path then
    local status = r.status --[[@as integer]]
    return status, r.message
  end
  if not buffer.is_markdown_path(r.path) then
    return 415, "not a Markdown file"
  end
  local target = { real = r.path, root = root, rel = relative(r.path, root), lines = {} }
  local buf = buffer.find_loaded_buffer(r.path)
  if buf then
    target.bufnr = buf
    self.target = target
    buffer.attach(self, buf)
  else
    local stat = uv.fs_stat(r.path)
    if stat and stat.size <= buffer.MAX_CONTENT_BYTES then
      local content = static.read_file(r.path)
      if not content then
        return 404, "not found"
      end
      target.lines = buffer.split_lines(content)
    else
      target.too_large = true
    end
    self.target = target
    buffer.detach(self)
  end
  self.timer:stop()
  self.cursor_pending = false
  self:broadcast_init()
  return 204
end

--- Sends update_config with the current options.
function Session:broadcast_config()
  self.sse:broadcast("update_config", { config = config.browser_view() })
end

---@param conn markdown_preview.Conn
function Session:add_client(conn)
  self.sse:add(conn, self:init_events())
end

--- Closes every handle the session owns. Safe to call more than once.
function Session:stop()
  if self.stopped then
    return
  end
  self.stopped = true
  buffer.detach(self)
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  self.sse:close()
  self.server:close()
  if not self.timer:is_closing() then
    self.timer:stop()
    self.timer:close()
  end
end

---@param host string
---@return string
local function url_host(host)
  if host:find(":", 1, true) and not host:match("^%[") then
    return "[" .. host .. "]"
  end
  return host
end

--- Starts a session previewing `buf`. Returns nil and an error message on failure.
---@param buf integer
---@return markdown_preview.Session? session, string? err
function M.start(buf)
  if vim.api.nvim_buf_get_name(buf) == "" then
    return nil, "the current buffer has no file name"
  end
  local opts = config.options
  local self = setmetatable({
    token = new_token(),
    target = target_for_buffer(buf),
    generation = 0,
    stopped = false,
    cursor_pending = false,
  }, Session)
  local ctx = {
    token = self.token,
    host = opts.host,
    ip = opts.host,
    port = 0,
    cdn = opts.cdn,
    root = function()
      return self.target.root
    end,
    bootstrap = function()
      return { cdn = config.options.cdn, config = config.browser_view() }
    end,
    on_events = function(conn)
      self:add_client(conn)
    end,
    on_open = function(rel)
      return self:open_path(rel)
    end,
  }
  local listen_opts = {
    host = opts.host,
    port = opts.port,
    precheck = function(head)
      return router.precheck(ctx, head)
    end,
  }
  local server, err = http.listen(listen_opts, function(conn, req)
    if self.stopped then
      conn:destroy()
      return
    end
    router.handle(ctx, conn, req)
  end)
  if not server then
    return nil, err
  end
  ctx.port = server.port
  ctx.ip = server.ip
  self.server = server
  self.sse = sse_mod.new()
  self.timer = assert(uv.new_timer())
  -- The bound literal, not the configured name: a name like localhost may resolve to ::1 while
  -- the browser would try 127.0.0.1 first, or the reverse.
  self.url = string.format("http://%s:%d/%s/", url_host(server.ip), server.port, self.token)
  self.augroup = buffer.create_autocmds(self)
  buffer.attach(self, buf)
  return self
end

return M
