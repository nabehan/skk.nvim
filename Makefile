DEPS_DIR := .tests/site/pack/deps/start
PLENARY := $(DEPS_DIR)/plenary.nvim

.PHONY: test deps

deps:
	@mkdir -p $(DEPS_DIR)
	@[ -d $(PLENARY) ] || git clone --depth=1 https://github.com/nvim-lua/plenary.nvim $(PLENARY)

test: deps
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests { minimal_init = 'tests/minimal_init.lua' }"
