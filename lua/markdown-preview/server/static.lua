local uv = vim.uv

local M = {}

local CHUNK_BYTES = 64 * 1024

local mime_types = {
  avif = "image/avif",
  bmp = "image/bmp",
  css = "text/css; charset=utf-8",
  flac = "audio/flac",
  gif = "image/gif",
  htm = "text/html; charset=utf-8",
  html = "text/html; charset=utf-8",
  ico = "image/x-icon",
  jpeg = "image/jpeg",
  jpg = "image/jpeg",
  js = "text/javascript; charset=utf-8",
  json = "application/json",
  m4a = "audio/mp4",
  m4v = "video/mp4",
  map = "application/json",
  markdown = "text/markdown; charset=utf-8",
  md = "text/markdown; charset=utf-8",
  mjs = "text/javascript; charset=utf-8",
  mov = "video/quicktime",
  mp3 = "audio/mpeg",
  mp4 = "video/mp4",
  oga = "audio/ogg",
  ogg = "audio/ogg",
  ogv = "video/ogg",
  otf = "font/otf",
  pdf = "application/pdf",
  png = "image/png",
  svg = "image/svg+xml",
  ttf = "font/ttf",
  txt = "text/plain; charset=utf-8",
  wasm = "application/wasm",
  wav = "audio/wav",
  webm = "video/webm",
  webp = "image/webp",
  woff = "font/woff",
  woff2 = "font/woff2",
  xml = "application/xml",
}

--- MIME type for a file name, `application/octet-stream` when unknown.
---@param path string
---@return string
function M.mime_type(path)
  local ext = path:match("%.([%w]+)$")
  return ext and mime_types[ext:lower()] or "application/octet-stream"
end

--- Normalizes a path without expanding `$VAR` or `~`, which must never apply to request paths.
---@param path string
---@return string
local function normalize(path)
  return vim.fs.normalize(path, { expand_env = false })
end
M.normalize = normalize

