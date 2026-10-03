local static = require("markdown-preview.server.static")

local M = {}

---@class markdown_preview.RouterContext
---@field token string
---@field port integer
---@field host string Configured bind host.
---@field ip string Literal address the server is bound to.
---@field cdn string
---@field root fun(): string Real path of the current preview root.
---@field bootstrap fun(): table Bootstrap object embedded in index.html.
---@field on_events fun(conn: markdown_preview.Conn) Takes ownership of an event-stream connection.
---@field on_open fun(rel: string): integer, string? Switches the previewed file; returns status and error.

local bootstrap_placeholder = "__MP_BOOTSTRAP__"

-- Responses served from the preview root may be HTML or SVG written by anyone (a cloned
-- repository). Sandboxing them keeps their scripts out of the page's origin, which holds the token.
local file_csp = "sandbox; default-src 'none'; img-src 'self' data:; media-src 'self'; style-src 'unsafe-inline'"

---@param host string
---@return string
local function host_literal(host)
  if host:find(":", 1, true) and not host:match("^%[") then
    return "[" .. host .. "]"
  end
  return host
end

--- Host header values accepted for a server on `port`: the loopback names, the configured host
--- and the literal address it was resolved to.
---@param host string
---@param port integer
---@param ip? string
---@return table<string, true>
function M.allowed_hosts(host, port, ip)
  local set = {}
  for _, h in ipairs({ "127.0.0.1", "localhost", "[::1]", host_literal(host), host_literal(ip or host) }) do
    set[(h .. ":" .. port):lower()] = true
  end
  return set
end

--- Content-Security-Policy for the HTML page. Scripts are limited to the page's own assets
--- directory so that no file served from the preview root can ever run as script.
---@param cdn_origin string
---@param host string Validated Host header value of the request.
---@param token string
---@return string
function M.csp(cdn_origin, host, token)
  local c = cdn_origin
  return table.concat({
    "default-src 'none'",
    "script-src http://" .. host .. "/" .. token .. "/assets/ " .. c .. " 'wasm-unsafe-eval'",
    "style-src 'self' " .. c .. " 'unsafe-inline'",
    "img-src 'self' https: data:",
    "media-src 'self' https:",
    "font-src " .. c .. " data:",
    "connect-src 'self' " .. c,
    "base-uri 'none'",
    "form-action 'none'",
  }, "; ")
end

--- JSON for embedding inside a <script type="application/json"> element.
---@param value table
---@return string
function M.embed_json(value)
  return (
    vim.json.encode(value):gsub("[<>&]", {
      ["<"] = "\\u003c",
      [">"] = "\\u003e",
      ["&"] = "\\u0026",
    })
  )
end

---@param ctx markdown_preview.RouterContext
---@param conn markdown_preview.Conn
---@param req markdown_preview.Request
local function serve_index(ctx, conn, req)
  local index = vim.fs.joinpath(static.web_root(), "index.html")
  local html = static.read_file(index)
  if not html then
    conn:error(500, "web/index.html not found")
    return
  end
  local json = M.embed_json(ctx.bootstrap())
  html = html:gsub(bootstrap_placeholder, function()
    return json
  end)
  local origin = ctx.cdn:match("^(https?://[^/]+)")
  conn:respond(200, {
    ["Content-Type"] = "text/html; charset=utf-8",
    ["Content-Security-Policy"] = M.csp(origin, req.headers["host"]:lower(), ctx.token),
    ["Referrer-Policy"] = "no-referrer",
  }, html)
end

---@param ctx markdown_preview.RouterContext
---@param conn markdown_preview.Conn
---@param req markdown_preview.Request
local function api_open(ctx, conn, req)
  local ok, body = pcall(vim.json.decode, req.body)
  if not ok or type(body) ~= "table" or type(body.path) ~= "string" or body.path == "" then
    conn:error(400, 'expected a JSON body {"path": "<root-relative path>"}')
    return
  end
  local status, message = ctx.on_open(body.path)
  if status == 204 then
    conn:respond(204)
  else
    conn:error(status, message or "error")
  end
end

---@param conn markdown_preview.Conn
---@param allow string
local function method_not_allowed(conn, allow)
  conn:error(405, "method not allowed", { ["Allow"] = allow })
end

--- Host and token check, run on the header block before any body byte is read.
--- Returns a status and message when the request must be rejected. Safe in libuv callbacks.
---@param ctx markdown_preview.RouterContext
---@param head markdown_preview.RequestHead
---@return integer? status, string? message
function M.precheck(ctx, head)
  local host = head.headers["host"]
  if not host or not M.allowed_hosts(ctx.host, ctx.port, ctx.ip)[host:lower()] then
    return 403, "forbidden host"
  end
  local base = "/" .. ctx.token
  if head.path ~= base and head.path:sub(1, #base + 1) ~= base .. "/" then
    return 403, "forbidden"
  end
  return nil
end

--- Dispatches one request. Runs on the main loop.
---@param ctx markdown_preview.RouterContext
---@param conn markdown_preview.Conn
---@param req markdown_preview.Request
function M.handle(ctx, conn, req)
  local status, message = M.precheck(ctx, req)
  if status then
    conn:error(status, message or "forbidden")
    return
  end
  local allowed = M.allowed_hosts(ctx.host, ctx.port, ctx.ip)
  local base = "/" .. ctx.token
  if req.path == base then
    conn:respond(301, { ["Location"] = base .. "/" })
    return
  end
  local route = req.path:sub(#base + 2)

  if route == "api/open" then
    if req.method ~= "POST" then
      method_not_allowed(conn, "POST")
      return
    end
    local origin = req.headers["origin"]
    if origin then
      local origin_host = origin:lower():match("^http://(.+)$")
      if not origin_host or not allowed[origin_host] then
        conn:error(403, "forbidden origin")
        return
      end
    end
    api_open(ctx, conn, req)
    return
  end

  local known = route == "" or route == "events" or route:sub(1, 7) == "assets/" or route:sub(1, 5) == "file/"
  if not known then
    conn:error(404, "not found")
    return
  end
  if req.method ~= "GET" then
    method_not_allowed(conn, "GET")
    return
  end
  if route == "" then
    serve_index(ctx, conn, req)
  elseif route == "events" then
    ctx.on_events(conn)
  elseif route:sub(1, 7) == "assets/" then
    local r = static.resolve(static.web_root(), route:sub(8))
    if not r.path then
      conn:error(r.status, r.message)
      return
    end
    static.serve_file(conn, r, req)
  elseif route:sub(1, 5) == "file/" then
    local r = static.resolve_media(ctx.root(), route:sub(6))
    if not r.path then
      conn:error(r.status, r.message)
      return
    end
    static.serve_file(conn, r, req, { ["Content-Security-Policy"] = file_csp })
  end
end

return M
