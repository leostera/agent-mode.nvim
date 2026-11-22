-- agent-mode's settings: their types, defaults, and checks.
--
-- Settings come from, in order: the defaults below, the `vim.g.agent_mode`
-- table (or a function returning one), and `setup(opts)` / `configure(opts)`.
-- None of them is required; the plugin works with the defaults.

local M = {}

---@alias agent_mode.AgentName "pi"|"claude"|"codex"|"opencode"|"axo"

---@class agent_mode.AgentRequest
---@field system_prompt string
---@field prompt string
---@field model string|nil
---@field thinking string|nil
---@field args string[]
---@field session { id: string|nil, started: boolean }|nil

---@class agent_mode.AgentCommand
---@field argv string[]
---@field stdin string|nil
---@field output "text"|"pi-json"|nil
---@field session_id string|nil
---@field read_session_id (fun(result: vim.SystemCompleted): string|nil)|nil

---@class agent_mode.AnswerKeymaps
---@field enter? string|false
---@field dismiss? string|false
---@field next? string|false
---@field prev? string|false

---@class agent_mode.AxoOptions
---@field session? string
---@field cmd? string
---@field timeout_ms? integer

--- What you can set; every field is optional.
---@class agent_mode.Config
---@field agent? agent_mode.AgentName|fun(request: agent_mode.AgentRequest): agent_mode.AgentCommand
---@field cmd? string Path to the agent's executable
---@field axo? agent_mode.AxoOptions
---@field model? string
---@field thinking? string
---@field system_prompt? string
---@field args? string[]
---@field keymap? string|false Deprecated: map <Plug>(AgentMode) instead
---@field input? "cursor"|"cmdline"
---@field answer_keymaps? agent_mode.AnswerKeymaps
---@field max_lines? integer
---@field code_action_timeout_ms? integer
---@field timeout_ms? integer
---@field lua? "confirm"|"allow"|false
---@field lua_timeout_ms? integer
---@field max_turns? integer
---@field session? boolean

---@type agent_mode.Config
M.defaults = {
  -- Which agent answers:
  --   "pi", "claude", "codex", "opencode", or a function(request) returning
  --     { argv, stdin } (see lua/agent_mode/agents.lua): a fresh agent per
  --     request, without tools, replies with JSON actions that agent-mode
  --     applies to the buffer.
  --   "axo": the agent of an Axo Session (see `axo` below) gets the request
  --     and edits the file itself; agent-mode reloads the buffer afterwards.
  agent = "pi",
  -- Path to the agent's executable, when it is not on Neovim's PATH.
  cmd = nil,
  axo = {
    -- The Session to send requests to: "self" is the Session Neovim runs in.
    session = "self",
    -- The axo CLI.
    cmd = "axo",
    -- The session's agent works with tools and may take a while.
    timeout_ms = 600000,
  },
  -- Model to ask for, or nil for the agent's own default.
  model = nil,
  -- Reasoning level, passed through to the agent (pi: off..xhigh, codex:
  -- minimal..high). nil uses agent-mode's per-agent default: pi "off",
  -- codex "low", since edits at the cursor should be quick.
  thinking = nil,
  -- Your own instructions, appended to agent-mode's system prompt. The JSON
  -- reply format always stays in place.
  system_prompt = nil,
  -- Extra command-line arguments for the agent.
  args = {},
  -- Deprecated: map <Plug>(AgentMode) yourself instead. A key here still
  -- maps it, with a warning.
  keymap = false,
  -- Where the prompt opens: "cursor" for a small window right below the
  -- cursor, or "cmdline" for vim.ui.input (the command line, or whatever
  -- UI plugin replaces it).
  input = "cursor",
  -- Normal mode keys mapped in a buffer while it shows answers: open the
  -- answer on the cursor line to move through and yank from (elsewhere the
  -- key does what it always does), dismiss the answer nearest the cursor,
  -- and jump to the next or previous one. false skips a key.
  answer_keymaps = { enter = "<CR>", dismiss = "<Esc>", next = "]a", prev = "[a" },
  -- Buffers longer than this are sent as a window around the cursor.
  max_lines = 2000,
  -- How long to wait for language servers to list code actions.
  code_action_timeout_ms = 1000,
  -- How long to wait for each reply from the agent before giving up.
  timeout_ms = 120000,
  -- Whether the agent may run Lua in Neovim to look things up (references,
  -- the call hierarchy, other files) and show them (tabs, splits, quickfix).
  -- What the code returns goes back to the agent for its next step.
  --   "confirm": show the code and ask first (y run, a run all for this
  --     request, n skip)
  --   "allow": run it without asking
  --   false: the agent is not offered Lua
  lua = "confirm",
  -- How long Lua that called ctx.async() may take to call done().
  lua_timeout_ms = 10000,
  -- How many replies a request may take; each round of Lua is one more.
  max_turns = 8,
  -- Send every request from this Neovim to one conversation with the agent,
  -- so you can refer to earlier questions, answers and results. Requests
  -- then run one at a time, in order. :AgentMode new starts a fresh one.
  -- false runs each request on its own, all at once.
  session = true,
}

