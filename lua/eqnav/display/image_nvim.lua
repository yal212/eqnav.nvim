--- 3rd/image.nvim backend. Secondary to snacks: it needs the `magick` luarock,
--- which is the usual source of install trouble on macOS, but it is the only
--- option that also drives ueberzug++ for terminals without native graphics.
---@type eqnav.DisplayBackend
local M = {
  name = "image_nvim",
  images = true,
}

local function api()
  local ok, image = pcall(require, "image")
  return ok and image or nil
end

function M.available()
  local image = api()
  return image ~= nil and type(image.from_file) == "function"
end

local images = {} ---@type table<integer, table[]>

function M.rows(_eq, png, _width)
  local image = api()
  if not image or not png then
    return 1
  end
  local ok, img = pcall(image.from_file, png)
  if not ok or not img then
    return 1
  end
  local cell_h = 17
  local ok2, dims = pcall(function()
    return require("image.utils.term").get_size()
  end)
  if ok2 and dims and (dims.cell_height or 0) > 0 then
    cell_h = dims.cell_height
  end
  return math.max(1, math.ceil((img.image_height or 0) / cell_h))
end

function M.lines()
  return nil
end

function M.place(bufnr, row, _eq, png)
  local image = api()
  if not image or not png then
    return nil
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
  images[bufnr] = images[bufnr] or {}
  table.insert(images[bufnr], img)
  return img
end

function M.clear(bufnr)
  for _, img in ipairs(images[bufnr] or {}) do
    pcall(function()
      img:clear()
    end)
  end
  images[bufnr] = nil
end

return M
