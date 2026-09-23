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
  return found
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
