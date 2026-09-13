local ok, telescope = pcall(require, "telescope")
if not ok then
  error("eqnav: this extension requires telescope.nvim")
end

return telescope.register_extension({
  exports = {
    eqnav = function(opts)
      require("eqnav.pickers.telescope").pick(opts)
    end,
  },
})
