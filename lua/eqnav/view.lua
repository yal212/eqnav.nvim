local config = require("eqnav.config")
local display = require("eqnav.display")
local scan = require("eqnav.scan")
local util = require("eqnav.scan.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("eqnav.view")

---@class eqnav.Entry
---@field eq eqnav.Equation
---@field header_row integer 1-indexed row of the entry's header line
---@field body_row integer 1-indexed row where the image/text starts
---@field rows integer body height in lines
---@field png string|nil
---@field err string|nil

---@class eqnav.View
---@field source_buf integer
---@field source_win integer|nil
---@field buf integer
---@field win integer|nil
---@field equations eqnav.Equation[]
---@field entries eqnav.Entry[]
local current = nil

function M.current()
  return current
end

function M.is_open()
  return current ~= nil and current.win ~= nil and vim.api.nvim_win_is_valid(current.win)
end

local HL = {
  EqnavIndex = { link = "Number" },
  EqnavContext = { link = "Title" },
  EqnavLabel = { link = "Identifier" },
  EqnavLocation = { link = "Comment" },
  EqnavPending = { link = "Comment" },
  EqnavError = { link = "DiagnosticError" },
  EqnavCurrent = { link = "CursorLine" },
  EqnavSource = { link = "Special" },
}

function M.setup_highlights()
  for name, spec in pairs(HL) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", spec, { default = true }))
  end
end

--- Format an entry's header. Real buffer text, not virtual text, so `/`, `:g`
--- and the text backend all keep working and a failed render still leaves
--- something readable behind.
---@param eq eqnav.Equation
---@param width integer
---@return string, table[] line, highlight spans
local function header(eq, width)
  local num = string.format("%3d", eq.index)
  local lnum = scan.mark_pos(eq)
  local loc = "L" .. lnum
  local label = eq.label and (" " .. eq.label) or ""
  local context = eq.context or ""

  local fixed = #num + 2 + #loc + 2 + #label
  local room = math.max(6, width - fixed - 2)
  if vim.fn.strdisplaywidth(context) > room then
    context = vim.fn.strcharpart(context, 0, room - 1) .. "…"
  end

  local left = num .. "  " .. context .. label
  local pad = math.max(1, width - vim.fn.strdisplaywidth(left) - #loc - 1)
  local line = left .. string.rep(" ", pad) .. loc

  local spans = {}
  table.insert(spans, { 0, #num, "EqnavIndex" })
  local ctx_start = #num + 2
  if #context > 0 then
    table.insert(spans, { ctx_start, ctx_start + #context, "EqnavContext" })
  end
  if #label > 0 then
    table.insert(spans, { ctx_start + #context, ctx_start + #context + #label, "EqnavLabel" })
  end
  table.insert(spans, { #line - #loc, #line, "EqnavLocation" })
  return line, spans
end

--- Rebuild the index buffer from the current equation list.
function M.render()
  if not current or not vim.api.nvim_buf_is_valid(current.buf) then
    return
  end
  local backend = display.get()
  local width = current.win
      and vim.api.nvim_win_is_valid(current.win)
      and vim.api.nvim_win_get_width(current.win)
    or config.options.window.width

  backend.clear(current.buf)

  local lines, spans, entries = {}, {}, {}
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(current.source_buf), ":t")
  local title = string.format(
    " eqnav · %d equation%s · %s",
    #current.equations,
    #current.equations == 1 and "" or "s",
    name ~= "" and name or "[No Name]"
  )
  table.insert(lines, title)
  table.insert(spans, { row = 1, cols = { { 0, #title, "EqnavSource" } } })
  table.insert(lines, "")

  for _, eq in ipairs(current.equations) do
    local prev = current.entries and current.entries[eq.index]
    local png = prev and prev.png or nil
    local err = prev and prev.err or nil

    local head, hspans = header(eq, width - 1)
    table.insert(lines, head)
    local header_row = #lines
    table.insert(spans, { row = header_row, cols = hspans })

    local body_row = #lines + 1
    local body = nil
    if err then
      body = { "    " .. err }
    elseif png then
      body = backend.lines(eq, png, width)
    elseif backend.images and config.options.render.enabled then
      body = { "    rendering…" }
    else
      body = backend.lines(eq, nil, width)
    end

    if body == nil then
      local rows = backend.rows(eq, png, width)
      body = {}
      for _ = 1, rows do
        table.insert(body, "")
      end
    end

    for _, l in ipairs(body) do
      table.insert(lines, l)
    end
    if err then
      table.insert(spans, { row = body_row, cols = { { 0, #body[1], "EqnavError" } } })
    elseif not png and backend.images and config.options.render.enabled then
      table.insert(spans, { row = body_row, cols = { { 0, #body[1], "EqnavPending" } } })
    end

    table.insert(lines, "")

    entries[eq.index] = {
      eq = eq,
      header_row = header_row,
      body_row = body_row,
      rows = #body,
      png = png,
      err = err,
    }
  end

  if #current.equations == 0 then
    table.insert(lines, "  no equations found in this buffer")
  end

  vim.bo[current.buf].modifiable = true
  vim.api.nvim_buf_set_lines(current.buf, 0, -1, false, lines)
  vim.bo[current.buf].modifiable = false
  vim.bo[current.buf].modified = false

  vim.api.nvim_buf_clear_namespace(current.buf, M.ns, 0, -1)
  for _, s in ipairs(spans) do
    for _, c in ipairs(s.cols) do
      pcall(vim.api.nvim_buf_set_extmark, current.buf, M.ns, s.row - 1, c[1], {
        end_col = math.min(c[2], #lines[s.row]),
        hl_group = c[3],
      })
    end
  end

  current.entries = entries

  -- Place images only after the lines exist, or the placement has nothing to
  -- attach to.
  if backend.images then
    for _, entry in ipairs(entries) do
      if entry.png then
        backend.place(current.buf, entry.body_row, entry.eq, entry.png)
      end
    end
  end
end

--- Record a finished render and repaint just that entry's body.
---
--- `id` is the equation the render was started for. An ordinal alone is not an
--- identity: a render in flight while the document changes comes back pointing
--- at whatever now occupies that slot, and painting it there shows the wrong
--- image until the next refresh happens to correct it. The content hash does
--- not survive an edit, so comparing it drops exactly those results. Cancelling
--- the work would be tidier; dropping the answer is enough and much simpler.
---@param index integer
---@param png string|nil
---@param err string|nil
---@param id? string identity of the equation the render was started for
function M.set_image(index, png, err, id)
  local entry = current and current.entries and current.entries[index]
  if not entry then
    return
  end
  if id ~= nil and entry.eq.id ~= id then
    return
  end
  entry.png = png
  entry.err = err
  M.render()
end

--- Bring the whole of `entry` into view, not just its header.
---
--- Neovim scrolls to keep the *cursor* visible, and the cursor sits on the
--- header -- so a body only ever came into view because the *next* header
--- pulled the window down past it. The last entry has no next header, which
--- left its image below the last visible row, reachable only through keys the
--- index does not advertise.
---
--- Touching the blank separator line after the body first hands the scrolling
--- to Neovim, which is what keeps this right under an image backend: those
--- rows are virtual lines or terminal overlays, not text this could measure
--- itself. It has to be the separator, not the last body row. snacks sizes an
--- image by its DPI and the display scale, and once drew them taller than the
--- rows reserved, hanging the surplus as virtual lines under the body (#38).
--- The renderer now stamps a DPI that makes the two agree (#6), but a backend
--- that draws taller must still not strand an image: Neovim treats a line as
--- visible without the virtual lines below it, and the separator comes after
--- all of them. Moving back to the header scrolls a second time only when the
--- entry is taller than the window, landing the header at the top with as much
--- of the body as fits.
---@param entry eqnav.Entry
local function reveal(entry)
  local last = vim.api.nvim_buf_line_count(current.buf)
  local bottom = math.min(entry.body_row + entry.rows, last)
  vim.api.nvim_win_set_cursor(current.win, { bottom, 0 })
  vim.api.nvim_win_set_cursor(current.win, { entry.header_row, 0 })
end

---@param n integer 1-indexed equation ordinal
function M.goto_entry(n)
  if not current or not M.is_open() then
    return
  end
  local entry = current.entries[n]
  if not entry then
    return
  end
  reveal(entry)
  M.highlight_current()
end

--- Ordinal of the equation the index cursor is currently on.
---@return integer|nil
function M.cursor_entry()
  if not current or not M.is_open() then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(current.win)[1]
  local best = nil
  for _, entry in ipairs(current.entries or {}) do
    if entry.header_row <= row then
      best = entry.eq.index
    end
  end
  return best
end

function M.next()
  local n = M.cursor_entry()
  M.goto_entry(math.min((n or 0) + 1, #(current and current.equations or {})))
end

function M.prev()
  local n = M.cursor_entry()
  M.goto_entry(math.max((n or 2) - 1, 1))
end

M.current_ns = vim.api.nvim_create_namespace("eqnav.current")

function M.highlight_current()
  if not current or not M.is_open() then
    return
  end
  vim.api.nvim_buf_clear_namespace(current.buf, M.current_ns, 0, -1)
  local n = M.cursor_entry()
  local entry = n and current.entries[n]
  if not entry then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, current.buf, M.current_ns, entry.header_row - 1, 0, {
    line_hl_group = "EqnavCurrent",
  })
end

--- A window showing the source buffer, creating one if it has been closed.
---@return integer|nil
local function source_window()
  if not current then
    return nil
  end
  if current.source_win and vim.api.nvim_win_is_valid(current.source_win) then
    if vim.api.nvim_win_get_buf(current.source_win) == current.source_buf then
      return current.source_win
    end
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == current.source_buf then
      current.source_win = win
      return win
    end
  end
  local index_win = current.win
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, current.source_buf)
  current.source_win = win
  if index_win and vim.api.nvim_win_is_valid(index_win) then
    vim.api.nvim_set_current_win(index_win)
  end
  return win
end

M.flash_ns = vim.api.nvim_create_namespace("eqnav.flash")

--- Jump to the source location of the equation under the index cursor.
---@param keep_open? boolean
function M.jump(keep_open)
  local n = M.cursor_entry()
  if not current or not n then
    return
  end
  local eq = current.equations[n]
  if not eq then
    return
  end
  local win = source_window()
  if not win then
    return
  end

  -- Read the position through the extmark, so the jump is right even if the
  -- document has been edited since the scan.
  local lnum, col = scan.mark_pos(eq)
  local last = vim.api.nvim_buf_line_count(current.source_buf)
  lnum = math.min(lnum, last)

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { lnum, col })
  vim.cmd("normal! zz")

  local buf = current.source_buf
  vim.api.nvim_buf_clear_namespace(buf, M.flash_ns, 0, -1)
  local end_line = math.min(eq.end_lnum - eq.lnum + lnum, last)
  for l = lnum, end_line do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.flash_ns, l - 1, 0, {
      line_hl_group = "Search",
    })
  end
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.flash_ns, 0, -1)
    end
  end, 350)

  if not keep_open then
    M.close()
  end
end

function M.yank()
  local n = M.cursor_entry()
  local eq = n and current and current.equations[n]
  if not eq then
    return
  end
  vim.fn.setreg(vim.v.register or '"', eq.raw)
  vim.notify("eqnav: yanked equation " .. n, vim.log.levels.INFO)
end

local function set_keymaps(buf)
  local keys = config.options.keymaps
  local function map(lhs, fn, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
  end
  -- j/k move equation-to-equation rather than line-to-line. There is no prose
  -- in this buffer, so a line is the wrong unit of travel -- this is the
  -- navigation wishlist#51 actually asked for.
  map(keys.next, M.next, "eqnav: next equation")
  map(keys.prev, M.prev, "eqnav: previous equation")
  map(keys.jump, function()
    M.jump(false)
  end, "eqnav: jump to source")
  map(keys.jump_keep, function()
    M.jump(true)
  end, "eqnav: jump, keep index open")
  map(keys.yank, M.yank, "eqnav: yank equation source")
  map(keys.refresh, function()
    M.refresh(true)
  end, "eqnav: re-render")
  map(keys.close, M.close, "eqnav: close")
  map(keys.export, function()
    require("eqnav.export.html").export_and_open()
  end, "eqnav: export to HTML")
end

---@param source_buf integer
---@return integer buf, integer win
local function open_window(source_buf)
  local pos = config.options.window.position
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "eqnav"
  vim.api.nvim_buf_set_name(buf, "eqnav://" .. source_buf)

  local win
  if pos == "tab" then
    vim.cmd("tabnew")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  elseif pos == "float" then
    local width = math.min(config.options.window.width, vim.o.columns - 4)
    local height = math.min(vim.o.lines - 6, math.floor(vim.o.lines * 0.8))
    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2) - 1,
      col = math.floor((vim.o.columns - width) / 2),
      border = "rounded",
      title = " equations ",
      title_pos = "center",
    })
  else
    local cmd = (pos == "left" or pos == "right") and "vsplit" or "split"
    vim.cmd(cmd)
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    local dir = ({ left = "H", right = "L", top = "K", bottom = "J" })[pos]
    vim.cmd("wincmd " .. dir)
    if pos == "left" or pos == "right" then
      vim.api.nvim_win_set_width(win, config.options.window.width)
    else
      vim.api.nvim_win_set_height(win, config.options.window.height)
    end
  end

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].list = false
  -- The index places entries itself (see reveal()); a non-zero 'scrolloff'
  -- scrolls ahead of the cursor and pushes a tall entry's body back off the
  -- bottom, so it does not inherit the user's.
  vim.wo[win].scrolloff = 0
  return buf, win
end

---@param opts? { source_buf?: integer, focus?: boolean }
function M.open(opts)
  opts = opts or {}
  local source_buf = opts.source_buf or vim.api.nvim_get_current_buf()

  if not config.enabled_for(source_buf) then
    vim.notify(
      "eqnav: filetype '" .. vim.bo[source_buf].filetype .. "' is not in config.filetypes",
      vim.log.levels.WARN
    )
    return
  end

  if M.is_open() then
    M.close()
  end

  M.setup_highlights()
  local source_win = vim.api.nvim_get_current_win()
  local equations = scan.scan(source_buf)
  local buf, win = open_window(source_buf)

  current = {
    source_buf = source_buf,
    source_win = source_win,
    buf = buf,
    win = win,
    equations = equations,
    entries = {},
  }

  set_keymaps(buf)
  M.render()
  M.goto_entry(1)

  local group = vim.api.nvim_create_augroup("eqnav.view." .. buf, { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved" }, {
    group = group,
    buffer = buf,
    callback = M.highlight_current,
  })

  -- Rendered images live in the terminal, not in the buffer: they stay painted
  -- until something sends the graphics-delete escape, so every path out of the
  -- index has to clear them. `q` routes through M.close(), which does -- but
  -- `:q`, `ZZ`, `:bd` and quitting Neovim do not, and those used to drop the
  -- view on the floor with its placements still live. The snacks backend happens
  -- to register its own BufWipeout/ExitPre cleanup (placement.new calls
  -- Snacks.image.setup), but display/image_nvim.lua has none, and leaning on
  -- another plugin's autocmds for this is how equations end up painted over the
  -- shell prompt after you quit.
  local function clear_images()
    pcall(function()
      display.get().clear(buf)
    end)
  end

  vim.api.nvim_create_autocmd({ "BufWipeout", "WinClosed" }, {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      clear_images()
      current = nil
    end,
  })
  -- Not buffer-scoped, so it also covers :qa from the source window.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = clear_images,
  })

  if config.options.render.enabled and display.get().images then
    require("eqnav.render").render_all(equations, function(index, png, err, id)
      if current and current.buf == buf then
        M.set_image(index, png, err, id)
      end
    end)
  end

  if opts.focus == false and vim.api.nvim_win_is_valid(source_win) then
    vim.api.nvim_set_current_win(source_win)
  end
  return current
end

function M.close()
  if not current then
    return
  end
  local buf, win = current.buf, current.win
  pcall(function()
    display.get().clear(buf)
  end)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  pcall(vim.api.nvim_del_augroup_by_name, "eqnav.view." .. buf)
  current = nil
end

function M.toggle(opts)
  if M.is_open() then
    M.close()
  else
    M.open(opts)
  end
end

--- Re-scan the source buffer and rebuild. `force` bypasses the render cache.
---@param force? boolean
function M.refresh(force)
  if not current then
    return
  end
  local keep = M.cursor_entry()
  current.equations = scan.scan(current.source_buf)
  current.entries = {}
  M.render()
  if keep then
    M.goto_entry(math.min(keep, #current.equations))
  end
  if config.options.render.enabled and display.get().images then
    require("eqnav.render").render_all(current.equations, function(index, png, err, id)
      if current then
        M.set_image(index, png, err, id)
      end
    end, { force = force })
  end
end

return M
