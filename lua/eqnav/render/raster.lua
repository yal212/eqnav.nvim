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

---@param tool string
---@param svg string
---@param png string
---@return string[]
local function command(tool, svg, png)
  if tool == "rsvg-convert" then
    -- The SVG already carries explicit px dimensions stamped by the daemon,
    -- so no scaling flags are needed and output is deterministic.
    return { tool, "-o", png, svg }
  end
  return { tool, "-background", "none", svg, "PNG32:" .. png }
end

--- Rasterize one SVG file to PNG.
---@param svg string
---@param png string
---@param cb fun(png: string|nil, err: string|nil)
function M.convert(svg, png, cb)
  local tool = M.detect()
  if not tool then
    cb(nil, "no rasterizer (install librsvg for rsvg-convert, or imagemagick)")
    return
  end
  vim.system(command(tool, svg, png), { text = true }, function(res)
    if res.code ~= 0 then
      cb(nil, vim.trim((res.stderr or "rasterizer failed"):gsub("%s+", " ")):sub(1, 200))
      return
    end
    local stat = vim.uv.fs_stat(png)
    if not stat or (stat.size or 0) == 0 then
      cb(nil, "rasterizer produced an empty file")
      return
    end
    cb(png, nil)
  end)
end

return M
