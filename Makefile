.PHONY: test test-lua test-daemon lint fmt clean demo demo-tex demo-cold

NVIM ?= nvim

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

lint:
	stylua --check lua plugin tests

fmt:
	stylua lua plugin tests

clean:
	rm -rf .tests node_modules