local plugin_web_root =
  normalize(vim.fs.joinpath(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h"), "web"))
local web_root_override ---@type string?

--- Directory holding index.html and the page assets.
---@return string
function M.web_root()
  return web_root_override or plugin_web_root
end

--- Overrides the asset directory (nil restores the plugin's own web/ directory).
---@param dir? string
function M.set_web_root(dir)
  web_root_override = dir and normalize(dir) or nil
end

--- Decodes %XX escapes. Returns nil for a malformed escape.
---@param s string
---@return string?
function M.percent_decode(s)
  if s:find("%%%X") or s:find("%%%x%X") or s:find("%%%x?$") then
    return nil
  end
  return (s:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

---@param path string
---@param root string
---@return boolean
local function is_under(path, root)
  if path == root then
    return true
  end
  local prefix = root:sub(-1) == "/" and root or root .. "/"
  return path:sub(1, #prefix) == prefix
end
M.is_under = is_under

---@class markdown_preview.Resolved
---@field path? string Real path of the file.
---@field stat? { dev: integer, ino: integer } Stat of `path` at check time; the opened descriptor must match it.
---@field status? integer HTTP status when resolution failed.
---@field message? string

--- Resolves a percent-encoded, root-relative path to a regular file inside `root`.
--- `root` must already be a real path. The lexical check runs before realpath so a path that
--- escapes the root is rejected with 403 whether or not the target exists.
---@param root string
---@param encoded string
---@return markdown_preview.Resolved
function M.resolve(root, encoded)
  local rel = M.percent_decode(encoded)
  if not rel then
    return { status = 400, message = "malformed percent-encoding" }
  end
  return M.resolve_decoded(root, rel)
end

--- Same as resolve() for an already decoded relative path.
---@param root string
---@param rel string
---@return markdown_preview.Resolved
function M.resolve_decoded(root, rel)
  if rel:find("[%z\1-\31\127\\]") then
    return { status = 400, message = "invalid character in path" }
  end
  if rel:sub(1, 1) == "/" then
    return { status = 403, message = "absolute paths are not allowed" }
  end
  local joined = normalize(root .. "/" .. rel)
  if not is_under(joined, root) then
    return { status = 403, message = "path is outside the preview root" }
  end
  local real = uv.fs_realpath(joined)
  if not real then
    -- A missing file behind a symlink that leaves the root must not reveal whether it exists.
    local dir = vim.fs.dirname(joined)
    local dir_real = uv.fs_realpath(dir)
    while not dir_real and dir ~= root and is_under(dir, root) do
      dir = vim.fs.dirname(dir)
      dir_real = uv.fs_realpath(dir)
    end
    if dir_real and not is_under(normalize(dir_real), root) then
      return { status = 403, message = "path is outside the preview root" }
    end
    return { status = 404, message = "not found" }
  end
  real = normalize(real)
  if not is_under(real, root) then
    return { status = 403, message = "path is outside the preview root" }
  end
  local stat = uv.fs_stat(real)
  if not stat or stat.type ~= "file" then
    return { status = 404, message = "not found" }
  end
  return { path = real, stat = stat }
end

-- Extensions served under file/: the media a Markdown page embeds, nothing that could run as
-- script in the page's origin and nothing like source code or credentials.
local media_extensions = {
  avif = true,
  bmp = true,
  flac = true,
  gif = true,
  ico = true,
  jpeg = true,
  jpg = true,
  m4a = true,
  m4v = true,
  mov = true,
  mp3 = true,
  mp4 = true,
  oga = true,
  ogg = true,
  ogv = true,
  png = true,
  svg = true,
  wav = true,
  webm = true,
  webp = true,
}

--- resolve() restricted to media files: any other extension, and any path segment starting with
--- `.` (dotfiles, `.git/`, `..`), is 403.
---@param root string
---@param encoded string
---@return markdown_preview.Resolved
function M.resolve_media(root, encoded)
  local rel = M.percent_decode(encoded)
  if not rel then
    return { status = 400, message = "malformed percent-encoding" }
  end
  if rel:find("[%z\1-\31\127\\]") then
    return { status = 400, message = "invalid character in path" }
  end
  for segment in vim.gsplit(rel, "/", { plain = true }) do
    if segment:sub(1, 1) == "." then
      return { status = 403, message = "hidden or relative path segments are not served" }
    end
  end
  local ext = rel:match("%.([%w]+)$")
  if not ext or not media_extensions[ext:lower()] then
    return { status = 403, message = "only image, video and audio files are served" }
  end
  return M.resolve_decoded(root, rel)
end

---@class markdown_preview.Range
---@field first integer
---@field last integer

--- Interprets a Range header for a resource of `size` bytes.
--- Returns the range, or "ignore" (serve the whole file), or "unsatisfiable".
---@param header? string
---@param size integer
---@return markdown_preview.Range|"ignore"|"unsatisfiable"
function M.parse_range(header, size)
  if not header then
    return "ignore"
  end
  local spec = header:match("^%s*bytes%s*=%s*(.-)%s*$")
  if not spec or spec:find(",", 1, true) then
    -- Unknown units and multiple ranges are ignored; a full 200 response is a valid answer.
    return "ignore"
  end
  local a, b = spec:match("^(%d*)%-(%d*)$")
  if not a or (a == "" and b == "") then
    return "ignore"
  end
  if a == "" then
    local n = tonumber(b) --[[@as integer]]
    if n == 0 or size == 0 then
      return "unsatisfiable"
    end
    return { first = math.max(size - n, 0), last = size - 1 }
  end
  local first = tonumber(a) --[[@as integer]]
  local last = size - 1
  if b ~= "" then
    last = tonumber(b) --[[@as integer]]
  end
  if b ~= "" and last < first then
    return "ignore"
  end
  if first >= size then
    return "unsatisfiable"
  end
  return { first = first, last = math.min(last, size - 1) }
end

--- Streams a file to the connection with Range support and closes the connection afterwards.
--- Reads are asynchronous and the next chunk is read only after the previous write completed,
--- so a large video neither blocks the editor nor buffers the whole file in memory.
---@param conn markdown_preview.Conn
---@param resolved markdown_preview.Resolved A successful resolve() result.
---@param req markdown_preview.Request
---@param extra_headers? table<string, string|integer>
function M.serve_file(conn, resolved, req, extra_headers)
  ---@type string
  local path = resolved.path
  local checked = resolved.stat
  uv.fs_open(path, "r", 438, function(oerr, fd)
    if oerr or not fd then
      conn:error(404, "not found")
      return
    end
    local function done()
      uv.fs_close(fd, function() end)
    end
    uv.fs_fstat(fd, function(serr, stat)
      if serr or not stat then
        done()
        conn:destroy()
        return
      end
      -- The path was checked before opening; a file swapped in between is a different inode.
      if not checked or stat.dev ~= checked.dev or stat.ino ~= checked.ino then
        done()
        conn:error(403, "file changed while being opened")
        return
      end
      local size = stat.size
      local range = M.parse_range(req.headers["range"], size)
      local headers = vim.deepcopy(extra_headers or {}) ---@type table<string, string|integer>
      headers["Accept-Ranges"] = "bytes"
      if range == "unsatisfiable" then
        done()
        headers["Content-Range"] = "bytes */" .. size
        headers["Content-Type"] = "application/json"
        local body = vim.json.encode({ error = "range not satisfiable" })
        headers["Content-Length"] = #body
        conn:write_head(416, headers)
        conn:write(body)
        conn:finish()
        return
      end
      local status, first, last = 200, 0, size - 1
      if type(range) == "table" then
        status, first, last = 206, range.first, range.last
        headers["Content-Range"] = string.format("bytes %d-%d/%d", first, last, size)
      end
      headers["Content-Type"] = M.mime_type(path)
      headers["Content-Length"] = last - first + 1
      local offset = first
      local function pump(werr)
        if werr or conn.closed then
          done()
          conn:destroy()
          return
        end
        if offset > last then
          done()
          conn:finish()
          return
        end
        local want = math.min(CHUNK_BYTES, last - offset + 1)
        uv.fs_read(fd, want, offset, function(rerr, data)
          if rerr or not data or #data == 0 then
            done()
            conn:destroy()
            return
          end
          offset = offset + #data
          conn:write(data, pump)
        end)
      end
      conn:write_head(status, headers, pump)
    end)
  end)
end

--- Reads a whole small file synchronously.
---@param path string
---@return string?
function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

return M
