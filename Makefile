.PHONY: test test-live

# Unit and integration tests. The language server tests run when
# lua-language-server is on PATH or installed by mason.
test:
	nvim --headless -l tests/unit_spec.lua
	nvim --headless -l tests/integration_spec.lua

# Real agents and models; costs tokens. Pick agents with AGENTS=pi,codex.
AGENTS ?= pi
test-live:
	AGENT_MODE_LIVE=$(AGENTS) nvim --headless -l tests/live_spec.lua