---@type agent_mode.Config|fun(): agent_mode.Config|nil
vim.g.agent_mode = vim.g.agent_mode

--- The `vim.g.agent_mode` settings, if any.
---@return agent_mode.Config
function M.from_globals()
  local g = vim.g.agent_mode
  if type(g) == "function" then
    g = g()
  end
  return type(g) == "table" and g or {}
end

--- Keys in `opts` that are not settings, e.g. typos, as dotted paths.
---@param opts table
---@return string[]
function M.unknown_keys(opts)
  local unknown = {}
  local function walk(given, known, prefix)
    for key, value in pairs(given) do
      local path = prefix .. tostring(key)
      if known[key] == nil and not (prefix == "" and (key == "model" or key == "thinking" or key == "cmd" or key == "system_prompt")) then
        unknown[#unknown + 1] = path
      elseif type(value) == "table" and type(known[key]) == "table" and not vim.islist(known[key]) then
        walk(value, known[key], path .. ".")
      end
    end
  end
  walk(opts, M.defaults, "")
  table.sort(unknown)
  return unknown
end

local function one_of(values)
  return function(value)
    return vim.tbl_contains(values, value), "one of " .. table.concat(vim.tbl_map(vim.inspect, values), ", ")
  end
end

--- Check a merged config. Returns an error message, or nil when it is fine.
---@param config agent_mode.Config
---@return string|nil err
function M.check(config)
  local ok, err = pcall(function()
    vim.validate("agent", config.agent, { "string", "function" })
    vim.validate("cmd", config.cmd, "string", true)
    vim.validate("model", config.model, "string", true)
    vim.validate("thinking", config.thinking, "string", true)
    vim.validate("system_prompt", config.system_prompt, "string", true)
    vim.validate("args", config.args, "table")
    vim.validate("keymap", config.keymap, { "string", "boolean" }, true)
    vim.validate("input", config.input, one_of({ "cursor", "cmdline" }))
    vim.validate("answer_keymaps", config.answer_keymaps, "table")
    vim.validate("max_lines", config.max_lines, "number")
    vim.validate("code_action_timeout_ms", config.code_action_timeout_ms, "number")
    vim.validate("timeout_ms", config.timeout_ms, "number")
    vim.validate("lua", config.lua, one_of({ "confirm", "allow", false }))
    vim.validate("lua_timeout_ms", config.lua_timeout_ms, "number")
    vim.validate("max_turns", config.max_turns, "number")
    vim.validate("session", config.session, "boolean")
    vim.validate("axo", config.axo, "table")
    vim.validate("axo.session", config.axo.session, "string")
    vim.validate("axo.cmd", config.axo.cmd, "string")
    vim.validate("axo.timeout_ms", config.axo.timeout_ms, "number")
  end)
  if not ok then
    return (tostring(err):gsub("^.-:%d+: ", ""))
  end
  if config.agent ~= "axo" then
    local _, agent_err = require("agent_mode.agents").resolve(config.agent)
    return agent_err
  end
  return nil
end

return M
