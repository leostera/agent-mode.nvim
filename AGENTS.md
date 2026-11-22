# agent-mode.nvim

Integration: direct to main.

- Plain Lua for Neovim 0.12+, no dependencies.
- `make test` must pass before landing. Run `make test-live AGENTS=pi,codex`
  when changing the prompt, the protocol, or an agent preset.
- Spawned agents (pi, codex, custom) never edit files. It replies with JSON actions
  (`lua/agent_mode/protocol.lua`), and the plugin applies them. Keep it that
  way: every change goes through the buffer, is one undo step, and is
  discarded if the buffer changed while the agent was working.
- With `agent = "axo"` the Session's agent does edit files; the invariant
  there is that the buffer is saved before the prompt goes out and reloaded
  only if the user has not changed it since.
