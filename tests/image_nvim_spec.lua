-- Contract test for the image.nvim display backend (#5).
--
-- The counterpart of snacks_spec.lua. Headless Neovim has no terminal graphics,
-- so pixels are out of reach; what this pins is that the image.nvim API eqnav
-- calls exists and accepts eqnav's arguments, and that eqnav only picks the
-- backend when image.nvim can actually draw.
local backend = require("eqnav.display.image_nvim")
local png = require("eqnav.display.png")
local helpers = require("tests.helpers")

local ok, image = pcall(require, "image")
local available = ok and type(image) == "table"

-- A skip reads exactly like a pass. CI checks image.nvim out deliberately and
-- sets EQNAV_REQUIRE_IMAGE_NVIM, which makes its absence a failure.
if vim.env.EQNAV_REQUIRE_IMAGE_NVIM == "1" and not available then
  error("EQNAV_REQUIRE_IMAGE_NVIM=1 but image.nvim did not load: " .. tostring(image))
end

local function skip_unless_image()
  if not available then
    pending("image.nvim not on the runtimepath")
    return true
  end
  return false
end

local did_setup = false
local function setup()
  if not did_setup then
    -- The kitty backend loads lazily, on first draw, so this emits nothing.
    image.setup({ backend = "kitty" })
    did_setup = true
  end
end

describe("png.size", function()
  it("reads a PNG's width and height from its IHDR", function()
    local file = helpers.make_png(37, 23)
    if not file then
      return
    end
    local w, h = png.size(file)
    assert.are.same({ 37, 23 }, { w, h })
  end)

  it("says 0x0 for anything that is not a PNG", function()
    assert.are.same({ 0, 0 }, { png.size("/definitely/not/a/file.png") })
    assert.are.same({ 0, 0 }, { png.size(nil) })
    local junk = vim.fn.tempname()
    vim.fn.writefile({ "not a png at all, but more than 24 bytes long" }, junk)
    assert.are.same({ 0, 0 }, { png.size(junk) })
  end)
end)

-- Ordered: everything in this block runs before image.nvim's setup().
describe("image.nvim backend, before setup()", function()
  -- until setup() every from_file() throws, so picking this backend would
  -- leave the index a column of blank gaps instead of falling back to text.
  it("is not available", function()
    if skip_unless_image() then
      return
    end
    assert.is_false(backend.available())
  end)

  -- available() tells set-up from not by this message; if it is reworded,
  -- the probe has to change with it.
  it("still reports 'not setup' from from_file", function()
    if skip_unless_image() then
      return
    end
    local called, err = pcall(image.from_file, "/nonexistent/eqnav.png")
    assert.is_false(called)
    assert.is_truthy(tostring(err):find("not setup", 1, true), tostring(err))
  end)

  it("still counts rows, which need nothing from image.nvim", function()
    local file = helpers.make_png(10, 4 * 17)
    if not file then
      return
    end
    -- 17px is the fallback cell height, and what headless always gets.
    local size = available and require("image/utils/term").get_size()
    local expected = size and math.ceil(4 * 17 / size.cell_height) or 4
    assert.are.equal(expected, backend.rows({ tex = "x" }, file, 60))
  end)
end)

describe("image.nvim backend, after setup()", function()
  it("is available", function()
    if skip_unless_image() then
      return
    end
    setup()
    assert.is_true(backend.available())
  end)

  it("calls only image.nvim API that exists", function()
    if skip_unless_image() then
      return
    end
    assert.is_function(image.from_file)
    assert.is_function(require("image/utils/term").get_size)
  end)

  -- get_size() is nil when the terminal will not report its pixel size, which
  -- is every headless run; rows() must then fall back, not divide by nil.
  it("gets cell dimensions it can divide by, or none at all", function()
    if skip_unless_image() then
      return
    end
    local size = require("image/utils/term").get_size()
    if size ~= nil then
      assert.is_true(size.cell_height > 0, vim.inspect(size))
    end
    local file = helpers.make_png(10, 40)
    if not file then
      return
    end
    local rows = backend.rows({ tex = "x" }, file, 60)
    assert.is_true(rows >= 1 and rows < 100, "implausible row count: " .. rows)
  end)

  -- image.nvim requires this module as "image/utils/term". Requiring it by the
  -- dotted name loads a second copy, with its own size cache and autocmd.
  it("shares image.nvim's copy of its terminal-size module", function()
    if skip_unless_image() then
      return
    end
    local file = helpers.make_png(10, 40)
    if not file then
      return
    end
    backend.rows({ tex = "x" }, file, 60)
    assert.is_nil(package.loaded["image.utils.term"])
  end)

  it("gives a non-PNG one row rather than an error", function()
    assert.are.equal(1, backend.rows({ tex = "x" }, "/definitely/not/a/file.png", 60))
  end)

  it("has its placement options accepted, and keeps an unchanged one", function()
    if skip_unless_image() then
      return
    end
    setup()
    local first, second = helpers.make_png(64, 32), helpers.make_png(64, 32)
    if not (first and second) then
      return
    end
    local buf = helpers.buf("\n\n\n\n", "markdown")
    local a = backend.place(buf, 2, { tex = "x" }, first)
    assert.is_truthy(a, "image.nvim rejected eqnav's from_file opts")
    assert.is_function(a.render)
    assert.is_function(a.clear)
    assert.are.equal(a, backend.place(buf, 2, { tex = "x" }, first))

    local b = backend.place(buf, 2, { tex = "x" }, second)
    assert.is_truthy(b)
    assert.are_not.equal(a, b)
    assert.has_no.errors(function()
      backend.clear(buf)
    end)
  end)
end)
