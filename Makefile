# gg.nvim test harness. `make test` runs the whole mini.test suite headless.
NVIM ?= nvim
MINI_VERSION ?= v0.18.0
MINI_DIR := deps/mini.nvim
FILE ?=

.PHONY: test test-file deps clean

test: $(MINI_DIR)
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua require([[tests.run]]).run()"

# Run a single test file: make test-file FILE=tests/unit/core/test_task.lua
test-file: $(MINI_DIR)
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua require([[tests.run]]).run([[$(FILE)]])"

deps: $(MINI_DIR)

$(MINI_DIR):
	git clone --filter=blob:none --depth 1 --branch $(MINI_VERSION) https://github.com/nvim-mini/mini.nvim $(MINI_DIR)

clean:
	git clean -fdX deps
