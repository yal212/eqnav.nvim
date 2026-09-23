local config = require("eqnav.config")

--- `:checkhealth eqnav`.
---
--- eqnav has a wide dependency surface -- node, a MathJax install, a
--- rasterizer, an image backend, a graphics-capable terminal, treesitter
--- parsers -- and every one of them fails in a different way. This exists so
--- "nothing renders" is a two-second diagnosis rather than a bug report.
local M = {}

local start = vim.health.start
local ok = vim.health.ok
local warn = vim.health.warn
local err = vim.health.error
local info = vim.health.info

local function check_neovim()
  start("Neovim")
  if vim.fn.has("nvim-0.10") == 1 then
    ok("Neovim " .. tostring(vim.version()))
  else
    err("eqnav requires Neovim 0.10 or newer")
  end
end

local function check_renderer()
  start("Renderer (MathJax)")
  local daemon = require("eqnav.render.daemon")
  local node = config.options.render.node

  if vim.fn.executable(node) ~= 1 then
    err(("'%s' not found on PATH"):format(node), {
      "Install Node.js 18 or newer, or set render.node to its path",
    })
    return
  end
  local v = vim.system({ node, "--version" }, { text = true }):wait()
  local version = vim.trim(v.stdout or "?")
  -- An older node starts, and then the daemon fails at runtime, so printing the
  -- version is not enough: a report that only prints it looks healthy.
  local major = tonumber(version:match("^v(%d+)"))
  if major and major < 18 then
    err(("node %s is too old; eqnav needs Node.js 18 or newer"):format(version), {
      "Install Node.js 18 or newer, or set render.node to its path",
    })
    return
  end
  ok("node " .. version)

  local script = daemon.script()
  if vim.fn.filereadable(script) ~= 1 then
    err("daemon script missing: " .. script)
    return
  end
  ok("daemon script " .. script)

  -- Ask the daemon where it resolves MathJax, rather than reimplementing the
  -- search here and letting the two drift apart.
  local res = vim.system({ node, script, "--list-paths" }, { text = true }):wait()
  if res.code ~= 0 then
    err("daemon failed to start: " .. vim.trim(res.stderr or ""))
    return
  end
  local decoded = pcall(vim.json.decode, res.stdout)
  local paths = decoded and vim.json.decode(res.stdout) or nil
  if paths and paths.resolved then
    ok("@mathjax/src at " .. paths.resolved)
  else
    err("@mathjax/src not installed", {
      "Run `npm install` in " .. daemon.root(),
      "With lazy.nvim, add  build = 'npm install'  to the plugin spec",
    })
  end
end

local function check_rasterizer()
  start("Rasterizer (SVG to PNG)")
  local raster = require("eqnav.render.raster")
  raster.reset()
  local tool = raster.detect()
  if not tool then
    err("no rasterizer found", {
      "brew install librsvg   (provides rsvg-convert, recommended)",
      "or install ImageMagick (magick / convert)",
    })
  elseif tool == "rsvg-convert" then
    ok("rsvg-convert (" .. vim.fn.exepath(tool) .. ")")
  else
    warn(tool .. " will work, but rsvg-convert renders MathJax output more faithfully", {
      "brew install librsvg",
    })
  end
end

local function check_display()
  start("Display backend")
  local display = require("eqnav.display")
  display.reset()
  local backend = display.get(true)

  if backend.images then
    ok("using the " .. backend.name .. " backend")
  else
    warn("falling back to the text backend: equations show as LaTeX source, not images", {
      "Install folke/snacks.nvim with image.enabled = true (recommended)",
      "or 3rd/image.nvim, with require('image').setup() called",
      "Either way, :EqnavExport still gives you a fully rendered HTML page",
    })
  end

  local snacks_ok, snacks = pcall(require, "snacks")
  if snacks_ok and snacks and snacks.image then
    local supported = pcall(function()
      return snacks.image.supports_terminal()
    end) and snacks.image.supports_terminal()
    if supported then
      ok("terminal reports graphics support")
    else
      warn("snacks.nvim is installed but reports no terminal graphics support")
    end
  end

  info("foreground colour for rendering: #" .. display.foreground())
end

local function check_terminal()
  start("Terminal")
  local term = vim.env.TERM_PROGRAM or vim.env.TERM or "unknown"
  info("TERM_PROGRAM=" .. tostring(vim.env.TERM_PROGRAM) .. "  TERM=" .. tostring(vim.env.TERM))

  if vim.env.TMUX then
    local res = vim.system({ "tmux", "show", "-gv", "allow-passthrough" }, { text = true }):wait()
    local value = vim.trim(res.stdout or "")
    if value == "on" or value == "all" then
      ok("tmux allow-passthrough is " .. value)
    else
      warn("tmux is running without allow-passthrough; images will not appear", {
        "Add  set -g allow-passthrough on  to your tmux.conf",
      })
    end
  else
    info("not running inside tmux")
  end

  if vim.env.SSH_TTY then
    warn("connected over SSH; terminal graphics may not survive the hop")
  end
  info("terminal: " .. term)
end

local function check_parsers()
  start("Treesitter")
  local seen = {}
  for _, ft in ipairs(config.options.filetypes) do
    local lang = require("eqnav.scan").language_for(ft)
    if not seen[lang] then
      seen[lang] = true
      -- language.add returns nil (it does not raise) when the parser is
      -- missing, so pcall alone reports every language as present.
      local pok, added = pcall(vim.treesitter.language.add, lang)
      if pok and added == true then
        ok(("%s -> parser '%s'"):format(ft, lang))
      else
        warn(("%s has no '%s' parser; eqnav will use the regex scanner"):format(ft, lang), {
          ":TSInstall " .. lang,
          "The regex scanner cannot see fenced code blocks as reliably",
        })
      end
    end
  end
end

local function check_cache()
  start("Cache")
  local cache = require("eqnav.render.cache")
  local files, bytes = cache.stats()
  info(
    ("%s (%d file%s, %.1f KB)"):format(cache.dir(), files, files == 1 and "" or "s", bytes / 1024)
  )
end

function M.check()
  check_neovim()
  check_renderer()
  check_rasterizer()
  check_display()
  check_terminal()
  check_parsers()
  check_cache()
end

return M
