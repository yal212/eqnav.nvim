local config = require("eqnav.config")

--- eqnav.nvim -- a rendered-equation index for Neovim.
---
--- Answers nvim-lua/wishlist#51: a separate, prose-free page of the document's
--- equations that you navigate with j/k and jump back from with <CR>.
local M = {}

M.config = config

---@param opts? table
function M.setup(opts)
  config.setup(opts)
  require("eqnav.view").setup_highlights()
  return M
end

---@param opts? { source_buf?: integer, focus?: boolean }
function M.open(opts)
  local view = require("eqnav.view")
  local state = view.open(opts)
  if state then
    require("eqnav.sync").attach(state.source_buf)
  end
  return state
end

function M.close()
  require("eqnav.sync").detach()
  require("eqnav.view").close()
end

---@param opts? table
function M.toggle(opts)
  if require("eqnav.view").is_open() then
    M.close()
  else
    M.open(opts)
  end
end

function M.is_open()
  return require("eqnav.view").is_open()
end

---@param force? boolean bypass the render cache
function M.refresh(force)
  require("eqnav.view").refresh(force)
end

--- The equations in a buffer, without opening anything. The building block for
--- pickers and any external integration.
---@param bufnr? integer
---@return eqnav.Equation[]
function M.equations(bufnr)
  return require("eqnav.scan").scan(bufnr)
end

---@param path? string
function M.export_html(path)
  require("eqnav.export.html").export_and_open(path)
end

---@param opts? table telescope picker options
function M.pick(opts)
  require("eqnav.pickers.telescope").pick(opts)
end

---@return integer removed
function M.clear_cache()
  require("eqnav.render.daemon").reset()
  return require("eqnav.render.cache").clear()
end

return M
