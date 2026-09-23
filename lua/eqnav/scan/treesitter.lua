local util = require("eqnav.scan.util")

local M = {}

--- Decide display-vs-inline for a markdown (latex_block) node by the width of
--- its opening delimiter: `$` is inline, `$$` is display. Verified against
--- tree-sitter-markdown's actual output rather than inferred from the text,
--- so it stays correct for multi-line blocks.
---@param node TSNode
---@param bufnr integer
---@return boolean|nil
local function delimiter_display(node, bufnr)
  for child in node:iter_children() do
    if child:type() == "latex_span_delimiter" then
      local text = vim.treesitter.get_node_text(child, bufnr) or ""
      return #text >= 2
    end
  end
  return nil
end

--- Is there an `eqnav` query for this language?
---@param lang string
local function query_for(lang)
  local ok, query = pcall(vim.treesitter.query.get, lang, "eqnav")
  if ok then
    return query
  end
  return nil
end

--- Does a language higher up the injection tree already have an eqnav query?
--- Then its captures are the math and this tree is their contents: markdown's
--- bundled injections hand every latex_block to the `latex` parser, and
--- querying that too listed each markdown equation twice.
---@param ltree vim.treesitter.LanguageTree
local function under_queried_parent(ltree)
  local parent = ltree:parent()
  while parent do
    if query_for(parent:lang()) then
      return true
    end
    parent = parent:parent()
  end
  return false
end

--- Name of a LaTeX environment node, e.g. "align*".
---@param node TSNode
---@param bufnr integer
---@return string|nil
local function environment_name(node, bufnr)
  local begin = node:field("begin")[1]
  local name = begin and begin:field("name")[1]
  if not name then
    return nil
  end
  return (vim.treesitter.get_node_text(name, bufnr) or ""):match("^{%s*(.-)%s*}$")
end

--- Drop every capture that lies inside another one. The grammar makes
--- aligned/split/array math environments in their own right, and they are
--- almost always written inside an equation or \[..\]: the nested one is part
--- of that entry, not an entry of its own. Same rule regex.lua applies.
---@param found eqnav.Equation[]
---@return eqnav.Equation[]
local function drop_nested(found)
  local function before(ar, ac, br, bc)
    return ar < br or (ar == br and ac < bc)
  end
  table.sort(found, function(a, b)
    if a.lnum ~= b.lnum or a.col ~= b.col then
      return before(a.lnum, a.col, b.lnum, b.col)
    end
    -- Same start: the wider range first, so it is the one kept.
    return before(b.end_lnum, b.end_col, a.end_lnum, a.end_col)
  end)
  local out, last = {}, nil
  for _, eq in ipairs(found) do
    if not (last and not before(last.end_lnum, last.end_col, eq.end_lnum, eq.end_col)) then
      table.insert(out, eq)
      last = eq
    end
  end
  return out
end

--- Scan a buffer for math nodes using treesitter.
---@param bufnr integer
---@return eqnav.Equation[]|nil equations, string|nil err
function M.scan(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil, "no treesitter parser for this buffer"
  end

  parser:parse(true)

  local found = {}
  local any_query = false

  parser:for_each_tree(function(tree, ltree)
    local lang = ltree:lang()
    local query = query_for(lang)
    if not query then
      return
    end
    any_query = true
    if under_queried_parent(ltree) then
      return
    end

    for id, node in query:iter_captures(tree:root(), bufnr) do
      if query.captures[id] == "eqnav.equation" then
        local srow, scol, erow, ecol = node:range()
        local raw = vim.treesitter.get_node_text(node, bufnr) or ""
        local tex, delim_display = util.strip(raw)

        -- Markdown needs the delimiter-width check; LaTeX encodes the answer
        -- in the node type itself.
        local display = delim_display
        if display == nil then
          display = delimiter_display(node, bufnr)
        end
        if display == nil then
          display = node:type() ~= "inline_formula"
            -- \begin{math} is the environment spelling of \(..\).
            and not (node:type() == "math_environment" and environment_name(node, bufnr) == "math")
        end

        if tex ~= "" then
          table.insert(found, {
            tex = tex,
            raw = raw,
            display = display,
            lnum = srow + 1,
            col = scol,
            end_lnum = erow + 1,
            end_col = ecol,
            label = util.label(raw),
            bufnr = bufnr,
          })
        end
      end
    end
  end)

  if not any_query then
    return nil, "no eqnav query for any language in this buffer"
  end
  return drop_nested(found)
end

--- Whether treesitter can handle this buffer at all, used to pick a scanner.
---@param bufnr integer
function M.available(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return false
  end
  local has = false
  parser:parse(true)
  parser:for_each_tree(function(_, ltree)
    if query_for(ltree:lang()) then
      has = true
    end
  end)
  return has
end

return M
