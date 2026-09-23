# Contributing

Bug reports, fixes and ideas are welcome. For anything bigger than a small fix, open an
issue first so the approach can be agreed before you write it.

## Setup

```
npm install        # MathJax, into the plugin directory
make parsers       # optional: the latex treesitter parser, see below
```

The tests and the demo harness also need `rsvg-convert` (or ImageMagick) and, for images,
[snacks.nvim](https://github.com/folke/snacks.nvim). `make demo` clones snacks into `.tests/`
on first run. The Lua tests need [plenary.nvim](https://github.com/nvim-lua/plenary.nvim).
They look for it at `$PLENARY_PATH`, then in lazy.nvim's directory, then at
`.tests/plenary.nvim`, which is where CI puts it:

```
git clone --depth 1 https://github.com/nvim-lua/plenary.nvim .tests/plenary.nvim
```

The image.nvim backend's contract spec needs [image.nvim](https://github.com/3rd/image.nvim)
in the same place. Without it, that spec reports as pending:

```
git clone --depth 1 https://github.com/3rd/image.nvim .tests/image.nvim
```

## Tests

```
make test          # both of the below
make test-daemon   # node tests/daemon_xml_spec.mjs: the MathJax daemon's serialization
make test-lua      # the plenary specs in tests/*_spec.lua
```

`make test-lua` uses `PlenaryBustedDirectory`, never `PlenaryBustedFile`, and so should you.
The directory runner starts a fresh nvim per spec with `tests/minimal_init.lua`. The file
runner reuses the current process, which has your own config loaded and where `require` does
not see runtimepath additions, so every optional-dependency test skips and still reports
success.

### Reproducing CI

Renders are cached by content hash. With a warm cache every equation comes from disk and
the node daemon never starts, so a warm run hides render-path failures that CI, which always
starts cold, will hit. To run the suite the way CI does:

```
XDG_CACHE_HOME=$(mktemp -d) EQNAV_REQUIRE_SNACKS=1 EQNAV_REQUIRE_IMAGE_NVIM=1 \
  EQNAV_REQUIRE_LATEX=1 make test
```

`EQNAV_REQUIRE_SNACKS`, `EQNAV_REQUIRE_IMAGE_NVIM` and `EQNAV_REQUIRE_LATEX` turn a missing
snacks.nvim, image.nvim or latex parser into a failure instead of a skip. Leave out
`EQNAV_REQUIRE_LATEX` if you have not run `make parsers`.

### The latex parser

`make parsers` builds the `latex` treesitter parser into `.tests/`, pinned to the revision
`:TSInstall latex` installs. It needs the `tree-sitter` CLI and a C compiler. With it,
`demo-tex` and the test suite use the treesitter scanner for `.tex`, as CI does. Without it,
they fall back to the regex scanner and the LaTeX treesitter specs report as pending.

## Looking at it

`make test` runs the automated suite. To *look* at the plugin, there is a sandboxed harness
that never reads your own config:

```
make demo        # markdown fixture, treesitter scanner
make demo-tex    # LaTeX fixture + preamble macros
make demo-cold   # as demo, but with a throwaway render cache
```

Each opens `tests/fixtures/all-symbols.*` in a Neovim that has only this plugin, plenary and
snacks on its runtimepath. The fixture has every symbol family and every MathJax package the
daemon loads, one display equation per row. Run `:Eqnav` and walk the index with `j`/`k`.
Each entry's header names the section it came from, so the heading above a broken row tells
you which row it is.

**Prefer `make demo-cold`.** As with the tests, a warm cache never starts Node, so a warm
run is no evidence that the render path works. If you changed anything on the render path,
look at a cold run before opening the PR.

Two variants are worth a look as well:

```
EQNAV_DEMO_INLINE=1 make demo   # index inline $x$ too
EQNAV_DEMO_POS=float make demo  # float window instead of a right split
```

### Demo assets

The README's sketch, `doc/demo.gif` and `doc/demo-export.png` all show one document,
`doc/demo.md`. Keep it to constructs the fixture already proves render. If the UI or that
document changes, regenerate the assets, each from a cold cache:

```
scripts/record-demo.sh export          # doc/demo-export.png: headless, needs Chrome
scripts/record-demo.sh record          # prints the steps, then opens the demo to record
scripts/record-demo.sh gif FILE.mov    # the recording -> doc/demo.gif, needs ffmpeg
```

The GIF needs a terminal that draws images, so it cannot be made headlessly: `record` opens
the sandbox in yours, and you run the screen recorder. If an asset shows a rendering bug,
file it. Don't retouch the picture.

## Style

Lua is formatted with [StyLua](https://github.com/JohnnyMorganz/StyLua) (`.stylua.toml`):

```
make fmt           # format
make lint          # check, as CI does
```

`doc/eqnav.txt` is hand-written. If you change behaviour, commands, options or the Lua API,
update it along with the README. `tests/docs_spec.lua` checks the command and API lists
against the code.

## Commits

History follows `type(scope): summary`, lower case and in the imperative:

```
fix(scan): index a nested environment once, not twice
perf(view): coalesce index rebuilds while renders stream in
test(fixtures): record what remains after #8, #10 and #11
```

- **type**: `fix`, `feat`, `perf`, `test`, `docs`, `ci`, `chore`.
- **scope**: the module the change is in: `view`, `render`, `scan`, `daemon`, `config`,
  `export`, `fixtures`. Leave it out when a change spans several.

The body says why: what was broken, and why this is the fix. Reference the issue with
`Fixes #N`.
