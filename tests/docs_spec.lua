-- The README and vimdoc restate facts the code owns. The filetype list
-- drifted once (#23) with nothing noticing, so it is checked against the code
-- rather than trusted.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function read(rel)
  local f = assert(io.open(root .. "/" .. rel, "r"), "cannot read " .. rel)
  local text = f:read("*a")
  f:close()
  return text
end

local readme = read("README.md")
local vimdoc = read("doc/eqnav.txt")

local function sorted(list)
  local out = vim.deepcopy(list)
  table.sort(out)
  return out
end

describe("docs", function()
  it("the README's lazy.nvim ft covers every default filetype", function()
    -- `ft` decides whether the plugin loads at all; a filetype missing from it
    -- has no :Eqnav, and nothing says why.
    local body = readme:match("\n%s*ft = (%b{})")
    assert.is_not_nil(body, "no `ft = { .. }` in the README's install snippet")
    local ft = {}
    for name in body:gmatch('"([^"]+)"') do
      table.insert(ft, name)
    end
    assert.same(sorted(require("eqnav.config").defaults.filetypes), sorted(ft))
  end)
end)
