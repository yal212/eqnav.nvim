local M = {}

--- Rendered output is keyed purely by content hash, so reopening the index on
--- an unchanged document is instant and never starts the node daemon at all.
local root = vim.fs.joinpath(vim.fn.stdpath("cache"), "eqnav")

function M.dir()
  return root
end

function M.ensure()
  vim.fn.mkdir(root, "p")
end

---@param id string
---@param ext "png"|"svg"
---@return string
function M.path(id, ext)
  return vim.fs.joinpath(root, id .. "." .. ext)
end

---@param id string
---@return string|nil png path if already rendered
function M.get(id)
  local p = M.path(id, "png")
  local stat = vim.uv.fs_stat(p)
  if stat and stat.size and stat.size > 0 then
    return p
  end
  return nil
end

---@param id string
---@return string|nil svg path
function M.get_svg(id)
  local p = M.path(id, "svg")
  local stat = vim.uv.fs_stat(p)
  if stat and stat.size and stat.size > 0 then
    return p
  end
  return nil
end

---@param id string
function M.invalidate(id)
  pcall(vim.uv.fs_unlink, M.path(id, "png"))
  pcall(vim.uv.fs_unlink, M.path(id, "svg"))
end

--- Remove everything. Exposed as :EqnavClearCache for when a colorscheme or
--- font change makes every cached image wrong at once.
---@return integer removed
function M.clear()
  local n = 0
  local handle = vim.uv.fs_scandir(root)
  if not handle then
    return 0
  end
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name:match("%.png$") or name:match("%.svg$") then
      if pcall(vim.uv.fs_unlink, vim.fs.joinpath(root, name)) then
        n = n + 1
      end
    end
  end
  return n
end

---@return integer files, integer bytes
function M.stats()
  local files, bytes = 0, 0
  local handle = vim.uv.fs_scandir(root)
  if not handle then
    return 0, 0
  end
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local stat = vim.uv.fs_stat(vim.fs.joinpath(root, name))
    if stat then
      files = files + 1
      bytes = bytes + (stat.size or 0)
    end
  end
  return files, bytes
end

return M
