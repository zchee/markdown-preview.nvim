---@class markdown_preview.ThemeConfig
---@field name "system"|"light"|"dark"
---@field high_contrast boolean

---@class markdown_preview.CursorLineConfig
---@field disable boolean
---@field color string CSS color of the cursor line band.
---@field opacity number Between 0 and 1.

---@class markdown_preview.ScrollConfig
---@field disable boolean
---@field top_offset_pct number Between 0 and 100.

---@class markdown_preview.Config
---@field host string Address the server binds to.
---@field port integer 0 lets the OS pick a free port.
---@field browser nil|false|string|string[] nil uses vim.ui.open, false prints the URL only.
---@field theme markdown_preview.ThemeConfig
---@field details_tags_open boolean
---@field cursor_line markdown_preview.CursorLineConfig
---@field scroll markdown_preview.ScrollConfig
---@field debounce_ms integer
---@field cdn string Base URL the page loads its libraries from.
---@field log_level nil|"error"|"warn"|"info"|"debug"

local M = {}

---@return markdown_preview.Config
local function defaults()
  return {
    host = "127.0.0.1",
    port = 0,
    browser = nil,
    theme = { name = "system", high_contrast = false },
    details_tags_open = true,
    cursor_line = { disable = false, color = "#c86414", opacity = 0.2 },
    scroll = { disable = false, top_offset_pct = 35 },
    debounce_ms = 30,
    cdn = "https://cdn.jsdelivr.net/npm",
    log_level = nil,
  }
end

-- Keys accepted in user options, nested tables listed as their own key sets. Unknown keys are
-- rejected so that a typo fails loudly instead of being ignored.
local known_keys = {
  [""] = {
    host = true,
    port = true,
    browser = true,
    theme = true,
    details_tags_open = true,
    cursor_line = true,
    scroll = true,
    debounce_ms = true,
    cdn = true,
    log_level = true,
  },
  theme = { name = true, high_contrast = true },
  cursor_line = { disable = true, color = true, opacity = true },
  scroll = { disable = true, top_offset_pct = true },
}

---@type markdown_preview.Config
M.options = defaults()

---@param opts table
local function check_unknown_keys(opts)
  for key, value in pairs(opts) do
    if not known_keys[""][key] then
      error(string.format("unknown option %q", tostring(key)), 0)
    end
    local nested = known_keys[key]
    if nested then
      if type(value) ~= "table" then
        error(string.format("%s: expected table, got %s", key, type(value)), 0)
      end
      for sub in pairs(value) do
        if not nested[sub] then
          error(string.format("unknown option %q", key .. "." .. tostring(sub)), 0)
        end
      end
    end
  end
end

--- Whether `host` names the loopback interface (127.0.0.0/8, ::1 or localhost).
---@param host string
---@return boolean
function M.is_loopback(host)
  host = host:lower():match("^%[(.*)%]$") or host:lower()
  return host == "localhost" or host == "::1" or host:match("^127%.%d+%.%d+%.%d+$") ~= nil
end

---@param v any
---@return boolean
local function is_integer(v)
  return type(v) == "number" and v == math.floor(v)
end

---@param o markdown_preview.Config
local function validate(o)
  vim.validate("host", o.host, function(v)
    return type(v) == "string" and v ~= ""
  end, "non-empty string")
  vim.validate("port", o.port, function(v)
    return is_integer(v) and v >= 0 and v <= 65535
  end, "integer between 0 and 65535")
  vim.validate("browser", o.browser, function(v)
    if v == nil or v == false then
      return true
    end
    if type(v) == "string" then
      return v ~= ""
    end
    if type(v) ~= "table" or not vim.islist(v) or #v == 0 then
      return false
    end
    for _, part in ipairs(v) do
      if type(part) ~= "string" then
        return false
      end
    end
    return true
  end, "nil, false, a command string or a non-empty list of strings")
  vim.validate("theme.name", o.theme.name, function(v)
    return v == "system" or v == "light" or v == "dark"
  end, '"system", "light" or "dark"')
  vim.validate("theme.high_contrast", o.theme.high_contrast, "boolean")
  vim.validate("details_tags_open", o.details_tags_open, "boolean")
  vim.validate("cursor_line.disable", o.cursor_line.disable, "boolean")
  vim.validate("cursor_line.color", o.cursor_line.color, "string")
  vim.validate("cursor_line.opacity", o.cursor_line.opacity, function(v)
    return type(v) == "number" and v >= 0 and v <= 1
  end, "number between 0 and 1")
  vim.validate("scroll.disable", o.scroll.disable, "boolean")
  vim.validate("scroll.top_offset_pct", o.scroll.top_offset_pct, function(v)
    return type(v) == "number" and v >= 0 and v <= 100
  end, "number between 0 and 100")
  vim.validate("debounce_ms", o.debounce_ms, function(v)
    return is_integer(v) and v >= 0
  end, "non-negative integer")
  vim.validate("cdn", o.cdn, function(v)
    -- The origin is spliced into the CSP header, so separators and whitespace are refused.
    if type(v) ~= "string" or v:find("[%z\1-\32\127;,]") then
      return false
    end
    if v:match("^https://[^/]+") then
      return true
    end
    local host = v:match("^http://([^/]+)")
    return host ~= nil and M.is_loopback((host:gsub(":%d+$", "")))
  end, "https:// URL (http:// only for a loopback host) without whitespace, ';' or ','")
  vim.validate("log_level", o.log_level, function(v)
    return v == nil or v == "error" or v == "warn" or v == "info" or v == "debug"
  end, 'nil, "error", "warn", "info" or "debug"')
end

--- Merges user options over the defaults and validates the result.
--- Raises an error naming the offending option when the merged config is invalid.
---@param opts? table
---@return markdown_preview.Config
function M.resolve(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    error("markdown-preview: invalid config: options must be a table", 0)
  end
  local ok, err = pcall(check_unknown_keys, opts)
  if not ok then
    error("markdown-preview: invalid config: " .. tostring(err), 0)
  end
  local merged = vim.tbl_deep_extend("force", defaults(), opts)
  -- A list replaces the default wholesale; deep_extend would merge lists index by index.
  if opts.browser ~= nil then
    merged.browser = opts.browser
  end
  ok, err = pcall(validate, merged)
  if not ok then
    error("markdown-preview: invalid config: " .. tostring(err), 0)
  end
  return merged
end

--- Replaces the active options. Raises on invalid options and leaves the previous ones in place.
---@param opts? table
function M.set(opts)
  M.options = M.resolve(opts)
end

--- The browser-relevant subset sent in the bootstrap JSON and in init/update_config events.
---@param o? markdown_preview.Config
---@return table
function M.browser_view(o)
  o = o or M.options
  return {
    theme = { name = o.theme.name, high_contrast = o.theme.high_contrast },
    details_tags_open = o.details_tags_open,
    cursor_line = {
      disable = o.cursor_line.disable,
      color = o.cursor_line.color,
      opacity = o.cursor_line.opacity,
    },
    scroll = { disable = o.scroll.disable, top_offset_pct = o.scroll.top_offset_pct },
  }
end

--- Origin (scheme://host[:port]) of a CDN base URL, by default the configured one.
---@param cdn? string
---@return string
function M.cdn_origin(cdn)
  cdn = cdn or M.options.cdn
  return (cdn:match("^(https?://[^/]+)"))
end

return M
