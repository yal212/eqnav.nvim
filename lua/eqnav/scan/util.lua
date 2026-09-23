local M = {}

-- Delimiter pairs we strip before handing math to the renderer. Environments
-- (\begin{align}..) are deliberately absent: MathJax understands those natively
-- and stripping them would lose the alignment.
local PAIRS = {
  { "$$", "$$", true },
  { "\\[", "\\]", true },
  { "\\(", "\\)", false },
  { "$", "$", false },
}

--- Drop a pandoc `{#eq:foo}` attribute. It is not TeX: pandoc consumes it before
--- TeX ever sees it, which is why the syntax exists, and MathJax fails on the
--- `#` with "You can't use 'macro parameter character #' in math mode". `M.label`
--- has already read it out of the raw text by the time this runs, and `raw` keeps
--- it so yanking still reproduces the source exactly. The pattern deliberately
--- mirrors `M.label`'s so the two cannot drift apart.
---@param s string
---@return string
local function drop_pandoc_label(s)
  return vim.trim((s:gsub("%s*{#eq:[%w_%-]+}", "")))
end

--- Strip math delimiters. Returns the inner text and whether the delimiters
--- themselves indicated display math (nil when they say nothing either way).
---@param raw string
---@return string tex, boolean|nil display
function M.strip(raw)
  local s = vim.trim(raw)
  for _, p in ipairs(PAIRS) do
    local open, close, display = p[1], p[2], p[3]
    if #s > #open + #close and s:sub(1, #open) == open and s:sub(-#close) == close then
      return drop_pandoc_label(s:sub(#open + 1, #s - #close)), display
    end
  end
  return drop_pandoc_label(s), nil
end

--- `\label{foo}` or a pandoc `{#eq:foo}` attribute, if the equation carries one.
---@param tex string
---@return string|nil
function M.label(tex)
  return tex:match("\\label%s*{([^}]+)}") or tex:match("{#(eq:[%w_%-]+)}")
end

--- Nearest preceding heading, used to give each index entry a sense of place.
---@param bufnr integer
---@param lnum integer 1-indexed
---@return string|nil
function M.context(bufnr, lnum)
  local from = math.max(0, lnum - 400)
  local lines = vim.api.nvim_buf_get_lines(bufnr, from, lnum, false)
  for i = #lines, 1, -1 do
    local line = lines[i]
    local md = line:match("^#+%s+(.+)$")
    if md then
      return vim.trim(md)
    end
    local tex = line:match("\\%a*section%*?%s*{(.-)}")
    if tex then
      return vim.trim(tex)
    end
  end
  return nil
end

--- Collapse an equation to one line for use in list UIs.
---@param tex string
---@param width? integer
function M.summarize(tex, width)
  width = width or 60
  local one = tex:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if vim.fn.strdisplaywidth(one) <= width then
    return one
  end
  return vim.fn.strcharpart(one, 0, width - 1) .. "…"
end

--- The daemon's output format. It is in every cache key, so bump it whenever the
--- daemon draws the same input differently -- otherwise a render cached before
--- the change is served forever, bug included. 2: \tag rasterizing blank (#40)
--- and a repeated \label rendering as an error box (#15). 3: inline math cut
--- off at its first possible line break (#46).
M.RENDER_VERSION = 3

--- Stable identity for an equation's rendered form. Anything that changes the
--- pixels must be in here, or a stale image is served from cache.
---@param tex string
---@param display boolean
---@param color string|nil
---@param ex number
---@param geom? eqnav.Geometry the cell size images are padded to, and the density
---@param width? integer index columns display math is broken to fit
function M.hash(tex, display, color, ex, geom, width)
  local parts = {
    tostring(M.RENDER_VERSION),
    tex,
    tostring(display),
    color or "-",
    tostring(ex),
    geom and string.format("%sx%s@%s", geom.cell_width, geom.cell_height, geom.scale) or "-",
  }
  -- Only when there is one, so a render with no width -- the HTML export's --
  -- keeps the key it always had.
  if width then
    table.insert(parts, tostring(width))
  end
  return vim.fn.sha256(table.concat(parts, "\0")):sub(1, 32)
end

return M
