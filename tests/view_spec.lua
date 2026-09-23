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

--- A document of `n` display equations, with equation `tall` (if given) padded
--- to `reps` terms so its wrapped text body is several rows deep.
---@param n integer
---@param tall? integer
---@param reps? integer defaults to more rows than a short index pane has
local function sections(n, tall, reps)
  local out = {}
  for i = 1, n do
    local tex = i == tall and (string.rep("\\alpha + ", reps or 70) .. "1")
      or ("x_" .. i .. " = " .. i)
    vim.list_extend(out, { "## Section " .. i, "", "$$" .. tex .. "$$", "" })
  end
  return table.concat(out, "\n")
end

-- Saved once, restored after every test: the image-cleanup tests patch it.
local text_clear = require("eqnav.display.text").clear

-- Likewise the module a stub image backend stands in for (see "reveals an
-- image drawn taller..."), restored even when that test fails part-way.
local real_image_nvim = package.loaded["eqnav.display.image_nvim"]

-- Likewise for the geometry: the scrolling tests shrink the window, and one of
-- them sets the global 'scrolloff' the index is supposed to be immune to.
local saved_lines, saved_scrolloff = vim.o.lines, vim.o.scrolloff

-- Likewise view.render, which the rebuild-counting test wraps.
local real_render = view.render

local function open(text)
  local bufnr = helpers.buf(text or DOC, "markdown")
  vim.api.nvim_set_current_buf(bufnr)
  eqnav.open({ source_buf = bufnr })
  return bufnr
end

--- Select a stub image backend, counting its place() and clear() calls into
--- `calls`. Its images are as many rows tall as stub_png() says, against a
--- one-row placeholder.
---@param calls? { place: integer, clear: integer }
---@param rows integer
---@return string path of a stub png that many rows tall
local function stub_png(rows)
  local path = vim.fn.tempname() .. ".png"
  vim.fn.writefile({ tostring(rows) }, path)
  return path
end

local function stub_images(calls)
  calls = calls or { place = 0, clear = 0 }
  -- Stands in for a real backend name, which is all config will accept.
  package.loaded["eqnav.display.image_nvim"] = {
    name = "stub_image",
    images = true,
    available = function()
      return true
    end,
    -- Read from the file, as the real backends measure it: a stub png holds its
    -- height in rows, and a missing one is a single row.
    rows = function(_, png)
      local ok, content = pcall(vim.fn.readfile, png or "")
      return ok and tonumber(content[1]) or 1
    end,
    lines = function()
      return nil
    end,
    place = function()
      calls.place = calls.place + 1
    end,
    clear = function()
      calls.clear = calls.clear + 1
    end,
  }
  eqnav.setup({ render = { enabled = false }, display = { backend = "image_nvim" } })
  require("eqnav.display").reset()
  return calls
end

describe("view", function()
  before_each(function()
    eqnav.setup({ render = { enabled = false } })
  end)
  after_each(function()
    eqnav.close()
    require("eqnav.display.text").clear = text_clear
    package.loaded["eqnav.display.image_nvim"] = real_image_nvim
    require("eqnav.display").reset()
    vim.o.lines, vim.o.scrolloff = saved_lines, saved_scrolloff
    view.render = real_render
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

  -- Neovim scrolls to keep the *cursor* visible, and the cursor sits on the
  -- header -- so a body came into view only because the *next* header pulled the
  -- window down past it. The last entry has no next header, and `j` stops there,
  -- so its image sat below the last visible row with no advertised key to reach
  -- it.
  it("scrolls the last entry's body into view, not just its header", function()
    vim.o.lines = 14
    -- Pinned, not inherited: a non-zero 'scrolloff' scrolls ahead of the cursor
    -- and hides this by accident. 0 is Neovim's default and what the report ran
    -- with.
    vim.o.scrolloff = 0
    open(sections(6))
    local state = view.current()
    local win = state.win
    local last = state.entries[#state.entries]
    local bottom = last.body_row + last.rows - 1
    -- Without this the test is vacuous: the whole index would fit on screen and
    -- the body would be visible whatever the cursor did.
    assert.is_true(
      bottom > vim.api.nvim_win_get_height(win),
      ("index fits the pane: body ends at %d, window is %d rows"):format(
        bottom,
        vim.api.nvim_win_get_height(win)
      )
    )

    -- Walk with `j`, as the report did. A single long jump is not the same
    -- thing: Neovim re-centres the cursor when the scroll distance is large,
    -- and a centred cursor happens to drag the body on screen with it.
    view.goto_entry(1)
    for _ = 1, #state.equations do
      view.next()
    end

    assert.is_true(
      vim.fn.line("w$", win) >= bottom,
      ("body ends at %d, last visible row is %d"):format(bottom, vim.fn.line("w$", win))
    )
    assert.are.equal(
      last.header_row,
      vim.api.nvim_win_get_cursor(win)[1],
      "the cursor must still sit on the header"
    )
  end)

  -- The same problem in miniature, and the one `open()` itself walks into via
  -- goto_entry(1): an entry taller than the pane cannot be shown whole, so it
  -- has to be shown from the top rather than scrolled until its header is gone.
  it("keeps the header on screen when the entry is taller than the pane", function()
    vim.o.lines = 12
    vim.o.scrolloff = 0
    open(sections(1, 1))
    local state = view.current()
    local entry = state.entries[1]
    assert.is_true(
      entry.rows > vim.api.nvim_win_get_height(state.win),
      ("fixture is not tall enough: %d rows in a %d-row window"):format(
        entry.rows,
        vim.api.nvim_win_get_height(state.win)
      )
    )

    view.goto_entry(1)

    assert.is_true(
      vim.fn.line("w0", state.win) <= entry.header_row,
      ("header at %d is above the first visible row %d"):format(
        entry.header_row,
        vim.fn.line("w0", state.win)
      )
    )
    assert.is_true(vim.fn.line("w$", state.win) >= entry.body_row, "none of the body is on screen")
  end)

  -- What snacks actually does, which the text backend above cannot show: it
  -- sizes an image by its DPI and the display scale, not the cell height
  -- rows() divides by, so at a Retina font size a one-row reservation draws
  -- as two rows -- hung as virtual lines under the reserved row (#38). The
  -- cursor stopping on that row does not bring lines below it into view.
  it("reveals an image drawn taller than the rows reserved for it", function()
    vim.o.lines = 14
    vim.o.scrolloff = 0
    local ns = vim.api.nvim_create_namespace("eqnav.test.stub_image")
    -- Stands in for a real backend name, which is all config will accept.
    package.loaded["eqnav.display.image_nvim"] = {
      name = "stub_image",
      images = true,
      available = function()
        return true
      end,
      rows = function()
        return 1
      end,
      lines = function()
        return nil
      end,
      place = function(bufnr, row)
        vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
          virt_lines = { { { "image row 1" } }, { { "image row 2" } } },
        })
      end,
      clear = function(bufnr)
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      end,
    }
    eqnav.setup({ render = { enabled = false }, display = { backend = "image_nvim" } })
    require("eqnav.display").reset()

    open(sections(6))
    local state = view.current()
    for i = 1, #state.equations do
      view.set_image(i, "/stub.png", nil)
    end
    view.flush()
    local win = state.win
    local last = state.entries[#state.entries]

    view.goto_entry(1)
    for _ = 1, #state.equations do
      view.next()
    end

    -- Screen rows from the top of the window through the virtual lines hung
    -- under the body. Neovim stores those as filler *above the next line*, so
    -- they are counted by ending on that line at vcol 0: ending on the body row
    -- itself leaves them out, and so does 'w$', which is how this got past the
    -- checks above.
    local drawn = vim.api.nvim_win_text_height(win, {
      start_row = vim.fn.line("w0", win) - 1,
      end_row = last.body_row + last.rows - 1,
      end_vcol = 0,
    }).all
    assert.is_true(
      drawn <= vim.api.nvim_win_get_height(win),
      ("image ends %d screen rows down a %d-row window"):format(
        drawn,
        vim.api.nvim_win_get_height(win)
      )
    )
    assert.are.equal(last.header_row, vim.api.nvim_win_get_cursor(win)[1])
  end)

  -- A global 'scrolloff' re-centres the cursor on the header and pushes the body
  -- straight back off the bottom, so the index pins its own.
  it("reveals a tall entry's body under a global scrolloff", function()
    vim.o.lines = 12
    vim.o.scrolloff = 999
    -- Tall enough to need scrolling, short enough to fit the pane once it does.
    open(sections(8, 4, 30))
    local state = view.current()

    view.goto_entry(1)
    for _ = 1, 3 do
      view.next()
    end

    assert.are.equal(4, view.cursor_entry())

    local entry = state.entries[4]
    local bottom = entry.body_row + entry.rows - 1
    assert.is_true(
      vim.fn.line("w$", state.win) >= bottom,
      ("body ends at %d, last visible row is %d"):format(bottom, vim.fn.line("w$", state.win))
    )
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

  -- Each finished render used to rebuild the whole index, so a document of n
  -- equations filling in cost n rebuilds of n entries each (#3). A burst of
  -- them -- every cache hit arrives in one batch -- is now one rebuild.
  it("coalesces a burst of finished renders into one rebuild", function()
    stub_images()
    local png = stub_png(4)
    open(sections(50))
    local state = view.current()
    local rebuilds = 0
    view.render = function()
      rebuilds = rebuilds + 1
      return real_render()
    end

    for i, eq in ipairs(state.equations) do
      view.set_image(i, png, nil, eq.id)
    end
    assert.are.equal(0, rebuilds, "rebuilt before the burst was over")
    assert.are.equal(png, state.entries[50].png, "the result was not recorded")

    -- Left alone, the repaint happens by itself, once.
    assert.is_true(vim.wait(1000, function()
      return rebuilds > 0
    end))
    vim.wait(100)
    assert.are.equal(1, rebuilds)
    assert.are.equal(4, view.current().entries[50].rows)

    -- A result for an equation that has since changed schedules nothing.
    view.set_image(2, stub_png(6), nil, "stale")
    vim.wait(100)
    assert.are.equal(1, rebuilds)

    -- flush() repaints now, and leaves nothing pending behind it.
    view.set_image(2, stub_png(6), nil, state.equations[2].id)
    view.flush()
    assert.are.equal(2, rebuilds)
    assert.are.equal(6, view.current().entries[2].rows)
    vim.wait(100)
    assert.are.equal(2, rebuilds)
  end)

  -- `r` on a document nobody edited has nothing to change: every equation keeps
  -- its image until the new render lands, so the text is identical, and
  -- rewriting it anyway tore down every image and lost the view -- including a
  -- window starting partway through an image, which only exists once the
  -- terminal has drawn it and so cannot be put back (#44).
  it("leaves an unchanged index untouched while a refresh re-renders it", function()
    local calls = stub_images()
    local png = stub_png(4)
    open(sections(6))
    local state = view.current()
    for i, eq in ipairs(state.equations) do
      -- What render_all does: the id it renders under is not the one a scan
      -- gives, since it hashes in the colour and the display geometry.
      eq.id = "rendered:" .. eq.id
      view.set_image(i, png, nil, eq.id)
    end
    view.flush()
    local win = state.win
    local header = state.entries[5].header_row
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = header - vim.api.nvim_win_get_height(win) + 1, lnum = header })
    end)
    local tick = vim.api.nvim_buf_get_changedtick(state.buf)
    local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
    local function view_state()
      return vim.api.nvim_win_call(win, vim.fn.winsaveview)
    end
    local before = view_state()
    calls.place, calls.clear = 0, 0

    -- `r` deletes each cached file to force its re-render (cache.invalidate).
    vim.fn.delete(png)
    view.refresh()
    state = view.current()
    for _, eq in ipairs(state.equations) do
      eq.id = "rendered:" .. eq.id
    end
    vim.fn.writefile({ "4" }, png)
    for _, eq in ipairs(state.equations) do
      view.set_image(eq.index, png, nil, eq.id)
      view.flush() -- one at a time, as a slow stream of renders lands
    end

    assert.are.same(lines, vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
    assert.are.equal(tick, vim.api.nvim_buf_get_changedtick(state.buf), "the index was rewritten")
    assert.are.equal(0, calls.clear, "every image was torn down")
    assert.are.same(before, view_state())

    -- A new image the same height swaps that one image, and nothing else.
    local other = stub_png(4)
    view.set_image(2, other, nil, state.equations[2].id)
    view.flush()
    assert.are.equal(other, view.current().entries[2].png)
    assert.are.equal(tick, vim.api.nvim_buf_get_changedtick(state.buf))
    assert.are.equal(0, calls.clear)
    assert.are.same(before, view_state())

    -- One of another height is laid out again.
    view.set_image(2, stub_png(6), nil, state.equations[2].id)
    view.flush()
    assert.are.equal(6, view.current().entries[2].rows)
    assert.are_not.equal(tick, vim.api.nvim_buf_get_changedtick(state.buf))
  end)

  -- An equation added above the cursor has no image yet: it shows as a one-row
  -- placeholder and grows as its render lands, and every entry after it moves
  -- down by a whole section. The cursor's line number used to stay put through
  -- that, leaving it on another equation, and the view with it (#44).
  it("keeps the cursor and the view on their equation when one is added above", function()
    stub_images()
    local png = stub_png(4)
    local source = open(sections(6))
    local state = view.current()
    for i, eq in ipairs(state.equations) do
      eq.id = "rendered:" .. eq.id -- as render_all does; see the spec above
      view.set_image(i, png, nil, eq.id)
    end
    view.flush()
    -- Entry 5's header on the window's last row: the collapsed layout cannot
    -- hold it there, so the view has to be put back once the images land.
    local win = state.win
    local header = state.entries[5].header_row
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = header - vim.api.nvim_win_get_height(win) + 1, lnum = header })
    end)
    assert.are.equal(5, view.cursor_entry())
    local tex = state.entries[5].eq.tex
    local function screen_row()
      return vim.api.nvim_win_get_cursor(win)[1] - vim.fn.line("w0", win) + 1
    end
    local screen = screen_row()

    vim.api.nvim_buf_set_lines(source, 0, 0, false, { "## Added", "", "$$y = 0$$", "" })
    view.refresh()
    state = view.current()
    assert.is_nil(state.entries[1].png, "the added equation has an image it never rendered")
    for _, eq in ipairs(state.equations) do
      eq.id = "rendered:" .. eq.id
      view.set_image(eq.index, png, nil, eq.id)
      view.flush() -- one at a time, as a slow stream of renders lands
    end

    assert.are.equal(6, view.cursor_entry(), "the cursor left its equation")
    assert.are.equal(tex, state.entries[6].eq.tex)
    assert.are.equal(state.entries[6].header_row, vim.api.nvim_win_get_cursor(win)[1])
    assert.are.equal(
      screen,
      screen_row(),
      ("the entry moved from screen row %d to %d"):format(screen, screen_row())
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

  -- Shipping `typst` in the defaults promised support that does not exist:
  -- there is no typst query, the regex fallback's delimiters are LaTeX-shaped,
  -- and MathJax cannot parse Typst math anyway. `before_each` re-runs setup, so
  -- this asserts the shipped defaults rather than whatever this session set.
  it("does not claim typst, which has neither a scanner nor a renderer", function()
    local bufnr = helpers.buf("$ x = 1 $", "typst")
    assert.is_false(require("eqnav.config").enabled_for(bufnr))
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
