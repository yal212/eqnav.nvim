local config = require("eqnav.config")

local M = {}

---@class eqnav.DisplayBackend
---@field name string
---@field available fun(): boolean
---@field rows fun(eq: eqnav.Equation, png: string|nil, width: integer): integer
---@field lines fun(eq: eqnav.Equation, png: string|nil, width: integer): string[]|nil
--- Show `png` at `row`, replacing whatever that row showed. The same png at the
--- same row again is a no-op, which is what lets an unchanged index re-render
--- without its images being torn down and redrawn.
---@field place fun(bufnr: integer, row: integer, eq: eqnav.Equation, png: string): any
---@field clear fun(bufnr: integer)
---@field images boolean whether this backend actually shows pixels
---@field geometry? fun(): eqnav.Geometry|nil cell size and density to render for
---@field overflows? fun(png: string, width: integer): boolean shown shrunk to fit `width` columns

-- Order matters: snacks needs no luarock and handles tmux passthrough itself,
-- so it is tried first. `text` always succeeds, which is what keeps the whole
-- plugin usable in a terminal without graphics and testable in headless CI.
local ORDER = { "snacks", "image_nvim", "text" }

local cached = nil

---@param name string
---@return eqnav.DisplayBackend|nil
local function load(name)
  local ok, mod = pcall(require, "eqnav.display." .. name)
  if ok and mod and mod.available() then
    return mod
  end
  return nil
end

--- The backend in use, honouring an explicit `display.backend` setting and
--- otherwise probing in preference order.
---@param force? boolean re-probe instead of using the cached answer
---@return eqnav.DisplayBackend
function M.get(force)
  if cached and not force then
    return cached
  end
  local want = config.options.display.backend
  if want ~= "auto" then
    cached = load(want) or require("eqnav.display.text")
    return cached
  end
  for _, name in ipairs(ORDER) do
    local backend = load(name)
    if backend then
      cached = backend
      return cached
    end
  end
  cached = require("eqnav.display.text")
  return cached
end

function M.reset()
  cached = nil
end

--- Foreground colour equations should be rendered in, as a bare hex string.
--- Black glyphs on a dark colorscheme are unreadable, so this follows Normal
--- unless the user pinned a colour.
---@return string
function M.foreground()
  if config.options.render.color then
    return (config.options.render.color:gsub("^#", ""))
  end
  local hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  if hl and hl.fg then
    return string.format("%06x", hl.fg)
  end
  return vim.o.background == "dark" and "e0e0e0" or "202020"
end

return M
