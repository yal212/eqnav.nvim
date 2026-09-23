--- PNG dimensions, read straight from the file. Shared by the image backends:
--- asking a graphics plugin for them means building an image object (image.nvim)
--- or depends on a helper it may not have (snacks), and a PNG stores them at a
--- fixed offset anyway.
local M = {}

--- Width and height in px, or 0, 0 for a missing file or anything not a PNG.
--- Read from the IHDR rather than by shelling out: PNG puts width and height as
--- big-endian u32 at bytes 17-24, and this runs once per equation.
---@param path string|nil
---@return integer width, integer height
function M.size(path)
  if not path then
    return 0, 0
  end
  local fh = io.open(path, "rb")
  if not fh then
    return 0, 0
  end
  local header = fh:read(24)
  fh:close()
  if not header or #header < 24 or header:sub(2, 4) ~= "PNG" then
    return 0, 0
  end
  local function u32(off)
    local a, b, c, d = header:byte(off, off + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
end

return M
