local cache = require("eqnav.render.cache")
local helpers = require("tests.helpers")
local render = require("eqnav.render")
local scan = require("eqnav.scan")

-- These exercise the real node daemon and the real rasterizer. They are the
-- only tests that touch the outside world, so they skip rather than fail when
-- the toolchain is absent.
local has_node = vim.fn.executable("node") == 1
  and vim.fn.isdirectory(render.daemon.root() .. "/node_modules/@mathjax/src") == 1
local has_raster = require("eqnav.render.raster").detect() ~= nil

--- Pump the event loop until `cond` or the deadline passes.
local function wait(cond, ms)
  return vim.wait(ms or 20000, cond, 25)
end

describe("render pipeline", function()
  before_each(function()
    require("eqnav").setup({ render = { color = "e0def4", ex = 9 } })
  end)

  it("resolves @mathjax/src", function()
    if not has_node then
      pending("node or @mathjax/src unavailable")
      return
    end
    local res = vim
      .system({ "node", render.daemon.script(), "--list-paths" }, { text = true })
      :wait()
    assert.are.equal(0, res.code, res.stderr)
    local info = vim.json.decode(res.stdout)
    assert.is_truthy(info.resolved, "should resolve a @mathjax/src install")
  end)

  it("renders a document's equations to PNG files", function()
    if not (has_node and has_raster) then
      pending("renderer toolchain unavailable")
      return
    end
    local bufnr = helpers.buf("$$E = mc^2$$\n\n$$\\frac{a}{b}$$\n", "markdown")
    local eqs = scan.scan(bufnr)
    assert.are.equal(2, #eqs)

    local results = {}
    render.render_all(eqs, function(index, png, err)
      results[index] = { png = png, err = err }
    end)

    assert.is_true(
      wait(function()
        return results[1] ~= nil and results[2] ~= nil
      end),
      "renders did not complete"
    )

    for i = 1, 2 do
      assert.is_nil(results[i].err, "equation " .. i .. ": " .. tostring(results[i].err))
      assert.is_truthy(results[i].png, "equation " .. i .. " produced no png")
      local stat = vim.uv.fs_stat(results[i].png)
      assert.is_truthy(stat and stat.size > 0, "png is empty")
    end
  end)

  -- The reason the daemon must use adaptor.serializeXML: MathJax writes raw TeX
  -- into data-latex attributes, and rsvg-convert refuses invalid XML.
  it("renders equations containing < and > (the XML escaping landmine)", function()
    if not (has_node and has_raster) then
      pending("renderer toolchain unavailable")
      return
    end
    local tricky = { "a < b", "\\text{if } x < y", "\\xrightarrow{a<b} c", "p \\& q" }
    local text = {}
    for _, t in ipairs(tricky) do
      table.insert(text, "$$" .. t .. "$$\n")
    end
    local bufnr = helpers.buf(table.concat(text, "\n"), "markdown")
    local eqs = scan.scan(bufnr)
    assert.are.equal(#tricky, #eqs)

    local results = {}
    render.render_all(eqs, function(index, png, err)
      results[index] = { png = png, err = err }
    end)
    assert.is_true(
      wait(function()
        return vim.tbl_count(results) == #tricky
      end),
      "renders did not complete"
    )

    for i, t in ipairs(tricky) do
      assert.is_nil(results[i].err, t .. " -> " .. tostring(results[i].err))
      assert.is_truthy(results[i].png, t .. " produced no png")
    end
  end)

  it("serves a second render of the same content from cache", function()
    if not (has_node and has_raster) then
      pending("renderer toolchain unavailable")
      return
    end
    local bufnr = helpers.buf("$$\\sigma^2 = 42$$", "markdown")
    local eqs = scan.scan(bufnr)

    local first
    render.render_all(eqs, function(_, png)
      first = png
    end)
    assert.is_true(wait(function()
      return first ~= nil
    end))

    -- With the daemon stopped, a cache hit is the only way this can succeed.
    render.daemon.stop()
    local second
    render.render_all(scan.scan(bufnr), function(_, png)
      second = png
    end)
    assert.is_true(
      wait(function()
        return second ~= nil
      end, 3000),
      "cache did not serve the repeat render"
    )
    assert.are.equal(first, second)
  end)

  it("changes the cache key when the colour changes", function()
    local util = require("eqnav.scan.util")
    local dark = util.hash("x", true, "e0def4", 9)
    local light = util.hash("x", true, "202020", 9)
    assert.are_not.equal(dark, light)
    assert.is_truthy(cache.path(dark, "png"):find(dark, 1, true))
  end)

  -- MathJax is deliberately configured to be forgiving: `noundefined` renders an
  -- unknown macro as red text and a genuine syntax error comes back as a visible
  -- <merror> box baked into the image. For an index view that is the right
  -- trade -- you see which equation is broken instead of an empty slot -- so the
  -- contract here is "never hangs, never throws", not "returns an error string".
  it("still produces an image for malformed TeX rather than hanging", function()
    if not (has_node and has_raster) then
      pending("renderer toolchain unavailable")
      return
    end
    local bufnr = helpers.buf("$$\\frac{a}$$\n\n$$\\notAMacro{x}$$\n", "markdown")
    local eqs = scan.scan(bufnr)
    assert.are.equal(2, #eqs)

    local results = {}
    render.render_all(eqs, function(index, png, err)
      results[index] = { png = png, err = err }
    end)
    assert.is_true(
      wait(function()
        return vim.tbl_count(results) == 2
      end),
      "malformed TeX hung the pipeline"
    )

    for i = 1, 2 do
      assert.is_truthy(results[i].png or results[i].err, "equation " .. i .. " reported nothing")
    end
  end)

  it("surfaces an error when the renderer cannot run at all", function()
    require("eqnav").setup({ render = { node = "definitely-not-a-real-binary" } })
    render.daemon.reset()
    local bufnr = helpers.buf("$$x$$", "markdown")
    local got = nil
    render.render_all(scan.scan(bufnr), function(_, png, err)
      got = { png = png, err = err }
    end)
    assert.is_true(
      wait(function()
        return got ~= nil
      end, 5000),
      "no callback when the renderer is missing"
    )
    assert.is_nil(got.png)
    assert.is_truthy(got.err)
    assert.is_truthy(got.err:find("definitely-not-a-real-binary", 1, true), got.err)
    render.daemon.reset()
  end)
end)
