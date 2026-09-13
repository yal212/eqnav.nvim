-- Headless test bootstrap. Deliberately does not depend on the user's config:
-- CI clones plenary into .tests/ and everything else is either shipped with
-- Neovim (markdown parsers) or part of this repo (queries).
local root = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.expand("<sfile>:p")), ":h:h")

local plenary = vim.env.PLENARY_PATH or vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim")
if vim.fn.isdirectory(plenary) == 0 then
  plenary = root .. "/.tests/plenary.nvim"
end

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(plenary)

-- Optional: snacks.nvim, so the display-backend contract test can run.
for _, dir in ipairs({
  root .. "/.tests/snacks.nvim",
  vim.fn.expand("~/.local/share/nvim/lazy/snacks.nvim"),
}) do
  if vim.fn.isdirectory(dir) == 1 then
    vim.opt.runtimepath:append(dir)
    break
  end
end

-- Optional: the user's parser dir, so `latex` is available when installed.
local ts = vim.fn.expand("~/.local/share/nvim/lazy/nvim-treesitter")
if vim.fn.isdirectory(ts) == 1 then
  vim.opt.runtimepath:append(ts)
end

vim.opt.swapfile = false
vim.cmd("runtime plugin/plenary.vim")
require("eqnav.config").setup({})
