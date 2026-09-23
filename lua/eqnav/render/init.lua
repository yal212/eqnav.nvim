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
---
--- It renders whatever it is given: `render.enabled` is the caller's to check.
--- The index does, but the export renders regardless (#47), since it is the
--- escape hatch for a terminal that cannot show images.
---@param equations eqnav.Equation[]
---
--- `opts.width` is the index's width in columns. Display math wider than that
--- is broken over lines to fit it (#41), where it used to be drawn whole and
--- shrunk by the image backend, glyphs and all. It needs the display geometry
--- to know how many ex fit in a column, so without that it does nothing.
---@param cb fun(index: integer, png: string|nil, err: string|nil, id: string)
---@param opts? { force?: boolean, width?: integer }
function M.render_all(equations, cb, opts)
  opts = opts or {}
  if #equations == 0 then
    return
  end

  cache.ensure()
  local color = display.foreground()
  local ex = config.options.render.ex
  local util = require("eqnav.scan.util")
  -- Where the backend can say what the display measures, render for it:
  -- `ex` stays CSS px per ex, drawn at the display's density and padded to
  -- whole cells so it is shown 1:1 (#6, #17). Without it, as before.
  local backend = display.get()
  local geom = backend.images and backend.geometry and backend.geometry() or nil
  -- The room for an image in ex: the index width less the column the entry
  -- header leaves free, in CSS px (a cell is device px), over px per ex.
  local width = geom and opts.width or nil
  local width_ex = width and (width - 1) * geom.cell_width / geom.scale / ex or nil

  local todo = {}
  for _, eq in ipairs(equations) do
    -- The colour is decided here, not at scan time, so a colorscheme change
    -- produces a different id and therefore a fresh render.
    eq.id = util.hash(eq.tex, eq.display, color, ex, geom, width)
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
        width = width_ex,
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

        local fit = nil
        if geom then
          fit = { zoom = geom.scale, ppu = math.ceil(96 * geom.scale) }
          -- The daemon reports the equation's size in ex; the SVG it wrote is
          -- that times `ex` in CSS px, and the PNG that times the scale. A \tag
          -- is reported at its natural width too (#40), but a size the daemon
          -- could not work out comes back as JSON null, and vim.NIL is truthy:
          -- hence type(), and no padding for that one.
          if type(res.width) == "number" and type(res.height) == "number" then
            local px = ex * geom.scale
            fit.box = raster.box(res.width * px, res.height * px, geom)
          end
        end

        raster.convert(svg_path, png_path, function(png, err)
          active = active - 1
          vim.schedule(function()
            cb(eq.index, png, err, eq.id)
            pump()
          end)
        end, fit)
      end)
    end
  end

  pump()
end

return M
