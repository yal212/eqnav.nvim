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

--- Per buffer, the image at each row and the file it shows.
local images = {} ---@type table<integer, table<integer, { png: string, img: table }>>

--- The PNG's own height over the cell height. Read from the file rather than
--- from image.nvim, which would build an Image (and throw before setup) just to
--- report a number the IHDR already holds.
function M.rows(_eq, png, _width)
  local _, h = require("eqnav.display.png").size(png)
  if h == 0 then
    return 1
  end
  local _, cell_h = cell_size()
  return math.max(1, math.ceil(h / cell_h))
end

function M.lines()
  return nil
end

function M.place(bufnr, row, _eq, png)
  local image = api()
  if not image or not png then
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
  local ok, img = pcall(image.from_file, png, {
    buffer = bufnr,
    with_virtual_padding = true,
    x = 0,
    y = row - 1, -- image.nvim rows are 0-indexed
  })
  if not ok or not img then
    return nil
  end
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
