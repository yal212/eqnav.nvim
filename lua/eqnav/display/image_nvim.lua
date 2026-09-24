--- 3rd/image.nvim backend. Secondary to snacks, but the only option that also
--- drives ueberzug++ for terminals without native graphics.
---@type eqnav.DisplayBackend
local M = {
  name = "image_nvim",
  images = true,
}

local function api()
  local ok, image = pcall(require, "image")
  return ok and image or nil
end

--- image.nvim has no public way to ask whether setup() has run, and until it
--- has, every from_file() throws -- so an image.nvim that is installed but never
--- set up would be picked over the text backend and show nothing at all. Asking
--- for a file that does not exist tells the two apart: before setup it throws
--- "not setup", after it "file not found". tests/image_nvim_spec.lua pins that
--- message, so a rewording upstream fails CI instead of flipping backends.
---@param image table
---@return boolean
local function is_setup(image)
  local ok, err = pcall(image.from_file, "/nonexistent/eqnav-setup-probe.png")
  return ok or not tostring(err):find("not setup", 1, true)
end

function M.available()
  local image = api()
  return image ~= nil and type(image.from_file) == "function" and is_setup(image)
end

--- Pixels per terminal cell, as image.nvim measures them. Not public API, so
--- guarded. The slash-separated name is deliberate: image.nvim requires it as
--- "image/utils/term", and package.loaded is keyed by that exact string, so the
--- dotted spelling loads a second copy with its own cached size and its own
--- VimResized autocmd.
---@return number cell_width, number cell_height
local function cell_size()
  local ok, size = pcall(function()
    return require("image/utils/term").get_size()
  end)
  if ok and size and (size.cell_height or 0) > 0 then
    return size.cell_width, size.cell_height
  end
  return 8, 17 -- headless, or the terminal would not say
end

--- What the renderer sizes images for: whole cells, at the display's density.
--- image.nvim has no density of its own, so the scale is snacks' guess from the
--- cell width. `keeps_height` has raster.box size the canvas for the way
--- image.nvim rounds (#54).
---@return eqnav.Geometry
function M.geometry()
  local cw, ch = cell_size()
  return { cell_width = cw, cell_height = ch, scale = math.max(1, cw / 8), keeps_height = true }
end

--- The PNG's size in whole cells, as image.nvim is asked to draw it: its rows
--- are its height in cells, rounded, because the renderer pads to ceil(n cells),
--- a hair over n; its columns are what image.nvim works out for that height,
--- in its own arithmetic. Read from the IHDR rather than from image.nvim, which
--- would build an Image (and throw before setup) for numbers the file holds.
---@param png string|nil
---@return integer cols, integer rows, number w, number h 0 cols for anything not a PNG
local function cells(png)
  local w, h = require("eqnav.display.png").size(png)
  if w == 0 or h == 0 then
    return 0, 1, 0, 0
  end
  local cw, ch = cell_size()
  local rows = math.max(1, math.floor(h / ch + 0.5))
  return math.max(1, math.ceil(rows * ch * (w / h) / cw)), rows, w, h
end

--- The box image.nvim is asked to draw `png` in, at most `width` columns, and
--- the box it then draws. It keeps the aspect by working one side out from the
--- other with its own adjust_to_aspect_ratio, which is called here on the same
--- numbers, so the rows eqnav reserves are the rows it draws. For a PNG the
--- renderer padded (raster.box), the two boxes are the same and the image is
--- shown 1:1; one wider than the window comes out shorter.
---@param png string|nil
---@param width integer
---@return integer cols, integer rows, integer drawn_rows
local function fit(png, width)
  local cols, rows, w, h = cells(png)
  if cols == 0 then
    return 1, 1, 1
  end
  cols = math.min(cols, math.max(1, width))
  local cw, ch = cell_size()
  local ok, _, drawn = pcall(function()
    local size = { cell_width = cw, cell_height = ch }
    return require("image/utils/math").adjust_to_aspect_ratio(size, w, h, cols, rows)
  end)
  if not (ok and type(drawn) == "number") then
    -- image.nvim is not loaded: the same rule, done here.
    drawn = rows
    if cols * cw / w < rows * ch / h then
      drawn = math.max(1, math.ceil(cols * cw * (h / w) / ch))
    end
  end
  return cols, rows, drawn
end

--- The rows image.nvim draws `png` in, in a window `width` columns wide.
function M.rows(_eq, png, width)
  local _, _, drawn = fit(png, width)
  return drawn
end

--- Whether image.nvim shrinks this image to fit `width` columns, drawing it
--- smaller than every other entry, for the index to mark (#41).
function M.overflows(png, width)
  return cells(png) > width
end

function M.lines()
  return nil
end

--- Per buffer, the image at each row and the file it shows.
local images = {} ---@type table<integer, table<integer, { png: string, img: table }>>

--- image.nvim draws an image in the window it is bound to, starting on the row
--- below its anchor line. Bound to no window, it takes x and y as terminal
--- coordinates, so the image lands at the left of the screen, over the source,
--- and stays put when the index scrolls (#60). So it is bound to the window
--- showing the index and anchored on the entry's header, which puts it on the
--- blank rows reserved under the header. No virtual padding: those rows are
--- already there. `overlap` counts the header and those rows, which keeps
--- image.nvim drawing what is left of the image while the header is scrolled
--- off the top. It gives up one row early: with only the image's last row still
--- in view, it draws nothing.
function M.place(bufnr, row, _eq, png)
  local image = api()
  if not image or not png then
    return nil
  end
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    return nil
  end
  local rows = images[bufnr] or {}
  images[bufnr] = rows
  local existing = rows[row]
  if existing and existing.png == png then
    return existing.img
  end
  if existing then
    pcall(function()
      existing.img:clear()
    end)
    rows[row] = nil
  end
  local cols, height, drawn = fit(png, vim.api.nvim_win_get_width(win))
  local ok, img = pcall(image.from_file, png, {
    window = win,
    buffer = bufnr,
    x = 0,
    y = math.max(0, row - 2), -- the header, 0-indexed; the image goes under it
    width = cols,
    height = height,
    overlap = drawn + 1,
  })
  if not ok or not img then
    return nil
  end
  -- The box is the one rows() reserved, which image.nvim's
  -- max_height_window_percentage (50 by default) and max_width/max_height
  -- would shrink. Its own document integration sets this the same way.
  img.ignore_global_max_size = true
  pcall(function()
    img:render()
  end)
  rows[row] = { png = png, img = img }
  return img
end

function M.clear(bufnr)
  for _, entry in pairs(images[bufnr] or {}) do
    pcall(function()
      entry.img:clear()
    end)
  end
  images[bufnr] = nil
end

return M
