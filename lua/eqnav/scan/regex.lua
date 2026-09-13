local util = require("eqnav.scan.util")

local M = {}

local ENVIRONMENTS = {
  "equation",
  "align",
  "alignat",
  "gather",
  "multline",
  "flalign",
  "eqnarray",
  "displaymath",
  "split",
  "cases",
  "dcases",
}

--- Lines that sit inside a fenced code block, which must never be scanned for
--- math. This is the case treesitter gets right for free and the reason the
--- regex scanner is only a fallback: it can only approximate the boundary.
---@param lines string[]
---@return table<integer, boolean>
local function fenced_lines(lines)
  local fenced, fence = {}, nil
  for i, line in ipairs(lines) do
    local marker = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
    if marker then
      if fence and marker:sub(1, 1) == fence:sub(1, 1) and #marker >= #fence then
        fenced[i], fence = true, nil
      elseif not fence then
        fence, fenced[i] = marker, true
      else
        fenced[i] = true
      end
    elseif fence then
      fenced[i] = true
    end
  end
  return fenced
end

--- Is the character at `idx` escaped by a backslash? Counts the run, so `\\$`
--- (an escaped backslash then a real delimiter) is not mistaken for `\$`.
local function escaped(s, idx)
  local n = 0
  local i = idx - 1
  while i >= 1 and s:sub(i, i) == "\\" do
    n = n + 1
    i = i - 1
  end
  return n % 2 == 1
end

--- Scan a buffer for math with delimiter matching. Used when no treesitter
--- parser with an eqnav query is available for the filetype.
---@param bufnr integer
---@return eqnav.Equation[]
function M.scan(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local fenced = fenced_lines(lines)
  local found = {}

  -- Offset table so a match in the joined text maps back to (line, col).
  local text, offsets, pos = {}, {}, 1
  for i, line in ipairs(lines) do
    offsets[i] = pos
    -- Blank out fenced lines and TeX comments: keeps byte offsets stable while
    -- making their content unmatchable.
    local scanable = line
    if fenced[i] then
      scanable = string.rep(" ", #line)
    else
      local c = scanable:find("%%")
      while c and escaped(scanable, c) do
        c = scanable:find("%%", c + 1)
      end
      if c then
        scanable = scanable:sub(1, c - 1) .. string.rep(" ", #scanable - c + 1)
      end
    end
    table.insert(text, scanable)
    pos = pos + #line + 1
  end
  local joined = table.concat(text, "\n")

  local function to_pos(byte)
    for i = #offsets, 1, -1 do
      if offsets[i] <= byte then
        return i, byte - offsets[i]
      end
    end
    return 1, 0
  end

  local function add(sb, eb, display)
    local raw = joined:sub(sb, eb)
    local tex = util.strip(raw)
    if vim.trim(tex) == "" then
      return
    end
    local sl, sc = to_pos(sb)
    local el, ec = to_pos(eb)
    table.insert(found, {
      tex = tex,
      raw = raw,
      display = display,
      lnum = sl,
      col = sc,
      end_lnum = el,
      end_col = ec + 1,
      label = util.label(raw),
      bufnr = bufnr,
    })
  end

  -- Environments first: their bodies may contain $ that must not be re-matched.
  -- `consumed` is read here as well as by the delimiter loop below: a `cases`
  -- or `split` nested in an `equation` is part of that entry, not one of its
  -- own, and ENVIRONMENTS lists the outer forms first so the enclosing span is
  -- always marked by the time the inner one is scanned.
  local consumed = {}
  for _, env in ipairs(ENVIRONMENTS) do
    local pattern = "\\begin%s*{" .. env .. "%*?}"
    local init = 1
    while true do
      local sb, se = joined:find(pattern, init)
      if not sb then
        break
      end
      if consumed[sb] then
        init = se + 1
      else
        local eb, ee = joined:find("\\end%s*{" .. env .. "%*?}", se)
        if not eb then
          break
        end
        add(sb, ee, true)
        for i = sb, ee do
          consumed[i] = true
        end
        init = ee + 1
      end
    end
  end

  local i, n = 1, #joined
  while i <= n do
    if consumed[i] then
      i = i + 1
    else
      local two = joined:sub(i, i + 1)
      local one = joined:sub(i, i)
      local open, close, display

      if two == "$$" then
        open, close, display = "$$", "$$", true
      elseif two == "\\[" then
        open, close, display = "\\[", "\\]", true
      elseif two == "\\(" then
        open, close, display = "\\(", "\\)", false
      elseif one == "$" and not escaped(joined, i) then
        open, close, display = "$", "$", false
      end

      if open then
        local from = i + #open
        local eb
        while true do
          eb = joined:find(close, from, true)
          if not eb then
            break
          end
          if close:sub(1, 1) == "$" and escaped(joined, eb) then
            from = eb + 1
          else
            break
          end
        end
        if eb then
          add(i, eb + #close - 1, display)
          i = eb + #close
        else
          i = i + #open
        end
      else
        i = i + 1
      end
    end
  end

  table.sort(found, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return a.col < b.col
  end)
  return found
end

return M
