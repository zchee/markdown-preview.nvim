local uv = vim.uv

local M = {}

M.MAX_HEADER_BYTES = 16 * 1024
-- Only POST api/open carries a body, and it holds one short JSON path.
M.MAX_BODY_BYTES = 16 * 1024
M.MAX_CONNECTIONS = 64
-- A connection that has not sent a complete request by then is closed.
M.REQUEST_TIMEOUT_MS = 10000
-- A final write to a peer that stopped reading is abandoned after this long.
M.FINISH_TIMEOUT_MS = 2000

local status_text = {
  [200] = "OK",
  [204] = "No Content",
  [206] = "Partial Content",
  [301] = "Moved Permanently",
  [400] = "Bad Request",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [408] = "Request Timeout",
  [413] = "Content Too Large",
  [415] = "Unsupported Media Type",
  [416] = "Range Not Satisfiable",
  [431] = "Request Header Fields Too Large",
  [500] = "Internal Server Error",
  [501] = "Not Implemented",
  [503] = "Service Unavailable",
  [505] = "HTTP Version Not Supported",
}

---@class markdown_preview.RequestHead
---@field method string
---@field target string Raw request target, e.g. "/token/file/a%20b.png?x=1".
---@field path string Target without the query string, still percent-encoded.
---@field version string "1.0" or "1.1".
---@field headers table<string, string> Lower-cased names; repeated headers joined with ", ".
---@field content_length integer

---@class markdown_preview.Request : markdown_preview.RequestHead
---@field body string

---@class markdown_preview.ParseError
---@field status integer
---@field message string

---@alias markdown_preview.Precheck fun(head: markdown_preview.RequestHead): integer?, string?

---@class markdown_preview.Parser
---@field private buf string Header bytes received so far.
---@field private head? markdown_preview.RequestHead
---@field private body string[] Body chunks, joined once complete.
---@field private body_len integer
---@field private precheck? markdown_preview.Precheck
local Parser = {}
Parser.__index = Parser

--- Creates an incremental HTTP/1.x request parser that accepts arbitrarily split input.
--- `precheck` runs as soon as the header block is parsed, before any body byte is kept; a status
--- it returns rejects the request.
---@param precheck? markdown_preview.Precheck
---@return markdown_preview.Parser
function M.new_parser(precheck)
  return setmetatable({ buf = "", head = nil, body = {}, body_len = 0, precheck = precheck }, Parser)
end

local tchar_name = "^[%w!#$%%&'*+%-.^_`|~]+$"

---@param status integer
---@param message string
---@return nil, markdown_preview.ParseError
local function fail(status, message)
  return nil, { status = status, message = message }
end

---@param block string Header block without the terminating empty line.
---@return markdown_preview.RequestHead?, markdown_preview.ParseError?
local function parse_head(block)
  local lines = vim.split(block, "\r\n", { plain = true })
  if lines[1]:find("%z") then
    return fail(400, "NUL in request line")
  end
  local method, target, major, minor = lines[1]:match("^(%u+) (%S+) HTTP/(%d)%.(%d)$")
  if not method then
    return fail(400, "malformed request line")
  end
  if major ~= "1" then
    return fail(505, "unsupported HTTP version")
  end
  local headers = {} ---@type table<string, string>
  local content_length ---@type integer?
  for i = 2, #lines do
    local line = lines[i]
    if line:match("^[ \t]") then
      return fail(400, "obsolete header line folding")
    end
    local name, value = line:match("^([^:]+):[ \t]*(.-)[ \t]*$")
    if not name or not name:match(tchar_name) then
      return fail(400, "malformed header line")
    end
    if value:find("[%z\1-\8\10-\31\127]") then
      return fail(400, "control character in header value")
    end
    name = name:lower()
    if name == "content-length" then
      if not value:match("^%d+$") or #value > 15 then
        return fail(400, "invalid Content-Length")
      end
      local n = tonumber(value) --[[@as integer]]
      if content_length and content_length ~= n then
        return fail(400, "conflicting Content-Length headers")
      end
      content_length = n
    end
    headers[name] = headers[name] and (headers[name] .. ", " .. value) or value
  end
  if headers["transfer-encoding"] then
    return fail(501, "Transfer-Encoding is not supported")
  end
  local version = major .. "." .. minor
  if version == "1.1" and not headers["host"] then
    return fail(400, "missing Host header")
  end
  return {
    method = method,
    target = target,
    path = target:match("^[^?#]*"),
    version = version,
    headers = headers,
    content_length = content_length or 0,
  }
end

---@param head markdown_preview.RequestHead
---@return markdown_preview.ParseError?
local function check_body(head)
  if head.content_length == 0 then
    return nil
  end
  if head.method ~= "POST" then
    return { status = 400, message = "a request body is only accepted on POST" }
  end
  if head.content_length > M.MAX_BODY_BYTES then
    return { status = 413, message = string.format("request body exceeds %d bytes", M.MAX_BODY_BYTES) }
  end
  return nil
end

