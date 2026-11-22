# agent-mode.nvim

Press a key, say what you want done to the code under your cursor, or ask a
question about it, and an agent does it in place.

```
cursor on `message`  →  ,a  →  Agent: rename to presenter  →  done
cursor on `retry()`  →  ,a  →  Agent: why is this retried twice?
```

```
  2   const message = `Hello, ${user.name}!`;  ⠦ Renaming message to presenter
  3   console.log(message);
  4   return message;
      │ pi: what does this return?
      │ It returns the greeting string `Hello, <user.name>!`, the same text it
      │ logs to the console.
```

- **Changes** are made in the buffer (one undo step each).
- **Answers** show up inline, below the line you asked from. They move with
  the code and never touch the file. `<CR>` on an answer's line opens it
  in place so you can move through it, select, and yank (`q` to go back).
  `]a` / `[a` jump between answers, `<Esc>` dismisses the one nearest the
  cursor, `:AgentModeDismiss!` clears all.
- **While it works**, the line shows a spinner and a one-line status: the
  agent's thinking, the summary it is writing, or the tool it is using.
- **Ask as many as you like**: move through a file firing off requests; each
  answer or edit lands next to its own line, even as lines move. An edit is
  applied only if the lines it replaces are still what the agent saw.

There are two ways to run it.

## Delegate to an Axo Session (`agent = "axo"`)

Neovim runs in an Axo Session's terminal pane with pi in the pane beside it.
agent-mode saves the buffer and sends your instruction, the file, and the
cursor to that pi with `axo session prompt`. It does the change with its own
tools, in view, with the whole conversation as context; no new agent is
started. The status next to the line follows its turn (reading, editing,
running commands) from the Session's transcript. When the turn ends, the
buffer picks up the file's changes, or, if it changed nothing, its reply is
shown inline as an answer. Requests to a Session run one at a time, so each
reply belongs to its question.

```lua
opts = {
  agent = "axo",
  axo = {
    session = "self",     -- the Session Neovim runs in, or a Session UUID
    cmd = "axo",
    timeout_ms = 600000,
  },
}
```

To use Axo when inside it and pi elsewhere:
`agent = vim.env.AXO_SESSION_ID and "axo" or "pi"`.

## Spawn an agent per request (`agent = "pi"`, `"codex"`, or a function)

A fresh agent with no tools sees the buffer, the cursor, your selection, the
diagnostics on the line, and what your language servers can do there
(rename, code actions). It answers with one of:

- **lsp_rename**: a project-wide rename through the language server
- **code_action**: one of the server's code actions at the cursor, picked by name
- **edit**: line edits to the current buffer, applied as one undo step
- **message**: an answer or an explanation when it can't help

The agent itself has no tools and never touches files: agent-mode applies its
reply to the buffer. If you edit the buffer while it is working, the reply is
discarded.

## Install

With lazy.nvim:

```lua
{
  "leostera/agent-mode.nvim",
  opts = {
    agent = "pi",          -- "axo", "pi", "codex", or a function (see below)
    model = nil,           -- nil uses the agent's default model
    thinking = nil,        -- nil: pi "off", codex "low"
    system_prompt = nil,   -- your own instructions, added to agent-mode's
    args = {},             -- extra CLI args for the agent
    keymap = "<leader>a",  -- normal and visual mode; false to skip
  },
}
```

Other options: `answer_keymaps` (`{ dismiss = "<Esc>", next = "]a", prev =
"[a" }`, mapped only in buffers showing answers), `max_lines` (2000; longer buffers are sent as a window around
the cursor), `code_action_timeout_ms` (1000), `timeout_ms` (120000).

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

## Changing settings on the fly

`configure()` changes only what you pass and keeps the rest (`setup()`
starts again from the defaults):

```vim
:lua require("agent_mode").configure({ agent = "axo" })
:lua require("agent_mode").configure({ agent = "pi", model = "sonnet", thinking = "low" })
:lua require("agent_mode").configure({ system_prompt = "Answer like a senior Go reviewer." })
```

`:AgentModeAgent codex` switches the agent (with completion), and
`:AgentModeAgent` alone shows the current one. Running requests finish with
the settings they started with.

## Commands

- `:AgentMode [instruction]`: run an instruction, or prompt for one
- `:AgentModeCancel`: stop the requests on the cursor line, or all of them
- `:AgentModeDismiss[!]`: clear the answer nearest the cursor (all with `!`)
- `:AgentModeAgent [pi|codex|axo]`: show or switch the agent
- `:AgentModeLog`: show the last prompt, command, and raw reply

## Tests

```sh
make test                         # unit + integration (uses lua-language-server if installed)
make test-live AGENTS=pi,codex    # against real agents; costs tokens
AGENT_MODE_AXO_SESSION=<uuid> make test-live AGENTS=axo
```
