local eqnav = require("eqnav")
local helpers = require("tests.helpers")
local view = require("eqnav.view")

local DOC = [[
# Notes

## RSA

$$c \equiv m^e \pmod{n}$$

Some prose in between.

## Totient

$$\phi(n) = (p-1)(q-1)$$

More prose.

## Euler

$$e^{i\pi} + 1 = 0$$
]]

-- Saved once, restored after every test: the image-cleanup tests patch it.
local text_clear = require("eqnav.display.text").clear

local function open(text)
  local bufnr = helpers.buf(text or DOC, "markdown")
  vim.api.nvim_set_current_buf(bufnr)
  eqnav.open({ source_buf = bufnr })
  return bufnr
end

describe("view", function()
  before_each(function()
    eqnav.setup({ render = { enabled = false } })
  end)
  after_each(function()
    eqnav.close()
    require("eqnav.display.text").clear = text_clear
  end)

  it("uses the text backend when no image backend is available", function()
    assert.are.equal("text", require("eqnav.display").get(true).name)
  end)

  it("opens an index listing every display equation", function()
    open()
    assert.is_true(view.is_open())
    local state = view.current()
    assert.are.equal(3, #state.equations)
    local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
    assert.is_truthy(lines[1]:find("3 equations"), "title: " .. lines[1])
  end)

  it("writes headers carrying the ordinal, heading and source line", function()
    open()
    local state = view.current()
    local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
    local header = lines[state.entries[1].header_row]
    assert.is_truthy(header:find("1"), header)
    assert.is_truthy(header:find("RSA"), header)
    assert.is_truthy(header:find("L5"), header)
  end)

  it("shows the TeX source in the body under the text backend", function()
    open()
    local state = view.current()
    local entry = state.entries[2]
    local body = vim.api.nvim_buf_get_lines(
      state.buf,
      entry.body_row - 1,
      entry.body_row - 1 + entry.rows,
      false
    )
    assert.is_truthy(table.concat(body, " "):find("phi(n)", 1, true), vim.inspect(body))
  end)

  it("is a scratch buffer the user cannot accidentally edit", function()
    open()
    local state = view.current()
    assert.are.equal("nofile", vim.bo[state.buf].buftype)
    assert.is_false(vim.bo[state.buf].modifiable)
    assert.are.equal("eqnav", vim.bo[state.buf].filetype)
  end)

  it("moves equation-to-equation, not line-to-line", function()
    open()
    local state = view.current()
    view.goto_entry(1)
    assert.are.equal(1, view.cursor_entry())

    view.next()
    assert.are.equal(2, view.cursor_entry())
    assert.are.equal(
      state.entries[2].header_row,
      vim.api.nvim_win_get_cursor(state.win)[1],
      "cursor should sit on the header, not one line down"
    )

    view.next()
    assert.are.equal(3, view.cursor_entry())
    view.next() -- past the end
    assert.are.equal(3, view.cursor_entry())

    view.prev()
    assert.are.equal(2, view.cursor_entry())
    view.prev()
    view.prev() -- past the start
    assert.are.equal(1, view.cursor_entry())
  end)

  it("binds j and k to equation navigation inside the index only", function()
    local source = open()
    local state = view.current()
    local maps = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(state.buf, "n")) do
      maps[m.lhs] = m.desc or ""
    end
    assert.is_truthy(maps["j"], "j should be mapped in the index")
    assert.is_truthy(maps["k"])
    assert.is_truthy(maps["<CR>"])
    assert.is_truthy(maps["q"])
    -- and must not leak into the document. (The source buffer legitimately
    -- has Neovim's own markdown ftplugin maps -- [[, ]], gO -- so assert on
    -- eqnav's keys specifically rather than on the map count.)
    local source_maps = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(source, "n")) do
      source_maps[m.lhs] = true
    end
    for _, lhs in ipairs({ "j", "k", "<CR>", "q", "o", "y", "r" }) do
      assert.is_nil(source_maps[lhs], lhs .. " leaked into the source buffer")
    end
  end)

  it("jumps to the equation's line in the source window", function()
    local source = open()
    view.goto_entry(3)
    view.jump(true)
    assert.are.equal(source, vim.api.nvim_get_current_buf())
    assert.are.equal(17, vim.api.nvim_win_get_cursor(0)[1])
  end)

  -- The payoff of tracking positions with extmarks instead of line numbers.
  it("still jumps to the right line after the document is edited above", function()
    local source = open()
    local before = view.current().equations[3].lnum
    assert.are.equal(17, before)

    vim.api.nvim_buf_set_lines(source, 0, 0, false, { "inserted", "three", "lines" })

    view.goto_entry(3)
    view.jump(true)
    assert.are.equal(
      20,
      vim.api.nvim_win_get_cursor(0)[1],
      "extmark should have followed the insertion"
    )
  end)

  it("yanks the equation source with its delimiters", function()
    open()
    view.goto_entry(1)
    view.yank()
    assert.are.equal("$$c \\equiv m^e \\pmod{n}$$", vim.fn.getreg('"'))
  end)

  -- Renders are async and identified by ordinal. When an edit lands while one is
  -- in flight, the ordinal still exists but no longer means the same equation --
  -- so the finished image would be painted onto its replacement and stay wrong
  -- until the next refresh happened to correct it. With sync.live on and a 300ms
  -- debounce this is reachable by ordinary typing.
  it("drops a render that finished for an equation no longer at that ordinal", function()
    local source = open("# T\n\n$$alpha$$\n\n$$beta$$\n")
    local stale_id = view.current().equations[2].id
    assert.are.equal("beta", view.current().equations[2].tex)

    vim.api.nvim_buf_set_lines(source, 4, 5, false, { "$$gamma$$" })
    view.refresh()

    local fresh = view.current().equations[2]
    assert.are.equal("gamma", fresh.tex)
    assert.are_not.equal(stale_id, fresh.id, "the hash must change with the content")

    view.set_image(2, "/nonexistent/beta.png", nil, stale_id)
    assert.is_nil(
      view.current().entries[2].png,
      "the in-flight render for the old equation 2 was painted onto the new one"
    )

    view.set_image(2, "/nonexistent/gamma.png", nil, fresh.id)
    assert.are.equal(
      "/nonexistent/gamma.png",
      view.current().entries[2].png,
      "a result that still matches must land"
    )
  end)

  it("reports an empty document without erroring", function()
    open("# Nothing here\n\nJust prose.\n")
    local state = view.current()
    assert.are.equal(0, #state.equations)
    local text = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
    assert.is_truthy(text:find("no equations found", 1, true))
  end)

  -- Rendered images are terminal state, not buffer state: they stay on screen
  -- until eqnav sends the graphics-delete escape. The mapped `q` goes through
  -- close(), which clears -- these cover the paths that do not, and which used to
  -- leave equations painted over the shell prompt after quitting. Headless has no
  -- terminal graphics, so this asserts the wiring, not the pixels.
  local function watch_clears()
    local backend = require("eqnav.display.text")
    local seen = {}
    backend.clear = function(b)
      table.insert(seen, b)
    end
    return seen
  end

  it("clears images when the index window is closed without the q mapping", function()
    open()
    local state = view.current()
    local ibuf, iwin = state.buf, state.win
    local cleared = watch_clears() -- after open(), so render()'s own clears do not count

    vim.api.nvim_win_close(iwin, true)

    assert.is_truthy(
      vim.tbl_contains(cleared, ibuf),
      "closing the window left the placements on screen: " .. vim.inspect(cleared)
    )
  end)

  it("clears images when Neovim exits with the index still open", function()
    open()
    local state = view.current()
    local ibuf = state.buf
    local cleared = watch_clears()

    vim.api.nvim_exec_autocmds("VimLeavePre", {})

    assert.is_truthy(
      vim.tbl_contains(cleared, ibuf),
      "quitting left the placements on screen: " .. vim.inspect(cleared)
    )
  end)

  it("closes cleanly and leaves no window or buffer behind", function()
    open()
    local state = view.current()
    local buf, win = state.buf, state.win
    eqnav.close()
    assert.is_false(view.is_open())
    assert.is_nil(view.current())
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  it("refuses filetypes that are not configured", function()
    local bufnr = helpers.buf("$$x$$", "python")
    vim.api.nvim_set_current_buf(bufnr)
    eqnav.open({ source_buf = bufnr })
    assert.is_false(view.is_open())
  end)
end)

describe("sync", function()
  it("maps a source line to the equation containing it", function()
    local sync = require("eqnav.sync")
    local bufnr = helpers.buf(DOC, "markdown")
    local eqs = require("eqnav.scan").scan(bufnr)
    assert.are.equal(1, sync.at_line(eqs, 5))
    assert.are.equal(1, sync.at_line(eqs, 7), "between equations falls back to the one above")
    assert.are.equal(2, sync.at_line(eqs, 11))
    assert.are.equal(3, sync.at_line(eqs, 18))
    assert.is_nil(sync.at_line(eqs, 1))
  end)
end)
