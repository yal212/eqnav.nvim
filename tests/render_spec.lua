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
    render.render_all(eqs, function(index, png, err, id)
      results[index] = { png = png, err = err, id = id }
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
      -- The identity view.set_image checks a result against, so that a render
      -- finishing after an edit is dropped rather than painted onto whatever
      -- now holds that ordinal.
      assert.are.equal(eqs[i].id, results[i].id, "callback should report the equation's id")
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

  --- Run :EqnavExport on a buffer holding `text` and return the page it opened,
  --- or nil if it never got that far. vim.ui.open is stubbed out: the export
  --- ends by launching a browser.
  local function export(text)
    vim.api.nvim_set_current_buf(helpers.buf(text, "markdown"))
    local path = vim.fn.tempname() .. ".html"
    local real_open, opened = vim.ui.open, nil
    vim.ui.open = function(p)
      opened = p
    end
    local ok, err = pcall(function()
      require("eqnav.export.html").export_and_open(path)
      wait(function()
        return opened ~= nil
      end)
    end)
    vim.ui.open = real_open
    assert(ok, err)
    if opened ~= path then
      return nil
    end
    local fh = assert(io.open(path))
    local page = fh:read("*a")
    fh:close()
    return page
  end

  -- #47: render.enabled governs the terminal view. The export is the escape
  -- hatch for a terminal that cannot show images, so it renders regardless --
  -- and it waits for one callback per equation, so render_all returning
  -- without any left it waiting forever.
  it("exports with rendering disabled even when the renderer cannot run", function()
    require("eqnav").setup({ render = { enabled = false, node = "definitely-not-a-real-binary" } })
    render.daemon.reset()
    local page = export("$$x^2 + " .. vim.uv.hrtime() .. "$$")
    render.daemon.reset()
    assert.is_truthy(page, "export never finished")
    assert.is_truthy(page:find("not rendered", 1, true))
  end)

  it("renders for export with rendering disabled", function()
    if not has_node then
      pending("node or @mathjax/src unavailable")
      return
    end
    require("eqnav").setup({ render = { enabled = false, color = "e0def4" } })
    -- A fresh equation, so a warm cache cannot stand in for the render.
    local page = export("$$y^2 + " .. vim.uv.hrtime() .. "$$")
    assert.is_truthy(page, "export never finished")
    assert.is_truthy(page:find("<svg", 1, true), "export did not render")
  end)
end)

