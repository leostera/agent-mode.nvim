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
- **Keep the thread.** Every request from one Neovim goes to the same
  conversation, so "do the same for the second caller" or "why did you
  pick that name?" just work.
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
lazy.nvim also installs [snacks.nvim](https://github.com/folke/snacks.nvim),
which draws the settings menu.

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

agent-mode runs your agent's CLI once per request with read-only tools: the
agent can read and search your project (pi also gets codemode), but it never
writes files. It answers, and agent-mode applies the answer to your buffer. Each run continues the same
session, so the agent remembers earlier requests (see
[One conversation per Neovim](#one-conversation-per-neovim)). Your agent's own
login, model access, and billing are used as they are.

| Agent | `agent =` | How it runs | `thinking` |
| --- | --- | --- | --- |
| [Claude Code](https://docs.anthropic.com/claude-code) | `"claude"` | `claude --print --tools Read,Grep,Glob`, `--session-id`/`--resume`, no MCP servers | `--effort`: `low` … `max` |
| [Codex](https://github.com/openai/codex) | `"codex"` | `codex exec --sandbox read-only`, then `codex exec resume <id>` | `model_reasoning_effort`: `minimal` … `high` (default `low`) |
| [OpenCode](https://opencode.ai) | `"opencode"` | `opencode run --agent plan --session <id>` (read-only) | n/a |
| [pi](https://pi.dev) | `"pi"` | `pi --print --tools read,grep,find,ls,codemode --session-id <id>` | `off` … `xhigh` (default `off`) |
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
- `:AgentModeConfig`: a menu to change the agent, model, thinking, Lua,
  conversation, and prompt settings, start a new conversation, or copy your
  settings as Lua for your config. It is drawn by
  [snacks.nvim](https://github.com/folke/snacks.nvim)'s picker, so every list
  is fuzzy-searchable (pi's models, for one); without snacks it falls back to
  `vim.ui.select`
- `:AgentModeNew`: start a new conversation with the agent
- `:AgentModeLog`: show the last prompt, command, session, and raw reply

## One conversation per Neovim

Every request from one Neovim goes to the same agent session, so you can
build on earlier ones: ask why a function exists, then "rename it to match
what you just said"; have it find the callers, then "add a test for the
second one". Each request still shows the agent the buffer as it is now.

The session starts with your first request. It lives in your agent's own
history, so you can open it there later (`claude --resume`, `pi --resume`,
`codex resume`, `opencode`), and it ends when you quit Neovim or run
`:AgentModeNew`.

So that each reply lands in the right place in the conversation, requests in a
session run one at a time: a request asked while another is running shows
"queued" by its line and starts when the first finishes. For requests that
don't need each other, `session = false` runs each one on its own and all at
once, as before.

## Let the agent look around and show you things

Some requests need more than the file you are in: "show me the call graph
starting here", "where else is this used?", "open the tests for this in a
split". The agent splits the work:

- **Its own tools** for anything on disk: it reads and searches your project
  (with codemode in pi) the way it always does.
- **Lua in your Neovim** for what only Neovim has: your language servers,
  unsaved buffers, windows and plugins, and showing you the result in a tab,
  a split, or the quickfix list.

What the Lua returns or prints goes back to the agent, which takes another
step or answers. A request can take up to `max_turns` steps. Asked for the
call graph of a function, pi searched the project for the callers five
levels up with its tools, then sent one piece of Lua to open the graph in a
new tab.

The agent's code works like a code mode:

- `describe()` lists what your Neovim has: its version, the language servers
  on the buffer, your plugins, and helpers.
- `describe("lsp")`, `describe("plugins")`, `describe("commands")`,
  `describe("keymaps")` and `describe("treesitter")` give the details, and
  `describe("telescope.builtin")` lists any module's functions.
- The prompt already includes a one-line summary: the Neovim version, the
  language servers and which of call hierarchy, references, definition and
  type hierarchy each supports, and your lazy.nvim plugins.
- Helpers keep the code short:
  - `am.scratch(lines, { open = "tab" })` shows results in a scratch buffer
    (`q` closes it).
  - `am.lsp(method, params, callback)` asks the buffer's language servers.
  - `am.lines(path)` reads a buffer or file.
- `ctx` says where you are (buffer, window, line, column, selection), and
  `ctx.async()` lets the code wait for language servers or processes without
  blocking the editor.

By default agent-mode shows the code first: `y` runs it, `a` runs it and the
rest of that request's code, and `n` skips it (the agent is told). Set
`lua = "allow"` to skip the question, or `lua = false` to not offer Lua at all.
The code runs with your editor's full permissions, so keep the question on if
you ask about code you don't trust: a file can contain text that tries to
steer the agent.

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
  timeout_ms = 120000,     -- per reply from the agent
  lua = "confirm",         -- let the agent run Lua: "confirm", "allow", or false
  lua_timeout_ms = 10000,  -- how long its asynchronous Lua may take
  max_turns = 8,           -- replies per request; each round of Lua is one
  session = true,          -- one conversation for every request from this Neovim
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
   an LSP rename, one of the listed code actions, line edits, an answer, or
   Lua to run in Neovim, whose result goes back to the agent for another step.
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

## License

MIT. See [LICENSE](LICENSE).
