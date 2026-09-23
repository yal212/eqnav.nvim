-- Contract test for the snacks.nvim display backend.
--
-- Headless Neovim has no terminal graphics, so this cannot assert that pixels
-- land in the right place. What it can assert -- and what actually breaks in
-- practice -- is that the API eqnav calls still exists and still accepts the
-- arguments eqnav passes. Without this, a snacks refactor surfaces as
-- "equations stopped appearing" with no stack trace.
local backend = require("eqnav.display.snacks")
local helpers = require("tests.helpers")

local ok, snacks = pcall(require, "snacks")
local available = ok and type(snacks) == "table" and snacks.image ~= nil

-- A test that silently skips reads exactly like a test that passes, which is
-- how an optional dependency quietly stops being covered. In CI, where snacks
-- is checked out deliberately, EQNAV_REQUIRE_SNACKS makes its absence a hard
-- failure instead.
local required = vim.env.EQNAV_REQUIRE_SNACKS == "1"
if required and not available then
  error("EQNAV_REQUIRE_SNACKS=1 but snacks.nvim did not load: " .. tostring(snacks))
end

local function skip_unless_snacks()
  if not available then
    pending("snacks.nvim not on the runtimepath")
    return true
  end
  return false
end

describe("snacks backend", function()
  it("declines gracefully when the terminal has no graphics", function()
    -- Headless: snacks may be loadable but reports no graphics support, and
    -- eqnav must then fall back rather than render into the void.
    assert.is_boolean(backend.available())
    if not available then
      assert.is_false(backend.available())
    end
  end)

  it("calls only snacks API that exists", function()
    if skip_unless_snacks() then
      return
    end
    assert.is_function(snacks.image.supports_terminal)
    assert.is_function(snacks.image.terminal.size)
    assert.is_function(snacks.image.placement.new)
    assert.is_function(snacks.image.placement.close)
    assert.is_function(snacks.image.placement.update)
  end)

  it("gets the cell dimensions it divides image height by", function()
    if skip_unless_snacks() then
      return
    end
    local size = snacks.image.terminal.size()
    assert.is_table(size)
    assert.is_number(size.cell_width)
    assert.is_number(size.cell_height)
    assert.is_true(size.cell_height > 0, "cell_height must be positive or rows() divides by zero")
  end)

  -- The renderer pads every image to this cell size and stamps a DPI from this
  -- scale, so snacks' own sizing lands on exactly the rows rows() reserved.
  it("reports the geometry the renderer pads images to", function()
    local g = backend.geometry()
    assert.is_table(g)
    assert.is_true(g.cell_width > 0 and g.cell_height > 0, vim.inspect(g))
    assert.is_true(g.scale >= 1, vim.inspect(g))
  end)

  it("has its placement options accepted by snacks", function()
    if skip_unless_snacks() then
      return
    end
    local png =
      vim.fn.glob(vim.fs.joinpath(vim.fn.stdpath("cache"), "eqnav", "*.png"), false, true)[1]
    if not png then
      pending("no cached render to place; run the render specs first")
      return
    end
    local buf = helpers.buf("\n\n\n", "markdown")
    local created, err = pcall(function()
      return snacks.image.placement.new(buf, png, {
        pos = { 1, 0 },
        inline = true,
        auto_resize = false,
        converted = true,
      })
    end)
    assert.is_true(created, "snacks rejected eqnav's placement opts: " .. tostring(err))
  end)

  it("converts a real PNG's height into a sane number of buffer lines", function()
    if skip_unless_snacks() then
      return
    end
    local png =
      vim.fn.glob(vim.fs.joinpath(vim.fn.stdpath("cache"), "eqnav", "*.png"), false, true)[1]
    if not png then
      pending("no cached render available")
      return
    end
    local rows = backend.rows({ tex = "x", display = true, index = 1 }, png, 60)
    assert.is_number(rows)
    assert.is_true(rows >= 1 and rows < 100, "implausible row count: " .. tostring(rows))
  end)

  -- snacks shrinks an image wider than the window to fit it, keeping its aspect,
  -- so it draws in fewer rows than its height alone says. Reserving by height
  -- left a gap under every over-wide equation.
  it("reserves the rows snacks draws an over-wide image in", function()
    if skip_unless_snacks() then
      return
    end
    local raster = require("eqnav.render.raster")
    if not raster.detect() then
      pending("no rasterizer")
      return
    end
    local g = backend.geometry()
    local w, h = math.ceil(40 * g.cell_width), math.ceil(4 * g.cell_height)
    local tmp = vim.fn.tempname()
    local fh = assert(io.open(tmp .. ".svg", "w"))
    fh:write(
      string.format(
        '<svg xmlns="http://www.w3.org/2000/svg" width="%dpx" height="%dpx">'
          .. '<rect width="%d" height="%d" fill="#fff"/></svg>',
        w,
        h,
        w,
        h
      )
    )
    fh:close()
    local png
    raster.convert(tmp .. ".svg", tmp .. ".png", function(p)
      png = p or false
    end)
    assert.is_true(vim.wait(10000, function()
      return png ~= nil
    end))
    assert.is_truthy(png)

    local tall = math.ceil(h / g.cell_height)
    local wide = math.ceil(w / g.cell_width)
    assert.are.equal(tall, backend.rows({ tex = "x" }, png, wide + 10))
    -- Half the width it needs: snacks halves it, and so its height.
    local half = backend.rows({ tex = "x" }, png, math.floor(wide / 2))
    assert.is_true(half < tall, "rows ignored the window width: " .. half)
    assert.are.equal(
      snacks.image.util.fit(png, { width = math.floor(wide / 2), height = tall }).height,
      half
    )
  end)

  it("reads PNG dimensions straight from the IHDR", function()
    -- The fallback path when snacks' own dim() is unavailable. A PNG stores
    -- width and height as big-endian u32 at bytes 17-24.
    local png =
      vim.fn.glob(vim.fs.joinpath(vim.fn.stdpath("cache"), "eqnav", "*.png"), false, true)[1]
    if not png then
      pending("no cached render available")
      return
    end
    local rows = backend.rows({ tex = "x", display = true, index = 1 }, png, 60)
    assert.is_true(rows >= 1)
    -- and a non-PNG must not crash it
    assert.is_number(backend.rows({ tex = "x" }, "/definitely/not/a/file.png", 60))
  end)
end)
