local cache = require("eqnav.render.cache")
local util = require("eqnav.scan.util")

--- Export the equation index as one self-contained HTML page.
---
--- wishlist#51 asked for this directly -- "I preferred HTML or PDF output" --
--- and it is also the escape hatch for terminals with no graphics at all. The
--- SVGs are the ones already rendered for the terminal view, so the page costs
--- nothing extra and matches what you were just looking at -- display math
--- broken over lines to fit the index included.
local M = {}

local function escape(s)
  return (
    tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
  )
end

--- Hand colour control back to CSS. The cached SVG has the terminal's
--- foreground baked in, which would be wrong in a browser that follows the
--- reader's light/dark preference; MathJax already marks the outer group
--- `currentColor`, so neutralising the explicit fills is enough.
--- Only #rrggbb is rewritten: named colours -- `noundefined`'s red for an
--- unknown macro, the daemon's red for a parse error (#62) -- stay as they are.
---@param svg string
local function themeable(svg)
  svg = svg:gsub('(fill=")#%x%x%x%x%x%x(")', "%1currentColor%2")
  svg = svg:gsub('(stroke=")#%x%x%x%x%x%x(")', "%1currentColor%2")
  -- Drop the XML prolog if present; the SVG is being inlined into HTML.
  svg = svg:gsub("^%s*<%?xml.-%?>%s*", "")
  return svg
end

