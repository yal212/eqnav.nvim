local util = require("eqnav.scan.util")

--- Fallback backend: show the TeX source instead of a picture.
---
--- Not a consolation prize. It is what lets every layer above it be tested
--- headlessly, and what keeps eqnav useful over ssh, in a terminal with no
--- graphics, or while the renderer is unavailable.
---@type eqnav.DisplayBackend
local M = {
  name = "text",
  images = false,
}

function M.available()
  return true
end

---@param eq eqnav.Equation
---@param width integer
---@return string[]
local function wrapped(eq, width)
  local inner = math.max(20, width - 6)
  local out = {}
  for _, line in ipairs(vim.split(eq.tex, "\n", { plain = true })) do
    line = vim.trim(line)
    if line == "" then
      goto continue
    end
    while vim.fn.strdisplaywidth(line) > inner do
      table.insert(out, "    " .. vim.fn.strcharpart(line, 0, inner))
      line = vim.fn.strcharpart(line, inner)
    end
    table.insert(out, "    " .. line)
    ::continue::
  end
  if #out == 0 then
    table.insert(out, "    " .. util.summarize(eq.tex, width - 6))
  end
  return out
end

function M.lines(eq, _png, width)
  return wrapped(eq, width)
end

function M.rows(eq, _png, width)
  return #wrapped(eq, width)
end

function M.place()
  return nil
end

function M.clear() end

return M
