-- Interactive test bootstrap -- the harness behind `make demo`.
--
-- Unlike tests/minimal_init.lua this is meant to be run WITHOUT --noplugin, so
-- plugin/eqnav.lua runs and :Eqnav and friends actually exist.
--
--   make demo        markdown fixture, treesitter scanner
--   make demo-tex    latex fixture, regex scanner + preamble macros
--   make demo-cold   throwaway XDG_CACHE_HOME, so renders really happen
--
-- Deliberately independent of ~/.config/nvim: what you see here is the plugin,
-- not your setup. The one thing it does borrow is a treesitter parser dir,
-- because markdown without a parser silently downgrades to the regex scanner
-- and you would be eyeballing the wrong code path.
local root = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.expand("<sfile>:p")), ":h:h")

---@param paths string[]
---@return string|nil
local function first_dir(paths)
  for _, dir in ipairs(paths) do
    if vim.fn.isdirectory(dir) == 1 then
      return dir
    end
  end
  return nil
end

vim.opt.runtimepath:prepend(root)

-- snacks is what turns the index into pixels. Without it display.get() returns
-- the text backend, view.lua:478 skips render_all entirely, and the MathJax
-- daemon never starts -- a demo that verifies nothing.
local snacks_dir = first_dir({
  root .. "/.tests/snacks.nvim",
  vim.fn.expand("~/.local/share/nvim/lazy/snacks.nvim"),
})
if snacks_dir then
  vim.opt.runtimepath:append(snacks_dir)
end

local ts_dir = first_dir({ vim.fn.expand("~/.local/share/nvim/lazy/nvim-treesitter") })
if ts_dir then
  vim.opt.runtimepath:append(ts_dir)
end

vim.opt.swapfile = false
vim.opt.termguicolors = true

-- A colorscheme with an explicit Normal foreground. display.foreground()
-- hashes that colour into the cache key, so pinning it keeps renders stable
-- between runs instead of depending on whatever the default happens to be.
pcall(vim.cmd.colorscheme, "habamax")

if snacks_dir then
  require("snacks").setup({ image = { enabled = true } })
end

require("eqnav").setup({
  -- Both overridable from the shell; see the Makefile targets.
  include_inline = vim.env.EQNAV_DEMO_INLINE == "1",
  window = { position = vim.env.EQNAV_DEMO_POS or "right" },
})

vim.schedule(function()
  local display = require("eqnav.display")
  local backend = display.get(true)
  local note = backend.images and ("images via " .. backend.name)
    or "TEXT ONLY -- no image backend, nothing will render"
  vim.notify(
    ("eqnav demo -- :Eqnav to open, j/k to walk, q to close  [%s]"):format(note),
    backend.images and vim.log.levels.INFO or vim.log.levels.WARN
  )
end)
