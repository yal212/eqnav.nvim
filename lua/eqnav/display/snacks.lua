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

--- Pixels per terminal cell, used to convert an image's height into the number
--- of buffer lines that must be reserved for it.
---@return integer cell_width, integer cell_height
local function cell_size()
  local s = snacks()
  if s then
    local ok, size = pcall(function()
      return s.image.terminal.size()
    end)
    if ok and size and (size.cell_height or 0) > 0 then
      return size.cell_width, size.cell_height
    end
  end
  return 8, 17 -- a reasonable default; only affects spacing, not correctness
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
  -- Read the IHDR directly rather than shelling out: PNG puts width and height
  -- as big-endian u32 at a fixed offset, and this runs once per equation.
  local fh = io.open(png, "rb")
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

function M.rows(_eq, png, _width)
  local _, h = png_size(png)
  if h == 0 then
    return 1
  end
  local _, cell_h = cell_size()
  return math.max(1, math.ceil(h / cell_h))
end

function M.lines()
  return nil -- image backends occupy blank lines
end

local placements = {} ---@type table<integer, table[]>

function M.place(bufnr, row, _eq, png)
  local s = snacks()
  if not s or not png then
    return nil
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
  placements[bufnr] = placements[bufnr] or {}
  table.insert(placements[bufnr], placement)
  return placement
end

function M.clear(bufnr)
  for _, p in ipairs(placements[bufnr] or {}) do
    pcall(function()
      p:close()
    end)
  end
  placements[bufnr] = nil
end

return M
