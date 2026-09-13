if vim.g.loaded_eqnav then
  return
end
vim.g.loaded_eqnav = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("eqnav.nvim requires Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end

local function cmd(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

cmd("Eqnav", function()
  require("eqnav").toggle()
end, { desc = "eqnav: toggle the equation index" })

cmd("EqnavOpen", function()
  require("eqnav").open()
end, { desc = "eqnav: open the equation index" })

cmd("EqnavClose", function()
  require("eqnav").close()
end, { desc = "eqnav: close the equation index" })

cmd("EqnavRefresh", function(a)
  require("eqnav").refresh(a.bang)
end, { bang = true, desc = "eqnav: re-scan (! to bypass the render cache)" })

cmd("EqnavExport", function(a)
  require("eqnav").export_html(a.args ~= "" and a.args or nil)
end, { nargs = "?", complete = "file", desc = "eqnav: export the index to HTML" })

cmd("EqnavPick", function()
  require("eqnav").pick()
end, { desc = "eqnav: fuzzy-find an equation" })

cmd("EqnavClearCache", function()
  local n = require("eqnav").clear_cache()
  vim.notify("eqnav: removed " .. n .. " cached file(s)", vim.log.levels.INFO)
end, { desc = "eqnav: clear the rendered-equation cache" })
