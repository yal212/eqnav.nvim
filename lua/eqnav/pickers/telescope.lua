local scan = require("eqnav.scan")
local util = require("eqnav.scan.util")

--- Fuzzy-find an equation and jump to it.
---
--- The index view answers "show me all the equations"; this answers "where is
--- the one with sigma in it" without scrolling anything.
local M = {}

local function telescope()
  local ok, t = pcall(require, "telescope")
  if not ok then
    return nil
  end
  return t
end

---@param eq eqnav.Equation
---@return string
local function display(eq)
  local lnum = scan.mark_pos(eq)
  local left = string.format("%3d  L%-5d", eq.index, lnum)
  local context = eq.context and (eq.context .. "  ") or ""
  return left .. "  " .. context .. util.summarize(eq.tex, 70)
end

---@param opts? table
function M.pick(opts)
  opts = opts or {}
  if not telescope() then
    vim.notify("eqnav: telescope.nvim is not installed", vim.log.levels.WARN)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local view = require("eqnav.view")
  local state = view.current()
  -- Reuse the open index's scan so ordinals and extmarks stay consistent.
  local equations = (state and state.source_buf == bufnr) and state.equations or scan.scan(bufnr)

  if #equations == 0 then
    vim.notify("eqnav: no equations in this buffer", vim.log.levels.INFO)
    return
  end

  pickers
    .new(opts, {
      prompt_title = "Equations",
      finder = finders.new_table({
        results = equations,
        entry_maker = function(eq)
          return {
            value = eq,
            -- Everything you might search by: the math, its label, its heading.
            ordinal = table.concat({ eq.tex, eq.label or "", eq.context or "" }, " "),
            display = display(eq),
            filename = vim.api.nvim_buf_get_name(bufnr),
            lnum = select(1, scan.mark_pos(eq)),
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = previewers.new_buffer_previewer({
        title = "Equation",
        define_preview = function(self, entry)
          local eq = entry.value
          local lines = {}
          if eq.context then
            table.insert(lines, "# " .. eq.context)
            table.insert(lines, "")
          end
          if eq.label then
            table.insert(lines, "label: " .. eq.label)
            table.insert(lines, "")
          end
          table.insert(lines, eq.display and "$$" or "$")
          for _, l in ipairs(vim.split(eq.tex, "\n", { plain = true })) do
            table.insert(lines, l)
          end
          table.insert(lines, eq.display and "$$" or "$")
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
          vim.bo[self.state.bufnr].filetype = "markdown"
        end,
      }),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if not entry then
            return
          end
          local eq = entry.value
          local lnum, col = scan.mark_pos(eq)
          for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == bufnr then
              vim.api.nvim_set_current_win(win)
              break
            end
          end
          pcall(vim.api.nvim_win_set_cursor, 0, { lnum, col })
          vim.cmd("normal! zz")
        end)
        return true
      end,
    })
    :find()
end

return M
