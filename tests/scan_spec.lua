local helpers = require("tests.helpers")
local scan = require("eqnav.scan")
local regex = require("eqnav.scan.regex")
local treesitter = require("eqnav.scan.treesitter")
local util = require("eqnav.scan.util")

describe("scan.util", function()
  it("strips each delimiter pair and reports display-ness", function()
    local cases = {
      { "$$x$$", "x", true },
      { "\\[x\\]", "x", true },
      { "\\(x\\)", "x", false },
      { "$x$", "x", false },
      { "$$\n\\frac a b\n$$", "\\frac a b", true },
    }
    for _, c in ipairs(cases) do
      local tex, display = util.strip(c[1])
      assert.are.equal(c[2], tex, "text for " .. c[1])
      assert.are.equal(c[3], display, "display for " .. c[1])
    end
  end)

  it("leaves environments intact so MathJax keeps the alignment", function()
    local raw = "\\begin{align} a &= b \\end{align}"
    assert.are.equal(raw, util.strip(raw))
  end)

  it("finds labels in both TeX and pandoc form", function()
    assert.are.equal("eq:mass", util.label("E=mc^2 \\label{eq:mass}"))
    assert.are.equal("eq:mass", util.label("E=mc^2 {#eq:mass}"))
    assert.is_nil(util.label("E=mc^2"))
  end)

  -- pandoc consumes a {#eq:..} attribute before TeX ever sees it, which is why
  -- the syntax exists. Left in the rendered text, MathJax fails with "You can't
  -- use 'macro parameter character #' in math mode".
  it("strips a pandoc {#eq:..} attribute, which MathJax cannot parse", function()
    local tex, display = util.strip("$$\\hbar \\omega = h \\nu {#eq:planck}$$")
    assert.are.equal("\\hbar \\omega = h \\nu", tex)
    assert.is_true(display)
    -- \label{..} stays: MathJax's ams package understands it.
    assert.are.equal("E = mc^2 \\label{eq:mass}", util.strip("$$E = mc^2 \\label{eq:mass}$$"))
  end)

  it("hashes on everything that changes the pixels", function()
    local base = util.hash("x", true, "ffffff", 9)
    assert.are.equal(base, util.hash("x", true, "ffffff", 9))
    assert.are_not.equal(base, util.hash("y", true, "ffffff", 9))
    assert.are_not.equal(base, util.hash("x", false, "ffffff", 9))
    assert.are_not.equal(base, util.hash("x", true, "000000", 9))
    assert.are_not.equal(base, util.hash("x", true, 18))
  end)
end)

describe("scan (markdown, treesitter)", function()
  it("uses the treesitter backend for markdown", function()
    local bufnr = helpers.buf("$$x$$", "markdown")
    assert.are.equal("treesitter", scan.backend(bufnr))
  end)

  it("finds display math and skips inline by default", function()
    local bufnr = helpers.buf(
      [[
# Heading

Inline $a^2+b^2=c^2$ here.

$$
\frac{\partial u}{\partial t} = \alpha \nabla^2 u
$$
]],
      "markdown"
    )
    local eqs = scan.scan(bufnr)
    assert.are.equal(1, #eqs)
    assert.is_true(eqs[1].display)
    assert.are.equal("\\frac{\\partial u}{\\partial t} = \\alpha \\nabla^2 u", eqs[1].tex)
    assert.are.equal(5, eqs[1].lnum)
  end)

  it("includes inline math when asked", function()
    local bufnr = helpers.buf("Inline $a^2$ and $$b^2$$", "markdown")
    local eqs = scan.scan(bufnr, { include_inline = true })
    assert.are.equal(2, #eqs)
    assert.is_false(eqs[1].display)
    assert.are.equal("a^2", eqs[1].tex)
    assert.is_true(eqs[2].display)
  end)

  -- The regression that motivates using treesitter at all.
  it("does NOT match math-looking text inside a fenced code block", function()
    local bufnr = helpers.buf(
      [[
$$real$$

```python
# not math: $x$ and $$y$$
cost = "$5"
```

$$also_real$$
]],
      "markdown"
    )
    local eqs = scan.scan(bufnr, { include_inline = true })
    local texts = vim.tbl_map(function(e)
      return e.tex
    end, eqs)
    assert.are.same({ "real", "also_real" }, texts)
  end)

  it("labels a pandoc-tagged equation without sending the '#' to the renderer", function()
    local bufnr = helpers.buf("$$\n\\hbar \\omega = h \\nu {#eq:planck}\n$$\n", "markdown")
    local eqs = scan.scan(bufnr)
    assert.are.equal(1, #eqs)
    assert.are.equal("eq:planck", eqs[1].label)
    assert.is_nil(eqs[1].tex:find("#", 1, true), "tex still carries the attribute: " .. eqs[1].tex)
    -- raw keeps it, so `y` still reproduces the source exactly.
    assert.is_truthy(eqs[1].raw:find("{#eq:planck}", 1, true), "raw: " .. eqs[1].raw)
  end)

  it("records the nearest heading as context", function()
    local bufnr = helpers.buf(
      [[
# Intro

## Method

$$x = 1$$
]],
      "markdown"
    )
    local eqs = scan.scan(bufnr)
    assert.are.equal("Method", eqs[1].context)
  end)

  it("numbers equations in document order", function()
    local bufnr = helpers.buf("$$a$$\n\n$$b$$\n\n$$c$$", "markdown")
    local eqs = scan.scan(bufnr)
    assert.are.same(
      { 1, 2, 3 },
      vim.tbl_map(function(e)
        return e.index
      end, eqs)
    )
    assert.are.same(
      { "a", "b", "c" },
      vim.tbl_map(function(e)
        return e.tex
      end, eqs)
    )
  end)
end)

describe("scan.regex (fallback)", function()
  it("finds all four delimiter pairs", function()
    local bufnr = helpers.buf(
      [[
$$display$$
\[bracket\]
\(paren\)
$inline$
]],
      "text"
    )
    local eqs = regex.scan(bufnr)
    assert.are.same(
      { "display", "bracket", "paren", "inline" },
      vim.tbl_map(function(e)
        return e.tex
      end, eqs)
    )
    assert.are.same(
      { true, true, false, false },
      vim.tbl_map(function(e)
        return e.display
      end, eqs)
    )
  end)

  it("finds math environments and keeps them whole", function()
    local bufnr = helpers.buf("\\begin{align}\na &= b \\\\\nc &= d\n\\end{align}", "text")
    local eqs = regex.scan(bufnr)
    assert.are.equal(1, #eqs)
    assert.is_true(eqs[1].display)
    assert.is_true(eqs[1].tex:find("\\begin{align}", 1, true) ~= nil)
  end)

  -- A `cases`/`split`/`dcases` is almost always written inside an `equation` or
  -- `align`, so before this was fixed most piecewise functions in a real .tex
  -- document produced a duplicate entry: one for the enclosing environment and
  -- one for the nested one, rendering as two near-identical images.
  it("indexes a nested environment once, as part of its enclosing one", function()
    local nested = {
      cases = "\\begin{equation}\n  f(x) = \\begin{cases}\n    x^2 & x \\geq 0 \\\\\n    -x^2 & x < 0\n  \\end{cases}\n\\end{equation}",
      split = "\\begin{equation}\n  \\begin{split}\n    a &= b \\\\\n      &= c\n  \\end{split}\n\\end{equation}",
      dcases = "\\begin{equation}\n  g(x) = \\begin{dcases}\n    1 & x > 0 \\\\\n    0 & x \\leq 0\n  \\end{dcases}\n\\end{equation}",
    }
    for env, text in pairs(nested) do
      local eqs = regex.scan(helpers.buf(text, "text"))
      assert.are.equal(1, #eqs, env .. " in equation: " .. vim.inspect(helpers.summary(eqs)))
      assert.is_truthy(
        eqs[1].tex:find("\\begin{equation}", 1, true),
        env .. ": the entry should be the whole equation, not the inner environment"
      )
    end
  end)

  -- The other half of the fix: nesting suppression must not swallow an
  -- environment that stands on its own.
  it("still indexes a standalone cases, and sibling environments separately", function()
    local standalone =
      regex.scan(helpers.buf("\\begin{cases}\na & b \\\\\nc & d\n\\end{cases}", "text"))
    assert.are.equal(1, #standalone, vim.inspect(helpers.summary(standalone)))

    local siblings = regex.scan(
      helpers.buf(
        "\\begin{equation}\na\n\\end{equation}\n\n\\begin{equation}\nb\n\\end{equation}",
        "text"
      )
    )
    assert.are.equal(2, #siblings, vim.inspect(helpers.summary(siblings)))

    local mixed =
      regex.scan(helpers.buf("\\begin{align}\na &= b\n\\end{align}\n\n$$c = d$$", "text"))
    assert.are.equal(2, #mixed, vim.inspect(helpers.summary(mixed)))
  end)

  it("skips fenced code blocks", function()
    local bufnr = helpers.buf("$$yes$$\n```\n$$no$$\n```\n", "text")
    local eqs = regex.scan(bufnr)
    assert.are.same(
      { "yes" },
      vim.tbl_map(function(e)
        return e.tex
      end, eqs)
    )
  end)

  it("skips TeX comments and escaped dollars", function()
    local bufnr = helpers.buf("% $$commented$$\ncosts \\$5 and \\$7\n$$real$$", "text")
    local eqs = regex.scan(bufnr)
    assert.are.same(
      { "real" },
      vim.tbl_map(function(e)
        return e.tex
      end, eqs)
    )
  end)

  it("reports positions that map back to the right line", function()
    local bufnr = helpers.buf("line one\n\n$$x = 1$$\n", "text")
    local eqs = regex.scan(bufnr)
    assert.are.equal(3, eqs[1].lnum)
    assert.are.equal(0, eqs[1].col)
  end)
end)

describe("scan extmarks", function()
  it("keeps the jump target correct after lines are inserted above", function()
    local bufnr = helpers.buf("# T\n\n$$x = 1$$\n", "markdown")
    local eqs = scan.scan(bufnr)
    assert.are.equal(3, eqs[1].lnum)

    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new", "lines", "above" })

    local lnum = scan.mark_pos(eqs[1])
    assert.are.equal(6, lnum, "extmark should have tracked the insertion")
    assert.are.equal(3, eqs[1].lnum, "the original scan value is untouched")
  end)
end)