--- Every chunk of a PNG file, in order, as { type, data, crc_ok }.
---@param path string
local function png_chunks(path)
  local fh = assert(io.open(path, "rb"))
  local bytes = fh:read("*a")
  fh:close()
  assert.are.equal("\137PNG\r\n\26\n", bytes:sub(1, 8), "not a PNG")
  local function u32(off)
    local a, b, c, d = bytes:byte(off, off + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  local out, pos = {}, 9
  while pos <= #bytes do
    local len = u32(pos)
    local kind = bytes:sub(pos + 4, pos + 7)
    local data = bytes:sub(pos + 8, pos + 7 + len)
    local crc = u32(pos + 8 + len)
    local ok = require("eqnav.render.raster").crc32(kind .. data) == crc
    table.insert(out, { type = kind, data = data, crc_ok = ok })
    pos = pos + 12 + len
  end
  return out
end

---@param data string
local function phys(data)
  local function u32(off)
    local a, b, c, d = data:byte(off, off + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(1), u32(5), data:byte(9)
end

---@param path string
---@return integer width, integer height
local function png_dims(path)
  local ihdr = png_chunks(path)[1]
  assert.are.equal("IHDR", ihdr.type)
  local w, h = phys(ihdr.data) -- IHDR opens with the same two u32s
  return w, h
end

-- #17 and #6: the terminal shows an image in a box of whole cells, and kitty
-- stretches the image to fill it. An image that is not already a whole number
-- of cells is stretched by its own factor, and snacks' DPI scaling on top made
-- the box disagree with the rows eqnav reserved. These pin the cure: render at
-- the display's density, pad to whole cells, and stamp a DPI snacks reads as 1:1.
describe("cell-aligned rasterization", function()
  local raster = require("eqnav.render.raster")
  local geom = { cell_width = 20, cell_height = 45, scale = 2.5 }

  before_each(function()
    require("eqnav").setup({ render = { color = "e0def4", ex = 9 } })
  end)

  it("pads to whole cells without growing an exact fit", function()
    assert.are.same({ width = 40, height = 90, top = 0, left = 0 }, raster.box(40, 90, geom))
  end)

  it("rounds up to the next cell and centres vertically", function()
    local b = raster.box(301, 47, geom)
    assert.are.same({ width = 320, height = 90, top = 21, left = 0 }, b)
  end)

  it("reserves at least one cell for an empty equation", function()
    local b = raster.box(0.5, 0.5, geom)
    assert.are.equal(20, b.width)
    assert.are.equal(45, b.height)
  end)

  it("never crops the image when the cell size is fractional", function()
    -- 44.6px rasterizes to 45 rows of pixels, but floor(1 * 44.8) is 44.
    local b = raster.box(10, 44.6, { cell_width = 9.5, cell_height = 44.8, scale = 1 })
    assert.is_true(b.height >= 45, "box cuts off the last pixel row: " .. b.height)
    -- and stays a whole number of cells, rounded down, so snacks' ceil() lands
    -- on the same count
    local rows = math.ceil(b.height / 44.8)
    assert.is_true(b.height > (rows - 1) * 44.8 and b.height <= rows * 44.8)
  end)

  it("stamps a unit-less pHYs that replaces any previous one", function()
    if not has_raster then
      pending("no rasterizer")
      return
    end
    local tmp = vim.fn.tempname()
    local svg, png = tmp .. ".svg", tmp .. ".png"
    local fh = assert(io.open(svg, "w"))
    fh:write(
      '<svg xmlns="http://www.w3.org/2000/svg" width="30px" height="10px">'
        .. '<rect width="30" height="10" fill="#fff"/></svg>'
    )
    fh:close()
    local done, err
    raster.convert(svg, png, function(p, e)
      done, err = p, e
    end, { box = raster.box(30, 10, geom), ppu = 240 })
    assert.is_true(wait(function()
      return done ~= nil or err ~= nil
    end))
    assert.is_nil(err)

    assert.is_nil(raster.stamp_dpi(png, 241))
    local found = {}
    for _, c in ipairs(png_chunks(png)) do
      assert.is_true(c.crc_ok, c.type .. " has a bad CRC")
      if c.type == "pHYs" then
        table.insert(found, c)
      end
    end
    assert.are.equal(1, #found, "expected exactly one pHYs chunk")
    local x, y, unit = phys(found[1].data)
    assert.are.same({ 241, 241, 0 }, { x, y, unit })
    assert.are.same({ 40, 45 }, { png_dims(png) })

    -- What snacks actually reads. CI has no ImageMagick; this is the local check
    -- that a unit-0 pHYs comes back verbatim rather than as pixels per cm.
    if vim.fn.executable("magick") == 1 then
      local res = vim
        .system({ "magick", "identify", "-format", "%xx%y", png }, { text = true })
        :wait()
      assert.are.equal("241x241", vim.trim(res.stdout))
    end
  end)

  it("keys the cache on the display geometry", function()
    local util = require("eqnav.scan.util")
    local a = util.hash("x", true, "e0def4", 9, geom)
    local b = util.hash("x", true, "e0def4", 9, { cell_width = 20, cell_height = 44, scale = 2.5 })
    assert.are_not.equal(a, b)
    assert.are_not.equal(a, util.hash("x", true, "e0def4", 9))
    -- The same cells padded for image.nvim's rounding are a different PNG, so
    -- switching backends must not serve snacks' render to image.nvim.
    local c =
      util.hash("x", true, "e0def4", 9, vim.tbl_extend("force", geom, { keeps_height = true }))
    assert.are_not.equal(a, c)
  end)

  -- image.nvim keeps the rows it is given and works the columns out from the
  -- aspect (#54): the canvas is ceil(n cells) tall, a hair over n, and a
  -- fraction of a px under the box's aspect wide. The exact round trip through
  -- image.nvim's own arithmetic is pinned in image_nvim_spec.lua.
  it("pads for image.nvim's rounding when the geometry asks for it", function()
    local g = { cell_width = 9.5, cell_height = 44.8, scale = 1, keeps_height = true }
    local b = raster.box(30, 50, g)
    assert.are.equal(90, b.height) -- ceil(2 * 44.8)
    assert.is_true(b.width >= 30, "box cuts off the image: " .. b.width)
    -- Just under 4 columns at this height's aspect: 4 * 9.5 * 90 / 89.6 = 38.17
    assert.are.equal(37, b.width)
    assert.are.equal(20, b.top)
  end)

  it("keys the cache on the index width, and only when there is one", function()
    local util = require("eqnav.scan.util")
    local a = util.hash("x", true, "e0def4", 9, geom)
    assert.are.equal(a, util.hash("x", true, "e0def4", 9, geom, nil))
    assert.are_not.equal(a, util.hash("x", true, "e0def4", 9, geom, 60))
    assert.are_not.equal(
      util.hash("x", true, "e0def4", 9, geom, 60),
      util.hash("x", true, "e0def4", 9, geom, 80)
    )
  end)

  -- A \tag makes MathJax size the SVG as width="100%", so the daemon reports no
  -- width, which arrives as vim.NIL: truthy, and arithmetic on it throws inside
  -- the daemon callback, so the entry waited on its render forever.
  it("finishes an equation the daemon reports no size for", function()
    if not (has_node and has_raster) then
      pending("renderer toolchain unavailable")
      return
    end
    local display = require("eqnav.display")
    local real_get = display.get
    display.get = function()
      return {
        name = "fake",
        images = true,
        geometry = function()
          return geom
        end,
      }
    end
    local ok, failure = pcall(function()
      local eqs = scan.scan(helpers.buf("$$x = y \\tag{1}$$\n", "markdown"))
      local got
      render.render_all(eqs, function(_, png, err)
        got = { png = png, err = err }
      end, { force = true })
      assert.is_true(
        wait(function()
          return got ~= nil
        end, 10000),
        "the render never called back"
      )
    end)
    display.get = real_get
    assert(ok, failure)
  end)

  -- #41: snacks shrinks an image wider than the index to fit it, so its glyphs
  -- came out smaller than every other entry's. Given the index width, display
  -- math is broken over lines to fit instead, at the one scale.
  it("breaks display math to fit the index width", function()
    if not (has_node and has_raster) then
      pending("renderer toolchain unavailable")
      return
    end
    local display = require("eqnav.display")
    local real_get = display.get
    display.get = function()
      return {
        name = "fake",
        images = true,
        geometry = function()
          return geom
        end,
      }
    end
    local ok, failure = pcall(function()
      local terms = {}
      for i = 1, 20 do
        table.insert(terms, "x_{" .. i .. "}^2")
      end
      local bufnr = helpers.buf("$$" .. table.concat(terms, " + ") .. "$$\n", "markdown")
      local function render_at(width)
        local eqs = scan.scan(bufnr)
        local got
        render.render_all(eqs, function(_, png, err)
          got = { png = png, err = err }
        end, { force = true, width = width })
        assert.is_true(
          wait(function()
            return got ~= nil
          end),
          "the render never called back"
        )
        assert.is_nil(got.err, tostring(got.err))
        local w, h = png_dims(got.png)
        return eqs[1].id, w, h
      end

      local whole_id, whole_w, whole_h = render_at(nil)
      local id, w, h = render_at(40)
      assert.are_not.equal(whole_id, id, "a width must be a different render")
      assert.is_true(whole_w > 39 * geom.cell_width, "the test equation is not over-wide")
      -- One column is left free, as the entry header leaves it.
      assert.is_true(w <= 39 * geom.cell_width, ("%dpx is wider than the index"):format(w))
      assert.is_true(h >= 2 * whole_h, "the equation was not broken over lines")
    end)
    display.get = real_get
    assert(ok, failure)
  end)

  it("renders every equation at one scale, padded to whole cells", function()
    if not (has_node and has_raster) then
      pending("renderer toolchain unavailable")
      return
    end
    local display = require("eqnav.display")
    local real_get = display.get
    display.get = function()
      return {
        name = "fake",
        images = true,
        geometry = function()
          return geom
        end,
      }
    end
    local ok, failure = pcall(function()
      local bufnr = helpers.buf(
        "$$x = 1$$\n\n$$\\frac{\\frac{a}{b}}{c}$$\n\n$$\\sum_{i=1}^{n} i^2 = \\frac{n(n+1)(2n+1)}{6}$$\n",
        "markdown"
      )
      local eqs = scan.scan(bufnr)
      local results = {}
      render.render_all(eqs, function(index, png, err)
        results[index] = { png = png, err = err }
      end, { force = true })
      assert.is_true(
        wait(function()
          return results[1] and results[2] and results[3]
        end),
        "renders did not complete"
      )

      local density
      for i, eq in ipairs(eqs) do
        local r = results[i]
        assert.is_nil(r.err, tostring(r.err))
        local w, h = png_dims(r.png)
        assert.are.equal(0, w % 20, "width " .. w .. " is not whole cells")
        assert.are.equal(0, h % 45, "height " .. h .. " is not whole cells")

        -- The SVG stays in CSS px, which the HTML export relies on, at one
        -- density per MathJax unit for every entry.
        local fh = assert(io.open(cache.path(eq.id, "svg")))
        local svg = fh:read("*a")
        fh:close()
        local sw = tonumber(svg:match('width="([%d.]+)px"'))
        local sh = tonumber(svg:match('height="([%d.]+)px"'))
        local vb = tonumber(svg:match('viewBox="[-%d.]+ [-%d.]+ [-%d.]+ ([-%d.]+)"'))
        density = density or sh / vb
        assert.is_true(
          math.abs(sh / vb - density) / density < 0.01,
          "glyph scale differs in entry " .. i
        )

        -- The PNG is exactly that SVG at the display scale, padded: the smallest
        -- cell box holding it, so nothing was stretched to reach the box.
        local b = raster.box(sw * geom.scale, sh * geom.scale, geom)
        assert.are.same({ b.width, b.height }, { w, h })
        assert.is_true(
          w - 20 < sw * geom.scale and h - 45 < sh * geom.scale,
          "box has a spare cell"
        )
      end
    end)
    display.get = real_get
    assert(ok, failure)
  end)
end)
