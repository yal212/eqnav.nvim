.PHONY: test test-lua test-daemon lint fmt clean

NVIM ?= nvim

test: test-daemon test-lua

test-lua:
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests { minimal_init = 'tests/minimal_init.lua' }"

test-daemon:
	node tests/daemon_xml_spec.mjs

lint:
	stylua --check lua plugin tests

fmt:
	stylua lua plugin tests

clean:
	rm -rf .tests node_modules
