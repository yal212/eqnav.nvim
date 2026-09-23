-- The README and vimdoc restate facts the code owns: the filetypes, the
-- commands, the Lua API. Each of these drifted once (#23, #24) with nothing
-- noticing, so the lists are checked against the code rather than trusted.
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

  it("documents every command in both the README and the vimdoc", function()
    local cmds = {}
    for name in read("plugin/eqnav.lua"):gmatch('cmd%("(%w+)"') do
      table.insert(cmds, name)
    end
    assert.is_true(#cmds > 0, "found no commands in plugin/eqnav.lua")
    for _, name in ipairs(cmds) do
      assert.is_truthy(readme:find("`:" .. name .. "[^%w]"), "README does not list :" .. name)
      assert.is_truthy(
        vimdoc:find("*:" .. name .. "*", 1, true),
        "vimdoc has no *:" .. name .. "* tag"
      )
    end
  end)

  it("tags every Lua API function in the vimdoc", function()
    for name, v in pairs(require("eqnav")) do
      if type(v) == "function" then
        local tag = "*eqnav." .. name .. "()*"
        assert.is_truthy(vimdoc:find(tag, 1, true), "vimdoc has no " .. tag)
      end
    end
  end)
end)
