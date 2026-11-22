-- How to run each supported agent CLI.
--
-- An agent is a function that turns a request into a command:
--
--   agent(request) -> { argv = { ... }, stdin = "...", output = "text"|"pi-json" }
--
-- where request is
--
--   {
--     system_prompt = string,   -- the agent-mode protocol plus the user's own system_prompt
--     prompt = string,          -- the buffer, cursor, and instruction
--     model = string|nil,       -- nil means the agent's default model
--     thinking = string|nil,    -- nil means the agent's default reasoning level
--     args = string[],          -- extra arguments from the user's config
--   }
--
-- With output = "text" (the default) the command must print the agent's final
-- reply, and nothing else, on stdout. With "pi-json" it prints pi's JSON event
-- stream, which lets agent-mode show the agent's thinking as it happens.
-- No agent gets tools: it only answers, and agent-mode applies the answer.

local M = {}

--- Output decoders turn an agent's stdout, chunk by chunk, into progress
--- events and, at the end, the reply text.
---   decoder.feed(chunk) -> { { kind = "thinking"|"text", delta = string }, ... }
---   decoder.reply()     -> string
M.decoders = {}

function M.decoders.text()
  local chunks = {}
  return {
    feed = function(chunk)
      chunks[#chunks + 1] = chunk
      return { { kind = "text", delta = chunk } }
    end,
    reply = function()
      return table.concat(chunks)
    end,
  }
end

local function message_text(message)
  local parts = {}
  for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
    if block.type == "text" and type(block.text) == "string" then
      parts[#parts + 1] = block.text
    end
  end
  return table.concat(parts)
end

--- pi --mode json: one JSON event per line.
M.decoders["pi-json"] = function()
  local pending = ""
  local streamed = {}
  local final = nil
  return {
    feed = function(chunk)
      local events = {}
      pending = pending .. chunk
      -- Split complete lines with plain finds: patterns like "[^\n]*$" are
      -- quadratic on long lines, and pi's events carry whole prompts.
      local start = 1
      while true do
        local newline = pending:find("\n", start, true)
        if not newline then
          break
        end
        local line = pending:sub(start, newline - 1)
        start = newline + 1
        local ok, event = pcall(vim.json.decode, line)
        if ok and type(event) == "table" then
          local update = event.assistantMessageEvent
          if event.type == "message_update" and type(update) == "table" and type(update.delta) == "string" then
            if update.type == "thinking_delta" then
              events[#events + 1] = { kind = "thinking", delta = update.delta }
            elseif update.type == "text_delta" then
              streamed[#streamed + 1] = update.delta
              events[#events + 1] = { kind = "text", delta = update.delta }
            end
          elseif event.type == "message_end" and type(event.message) == "table" and event.message.role == "assistant" then
            final = message_text(event.message)
          end
        end
      end
      pending = pending:sub(start)
      return events
    end,
    reply = function()
      return final or table.concat(streamed)
    end,
  }
end

--- Some agents take their system prompt as a file: pi kills itself when an
--- argument is longer than about 1 KB with some extensions loaded.
local function system_prompt_file(text)
  local path = vim.fn.tempname()
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
  return path
end

--- pi (https://pi.dev). Takes the system prompt as a file and the request on
--- stdin. The prompt goes through a file because some pi extensions kill the
--- process when an argument is longer than about 1 KB.
function M.pi(request)
  local argv = {
    "pi",
    "--print",
    "--mode",
    "json",
    "--no-tools",
    "--no-session",
    "--no-context-files",
    "--no-skills",
    "--no-mcp",
    "--thinking",
    request.thinking or "off",
  }
  if request.model then
    vim.list_extend(argv, { "--model", request.model })
  end
  vim.list_extend(argv, request.args)
  vim.list_extend(argv, { "--system-prompt", system_prompt_file(request.system_prompt) })
  return { argv = argv, stdin = request.prompt, output = "pi-json" }
end

--- OpenAI Codex CLI. It has no system prompt flag, so the system prompt
--- leads the request on stdin. Runs ephemeral and read-only.
function M.codex(request)
  local argv = {
    "codex",
    "exec",
    "--ephemeral",
    "--skip-git-repo-check",
    "--sandbox",
    "read-only",
    "--color",
    "never",
    "-c",
    string.format("model_reasoning_effort=%q", request.thinking or "low"),
  }
  if request.model then
    vim.list_extend(argv, { "--model", request.model })
  end
  vim.list_extend(argv, request.args)
  argv[#argv + 1] = "-"
  return { argv = argv, stdin = request.system_prompt .. "\n\n---\n\n" .. request.prompt }
end

--- Claude Code. No tools, no session saved, no MCP servers; the system
--- prompt goes in a file and the request on stdin. `thinking` is passed as
--- --effort (low, medium, high, xhigh, max).
function M.claude(request)
  local argv = {
    "claude",
    "--print",
    "--output-format",
    "text",
    "--tools",
    "",
    "--no-session-persistence",
    "--strict-mcp-config",
  }
  if request.model then
    vim.list_extend(argv, { "--model", request.model })
  end
  if request.thinking then
    vim.list_extend(argv, { "--effort", request.thinking })
  end
  vim.list_extend(argv, request.args)
  vim.list_extend(argv, { "--system-prompt-file", system_prompt_file(request.system_prompt) })
  return { argv = argv, stdin = request.prompt }
end

--- OpenCode, with its read-only "plan" agent so it cannot edit files. It has
--- no system prompt flag, so the system prompt leads the request on stdin.
--- `model` is OpenCode's provider/model.
function M.opencode(request)
  local argv = { "opencode", "run", "--agent", "plan" }
  if request.model then
    vim.list_extend(argv, { "--model", request.model })
  end
  vim.list_extend(argv, request.args)
  return { argv = argv, stdin = request.system_prompt .. "\n\n---\n\n" .. request.prompt }
end

--- The preset names, for completion and errors.
M.presets = { "pi", "claude", "codex", "opencode" }

--- Resolve the configured agent: a preset name or a function.
--- @return function|nil agent
--- @return string|nil err
function M.resolve(agent)
  if type(agent) == "function" then
    return agent
  end
  if type(agent) == "string" and vim.tbl_contains(M.presets, agent) then
    return M[agent]
  end
  return nil,
    string.format("unknown agent %s; use one of %s, or a function", vim.inspect(agent), table.concat(M.presets, ", "))
end

return M
