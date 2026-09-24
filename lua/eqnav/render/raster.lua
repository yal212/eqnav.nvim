local M = {}

--- rsvg-convert first: librsvg renders MathJax's output faithfully and is
--- fast. ImageMagick's internal SVG renderer is a rougher approximation, so it
--- is only the fallback.
local CANDIDATES = { "rsvg-convert", "magick", "convert" }

local resolved = nil

---@return string|nil name
function M.detect()
  if resolved ~= nil then
    return resolved or nil
  end
  local config = require("eqnav.config")
  local forced = config.options.render.rasterizer
  if forced then
    resolved = vim.fn.executable(forced) == 1 and forced or false
    return resolved or nil
  end
  for _, c in ipairs(CANDIDATES) do
    if vim.fn.executable(c) == 1 then
      resolved = c
      return c
    end
  end
  resolved = false
  return nil
end

function M.reset()
  resolved = nil
end

---@class eqnav.RasterBox
---@field width integer
---@field height integer
---@field top integer
---@field left integer

---@class eqnav.Geometry
---@field cell_width number device px
---@field cell_height number device px
---@field scale number device px per CSS px
--- The backend draws an image in the rows it is asked for and works out the
--- columns from the image's aspect ratio, rounding up (image.nvim). M.box then
--- sizes the canvas for that rounding rather than snacks'.
---@field keeps_height? boolean