local CSS = [[
:root {
  --bg: #fbfbfd; --fg: #1c1c22; --muted: #6b6b7b; --line: #e3e3ec;
  --card: #ffffff; --accent: #4c4ce0;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #16161e; --fg: #e0def4; --muted: #8a879e; --line: #2a2a38;
    --card: #1c1c26; --accent: #9d8cff;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--fg);
  font: 15px/1.55 ui-sans-serif, -apple-system, "Segoe UI", Roboto, sans-serif;
}
.wrap { display: grid; grid-template-columns: 240px minmax(0,1fr); gap: 32px;
        max-width: 1100px; margin: 0 auto; padding: 32px 20px 96px; }
nav { position: sticky; top: 32px; align-self: start; max-height: calc(100vh - 64px);
      overflow-y: auto; font-size: 13px; }
nav h2 { font-size: 11px; letter-spacing: .09em; text-transform: uppercase;
         color: var(--muted); margin: 0 0 10px; }
nav a { display: block; padding: 4px 8px; border-radius: 6px; color: var(--muted);
        text-decoration: none; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
nav a:hover { background: var(--card); color: var(--fg); }
nav a .n { display: inline-block; min-width: 2.2em; color: var(--accent); font-variant-numeric: tabular-nums; }
header h1 { font-size: 20px; margin: 0 0 4px; }
header p { margin: 0 0 28px; color: var(--muted); font-size: 13px; }
.eq { border: 1px solid var(--line); border-radius: 10px; background: var(--card);
      padding: 18px 20px; margin-bottom: 14px; scroll-margin-top: 24px; }
.eq-head { display: flex; align-items: baseline; gap: 10px; margin-bottom: 14px;
           font-size: 12px; color: var(--muted); }
.eq-head .n { color: var(--accent); font-weight: 600; font-variant-numeric: tabular-nums; }
.eq-head .ctx { color: var(--fg); font-weight: 500; }
.eq-head .label { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
.eq-head .loc { margin-left: auto; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
.eq-body { overflow-x: auto; padding: 6px 0; }
.eq-body svg { max-width: 100%; height: auto; }
.eq-src { margin: 12px 0 0; padding-top: 12px; border-top: 1px solid var(--line);
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px;
          color: var(--muted); white-space: pre-wrap; word-break: break-word; }
.missing { color: var(--muted); font-style: italic; }
@media (max-width: 760px) {
  .wrap { grid-template-columns: 1fr; gap: 16px; padding: 20px 16px 64px; }
  nav { position: static; max-height: none; }
}
]]

---@param equations eqnav.Equation[]
---@param source string
---@return string
function M.build(equations, source)
  local out = {}
  local function w(s)
    table.insert(out, s)
  end

  w("<!doctype html>")
  w('<html lang="en"><head><meta charset="utf-8">')
  w('<meta name="viewport" content="width=device-width, initial-scale=1">')
  w("<title>equations · " .. escape(source) .. "</title>")
  w("<style>" .. CSS .. "</style>")
  w('</head><body><div class="wrap">')

  w("<nav><h2>Equations</h2>")
  for _, eq in ipairs(equations) do
    local text = eq.context or util.summarize(eq.tex, 30)
    w(
      string.format(
        '<a href="#eq-%d"><span class="n">%d</span>%s</a>',
        eq.index,
        eq.index,
        escape(text)
      )
    )
  end
  w("</nav>")

  w("<main><header>")
  w("<h1>" .. escape(source) .. "</h1>")
  w(
    string.format(
      "<p>%d equation%s · exported by eqnav.nvim</p>",
      #equations,
      #equations == 1 and "" or "s"
    )
  )
  w("</header>")

  for _, eq in ipairs(equations) do
    w(string.format('<section class="eq" id="eq-%d">', eq.index))
    w('<div class="eq-head">')
    w(string.format('<span class="n">%d</span>', eq.index))
    if eq.context then
      w('<span class="ctx">' .. escape(eq.context) .. "</span>")
    end
    if eq.label then
      w('<span class="label">' .. escape(eq.label) .. "</span>")
    end
    w(string.format('<span class="loc">L%d</span>', eq.lnum))
    w("</div>")

    w('<div class="eq-body">')
    local svg_path = eq.id and cache.get_svg(eq.id)
    local svg = nil
    if svg_path then
      local fh = io.open(svg_path, "r")
      if fh then
        svg = fh:read("*a")
        fh:close()
      end
    end
    if svg and svg ~= "" then
      w(themeable(svg))
    else
      w('<p class="missing">not rendered</p>')
    end
    w("</div>")

    w('<pre class="eq-src">' .. escape(eq.tex) .. "</pre>")
    w("</section>")
  end

  w("</main></div></body></html>")
  return table.concat(out, "\n")
end

---@param equations eqnav.Equation[]
---@param source_buf integer
---@param path? string
---@return string path
function M.write(equations, source_buf, path)
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(source_buf), ":t")
  if name == "" then
    name = "buffer"
  end
  path = path or vim.fs.joinpath(vim.fn.stdpath("cache"), "eqnav", name:gsub("%W", "_") .. ".html")
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fh = assert(io.open(path, "w"))
  fh:write(M.build(equations, name))
  fh:close()
  return path
end

--- Export the current index (rendering anything still missing first) and open
--- the result in the system browser.
---@param path? string
function M.export_and_open(path)
  local view = require("eqnav.view")
  local state = view.current()
  local equations, source_buf

  if state then
    equations, source_buf = state.equations, state.source_buf
  else
    source_buf = vim.api.nvim_get_current_buf()
    equations = require("eqnav.scan").scan(source_buf)
  end

  if #equations == 0 then
    vim.notify("eqnav: no equations to export", vim.log.levels.WARN)
    return
  end

  local missing = 0
  for _, eq in ipairs(equations) do
    if not (eq.id and cache.get_svg(eq.id)) then
      missing = missing + 1
    end
  end

  local function finish()
    local out = M.write(equations, source_buf, path)
    vim.notify("eqnav: exported " .. out, vim.log.levels.INFO)
    vim.ui.open(out)
  end

  if missing == 0 then
    finish()
    return
  end

  vim.notify("eqnav: rendering " .. missing .. " equation(s) for export…", vim.log.levels.INFO)
  local done = 0
  -- At the width the index rendered for, when these are its equations:
  -- render_all writes each key into the equation, and any other width re-keyed
  -- the index's under it, dropping its renders still in flight as stale.
  -- Regardless of render.enabled, which governs the terminal view (#47).
  require("eqnav.render").render_all(equations, function()
    done = done + 1
    if done >= #equations then
      finish()
    end
  end, { width = state and state.render_width })
end

return M
