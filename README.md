# eqnav.nvim

A separate, prose-free page of your document's **rendered** equations. Walk it with
`j`/`k`, press `<CR>`, and land on that equation in the source.

```
 eqnav · 16 equations · so-easy-rsa-en.md          │  ## Observation
                                                   │
   1  Observation                          L72     │  The generator advances by
      s_{t+1} ≡ (s_t · A + B)  (mod M)             │
                                                   │  $$
   2  Action                               L93     │  s_{t+1} \equiv (s_t \cdot
      p ≡ (s_p + A)  (mod M)                       │  $$
                                                   │
   3  Action                               L95     │  which means we can walk it
      s_p ≡ (p - A)  (mod M)                       │  backwards…
```

## Why

This implements [nvim-lua/wishlist#51](https://github.com/nvim-lua/wishlist/issues/51),
open since 2023. The request was specific:

> a separate page just for equations, like being able to j/k up and down the rendered
> equations without the text around … links that allow going from the equations page to
> the location of the equation in the original page

The motivation is context-switch cost. Hunting for an equation by jumping through the
document means bouncing between prose and math, and every bounce costs a refocus before
you can decide *"no, not that one."* An index with the prose stripped out is faster to
scan than the document is.

Neovim has excellent **inline** math preview — [`mdmath.nvim`][mdmath],
[`render-latex.nvim`][renderlatex], [`latex-preview.nvim`][latexpreview],
[`nabla.nvim`][nabla], neorg. None of them do the indexed view. eqnav is only that: the
index and the jump-back. Rendering is something it consumes, not something it invents.

## Requirements

| | |
|---|---|
| **Neovim** | 0.10+ |
| **Node.js** | 18+ — runs MathJax. No TeX distribution needed. |
| **A rasterizer** | `rsvg-convert` (`brew install librsvg`, `apt install librsvg2-bin`) or ImageMagick |
| **An image backend** | [snacks.nvim][snacks] with `image.enabled`, or [image.nvim][imagenvim] |
| **A graphics terminal** | Kitty, Ghostty, WezTerm, or iTerm2 (see [tmux](#tmux) below) |

Neovim and Node are required: Node is what renders, so without it there is no rendered
math anywhere, in the index or in `:EqnavExport`. The other three degrade gracefully.
Without a rasterizer, image backend or graphics terminal, the index shows LaTeX source,
and `:EqnavExport` still produces a fully rendered HTML page. Run `:checkhealth eqnav`
to see which piece is missing.

## Install

With [lazy.nvim][lazy]. The `build` step installs MathJax into the plugin directory.

```lua
{
  "yal212/eqnav.nvim",
  build = "npm install",
  dependencies = {
    "folke/snacks.nvim",      -- optional: renders equations as images
    "nvim-telescope/telescope.nvim", -- optional: :EqnavPick
  },
  -- Must cover `filetypes` below: `ft` decides whether eqnav loads at all.
  ft = { "markdown", "quarto", "rmd", "tex", "latex", "plaintex" },
  opts = {},
  keys = {
    { "<leader>e", "<cmd>Eqnav<cr>", desc = "Equation index" },
  },
}
```

Make sure snacks has images on:

```lua
{ "folke/snacks.nvim", opts = { image = { enabled = true } } }
```

## Use

| Command | |
|---|---|
| `:Eqnav` | toggle the index |
| `:EqnavOpen` / `:EqnavClose` | open / close the index |
| `:EqnavRefresh[!]` | re-scan (`!` bypasses the render cache) |
| `:EqnavPick` | fuzzy-find an equation (telescope) |
| `:EqnavExport [path]` | export to a self-contained HTML page and open it |
| `:EqnavClearCache` | drop every cached render |

Inside the index:

| Key | |
|---|---|
| `j` / `k` | next / previous **equation** (not line) |
| `<CR>` | jump to the source and close |
| `o` | jump to the source, keep the index open |
| `y` | yank the equation's source |
| `r` | force re-render |
| `gx` | export to HTML |
| `q` | close |

## Configuration

Defaults shown; pass only what you want to change.

```lua
require("eqnav").setup({
  -- Typst is not supported: its math is not TeX, and it separates inline from
  -- display by the whitespace after `$`, so it needs its own query and its own
  -- renderer. Add "typst" here if you want to experiment anyway.
  filetypes = { "markdown", "quarto", "rmd", "tex", "latex", "plaintex" },

  -- Index inline $x$ as well as display $$..$$. Off by default: the point of
  -- the index is to escape noise, and inline math is mostly single symbols.
  include_inline = false,

  window = {
    position = "right", -- right|left|top|bottom|float|tab
    width = 60,
    height = 15,
  },

  render = {
    enabled = true,
    ex = 9,           -- CSS px per TeX `ex`; the equation-size knob
    color = nil,      -- nil follows the Normal highlight's foreground
    concurrency = 8,
    node = "node",
    rasterizer = nil, -- nil auto-detects rsvg-convert, then ImageMagick
  },

  display = { backend = "auto" }, -- auto|snacks|image_nvim|text

  sync = {
    live = true,     -- re-scan and re-render as you edit
    debounce = 300,
    follow = false,  -- also move the source window to match the index cursor
  },

  keymaps = {
    next = "j", prev = "k", jump = "<CR>", jump_keep = "o",
    yank = "y", refresh = "r", export = "gx", close = "q",
  },
})
```

### Lua API

```lua
local eqnav = require("eqnav")
eqnav.open()           -- also close(), toggle()
eqnav.is_open()        --> boolean  (for a statusline or a conditional keymap)
eqnav.refresh(force)   -- re-scan; force bypasses the render cache
eqnav.equations(bufnr) --> eqnav.Equation[]  (scan without opening anything)
eqnav.pick(opts)       -- the telescope picker behind :EqnavPick
eqnav.export_html(path)
eqnav.clear_cache()    --> number of files removed
```

`:help eqnav-api` has the details.

## How it works

```
scan/     buffer   → Equation[]        treesitter first, regex fallback
render/   Equation → png + svg         MathJax daemon, content-hash cached
display/  png      → pixels            snacks → image.nvim → text
view.lua  the index buffer, navigation, jump-back
```

A few things worth knowing:

**Scanning uses treesitter where it can.** That is what keeps `$x$` inside a fenced code
block — or a bare `cost = "$5"` — out of your index. A regex scanner cannot see the fence.
Where no parser is installed eqnav falls back to delimiter matching and says so in
`:checkhealth`.

**Positions are tracked with extmarks, not line numbers**, so `<CR>` still lands on the
right line after you have edited the document above an equation.

**Renders are cached by content hash**, so reopening the index on an unchanged document
is instant and never starts Node at all. The foreground colour is part of the hash, which
is how equations follow your colorscheme instead of staying black on a dark background.

**The index appears before the images do.** Scanning is synchronous and fast; headers are
drawn immediately and images fill in as they arrive.

**Every entry is drawn at the same size.** Display math wider than the index is broken over
lines to fit it. An equation that can't be broken, such as a wide matrix, is shrunk to fit
instead and its header is marked `⟷`. After resizing the index, press `r` to render for the
new width.

### tmux

Terminal graphics need passthrough:

```tmux
set -g allow-passthrough on
```

`:checkhealth eqnav` reports whether it is set. If images still do not appear, the text
backend and `:EqnavExport` both work everywhere.

### LaTeX documents

Install the parser for the best results:

```vim
:TSInstall latex
```

eqnav reads `\newcommand`, `\renewcommand` and `\DeclareMathOperator` out of the preamble
and passes them to MathJax, so a document's own macros resolve. MathJax is not TeX,
though — equations depending on real LaTeX packages may not render identically.

### Testing locally

`make test` runs the automated suite. To *look* at the plugin, there is a
sandboxed harness that never reads your own config:

```
make demo        # markdown fixture, treesitter scanner
make demo-tex    # LaTeX fixture + preamble macros (see below for the scanner)
make demo-cold   # as demo, but with a throwaway render cache
```

`make parsers` builds the `latex` treesitter parser into `.tests/`, pinned to
the revision `:TSInstall latex` installs. It needs the `tree-sitter` CLI and a
C compiler. With it, `demo-tex` and the test suite use the treesitter scanner
for `.tex`, as CI does. Without it, they fall back to the regex scanner and
the LaTeX treesitter specs report as pending.

Each opens `tests/fixtures/all-symbols.*` — every symbol family and every
MathJax package the daemon loads, one display equation per row — in a Neovim
that has only this plugin, plenary and snacks on its runtimepath. Press
`:Eqnav` and walk the index with `j`/`k`; each entry's header names the section
it came from, so a broken row is identified by the heading above it.

**Prefer `make demo-cold`.** Renders are cached by content hash, so a warm
cache serves every equation from disk and never starts Node — a warm run is not
evidence that the render path works. `demo-cold` points `XDG_CACHE_HOME` at a
throwaway directory, which is also how to reproduce CI locally:

```
XDG_CACHE_HOME=$(mktemp -d) EQNAV_REQUIRE_SNACKS=1 make test
```

Two variants are worth a look as well:

```
EQNAV_DEMO_INLINE=1 make demo   # index inline $x$ too
EQNAV_DEMO_POS=float make demo  # float window instead of a right split
```

## Credits

The MathJax daemon's architecture — a long-lived process speaking newline-delimited JSON,
and crucially the use of `adaptor.serializeXML` rather than `innerHTML` — follows
[`latex-preview.nvim`][latexpreview], whose author worked out that MathJax 4 writes raw
TeX into `data-latex` attributes and that `rsvg-convert` rejects the resulting invalid
XML. That saved a long afternoon.

Thanks to `userrand` for [the original request][issue] and to `benlubas` for the neorg
renderer work discussed in that thread.

## License

MIT

[issue]: https://github.com/nvim-lua/wishlist/issues/51
[mdmath]: https://github.com/Thiago4532/mdmath.nvim
[renderlatex]: https://github.com/techwizrd/render-latex.nvim
[latexpreview]: https://github.com/sonv/latex-preview.nvim
[nabla]: https://github.com/jbyuki/nabla.nvim
[snacks]: https://github.com/folke/snacks.nvim
[imagenvim]: https://github.com/3rd/image.nvim
[lazy]: https://github.com/folke/lazy.nvim
