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

--- `bufnr`, shown in the current window: place() draws into the window
--- showing the index, and there is none for a buffer nobody is looking at.
---@param bufnr integer
---@return integer bufnr
local function shown(bufnr)
  vim.api.nvim_win_set_buf(0, bufnr)
  return bufnr
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
    local expected = size and math.max(1, math.floor(4 * 17 / size.cell_height + 0.5)) or 4
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
    local buf = shown(helpers.buf("\n\n\n\n", "markdown"))
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

-- The renderer pads each PNG to whole cells of geometry() and renders it at
-- the display's density, as it does for snacks (#6, #17). Without geometry()
-- the PNGs were unpadded and 1x, and image.nvim drew them a row short (#54).
describe("image.nvim backend geometry", function()
  it("reports the geometry the renderer pads images to", function()
    local g = backend.geometry()
    assert.is_table(g)
    assert.is_true(g.cell_width > 0 and g.cell_height > 0, vim.inspect(g))
    assert.is_true(g.scale >= 1, vim.inspect(g))
  end)

  -- eqnav hands image.nvim the box itself, and image.nvim keeps its rows and
  -- works the columns out from the PNG's aspect. It draws exactly that box when
  -- its aspect-ratio pass gives the box back unchanged, which is what this pins,
  -- on the canvases raster.box makes for it. Fractional cells are the case that
  -- matters: image.nvim's cell is the window's pixel size over its rows. Whole
  -- ones are the other: a canvas of exactly the box's aspect came back a column
  -- wider, floating point pushing a whole number over its ceil().
  it("gets back from image.nvim exactly the box eqnav reserves", function()
    if skip_unless_image() then
      return
    end
    local adjust = require("image/utils/math").adjust_to_aspect_ratio
    local raster = require("eqnav.render.raster")
    for _, cell in ipairs({ { 20, 45 }, { 9.5, 44.8 }, { 8, 17 }, { 16, 32 }, { 7.3, 15.6 } }) do
      local cw, ch = cell[1], cell[2]
      local geom = { cell_width = cw, cell_height = ch, scale = 1, keeps_height = true }
      for w = 3, 900, 29 do
        for h = 1, 200, 7 do
          local ctx = vim.inspect({ cell = cell, w = w, h = h })
          local box = raster.box(w, h, geom)
          assert.is_true(box.width >= math.ceil(w) and box.height >= math.ceil(h), ctx)
          -- The rows the equation needs, and the columns, or one more when the
          -- width is within a px of a whole column.
          local n = math.floor(box.height / ch + 0.5)
          local m = math.ceil(n * ch * (box.width / box.height) / cw)
          assert.are.equal(math.max(1, math.ceil(h / ch)), n, ctx)
          assert.is_true(m * cw >= w and m <= math.max(1, math.ceil(w / cw)) + 1, ctx)
          local aw, ah = adjust(geom, box.width, box.height, m, n)
          assert.are.same({ m, n }, { aw, ah }, ctx)
        end
      end
    end
  end)

  it("reserves the whole cells a padded PNG covers", function()
    local g = backend.geometry()
    local box = require("eqnav.render.raster").box(40, 2.4 * g.cell_height, g)
    local file = helpers.make_png(box.width, box.height)
    if not file then
      return
    end
    assert.are.equal(3, backend.rows({ tex = "x" }, file, 60))
    assert.is_false(backend.overflows(file, 60))
  end)

  -- Wider than the index, the image is drawn narrower, keeping its aspect, so it
  -- takes fewer rows. The number is image.nvim's own.
  it("reserves the rows an over-wide image is drawn in", function()
    local g = backend.geometry()
    local box = require("eqnav.render.raster").box(40 * g.cell_width, 4 * g.cell_height, g)
    local file = helpers.make_png(box.width, box.height)
    if not file then
      return
    end
    assert.are.equal(4, backend.rows({ tex = "x" }, file, 50))
    assert.is_false(backend.overflows(file, 50))
    local half = backend.rows({ tex = "x" }, file, 20)
    assert.is_true(half < 4, "rows ignored the window width: " .. half)
    assert.is_true(backend.overflows(file, 20))
    if available then
      local size = { cell_width = g.cell_width, cell_height = g.cell_height }
      local _, drawn =
        require("image/utils/math").adjust_to_aspect_ratio(size, box.width, box.height, 20, 4)
      assert.are.equal(drawn, half)
    end
  end)
end)

-- image.nvim takes x/y as screen coordinates for an image bound to no window,
-- so every image was drawn at column 0, over the source, and stayed put when
-- the index scrolled (#60).
describe("image.nvim backend placement", function()
  it("binds the image to the index window, on the rows reserved for it", function()
    if skip_unless_image() then
      return
    end
    setup()
    local g = backend.geometry()
    local box = require("eqnav.render.raster").box(10 * g.cell_width - 2, 2.6 * g.cell_height, g)
    local file = helpers.make_png(box.width, box.height)
    if not file then
      return
    end
    local buf = shown(helpers.buf("header\n\n\n\n\n", "markdown"))
    local win = vim.api.nvim_get_current_win()
    local img = backend.place(buf, 2, { tex = "x" }, file)
    assert.is_truthy(img, "image.nvim rejected eqnav's from_file opts")
    assert.are.equal(win, img.window)
    assert.are.equal(buf, img.buffer)
    -- image.nvim draws below its anchor: anchored on the header, the image
    -- starts on the first reserved row.
    assert.are.equal(0, img.geometry.y)
    assert.are.equal(0, img.geometry.x)
    assert.are.same({ 10, 3 }, { img.geometry.width, img.geometry.height })
    -- No virtual lines of its own under the blank rows eqnav reserved.
    assert.is_falsy(img.with_virtual_padding)
    -- The header and the three rows under it: while any of them is scrolled
    -- off the top, image.nvim draws what is left of the image.
    assert.are.equal(4, img.overlap)
    -- Nor shrunk to image.nvim's max_height_window_percentage and friends.
    assert.is_true(img.ignore_global_max_size)
    backend.clear(buf)
  end)

  it("fits an over-wide image to the window it is placed in", function()
    if skip_unless_image() then
      return
    end
    setup()
    local g = backend.geometry()
    local box = require("eqnav.render.raster").box(400 * g.cell_width, 4 * g.cell_height, g)
    local file = helpers.make_png(box.width, box.height)
    if not file then
      return
    end
    local buf = shown(helpers.buf("header\n\n\n\n\n", "markdown"))
    local width = vim.api.nvim_win_get_width(0)
    local img = backend.place(buf, 2, { tex = "x" }, file)
    assert.is_truthy(img)
    -- Asked for the window's width at the full height; image.nvim takes the
    -- rows down to keep the aspect, to the number rows() reserved.
    assert.are.same({ width, 4 }, { img.geometry.width, img.geometry.height })
    local rows = backend.rows({ tex = "x" }, file, width)
    assert.is_true(rows < 4)
    local size = { cell_width = g.cell_width, cell_height = g.cell_height }
    local _, drawn =
      require("image/utils/math").adjust_to_aspect_ratio(size, box.width, box.height, width, 4)
    assert.are.equal(drawn, rows)
    assert.are.equal(rows + 1, img.overlap)
    backend.clear(buf)
  end)

  it("draws nothing for a buffer no window shows", function()
    if skip_unless_image() then
      return
    end
    setup()
    local file = helpers.make_png(64, 32)
    if not file then
      return
    end
    local buf = helpers.buf("header\n\n\n", "markdown")
    assert.is_nil(backend.place(buf, 2, { tex = "x" }, file))
  end)
end)
