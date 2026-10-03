-- CursorMoved only fires from Neovim's input loop, so these specs run the preview in a child
-- `nvim --embed` and drive it with real keys through nvim_input, the way a user's typing arrives.
local h = require("helpers")

local repo = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

describe("cursor sync with real input", function()
  local t, chan, port, token, es

  ---@param code string
  ---@param ... any
  ---@return any
  local function child(code, ...)
    return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
  end

  ---@param keys string
  local function input(keys)
    vim.rpcrequest(chan, "nvim_input", keys)
  end

  before_each(function()
    t = h.tree()
    chan = vim.fn.jobstart({
      vim.v.progpath,
      "--embed",
      "--headless",
      "--noplugin",
      "-u",
      vim.fs.joinpath(repo, "tests", "minimal_init.lua"),
    }, { rpc = true })
    assert.is_true(chan > 0, "could not start child nvim")
    local info = child(
      [[
      local web, file = ...
      require("markdown-preview.server.static").set_web_root(web)
      require("markdown-preview").setup({ browser = false })
      vim.cmd.edit(vim.fn.fnameescape(file))
      require("markdown-preview").start()
      local s = require("markdown-preview.session").current
      return { port = s.server.port, token = s.token }
    ]],
      t.web,
      t.readme
    )
    port, token = info.port, info.token
    es = h.events(port, "/" .. token .. "/events")
    assert.is_not_nil(es.wait_for("init"), es.describe())
  end)

  after_each(function()
    es.close()
    vim.fn.jobstop(chan)
    h.cleanup(t)
  end)

  it("sends cursor_move with the 0-based line after normal-mode motions", function()
    input("2j")
    local ev = es.wait_for("cursor_move")
    assert.is_not_nil(ev, es.describe())
    assert.are.same({ path = "README.md", cursor_line = 2 }, ev.data)
    input("G")
    ev = es.wait_for("cursor_move", 2)
    assert.is_not_nil(ev, es.describe())
    assert.are.equal(3, ev.data.cursor_line)
    input("gg")
    ev = es.wait_for("cursor_move", 3)
    assert.are.equal(0, ev.data.cursor_line)
  end)

  it("sends typed text as content_change before the cursor_move that follows it", function()
    input("Gonew last line<Esc>")
    local change = es.wait_for("content_change")
    assert.is_not_nil(change, es.describe())
    assert.are.same(
      { "# Readme", "", "first paragraph", "second line", "new last line" },
      change.data.lines,
      es.describe()
    )
    local _, change_index = es.wait_match("content_change", function()
      return true
    end)
    local cursor, cursor_index = es.wait_match("cursor_move", function(d)
      return d.cursor_line == 4
    end)
    assert.is_not_nil(cursor, "no cursor_move for the new line" .. es.describe())
    assert.is_true(
      change_index < cursor_index,
      "cursor_move for the new line arrived before its content" .. es.describe()
    )
  end)

  it("suspends cursor sync while another file is previewed and resumes on BufEnter", function()
    local res = h.fetch(port, "POST", "/" .. token .. "/api/open", nil, '{"path":"docs/guide.md"}')
    assert.are.equal(204, res.status, h.show(res))
    assert.is_not_nil(es.wait_for("init", 2), es.describe())
    input("2j")
    vim.wait(200)
    assert.are.equal(0, es.count("cursor_move"), "cursor_move sent for a buffer that is not previewed" .. es.describe())
    input(":edit " .. vim.fn.fnameescape(t.guide) .. "<CR>")
    local init = es.wait_for("init", 3)
    assert.is_not_nil(init, es.describe())
    assert.are.equal("docs/guide.md", init.data.path)
    assert.are.equal(0, init.data.cursor_line)
    input("j")
    local ev = es.wait_match("cursor_move", function(d)
      return d.cursor_line == 1
    end)
    assert.is_not_nil(ev, es.describe())
    assert.are.same({ path = "docs/guide.md", cursor_line = 1 }, ev.data)
  end)

  it("stops the server on VimLeavePre and sends goodbye", function()
    input(":qa!<CR>")
    assert.is_not_nil(es.wait_for("goodbye"), es.describe())
    assert.is_true(
      vim.wait(2000, function()
        return es.closed
      end, 5),
      "stream not closed" .. es.describe()
    )
  end)
end)
