# Changelog

All notable changes to eqnav.nvim are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- A TeX parse error such as `\frac{a}` rendered as a solid block with no
  readable text: its box and its text were both drawn in the foreground
  colour. The error is now red text on a translucent red box, in the index and
  in the export (#62).
- The image.nvim backend drew every image at the left of the screen, over the
  source, and left it there when the index scrolled. It also hung its own
  blank rows under each image, on top of the ones eqnav reserves. Images now
  sit on their entry's rows in the index window and scroll with it (#60).
- The image.nvim backend drew most images a row shorter than eqnav reserved,
  squashed to fit, and shrank tall ones to half the window. Equations are now
  rendered at the display's density and padded to the cells image.nvim draws,
  and shown 1:1 in exactly the rows reserved (#54).

## [0.1.0] - 2026-09-24

The first release: an index of a document's rendered equations, as asked for in
[nvim-lua/wishlist#51](https://github.com/nvim-lua/wishlist/issues/51).

### Added

- The index: a separate, prose-free page of the document's rendered equations.
  `j`/`k` move by equation, `<CR>` jumps to it in the source, `o` jumps and
  keeps the index open, `y` yanks its source, `r` re-renders, `gx` exports and
  `q` closes.
- Commands `:Eqnav`, `:EqnavOpen`, `:EqnavClose`, `:EqnavRefresh[!]`,
  `:EqnavPick`, `:EqnavExport [path]` and `:EqnavClearCache`.
- A Lua API: `open`, `close`, `toggle`, `is_open`, `refresh`, `equations`,
  `pick`, `export_html` and `clear_cache`.
- Scanning for Markdown, Quarto, R Markdown and LaTeX, with treesitter first and
  a regex scanner as the fallback. Jump targets are tracked with extmarks, so
  they stay right while the document is edited above them.
- Rendering through MathJax, in a long-lived Node daemon: no TeX distribution
  needed. Renders are cached by content hash, follow the colorscheme's
  foreground, and pick up a LaTeX preamble's `\newcommand`, `\renewcommand`
  and `\DeclareMathOperator`.
- Display backends for snacks.nvim and image.nvim, and a text backend that
  shows LaTeX source where the terminal has no graphics.
- Live sync: the index re-scans and re-renders as you edit.
- `:EqnavExport`, a self-contained HTML page of every equation that follows the
  browser's light or dark preference.
- A telescope picker, `:EqnavPick`.
- `:checkhealth eqnav`, covering Neovim, Node and MathJax, the rasterizer, the
  image backend, the terminal, the treesitter parsers and the cache.

### Fixed

- A daemon that had exited no longer clobbers the one that replaced it.
- Every math environment rendered as "Erroneous nesting of equation
  structures", and `\mathbb`, `\mathfrak`, Hebrew letters and `\require` never
  rendered (#8, #10).
- `\ce{...}` renders: mhchem's font extension is now loaded.
- `\dag`, `\ddag` and `\P`, which MathJax does not ship, are defined (#16).
- Pandoc `{#eq:...}` labels are stripped before rendering (#11).
- A second render of the same `\label` no longer errors with "multiply
  defined" (#15).
- An equation with `\tag` rasterized to a blank image (#40).
- Inline equations were rendered only up to their first possible line break
  (#46).
- A nested environment such as `cases` inside `equation` was indexed twice
  (#9).
- With the latex parser installed, every Markdown equation was listed twice
  (#36).
- The treesitter LaTeX scanner missed `equation`, `align`, `gather` and
  `multline` (#1), and a scan that captured nothing was taken as "no math"
  instead of falling back to the regex scanner (#20).
- A stale render could paint the wrong image after an edit (#2).
- Rendered images stayed on the terminal after the index closed or Neovim
  exited (#12).
- The last entry's image could not be scrolled into view (#18), and a one-row
  entry's image was left below the index under `j`/`k` (#38).
- Images were drawn at a size eqnav had not reserved rows for, and stretched by
  up to 2x. They are now rendered at the display's pixel density and padded to
  whole cells (#6, #17).
- An equation wider than the index is broken over lines to fit, instead of
  being shrunk (#41).
- `r` in the index moved the cursor to a different entry (#44).
- The index rebuild was O(n²) while images streamed in (#3).
- `:EqnavExport` never finished when `render.enabled` was false (#47).
- The image.nvim backend loaded a second copy of image.nvim's terminal-size
  module, and was picked even when image.nvim had not been set up (#5).
- typst was listed as a supported filetype, though it is not supported (#4).

[Unreleased]: https://github.com/yal212/eqnav.nvim/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/yal212/eqnav.nvim/releases/tag/v0.1.0
