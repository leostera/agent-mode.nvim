.PHONY: test test-live typecheck deps

# The plugins agent-mode uses, for the tests: in .deps/, or set NUI to a
# checkout you already have.
NUI ?= .deps/nui.nvim
deps: $(NUI)
$(NUI):
	git clone --quiet --depth 1 https://github.com/MunifTanjim/nui.nvim $(NUI)

# Unit and integration tests. The language server tests run when
# lua-language-server is on PATH or installed by mason.
export AGENT_MODE_NUI = $(abspath $(NUI))
test: deps
	nvim --headless -l tests/unit_spec.lua
	nvim --headless -l tests/integration_spec.lua

# Real agents and models; costs tokens. Pick agents with
# AGENTS=claude,codex,opencode,pi (and axo with AGENT_MODE_AXO_SESSION set).
AGENTS ?= pi
test-live: deps
	AGENT_MODE_LIVE=$(AGENTS) nvim --headless -l tests/live_spec.lua

# Type-check lua/ and plugin/ with lua-language-server against Neovim's
# runtime (LuaCATS annotations).
LUA_LS ?= lua-language-server
typecheck:
	VIMRUNTIME=$$(nvim --clean --headless -c 'lua io.stdout:write(vim.env.VIMRUNTIME)' +qa) \
	  $(LUA_LS) --check . --checklevel=Warning --configpath=.luarc.json