--- Feeds bytes to the parser.
--- Returns the complete request, or nil when more bytes are needed, or nil plus an error.
---@param chunk string
---@return markdown_preview.Request?, markdown_preview.ParseError?
function Parser:feed(chunk)
  if not self.head then
    self.buf = self.buf .. chunk
    local stop = self.buf:find("\r\n\r\n", 1, true)
    if not stop then
      if #self.buf > M.MAX_HEADER_BYTES then
        return fail(431, "request header exceeds 16 kB")
      end
      return nil
    end
    if stop + 3 > M.MAX_HEADER_BYTES then
      return fail(431, "request header exceeds 16 kB")
    end
    local head, err = parse_head(self.buf:sub(1, stop - 1))
    if not head then
      return nil, err
    end
    if self.precheck then
      local status, message = self.precheck(head)
      if status then
        return fail(status, message or "forbidden")
      end
    end
    local berr = check_body(head)
    if berr then
      return nil, berr
    end
    self.head = head
    chunk = self.buf:sub(stop + 4)
    self.buf = ""
  end
  local head = self.head --[[@as markdown_preview.RequestHead]]
  if #chunk > 0 and self.body_len < head.content_length then
    self.body[#self.body + 1] = chunk
    self.body_len = self.body_len + #chunk
  end
  if self.body_len < head.content_length then
    return nil
  end
  local body = table.concat(self.body):sub(1, head.content_length)
  return {
    method = head.method,
    target = head.target,
    path = head.path,
    version = head.version,
    headers = head.headers,
    content_length = head.content_length,
    body = body,
  }
end

---@class markdown_preview.Conn
---@field tcp uv.uv_tcp_t
---@field server markdown_preview.Server
---@field closed boolean True once close has been requested.
---@field finishing boolean True while a graceful shutdown is flushing pending writes.
---@field handled boolean True once a complete request was handed to the handler.
---@field on_eof? fun(conn: markdown_preview.Conn) Called when the peer closes after the request.
---@field deadline? uv.uv_timer_t Closes the connection when the request, or the final flush, takes too long.
local Conn = {}
Conn.__index = Conn

--- Cancels the request deadline; called once the request is complete.
function Conn:clear_deadline()
  local timer = self.deadline
  if timer then
    self.deadline = nil
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
end

--- Closes the socket immediately; pending writes are cancelled.
function Conn:destroy()
  if self.closed then
    return
  end
  self.closed = true
  self:clear_deadline()
  local tcp = self.tcp
  if not tcp:is_closing() then
    tcp:close(function()
      self.server.conns[self] = nil
    end)
  else
    self.server.conns[self] = nil
  end
end

--- Flushes pending writes, then closes the socket.
function Conn:finish()
  if self.closed or self.finishing then
    return
  end
  self.finishing = true
  local ok = self.tcp:shutdown(function()
    self:destroy()
  end)
  if not ok then
    self:destroy()
    return
  end
  self:clear_deadline()
  local timer = uv.new_timer()
  if timer then
    self.deadline = timer
    timer:start(M.FINISH_TIMEOUT_MS, 0, function()
      self:destroy()
    end)
  end
end

--- Writes raw bytes. `cb` receives an error string or nil.
---@param data string
---@param cb? fun(err?: string)
---@return boolean ok
function Conn:write(data, cb)
  if self.closed or self.finishing or self.tcp:is_closing() then
    if cb then
      cb("connection closed")
    end
    return false
  end
  local ok, err = self.tcp:write(data, function(werr)
    if cb then
      cb(werr)
    end
  end)
  if not ok then
    if cb then
      cb(err or "write failed")
    end
    return false
  end
  return true
end

---@param status integer
---@param headers? table<string, string|integer>
---@return string
local function build_head(status, headers)
  headers = headers or {}
  local merged = { ---@type table<string, string|integer>
    ["Connection"] = "close",
    ["Cache-Control"] = "no-store",
    ["X-Content-Type-Options"] = "nosniff",
  }
  for k, v in pairs(headers) do
    merged[k] = v
  end
  local names = vim.tbl_keys(merged)
  table.sort(names)
  local out = { string.format("HTTP/1.1 %d %s", status, status_text[status] or "Unknown") }
  for _, name in ipairs(names) do
    out[#out + 1] = name .. ": " .. tostring(merged[name])
  end
  return table.concat(out, "\r\n") .. "\r\n\r\n"
end

--- Writes the status line and headers. The caller writes the body and calls finish().
---@param status integer
---@param headers? table<string, string|integer>
---@param cb? fun(err?: string)
function Conn:write_head(status, headers, cb)
  self:write(build_head(status, headers), cb)
end

--- Sends a complete response and closes the connection afterwards.
---@param status integer
---@param headers? table<string, string|integer>
---@param body? string
function Conn:respond(status, headers, body)
  body = body or ""
  headers = vim.deepcopy(headers or {})
  -- RFC 9110 forbids Content-Length on 204.
  if status ~= 204 then
    headers["Content-Length"] = #body
  end
  self:write(build_head(status, headers) .. body)
  self:finish()
end

--- Sends `{"error": message}` with the given status and closes the connection.
---@param status integer
---@param message string
---@param headers? table<string, string|integer>
function Conn:error(status, message, headers)
  headers = vim.deepcopy(headers or {})
  headers["Content-Type"] = "application/json"
  self:respond(status, headers, vim.json.encode({ error = message }))
end

---@class markdown_preview.Server
---@field tcp uv.uv_tcp_t
---@field host string Configured host, possibly a name.
---@field ip string Literal address the socket is bound to (a name is resolved once, at listen).
---@field port integer
---@field conns table<markdown_preview.Conn, true>
---@field closed boolean
local Server = {}
Server.__index = Server

--- Number of client connections whose handles are not yet fully closed.
---@return integer
function Server:connection_count()
  return vim.tbl_count(self.conns)
end

--- Stops listening and destroys every connection that is not already flushing a final write.
--- `cb` runs once the listening socket is closed.
---@param cb? fun()
function Server:close(cb)
  if self.closed then
    if cb then
      cb()
    end
    return
  end
  self.closed = true
  for conn in pairs(self.conns) do
    if not conn.finishing then
      conn:destroy()
    end
  end
  if not self.tcp:is_closing() then
    self.tcp:close(cb)
  elseif cb then
    cb()
  end
end

---@param server markdown_preview.Server
---@param tcp uv.uv_tcp_t
---@param handler fun(conn: markdown_preview.Conn, req: markdown_preview.Request)
---@param precheck? markdown_preview.Precheck
local function accept(server, tcp, handler, precheck)
  local conn = setmetatable({
    tcp = tcp,
    server = server,
    closed = false,
    finishing = false,
    handled = false,
  }, Conn)
  server.conns[conn] = true
  local deadline = uv.new_timer()
  if deadline then
    conn.deadline = deadline
    deadline:start(M.REQUEST_TIMEOUT_MS, 0, function()
      if not conn.handled then
        conn:destroy()
      end
    end)
  end
  local parser = M.new_parser(precheck)
  tcp:read_start(function(err, chunk)
    if conn.closed then
      return
    end
    if err or chunk == nil then
      if conn.on_eof then
        conn.on_eof(conn)
      elseif conn.handled and not err then
        -- The peer half-closed after sending its request; the response may still be streaming
        -- (asynchronous file reads). Write errors and finish() end the connection.
        conn.tcp:read_stop()
        return
      end
      conn:destroy()
      return
    end
    if conn.handled then
      -- One request per connection; later bytes (pipelining, or keep-alive probes on the event
      -- stream) are ignored. EOF is still observed above.
      return
    end
    local req, perr = parser:feed(chunk)
    if perr then
      conn.handled = true
      conn:clear_deadline()
      conn:error(perr.status, perr.message)
      return
    end
    if req then
      conn.handled = true
      conn:clear_deadline()
      -- Handlers call Neovim API functions, which are not allowed in libuv callbacks.
      vim.schedule(function()
        if conn.closed then
          return
        end
        local ok, herr = pcall(handler, conn, req)
        if not ok then
          require("markdown-preview.log").log("error", "request handler failed: %s", tostring(herr))
          if not conn.closed and not conn.finishing then
            conn:error(500, "internal server error")
          end
        end
      end)
    end
  end)
end

---@param host string
---@return string? ip, string? err
local function resolve_host(host)
  local bare = host:match("^%[(.*)%]$") or host
  if bare:match("^%d+%.%d+%.%d+%.%d+$") or bare:find(":", 1, true) then
    return bare
  end
  local res, err = uv.getaddrinfo(bare, nil, { socktype = "stream" })
  if not res or not res[1] then
    return nil, string.format("cannot resolve host %q: %s", host, tostring(err))
  end
  return res[1].addr
end

--- Binds and listens. `handler` is called on the main loop for every complete request.
--- `opts.precheck` runs on each header block before any body byte is read (see new_parser).
---@param opts { host: string, port: integer, precheck?: markdown_preview.Precheck }
---@param handler fun(conn: markdown_preview.Conn, req: markdown_preview.Request)
---@return markdown_preview.Server? server, string? err
function M.listen(opts, handler)
  local ip, rerr = resolve_host(opts.host)
  if not ip then
    return nil, rerr
  end
  local tcp = assert(uv.new_tcp())
  local ok, err = tcp:bind(ip, opts.port)
  if not ok then
    tcp:close()
    return nil, string.format("cannot bind %s:%d: %s", ip, opts.port, tostring(err))
  end
  local server = setmetatable({ tcp = tcp, host = opts.host, ip = ip, port = 0, conns = {}, closed = false }, Server)
  ok, err = tcp:listen(128, function(lerr)
    if lerr or server.closed then
      return
    end
    local client = uv.new_tcp()
    if not client then
      return
    end
    if not tcp:accept(client) then
      client:close()
      return
    end
    if server:connection_count() >= M.MAX_CONNECTIONS then
      client:close()
      return
    end
    accept(server, client, handler, opts.precheck)
  end)
  if not ok then
    tcp:close()
    return nil, string.format("cannot listen on %s:%d: %s", ip, opts.port, tostring(err))
  end
  local name = tcp:getsockname()
  server.port = name and name.port or opts.port
  return server
end

return M
