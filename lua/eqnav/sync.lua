local config = require("eqnav.config")
local scan = require("eqnav.scan")

--- Keeps the index and the source in step: re-scan as the document changes,
--- and mirror the cursor between the two windows.
local M = {}

M.ns = vim.api.nvim_create_namespace("eqnav.sync")

local group = nil
local timer = nil
-- Cursor mirroring is inherently mutually recursive; this flag is what stops
-- index-follows-source and source-follows-index from driving each other.
local syncing = false

local function debounce(fn, ms)
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  timer = vim.uv.new_timer()
  timer:start(
    ms,
    0,
    vim.schedule_wrap(function()
      if timer then
        timer:stop()
        timer:close()
        timer = nil
      end
      fn()
    end)
  )
end

--- Equation whose range contains `lnum`, else the nearest one above it.
---@param equations eqnav.Equation[]
---@param lnum integer
---@return integer|nil index
function M.at_line(equations, lnum)
  local best = nil
  for _, eq in ipairs(equations) do
    local start = scan.mark_pos(eq)
    local finish = start + (eq.end_lnum - eq.lnum)
    if lnum >= start and lnum <= finish then
      return eq.index
    end
    if start <= lnum then
      best = eq.index
    end
  end
  return best
end

--- Highlight an equation's range in the source buffer.
---@param eq eqnav.Equation|nil
function M.highlight_source(eq)
  local view = require("eqnav.view")
  local state = view.current()
  if not state or not vim.api.nvim_buf_is_valid(state.source_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(state.source_buf, M.ns, 0, -1)
  if not eq then
    return
  end
  local lnum = scan.mark_pos(eq)
  local last = vim.api.nvim_buf_line_count(state.source_buf)
  for l = lnum, math.min(lnum + (eq.end_lnum - eq.lnum), last) do
    pcall(vim.api.nvim_buf_set_extmark, state.source_buf, M.ns, l - 1, 0, {
      line_hl_group = "EqnavCurrent",
    })
  end
end

--- Wire autocmds for a source buffer while its index is open.
---@param source_buf integer
function M.attach(source_buf)
  M.detach()
  group = vim.api.nvim_create_augroup("eqnav.sync." .. source_buf, { clear = true })
  local view = require("eqnav.view")

  if config.options.sync.live then
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = group,
      buffer = source_buf,
      callback = function()
        debounce(function()
          if view.is_open() then
            view.refresh()
          end
        end, config.options.sync.debounce)
      end,
    })
  end

  -- Index follows the source cursor.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = source_buf,
    callback = function()
      if syncing or not view.is_open() then
        return
      end
      local state = view.current()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      local index = M.at_line(state.equations, lnum)
      if index then
        syncing = true
        view.goto_entry(index)
        syncing = false
      end
    end,
  })

  -- Source follows the index cursor. Opt-in: moving someone's other window
  -- unasked is surprising, so `sync.follow` defaults to false and only the
  -- highlight is applied.
  local state = view.current()
  if state then
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = group,
      buffer = state.buf,
      callback = function()
        if syncing then
          return
        end
        local index = view.cursor_entry()
        local eq = index and view.current() and view.current().equations[index]
        M.highlight_source(eq)
        if eq and config.options.sync.follow then
          local win = state.source_win
          if win and vim.api.nvim_win_is_valid(win) then
            syncing = true
            local lnum = scan.mark_pos(eq)
            pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
            syncing = false
          end
        end
      end,
    })
  end

  -- A colorscheme change makes every cached image the wrong colour; the id
  -- includes the foreground, so a refresh re-renders rather than reusing them.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      if view.is_open() then
        view.setup_highlights()
        view.refresh()
      end
    end,
  })
end

function M.detach()
  if group then
    pcall(vim.api.nvim_del_augroup_by_id, group)
    group = nil
  end
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_clear_namespace, buf, M.ns, 0, -1)
    end
  end
end

return M