--- The canvas an image of `w` x `h` device px is padded onto: a whole number of
--- terminal cells on each axis (#17).
---
--- The terminal shows an image in a box of whole cells and stretches it to fill
--- the box, so an image that is not already whole cells is stretched by a factor
--- of its own, up to 2x for a short equation. Padding makes that box exact.
---
--- A cell can be fractional px (snacks divides the window's pixel size by its
--- rows), and a canvas must be whole px. Flooring n cells keeps snacks' ceil()
--- on the same n; the bump makes sure flooring never crops the image's last
--- pixel row, which the rasterizer rounds up.
---
--- image.nvim is handed the box (`keeps_height`), keeps its rows, and takes the
--- columns as ceil(rows * cell_height * aspect / cell_width). A canvas exactly
--- the box's aspect makes that the ceil of a whole number, which floating point
--- can push one column over (#54). So the height is ceil(n cells), which rounds
--- back to n, and the width a quarter to one and a quarter px under the box's
--- aspect, which makes the columns come out a hair under m and ceil to m.
---@param w number
---@param h number
---@param geom eqnav.Geometry
---@return eqnav.RasterBox
function M.box(w, h, geom)
  local function cells(len, cell)
    local n = math.max(1, math.ceil(len / cell))
    if math.floor(n * cell) < math.ceil(len) then
      n = n + 1
    end
    return n
  end
  local width, height
  if geom.keeps_height then
    local cw, ch = geom.cell_width, geom.cell_height
    local n = math.max(1, math.ceil(h / ch))
    height = math.ceil(n * ch)
    local m = math.max(1, math.ceil(w / cw))
    repeat
      -- The width of exactly the box's aspect at this height.
      local exact = height * m * cw / (n * ch)
      width = math.ceil(exact - 0.25) - 1
      m = m + 1
    until width >= math.ceil(w)
  else
    width = math.floor(cells(w, geom.cell_width) * geom.cell_width)
    height = math.floor(cells(h, geom.cell_height) * geom.cell_height)
  end
  return {
    width = width,
    height = height,
    -- Centred vertically so the spare fraction of a row splits between the gap
    -- above and below rather than piling up before the next header.
    top = math.floor((height - h) / 2),
    left = 0,
  }
end

---@param tool string
---@param svg string
---@param png string
---@param opts { box?: eqnav.RasterBox, zoom?: number }
---@return string[]
local function command(tool, svg, png, opts)
  local box = opts.box
  if tool == "rsvg-convert" then
    -- The SVG already carries explicit px dimensions stamped by the daemon, so
    -- output is deterministic. `zoom` takes those CSS px to device px; the page
    -- and offsets below are already device px, measured after the zoom.
    local cmd = { tool }
    if opts.zoom then
      vim.list_extend(cmd, { "--zoom", tostring(opts.zoom) })
    end
    if box then
      vim.list_extend(cmd, {
        "--page-width",
        tostring(box.width),
        "--page-height",
        tostring(box.height),
        "--top",
        tostring(box.top),
        "--left",
        tostring(box.left),
      })
    end
    vim.list_extend(cmd, { "-o", png, svg })
    return cmd
  end
  local cmd = { tool, "-background", "none" }
  if opts.zoom then
    -- ImageMagick reads an SVG's px at 96 dpi, so this density is the zoom.
    vim.list_extend(cmd, { "-density", tostring(96 * opts.zoom) })
  end
  table.insert(cmd, svg)
  if box then
    -- West: left edge, centred vertically, the same placement as M.box's top.
    vim.list_extend(cmd, { "-gravity", "West", "-extent", box.width .. "x" .. box.height })
  end
  table.insert(cmd, "PNG32:" .. png)
  return cmd
end

local crc_table = nil

--- CRC-32 as PNG chunks use it (ISO 3309, reflected 0xEDB88320).
---@param s string
---@return integer unsigned
function M.crc32(s)
  local bit = require("bit")
  if not crc_table then
    crc_table = {}
    for i = 0, 255 do
      local c = i
      for _ = 1, 8 do
        if bit.band(c, 1) == 1 then
          c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
        else
          c = bit.rshift(c, 1)
        end
      end
      crc_table[i] = c
    end
  end
  local c = 0xFFFFFFFF
  for i = 1, #s do
    c = bit.bxor(crc_table[bit.band(bit.bxor(c, s:byte(i)), 0xFF)], bit.rshift(c, 8))
  end
  -- bit ops are signed 32-bit in LuaJIT; the file stores it unsigned.
  return bit.bxor(c, 0xFFFFFFFF) % 0x100000000
end

---@param n integer
---@return string
local function u32(n)
  return string.char(
    math.floor(n / 0x1000000) % 256,
    math.floor(n / 0x10000) % 256,
    math.floor(n / 0x100) % 256,
    n % 256
  )
end

--- Give a PNG a resolution of `ppu` with the unit left unspecified.
---
--- snacks sizes an image as `px / dpi * 96 * scale`, taking the DPI from
--- `magick identify`. rsvg-convert writes no pHYs, which ImageMagick reports as
--- 72, so every image was drawn 96/72 * scale times the size eqnav reserved rows
--- for (#6). Stamping ppu = 96 * scale makes that factor 1.
---
--- The unit has to be 0. A pHYs in pixels per metre, the only real unit PNG has,
--- comes back from ImageMagick as pixels per *centimetre* (240 dpi is reported
--- as 94.48), and snacks would read that number as a DPI. With unit 0 it reports
--- the stored number as-is.
---@param png string
---@param ppu integer
---@return string|nil err
function M.stamp_dpi(png, ppu)
  local fh = io.open(png, "rb")
  if not fh then
    return "cannot read " .. png
  end
  local bytes = fh:read("*a")
  fh:close()
  if bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" or bytes:sub(13, 16) ~= "IHDR" then
    return "not a PNG: " .. png
  end
  local data = u32(ppu) .. u32(ppu) .. "\0"
  local out = { bytes:sub(1, 33), u32(#data), "pHYs", data, u32(M.crc32("pHYs" .. data)) }
  -- Copy every chunk after IHDR except an existing pHYs, which would conflict.
  local pos = 34
  while pos + 11 <= #bytes do
    local a, b, c, d = bytes:byte(pos, pos + 3)
    local len = ((a * 256 + b) * 256 + c) * 256 + d
    if bytes:sub(pos + 4, pos + 7) ~= "pHYs" then
      table.insert(out, bytes:sub(pos, pos + 11 + len))
    end
    pos = pos + 12 + len
  end
  fh = io.open(png, "wb")
  if not fh then
    return "cannot write " .. png
  end
  fh:write(table.concat(out))
  fh:close()
  return nil
end

--- Rasterize one SVG file to PNG.
---@param svg string
---@param png string
---@param cb fun(png: string|nil, err: string|nil)
---@param opts? { zoom?: number, box?: eqnav.RasterBox, ppu?: integer } scale by `zoom`, pad onto `box`, stamp `ppu`
function M.convert(svg, png, cb, opts)
  opts = opts or {}
  local tool = M.detect()
  if not tool then
    cb(nil, "no rasterizer (install librsvg for rsvg-convert, or imagemagick)")
    return
  end
  vim.system(command(tool, svg, png, opts), { text = true }, function(res)
    if res.code ~= 0 then
      cb(nil, vim.trim((res.stderr or "rasterizer failed"):gsub("%s+", " ")):sub(1, 200))
      return
    end
    local stat = vim.uv.fs_stat(png)
    if not stat or (stat.size or 0) == 0 then
      cb(nil, "rasterizer produced an empty file")
      return
    end
    if opts.ppu then
      local err = M.stamp_dpi(png, opts.ppu)
      if err then
        cb(nil, err)
        return
      end
    end
    cb(png, nil)
  end)
end

return M
