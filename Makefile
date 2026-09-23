.PHONY: test test-lua test-daemon lint fmt clean demo demo-tex demo-cold parsers

NVIM ?= nvim
TREE_SITTER ?= tree-sitter
CC ?= cc

test: test-daemon test-lua

# NOTE: PlenaryBustedDirectory, not PlenaryBustedFile. The directory runner
# spawns a fresh nvim per spec with our minimal_init; the file runner reuses the
# current process, where `require` does not see runtimepath additions and every
# optional-dependency test skips while still reporting success.
test-lua:
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests { minimal_init = 'tests/minimal_init.lua' }"

test-daemon:
	node tests/daemon_xml_spec.mjs

# Interactive harness. Opens a sandboxed nvim -- your ~/.config/nvim is not
# read -- on a fixture covering every symbol family and MathJax package.
demo: .tests/snacks.nvim
	$(NVIM) -u tests/manual_init.lua tests/fixtures/all-symbols.md

demo-tex: .tests/snacks.nvim
	$(NVIM) -u tests/manual_init.lua tests/fixtures/all-symbols.tex

# A warm render cache serves every equation from disk and never starts the node
# daemon, so a warm demo proves nothing about the render path. This is the run
# that actually exercises it.
demo-cold: .tests/snacks.nvim
	XDG_CACHE_HOME=$$(mktemp -d) $(NVIM) -u tests/manual_init.lua tests/fixtures/all-symbols.md

# .tests/ is gitignored; same dependency CI checks out in .github/workflows.
# Without it display.get() returns the text backend and nothing renders.
.tests/snacks.nvim:
	git clone --filter=blob:none --depth 1 https://github.com/folke/snacks.nvim $@

# The `latex` treesitter parser, so the LaTeX query is actually executed rather
# than every .tex test silently taking the regex path. Pinned to the revision
# nvim-treesitter installs, which is what users get from :TSInstall latex.
# tree-sitter-latex does not commit parser.c, so it is generated -- from
# grammar.json, which needs no JS runtime. ABI 14 so Neovim 0.10 can load it.
LATEX_REV := fa8df448fc2c0192a8c2f8cfc97de53cb2b4ecb9

parsers: .tests/parsers/parser/latex.so

.tests/parsers/parser/latex.so:
	rm -rf .tests/tree-sitter-latex
	git init -q .tests/tree-sitter-latex
	git -C .tests/tree-sitter-latex fetch -q --depth 1 \
		https://github.com/latex-lsp/tree-sitter-latex $(LATEX_REV)
	git -C .tests/tree-sitter-latex checkout -q FETCH_HEAD
	cd .tests/tree-sitter-latex && $(TREE_SITTER) generate --abi 14 src/grammar.json
	mkdir -p $(dir $@)
	$(CC) -shared -fPIC -O2 -I.tests/tree-sitter-latex/src \
		.tests/tree-sitter-latex/src/parser.c .tests/tree-sitter-latex/src/scanner.c -o $@

lint:
	stylua --check lua plugin tests

fmt:
	stylua lua plugin tests

clean:
	rm -rf .tests node_modules
