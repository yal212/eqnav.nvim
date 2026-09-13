local M = {}

--- A scratch buffer holding `text`, with the given filetype.
---@param text string
---@param filetype? string
---@return integer bufnr
function M.buf(text, filetype)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.bo[bufnr].filetype = filetype or "markdown"
  return bufnr
end

--- Compact view of a scan result, so failures read as data rather than a dump.
---@param equations eqnav.Equation[]
function M.summary(equations)
  return vim.tbl_map(function(e)
    return { tex = e.tex, display = e.display, lnum = e.lnum }
  end, equations)
end

return M
