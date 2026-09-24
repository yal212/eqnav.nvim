local M = {}

---@class eqnav.Config
local defaults = {
  -- Filetypes eqnav will scan. Anything not listed is ignored outright.
  -- `typst` is deliberately absent: there is no queries/typst/eqnav.scm, the
  -- regex fallback's delimiters are LaTeX-shaped, and Typst math is not TeX, so
  -- MathJax cannot read it even where the `$` happens to line up. Listing it
  -- promised support that does not exist. Add it yourself to experiment.
  filetypes = { "markdown", "quarto", "rmd", "tex", "latex", "plaintex" },

  -- Index inline math ($x$) as well as display math ($$..$$).
  -- Off by default on purpose: the index is about escaping noise, and a
  -- document's inline math is mostly single symbols that re-create it.
  include_inline = false,

  window = {
    position = "right", ---@type "right"|"left"|"top"|"bottom"|"float"|"tab"
    width = 60,
    height = 15,
  },

  render = {
    enabled = true,
    ex = 9, -- CSS px per TeX `ex`, times the display density; sets equation size
    color = nil, -- nil follows the Normal highlight's foreground
    concurrency = 8, -- parallel rasterizer processes
    node = "node",
    rasterizer = nil, -- nil auto-detects rsvg-convert, then magick
  },

  display = {
    backend = "auto", ---@type "auto"|"snacks"|"image_nvim"|"text"
  },

  sync = {
    live = true, -- re-scan and re-render as the source buffer changes
    debounce = 300,
    follow = false, -- move the source window to match the index cursor
  },

  keymaps = {
    next = "j",
    prev = "k",
    jump = "<CR>",
    jump_keep = "o",
    yank = "y",
    refresh = "r",
    export = "gx",
    close = "q",
  },
}

---@type eqnav.Config
M.options = vim.deepcopy(defaults)
M.defaults = defaults

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  vim.validate("filetypes", M.options.filetypes, "table")
  vim.validate("window.position", M.options.window.position, function(v)
    return vim.tbl_contains({ "right", "left", "top", "bottom", "float", "tab" }, v)
  end, "one of right|left|top|bottom|float|tab")
  vim.validate("display.backend", M.options.display.backend, function(v)
    return vim.tbl_contains({ "auto", "snacks", "image_nvim", "text" }, v)
  end, "one of auto|snacks|image_nvim|text")
  return M.options
end

---@param bufnr integer
function M.enabled_for(bufnr)
  return vim.tbl_contains(M.options.filetypes, vim.bo[bufnr].filetype)
end

return M
