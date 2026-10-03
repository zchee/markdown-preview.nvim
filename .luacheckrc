std = "luajit"
cache = true
codes = true
max_line_length = 120

-- Plugins assign vim.g, vim.opt and (in tests) vim.notify, so `vim` is a writable global.
globals = {
  "vim",
}

files["tests/**/*_spec.lua"] = {
  read_globals = {
    "describe",
    "it",
    "before_each",
    "after_each",
    "setup",
    "teardown",
    "pending",
    "assert",
  },
}
