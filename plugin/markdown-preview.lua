if vim.g.loaded_markdown_preview then
  return
end
vim.g.loaded_markdown_preview = true

local subcommands = { "start", "stop", "toggle" }

vim.api.nvim_create_user_command("MarkdownPreview", function(args)
  local sub = args.fargs[1] or "toggle"
  if not vim.tbl_contains(subcommands, sub) then
    vim.notify("markdown-preview: unknown subcommand " .. sub, vim.log.levels.ERROR)
    return
  end
  require("markdown-preview")[sub]()
end, {
  nargs = "?",
  desc = "Markdown live preview: start, stop or toggle",
  complete = function(lead)
    return vim.tbl_filter(function(s)
      return s:sub(1, #lead) == lead
    end, subcommands)
  end,
})
