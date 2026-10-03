LUA_PATHS := lua plugin tests

NVIM ?= nvim
STYLUA ?= stylua
LUACHECK ?= luacheck
UV ?= uv

# Headless Chrome used by the browser checks; tests/browser/chrome.py reads it from MP_CHROME.
# Exported so a path with spaces (the macOS default) needs no quoting in recipes.
ifeq ($(shell uname -s),Darwin)
MP_CHROME ?= /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
else
MP_CHROME ?= $(firstword $(shell command -v google-chrome google-chrome-stable chromium chromium-browser 2>/dev/null))
endif
export MP_CHROME

# The specs reuse an existing plenary.nvim checkout when PLENARY_DIR points at one; otherwise
# tests/minimal_init.lua clones it into the system temp directory.
SPEC_DIR := tests
MINIMAL_INIT := tests/minimal_init.lua

.PHONY: check lint format test test-browser

check: lint test

lint:
	$(STYLUA) --check $(LUA_PATHS)
	$(LUACHECK) $(LUA_PATHS)

format:
	$(STYLUA) $(LUA_PATHS)

test:
	$(NVIM) --headless --noplugin -u $(MINIMAL_INIT) \
		-c "PlenaryBustedDirectory $(SPEC_DIR) { minimal_init = '$(MINIMAL_INIT)', sequential = true }"

test-browser:
	@test -n "$(MP_CHROME)" || { echo "MP_CHROME is empty: install Chrome or set MP_CHROME" >&2; exit 1; }
	$(UV) run tests/browser/check_render.py
	$(UV) run tests/browser/check_sync.py
