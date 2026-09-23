--- snacks.nvim image backend.
---
--- Preferred because it needs no `magick` luarock, speaks the Kitty graphics
--- protocol, and already knows how to wrap escapes for tmux passthrough.
---@type eqnav.DisplayBackend
local M = {
  name = "snacks",
  images = true,
}

---@return table|nil
local function snacks()
  local ok, s = pcall(require, "snacks")
  if not ok or not s or not s.image then
    return nil
  end
  return s
end

function M.available()
  local s = snacks()
  if not s then
    return false
  end
  -- `supports_terminal` is the honest question: snacks may be installed while
  -- the terminal cannot show anything, in which case we want the text backend
  -- rather than a buffer full of invisible gaps.
  local ok, supported = pcall(function()
    return s.image.supports_terminal()
  end)
  return ok and supported == true
end

--- Pixels per terminal cell, and device px per CSS px, as snacks measures them.
---@return number cell_width, number cell_height, number scale
local function cell_size()
  local s = snacks()
  if s then
    local ok, size = pcall(function()
      return s.image.terminal.size()
    end)
    if ok and size and (size.cell_height or 0) > 0 then
      return size.cell_width, size.cell_height, math.max(1, size.scale or 1)
    end
  end
  return 8, 17, 1 -- a reasonable default; only affects spacing, not correctness
end

--- What the renderer sizes images for. Rendering at `scale` keeps glyphs sharp
--- on a HiDPI display, and the renderer pads to whole cells of this size, which
--- is what makes rows() exact.
---@return eqnav.Geometry
function M.geometry()
  local cw, ch, scale = cell_size()
  return { cell_width = cw, cell_height = ch, scale = scale }
end

---@param png string|nil
---@return integer width, integer height
local function png_size(png)
  if not png then
    return 0, 0
  end
  local ok, dims = pcall(function()
    local s = snacks()
    return s and s.image.util and s.image.util.dim and s.image.util.dim(png) or nil
  end)
  if ok and dims and dims.width then
    return dims.width, dims.height
  end
  return require("eqnav.display.png").size(png)
end

--- Exact rather than an estimate: the renderer pads each image to whole cells
--- of geometry() and stamps it with the DPI that makes snacks' `px / dpi * 96 *
--- scale` sizing come out 1:1 (raster.box and raster.stamp_dpi). So its height
--- in cells is what snacks draws, unless the image is wider than the window:
--- snacks then shrinks it to fit, keeping its aspect, and it takes fewer rows.
--- That case is asked of snacks' own fit() rather than copied from it.
function M.rows(_eq, png, width)
  local _, h = png_size(png)
  if h == 0 then
    return 1
  end
  local _, cell_h = cell_size()
  local rows = math.max(1, math.ceil(h / cell_h))
  local s = snacks()
  local ok, fit = pcall(function()
    return s.image.util.fit(png, { width = width, height = rows })
  end)
  if ok and fit and (fit.height or 0) > 0 then
    return math.min(rows, fit.height)
  end
  return rows
end

--- Whether snacks shrinks this image to fit a window `width` columns wide. It
--- does that to anything wider, keeping the aspect, so the glyphs come out
--- smaller than every other entry's. The renderer breaks display math to fit
--- the index (#41); this is what it could not break, for the index to mark.
--- Measured the way rows() is: the image is whole cells at 1:1.
function M.overflows(png, width)
  local w = png_size(png)
  if w == 0 then
    return false
  end
  local cell_w = cell_size()
  return math.ceil(w / cell_w) > width
end

function M.lines()
  return nil -- image backends occupy blank lines
end

--- Per buffer, the placement at each row and the file it shows.
local placements = {} ---@type table<integer, table<integer, { png: string, placement: table }>>

function M.place(bufnr, row, _eq, png)
  local s = snacks()
  if not s or not png then
    return nil
  end
  local rows = placements[bufnr] or {}
  placements[bufnr] = rows
  local existing = rows[row]
  if existing and existing.png == png then
    return existing.placement
  end
  if existing then
    pcall(function()
      existing.placement:close()
    end)
    rows[row] = nil
  end
  local ok, placement = pcall(function()
    return s.image.placement.new(bufnr, png, {
      pos = { row, 0 }, -- snacks positions are (1,0)-indexed
      inline = true,
      auto_resize = false,
      converted = true,
    })
  end)
  if not ok then
    return nil
  end
  rows[row] = { png = png, placement = placement }
  return placement
end

function M.clear(bufnr)
  for _, p in pairs(placements[bufnr] or {}) do
    pcall(function()
      p.placement:close()
    end)
  end
  placements[bufnr] = nil
end

return M
