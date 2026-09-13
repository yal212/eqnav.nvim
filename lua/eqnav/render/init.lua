local cache = require("eqnav.render.cache")
local config = require("eqnav.config")
local daemon = require("eqnav.render.daemon")
local display = require("eqnav.display")
local raster = require("eqnav.render.raster")

local M = {}

M.cache = cache
M.daemon = daemon
M.raster = raster

--- Everything before \begin{document}, so a document's own \newcommand macros
--- are available to MathJax. Per-line failures are swallowed daemon-side; this
--- just finds the text.
---@param bufnr integer
---@return string|nil
function M.preamble(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft ~= "tex" and ft ~= "latex" and ft ~= "plaintex" then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 400, false)
  local out = {}
  for _, line in ipairs(lines) do
    if line:find("\\begin{document}", 1, true) then
      break
    end
    -- Only macro definitions are useful and safe to replay.
    if
      line:match("\\newcommand")
      or line:match("\\renewcommand")
      or line:match("\\DeclareMathOperator")
    then
      table.insert(out, line)
    end
  end
  return #out > 0 and table.concat(out, "\n") or nil
end

--- Render a list of equations, calling back as each finishes.
---
--- Cache hits are reported immediately and never reach the daemon, so an
--- unchanged document repaints without starting node at all.
--- The callback's `id` is the equation's content hash as it was when the render
--- started, so a caller can tell a result that is still wanted from one whose
--- equation has since been edited away. See view.set_image.
---@param equations eqnav.Equation[]
---@param cb fun(index: integer, png: string|nil, err: string|nil, id: string)
---@param opts? { force?: boolean }
function M.render_all(equations, cb, opts)
  opts = opts or {}
  if not config.options.render.enabled or #equations == 0 then
    return
  end

  cache.ensure()
  local color = display.foreground()
  local ex = config.options.render.ex
  local util = require("eqnav.scan.util")

  local todo = {}
  for _, eq in ipairs(equations) do
    -- The colour is decided here, not at scan time, so a colorscheme change
    -- produces a different id and therefore a fresh render.
    eq.id = util.hash(eq.tex, eq.display, color, ex)
    if opts.force then
      cache.invalidate(eq.id)
    end
    local hit = not opts.force and cache.get(eq.id)
    if hit then
      vim.schedule(function()
        cb(eq.index, hit, nil, eq.id)
      end)
    else
      table.insert(todo, eq)
    end
  end

  if #todo == 0 then
    return
  end

  local preamble = M.preamble(equations[1].bufnr)
  local limit = math.max(1, config.options.render.concurrency)
  local active, cursor = 0, 1

  local function pump()
    while active < limit and cursor <= #todo do
      local eq = todo[cursor]
      cursor = cursor + 1
      active = active + 1

      daemon.request({
        equation = eq.tex,
        display = eq.display,
        color = color,
        preamble = preamble,
        ex = ex,
      }, function(res)
        if not res.ok then
          active = active - 1
          vim.schedule(function()
            cb(eq.index, nil, vim.trim(tostring(res.err or "render failed")):sub(1, 120), eq.id)
            pump()
          end)
          return
        end

        local svg_path = cache.path(eq.id, "svg")
        local png_path = cache.path(eq.id, "png")
        local fh, ferr = io.open(svg_path, "w")
        if not fh then
          active = active - 1
          vim.schedule(function()
            cb(eq.index, nil, "cannot write cache: " .. tostring(ferr), eq.id)
            pump()
          end)
          return
        end
        fh:write(res.svg)
        fh:close()

        raster.convert(svg_path, png_path, function(png, err)
          active = active - 1
          vim.schedule(function()
            cb(eq.index, png, err, eq.id)
            pump()
          end)
        end)
      end)
    end
  end

  pump()
end

--- Render a single equation, used by the picker previewer and hover.
---@param eq eqnav.Equation
---@param cb fun(png: string|nil, err: string|nil)
function M.render_one(eq, cb)
  M.render_all({ eq }, function(_, png, err)
    cb(png, err)
  end)
end

return M
