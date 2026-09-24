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
    -- Made here, not found in the render cache: CI's cache is always cold, and
    -- a test that needs another spec to have run first never runs there (#56).
    local png = helpers.make_png(64, 32)
    if not png then
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

  it("converts a real PNG's height into the rows it is drawn in", function()
    if skip_unless_snacks() then
      return
    end
    local g = backend.geometry()
    local png = helpers.make_png(64, math.ceil(3 * g.cell_height))
    if not png then
      return
    end
    assert.are.equal(3, backend.rows({ tex = "x", display = true, index = 1 }, png, 60))
  end)

  -- snacks shrinks an image wider than the window to fit it, keeping its aspect,
  -- so it draws in fewer rows than its height alone says. Reserving by height
  -- left a gap under every over-wide equation.
  it("reserves the rows snacks draws an over-wide image in", function()
    if skip_unless_snacks() then
      return
    end
    local g = backend.geometry()
    local w, h = math.ceil(40 * g.cell_width), math.ceil(4 * g.cell_height)
    local png = helpers.make_png(w, h)
    if not png then
      return
    end

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

  -- The index re-renders whenever an image lands, and an unedited one comes out
  -- the same. Closing and reopening a placement that has not changed makes the
  -- terminal drop and redraw it, and the view scrolled into it goes too (#44).
  it("keeps a placement that is placed again unchanged, and swaps a changed one", function()
    if skip_unless_snacks() then
      return
    end
    local first, second = helpers.make_png(64, 32), helpers.make_png(64, 32)
    if not (first and second) then
      return
    end
    local buf = helpers.buf("\n\n\n\n", "markdown")
    local a = backend.place(buf, 2, { tex = "x" }, first)
    assert.is_truthy(a, "snacks refused the placement")
    assert.are.equal(a, backend.place(buf, 2, { tex = "x" }, first))
    assert.is_falsy(a.closed, "an unchanged placement was closed")

    local b = backend.place(buf, 2, { tex = "x" }, second)
    assert.are_not.equal(a, b)
    assert.is_true(a.closed, "the replaced placement was left open")
    assert.is_falsy(b.closed)

    backend.clear(buf)
    assert.is_true(b.closed)
  end)

  it("reads PNG dimensions straight from the IHDR", function()
    -- The fallback path when snacks' own dim() is unavailable. A PNG stores
    -- width and height as big-endian u32 at bytes 17-24.
    local g = backend.geometry()
    local png = helpers.make_png(64, math.ceil(3 * g.cell_height))
    if not png then
      return
    end
    local util = available and snacks.image.util or nil
    local dim = util and util.dim
    if util then
      util.dim = nil
    end
    local called, rows = pcall(backend.rows, { tex = "x", display = true, index = 1 }, png, 60)
    if util then
      util.dim = dim
    end
    assert.is_true(called, tostring(rows))
    assert.are.equal(3, rows)
    -- and a non-PNG must not crash it
    assert.is_number(backend.rows({ tex = "x" }, "/definitely/not/a/file.png", 60))
  end)
end)
