local config = require("eqnav.config")
local regex = require("eqnav.scan.regex")
local treesitter = require("eqnav.scan.treesitter")
local util = require("eqnav.scan.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("eqnav.marks")

-- Neovim does not map the tex filetypes onto the `latex` parser on its own
-- (nvim-treesitter normally does it), so without this a .tex buffer looks for
-- a parser and an eqnav query named "tex" and silently finds neither.
local FT_LANG = { tex = "latex", plaintex = "latex", rmd = "markdown", quarto = "markdown" }

for ft, lang in pairs(FT_LANG) do
  pcall(vim.treesitter.language.register, lang, ft)
end

--- Treesitter language backing a filetype.
---@param ft string
---@return string
function M.language_for(ft)
  return FT_LANG[ft] or vim.treesitter.language.get_lang(ft) or ft
end

---@class eqnav.Equation
---@field id string content hash; the render cache key
---@field tex string math source, delimiters stripped
---@field raw string source including delimiters
---@field display boolean display math vs inline
---@field lnum integer 1-indexed start line
---@field col integer 0-indexed start column
---@field end_lnum integer
---@field end_col integer
---@field index integer ordinal within the document
---@field label string|nil \label{..} if present
---@field context string|nil nearest heading
---@field bufnr integer
---@field mark integer|nil extmark id tracking the live position

--- Drop extmarks for a buffer's previous scan.
---@param bufnr integer
function M.clear_marks(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
end

--- Anchor each equation to an extmark so edits above it keep the jump target
--- correct without a full re-scan. Line numbers alone go stale the moment
--- anything is inserted; `mark_pos` below always reads through the extmark.
---@param bufnr integer
---@param equations eqnav.Equation[]
local function attach_marks(bufnr, equations)
  M.clear_marks(bufnr)
  local last = vim.api.nvim_buf_line_count(bufnr)
  for _, eq in ipairs(equations) do
    local row = math.min(eq.lnum - 1, last - 1)
    local end_row = math.min(eq.end_lnum - 1, last - 1)
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, eq.col, {
      end_row = end_row,
      end_col = eq.end_col,
      right_gravity = false,
      end_right_gravity = true,
    })
    eq.mark = ok and id or nil
  end
end

--- Current position of an equation, read from its extmark when it has one.
---@param eq eqnav.Equation
---@return integer lnum 1-indexed
---@return integer col
function M.mark_pos(eq)
  if eq.mark and vim.api.nvim_buf_is_valid(eq.bufnr) then
    local m = vim.api.nvim_buf_get_extmark_by_id(eq.bufnr, M.ns, eq.mark, {})
    if m and m[1] then
      return m[1] + 1, m[2]
    end
  end
  return eq.lnum, eq.col
end

--- Scan a buffer into an ordered list of equations.
---@param bufnr? integer
---@param opts? { include_inline?: boolean, marks?: boolean }
---@return eqnav.Equation[]
function M.scan(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}
  local include_inline = opts.include_inline
  if include_inline == nil then
    include_inline = config.options.include_inline
  end

  local found = treesitter.scan(bufnr)
  if not found then
    found = regex.scan(bufnr)
  end

  local color = config.options.render.color
  local ex = config.options.render.ex

  local out = {}
  for _, eq in ipairs(found) do
    if eq.display or include_inline then
      eq.index = #out + 1
      eq.context = util.context(bufnr, eq.lnum)
      eq.id = util.hash(eq.tex, eq.display, color, ex)
      table.insert(out, eq)
    end
  end

  if opts.marks ~= false then
    attach_marks(bufnr, out)
  end
  return out
end

--- Which scanner would be used for this buffer. Surfaced by :checkhealth.
---@param bufnr integer
---@return "treesitter"|"regex"
function M.backend(bufnr)
  return treesitter.available(bufnr) and "treesitter" or "regex"
end

return M
