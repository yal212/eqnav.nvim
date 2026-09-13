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

  -- #8: @mathjax/mathjax-newcm-font ships most of its glyph coverage as ranges
  -- MathJax fetches on demand (svg/dynamic/: double-struck, fraktur,
  -- calligraphic, monospace, sans-serif, ...). A glyph from a range that is not
  -- loaded yet raises MathJax's Retry signal, which only the promise API
  -- resolves; \require{..} loads a package the same way. Two things make this
  -- easy to miss: a loaded range stays loaded for the life of the daemon, so
  -- *which* equations fail drifts between runs, and a warm cache never reaches
  -- the daemon at all. Hence a fresh daemon, and daemon.request, which does not
  -- consult the cache.
  it("renders glyphs from font ranges MathJax loads on demand", function()
    if not has_node then
      pending("node or @mathjax/src unavailable")
      return
    end
    render.daemon.reset()

    -- One case per range, so each is the first request to need its own.
    local cases = {
      { "\\mathbb{R}", "double-struck" },
      { "\\mathfrak{g}", "fraktur" },
      { "\\mathcal{L}", "calligraphic" },
      { "\\mathtt{x}", "monospace" },
      { "\\mathsf{y}", "sans-serif" },
      -- Not only glyph ranges: \require and autoload pull in a whole TeX package
      -- mid-render through the same mechanism.
      { "\\require{verb}\\verb|x|", "a package loaded by \\require" },
      { "\\href{http://example.com}{y}", "a package loaded by autoload" },
      -- mhchem needs @mathjax/mathjax-mhchem-font-extension on top of the promise
      -- API: MathJax 4 keeps its glyphs out of the main font, and without that
      -- package the loader rejects [tex]/mhchem with "Extension mhchem failed to
      -- load". package.json depends on it for exactly this case.
      { "\\require{mhchem}\\ce{CO2 + C -> 2CO}", "mhchem, fonts and all" },
    }

    local results = {}
    for i, case in ipairs(cases) do
      render.daemon.request({ equation = case[1], display = true, color = "e0def4" }, function(res)
        results[i] = res
      end)
    end
    assert.is_true(
      wait(function()
        return vim.tbl_count(results) == #cases
      end),
      "renders did not complete"
    )

    for i, case in ipairs(cases) do
      local what = case[1] .. " (" .. case[2] .. ")"
      assert.is_true(results[i].ok, what .. ": " .. tostring(results[i].err))
      -- MathJax bakes a failure into the image as an error box, so res.ok alone
      -- is not the question -- an error box is a perfectly valid SVG.
      local err = results[i].svg:match('data%-mjx%-error="([^"]*)"')
      assert.is_nil(err, what .. " rendered an error box: " .. tostring(err))
    end
    render.daemon.reset()
  end)

  -- #10: colouring by wrapping the source in \color{..}{..} is illegal around an
  -- environment, and every eqnav render passes a colour. The node-level spec
  -- (tests/daemon_xml_spec.mjs) owns the colour contract in detail; this one
  -- proves the Lua pipeline delivers it end to end, since render_all is what
  -- decides the colour and writes the cache.
  it("renders display-math environments without an error box", function()
    if not (has_node and has_raster) then
      pending("renderer toolchain unavailable")
      return
    end
    local envs = {
      "\\begin{equation} x = 1 \\end{equation}",
      "\\begin{align} a &= b \\\\ c &= d \\end{align}",
      "\\begin{gather} p = q \\\\ r = s \\end{gather}",
      "\\begin{multline} a + b \\\\ + c \\end{multline}",
      "\\begin{eqnarray} \\alpha & = & \\beta \\end{eqnarray}",
    }
    local text = {}
    for _, e in ipairs(envs) do
      table.insert(text, "$$" .. e .. "$$\n")
    end
    local bufnr = helpers.buf(table.concat(text, "\n"), "markdown")
    local eqs = scan.scan(bufnr)
    assert.are.equal(#envs, #eqs)

    local results = {}
    -- force: a warm cache would serve yesterday's error boxes and never reach
    -- the daemon, which is exactly how this stayed hidden.
    render.render_all(eqs, function(index, png, err)
      results[index] = { png = png, err = err }
    end, { force = true })
    assert.is_true(
      wait(function()
        return vim.tbl_count(results) == #envs
      end),
      "renders did not complete"
    )

    for i, env in ipairs(envs) do
      assert.is_nil(results[i].err, env .. " -> " .. tostring(results[i].err))
      assert.is_truthy(results[i].png, env .. " produced no png")
      local svg_path = cache.get_svg(eqs[i].id)
      assert.is_truthy(svg_path, env .. ": no cached svg")
      local fh = assert(io.open(svg_path, "r"))
      local svg = fh:read("*a")
      fh:close()
      local err = svg:match('data%-mjx%-error="([^"]*)"')
      assert.is_nil(err, env .. " rendered an error box: " .. tostring(err))
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

  -- Regression: stop() SIGTERMs the daemon, but vim.system reports a signalled
  -- child as code 0, and its on_exit is scheduled -- so the stale exit used to
  -- land after the next start() and null out the live process handle. The
  -- "ready" line that followed then crashed inside a scheduled callback and
  -- stranded every queued request. There is deliberately no pause before the
  -- restart here: an exit still in flight is the whole race.
  it("serves requests again after the daemon is stopped and restarted", function()
    if not has_node then
      pending("node or @mathjax/src unavailable")
      return
    end
    render.daemon.reset()

    local first
    render.daemon.request({ equation = "x^2", display = true }, function(res)
      first = res
    end)
    assert.is_true(
      wait(function()
        return first ~= nil
      end),
      "first request never completed"
    )
    assert.is_true(first.ok, tostring(first.err))

    render.daemon.stop()

    local second
    render.daemon.request({ equation = "y^2", display = true }, function(res)
      second = res
    end)
    assert.is_true(
      wait(function()
        return second ~= nil
      end),
      "restarted daemon never answered"
    )
    assert.is_true(second.ok, tostring(second.err))
    render.daemon.reset()
  end)

  -- A deliberate stop still owes every caller an answer: render_all's pump only
  -- advances from a callback, so a silently dropped request stalls it forever.
  it("reports pending requests as failed when the daemon is stopped", function()
    if not has_node then
      pending("node or @mathjax/src unavailable")
      return
    end
    render.daemon.reset()

    -- Nothing pumps the loop between these two calls, so the request is still
    -- queued behind the daemon's "ready" line when the stop arrives.
    local got
    render.daemon.request({ equation = "z^2", display = true }, function(res)
      got = res
    end)
    render.daemon.stop()

    assert.is_truthy(got, "stop() dropped a pending request without answering it")
    assert.is_false(got.ok)
    assert.is_truthy(got.err)
    render.daemon.reset()
  end)
end)
