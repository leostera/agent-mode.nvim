# agent-mode.nvim

Ask your coding agent about the code under your cursor, or tell it what to
change, without leaving Neovim. Answers show up right below the line you asked
about, and changes land in the buffer as one undo step.

Works with the agent you already use: **Claude Code**, **Codex**, **OpenCode**,
or **pi**. [agent-mode.leostera.dev](https://agent-mode.leostera.dev)

![Two questions answered inline below their lines, then a block extracted into a function](docs/demo.gif)

<sub>Sped up: the waits for the agent are cut.</sub>

## Why

When you are reading code and something is unclear, or you know exactly what
change you want, switching to a chat window means copying context, explaining
where you are, and copying the result back. agent-mode skips all of that:

- **Ask where you are.** Put the cursor on a line, press `<leader>a`, type a
  question. The agent sees the file, your cursor, your selection, the
  diagnostics on the line, and what your language server can do there.
- **Read the answer in context.** It renders as Markdown right under the line,
  moves with the code, and never touches the file. Press `<CR>` on the line to
  step into it and yank from it.
- **Change code in place.** "rename to presenter", "extract this into a
  function", "add error handling". Renames go through your language server
  when one is attached; other changes are applied to the buffer as a single
  undo step.
- **Keep going.** Fire off as many requests as you like while you move through
  the file. Each shows a live status next to its line, and each answer or edit
  lands next to the line it was about, even as lines move.

## How it compares

Other plugins bring agents into Neovim too. They are built around a chat, a
sidebar, or the agent's own terminal; agent-mode is built around the line you
are on.

| | Where you talk to it | Where answers go | How edits land | Models | Language server |
| --- | --- | --- | --- | --- | --- |
| **agent-mode.nvim** | A box under the cursor | Under the line you asked about | Straight into the buffer, one undo step; several requests at once | The agent CLI you use (Claude Code, Codex, OpenCode, pi) | The agent can pick a rename or code action |
| [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim) | Chat buffer, inline prompt | Chat buffer | Diff to accept or reject | Model APIs, and CLI agents over ACP | Diagnostics as context |
| [avante.nvim](https://github.com/avante-corp/avante.nvim) | Sidebar | Sidebar | Suggested diff to apply | Model APIs, and CLI agents over ACP | Not documented |
| [sidekick.nvim](https://github.com/folke/sidekick.nvim) | The agent's terminal in a split | The agent's terminal | The agent edits files | Any agent CLI, plus Copilot next-edit suggestions | Copilot's suggestions |
| [opencode.nvim](https://github.com/nickjvandyke/opencode.nvim) | Prompt sent to OpenCode | OpenCode's interface | OpenCode edits; accept, reject, reload | OpenCode | No |
| [claudecode.nvim](https://github.com/coder/claudecode.nvim) | Claude Code's terminal | Claude Code's terminal | Diff to accept or reject | Claude Code | No |
| [gp.nvim](https://github.com/Robitx/gp.nvim) | Command or chat buffer | Chat buffer, popup, or the buffer | Rewrite, append, or prepend text | Model APIs | No |

Pick a chat plugin when you want a long conversation about a codebase. Pick
agent-mode when you want a quick answer or change at the line you are on.

## Install

Requires Neovim 0.12+ and one of the agent CLIs below, installed and logged in.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "leostera/agent-mode.nvim",
  opts = {
    agent = "claude", -- "claude", "codex", "opencode", or "pi"
  },
}
```

Then put the cursor somewhere, press `<leader>a`, and type.

## Pick your agent

agent-mode runs your agent's CLI once per request, with no tools: the agent
only answers, and agent-mode applies the answer. Your agent's own login,
model access, and billing are used as they are.

| Agent | `agent =` | How it runs | `thinking` |
| --- | --- | --- | --- |
| [Claude Code](https://docs.anthropic.com/claude-code) | `"claude"` | `claude --print --tools ""`, no session saved, no MCP servers | `--effort`: `low` … `max` |
| [Codex](https://github.com/openai/codex) | `"codex"` | `codex exec --sandbox read-only --ephemeral` | `model_reasoning_effort`: `minimal` … `high` (default `low`) |
| [OpenCode](https://opencode.ai) | `"opencode"` | `opencode run --agent plan` (read-only) | n/a |
| [pi](https://pi.dev) | `"pi"` | `pi --print --no-tools --no-session` | `off` … `xhigh` (default `off`) |
| anything else | a function | see [Custom agents](#custom-agents) | |

Choose a model with `model`, in the format your agent expects:

```lua
opts = {
  agent = "claude",
  model = "sonnet",
  thinking = "low",
}
```

If the CLI is not on Neovim's `PATH` (common when Neovim starts from a GUI),
point at it with `cmd = vim.fn.expand("~/.local/bin/claude")`.

## Use

| Key | Where | What |
| --- | --- | --- |
| `<leader>a` | normal, visual | Ask about, or change, the code at the cursor (or the selection) |
| `<CR>` | on a line with an answer | Step into the answer to scroll, select, and yank; `q` to go back |
| `]a` / `[a` | while answers are shown | Jump to the next / previous answer |
| `<Esc>` | while answers are shown | Dismiss the answer nearest the cursor |

The answer keys exist only in buffers that show an answer, so they do not
change your mappings anywhere else.

Commands:

- `:AgentMode [instruction]`: run an instruction, or open the prompt
- `:AgentModeAgent [name]`: show or switch the agent, with completion
- `:AgentModeCancel`: stop the requests on the cursor line, or all of them
- `:AgentModeDismiss[!]`: clear the answer nearest the cursor (all with `!`)
- `:AgentModeLog`: show the last prompt, command, and raw reply

## Configuration

Everything is optional; these are the defaults.

```lua
require("agent_mode").setup({
  agent = "pi",            -- "claude", "codex", "opencode", "pi", or a function
  cmd = nil,               -- path to the agent's executable
  model = nil,             -- nil: the agent's default
  thinking = nil,          -- reasoning level, passed to the agent
  system_prompt = nil,     -- your own instructions, added to agent-mode's
  args = {},               -- extra CLI arguments for the agent
  keymap = "<leader>a",    -- normal and visual mode; false to skip
  input = "cursor",        -- "cursor": prompt below the cursor; "cmdline": vim.ui.input
  answer_keymaps = { enter = "<CR>", dismiss = "<Esc>", next = "]a", prev = "[a" },
  max_lines = 2000,        -- longer buffers are sent as a window around the cursor
  code_action_timeout_ms = 1000,
  timeout_ms = 120000,
})
```

Change settings while Neovim runs; `configure()` keeps everything you do not
pass:

```vim
:AgentModeAgent codex
:lua require("agent_mode").configure({ model = "opus", thinking = "high" })
:lua require("agent_mode").configure({ system_prompt = "Prefer small, idiomatic changes." })
```

Answers use the `AgentModeAnswer`, `AgentModeAnswerBorder`, and
`AgentModeAnswerTitle` highlight groups, and the prompt uses `AgentModeInput`,
`AgentModeInputBorder`, and `AgentModeInputTitle`. They link to your floating
window colors by default.

### Custom agents

`agent` can be a function that turns a request into a command. The command
must print the reply, and only the reply, on stdout:

```lua
agent = function(request)
  -- request: { system_prompt, prompt, model, thinking, args }
  return {
    argv = { "my-agent", "--quiet", "--model", request.model or "fast" },
    stdin = request.system_prompt .. "\n\n" .. request.prompt,
  }
end
```

## How it works

1. agent-mode snapshots the buffer, cursor, selection, and diagnostics, and
   asks your language servers whether they can rename here and which code
   actions they offer.
2. The agent gets all of that with your instruction, and replies with one JSON
   object: a summary (shown next to the line while it works), and actions:
   an LSP rename, one of the listed code actions, line edits, or an answer.
3. agent-mode checks the reply and applies it. Edits are applied only if the
   lines they replace are still exactly what the agent saw (after accounting
   for lines that moved), so a slow reply never clobbers what you typed.

The agent never writes files itself, and every change is one undo step.

## Hand requests to an agent session you already have open

If you run an agent next to Neovim in [Axo](https://github.com/leostera/axo),
agent-mode can send requests to that session instead of starting a new agent
each time (`agent = "axo"`). That agent works with its own tools and its whole
conversation as context; agent-mode saves the buffer first, shows the agent's
steps next to the line, and brings the buffer up to date, or shows the reply
inline when it only answered.

```lua
opts = {
  agent = vim.env.AXO_SESSION_ID and "axo" or "claude",
  axo = { session = "self", timeout_ms = 600000 },
}
```

## Development

```sh
make test                                  # unit + integration tests
make test-live AGENTS=claude,codex,opencode,pi   # against real agents; costs tokens
```

The integration tests use a scripted agent, and a real `lua-language-server`
when one is installed (on `PATH` or through mason).
