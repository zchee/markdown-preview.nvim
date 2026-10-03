-- Test bootstrap: puts this plugin and plenary.nvim on the runtimepath. plenary is taken from
-- $PLENARY_DIR, then the usual lazy.nvim location, and is cloned into a temp dir when neither exists.
local repo = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local function plenary_dir()
  local candidates = {
    vim.env.PLENARY_DIR or "",
    vim.fs.joinpath(vim.fn.stdpath("data"), "lazy", "plenary.nvim"),
    vim.fs.joinpath(vim.env.HOME or "", ".local", "share", "nvim", "lazy", "plenary.nvim"),
  }
  for _, dir in ipairs(candidates) do
    if dir ~= "" and vim.uv.fs_stat(vim.fs.joinpath(dir, "lua", "plenary")) then
      return dir
    end
  end
  local dir = vim.fs.joinpath(vim.uv.os_tmpdir(), "markdown-preview-test-plenary.nvim")
  if not vim.uv.fs_stat(vim.fs.joinpath(dir, "lua", "plenary")) then
    local res = vim
      .system({ "git", "clone", "--depth", "1", "https://github.com/nvim-lua/plenary.nvim", dir }, { text = true })
      :wait()
    if res.code ~= 0 then
      error("cannot clone plenary.nvim: " .. (res.stderr or ""))
    end
  end
  return dir
end

vim.opt.runtimepath:prepend(plenary_dir())
vim.opt.runtimepath:prepend(repo)
package.path = vim.fs.joinpath(repo, "tests", "?.lua") .. ";" .. package.path
vim.opt.swapfile = false
vim.cmd("filetype on")
vim.cmd("runtime plugin/plenary.vim")
vim.cmd("runtime plugin/markdown-preview.lua")
