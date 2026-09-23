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

--- A plain `w`x`h` px PNG made by the rasterizer eqnav uses, or nil (and the
--- test marked pending) when there is none.
---@return string|nil
function M.make_png(w, h)
  local raster = require("eqnav.render.raster")
  if not raster.detect() then
    pending("no rasterizer")
    return nil
  end
  local tmp = vim.fn.tempname()
  local fh = assert(io.open(tmp .. ".svg", "w"))
  fh:write(
    string.format(
      '<svg xmlns="http://www.w3.org/2000/svg" width="%dpx" height="%dpx">'
        .. '<rect width="%d" height="%d" fill="#fff"/></svg>',
      w,
      h,
      w,
      h
    )
  )
  fh:close()
  local png
  raster.convert(tmp .. ".svg", tmp .. ".png", function(p)
    png = p or false
  end)
  assert.is_true(vim.wait(10000, function()
    return png ~= nil
  end))
  assert.is_truthy(png)
  return png
end

return M
