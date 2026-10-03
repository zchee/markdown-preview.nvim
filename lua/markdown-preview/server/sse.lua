local uv = vim.uv

local M = {}

M.PING_INTERVAL_MS = 15000
M.MAX_CLIENTS = 16
-- A client that stops reading is dropped once this much output is waiting for it.
M.MAX_QUEUE_BYTES = 4 * 1024 * 1024

---@class markdown_preview.SSE
---@field clients table<markdown_preview.Conn, true>
---@field timer? uv.uv_timer_t
local SSE = {}
SSE.__index = SSE

--- Formats one event in the wire form `event: <type>\ndata: <json>\n\n`.
---@param event string
---@param data table
---@return string
function M.format(event, data)
  return "event: " .. event .. "\ndata: " .. vim.json.encode(data) .. "\n\n"
end

--- Creates a client registry with a keep-alive ping every `ping_ms` milliseconds.
---@param ping_ms? integer
---@return markdown_preview.SSE
function M.new(ping_ms)
  local self = setmetatable({ clients = {} }, SSE)
  local timer = assert(uv.new_timer())
  local interval = ping_ms or M.PING_INTERVAL_MS
  timer:start(interval, interval, function()
    self:send_raw(": ping\n\n")
  end)
  self.timer = timer
  return self
end

---@param conn markdown_preview.Conn
function SSE:remove(conn)
  if self.clients[conn] then
    self.clients[conn] = nil
    conn:destroy()
  end
end

--- Takes ownership of a connection, sends the response head and `first` (the init event).
--- Answers 503 instead when MAX_CLIENTS streams are already open.
---@param conn markdown_preview.Conn
---@param first string Already formatted event.
---@return boolean accepted
function SSE:add(conn, first)
  if self:count() >= M.MAX_CLIENTS then
    conn:error(503, "too many event-stream clients")
    return false
  end
  self.clients[conn] = true
  conn.on_eof = function(c)
    self.clients[c] = nil
  end
  conn:write_head(200, {
    ["Content-Type"] = "text/event-stream; charset=utf-8",
    ["Connection"] = "keep-alive",
  })
  conn:write(first, function(err)
    if err then
      self:remove(conn)
    end
  end)
  return true
end

---@param payload string
function SSE:send_raw(payload)
  for conn in pairs(self.clients) do
    if conn.tcp:get_write_queue_size() > M.MAX_QUEUE_BYTES then
      self:remove(conn)
    else
      conn:write(payload, function(err)
        if err then
          self:remove(conn)
        end
      end)
    end
  end
end

--- Sends one event to every connected client.
---@param event string
---@param data table
function SSE:broadcast(event, data)
  if next(self.clients) == nil then
    return
  end
  self:send_raw(M.format(event, data))
end

---@return integer
function SSE:count()
  return vim.tbl_count(self.clients)
end

--- Sends `goodbye`, flushes and closes every client, and stops the ping timer.
function SSE:close()
  local payload = M.format("goodbye", vim.empty_dict())
  for conn in pairs(self.clients) do
    conn:write(payload)
    conn:finish()
  end
  self.clients = {}
  if self.timer and not self.timer:is_closing() then
    self.timer:stop()
    self.timer:close()
  end
  self.timer = nil
end

return M
