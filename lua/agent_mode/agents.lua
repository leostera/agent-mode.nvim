-- How to run each supported agent CLI.
--
-- An agent is a function that turns a request into a command:
--
--   agent(request) -> { argv = { ... }, stdin = "...", env = { ... } }
--
-- where request is
--
--   {
--     system_prompt = string,   -- the agent-mode protocol plus the user's own system_prompt
--     prompt = string,          -- the buffer, cursor, and instruction
--     model = string|nil,       -- nil means the agent's default model
--     thinking = string|nil,    -- nil means the agent's default reasoning level
--     args = string[],          -- extra arguments from the user's config
--     session = { id = string|nil, started = boolean }|nil,
--                               -- the conversation to continue; nil runs
--                               -- without one
--     mcp = { command, args, server, pi_extension },
--                               -- the nvim-mcp server for this Neovim
--                               -- (command and args start it), and pi's
--                               -- extension that registers it
--   }
--
-- With a session, the command may set `session_id` (the id it uses, when it
-- picks one) or `read_session_id(result)` (to read it from the finished
-- process); agent-mode keeps it for the next request.
--
-- The agent works in Neovim through nvim-mcp's tools (edit,
-- show_answer, run_lua, ...); what it prints on stdout at the end is shown
-- as the answer when it did not use them. Agents also get their usual tools
-- (pi adds codemode), so they can look around the project and change other
-- files themselves; agent-mode reloads open buffers whose files changed.

local M = {}

--- Some agents take their system prompt as a file: pi kills itself when an
--- argument is longer than about 1 KB with some extensions loaded.
local function system_prompt_file(text)
  local path = vim.fn.tempname()
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
  return path
end

local function uuid()
  local bytes = assert(vim.uv.random(16))
  local hex = bytes:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end)
  return string.format("%s-%s-4%s-a%s-%s", hex:sub(1, 8), hex:sub(9, 12), hex:sub(14, 16), hex:sub(18, 20), hex:sub(21, 32))
end
M.uuid = uuid

--- pi (https://pi.dev). Takes the system prompt as a file and the request on
--- stdin, and the nvim-mcp server through pi/pi-nvim.ts. The prompt goes through a file because some pi extensions kill the
--- process when an argument is longer than about 1 KB. --session-id creates
--- the session the first time and continues it after.
function M.pi(request)
  local session_id = request.session and (request.session.id or uuid())
  local argv = {
    "pi",
    "--print",
    "--tools",
    "+codemode",
    "--no-context-files",
    "--no-skills",
    "--extension",
    request.mcp.pi_extension,
    "--thinking",
    request.thinking or "off",
  }
  if session_id then
    vim.list_extend(argv, { "--session-id", session_id })
  else
    argv[#argv + 1] = "--no-session"
  end
  if request.model then
    vim.list_extend(argv, { "--model", request.model })
  end
  vim.list_extend(argv, request.args)
  vim.list_extend(argv, { "--system-prompt", system_prompt_file(request.system_prompt) })
  -- The extension registers the nvim-mcp server for this Neovim.
  return {
    argv = argv,
    stdin = request.prompt,
    env = { NVIM_MCP_SERVER = request.mcp.server },
    session_id = session_id,
  }
end

--- OpenAI Codex CLI. It has no system prompt flag, so the system prompt
--- leads the request on stdin. Its sandbox lets it write in the workspace.
--- A session starts with a plain
--- `codex exec`, which prints its id on stderr, and continues with
--- `codex exec resume <id>`, which takes settings only as -c.
function M.codex(request)
  local session = request.session
  local resuming = session and session.started and session.id
  local argv = { "codex", "exec" }
  if resuming then
    vim.list_extend(argv, { "resume", "--skip-git-repo-check", "-c", 'sandbox_mode="workspace-write"' })
  else
    vim.list_extend(argv, { "--skip-git-repo-check", "--sandbox", "workspace-write", "--color", "never" })
    if not session then
      argv[#argv + 1] = "--ephemeral"
    end
  end
  vim.list_extend(argv, { "-c", string.format("model_reasoning_effort=%q", request.thinking or "low") })
  vim.list_extend(argv, {
    "-c",
    string.format("mcp_servers.nvim-mcp.command=%q", request.mcp.command),
    "-c",
    string.format("mcp_servers.nvim-mcp.args=%s", vim.json.encode(request.mcp.args)),
    -- exec cannot ask, so nvim-mcp's tools are approved up front.
    "-c",
    'mcp_servers.nvim-mcp.default_tools_approval_mode="approve"',
  })
  if request.model then
    vim.list_extend(argv, { "-c", string.format("model=%q", request.model) })
  end
  vim.list_extend(argv, request.args)
  if resuming then
    argv[#argv + 1] = session.id
  end
  argv[#argv + 1] = "-"
  return {
    argv = argv,
    stdin = request.system_prompt .. "\n\n---\n\n" .. request.prompt,
    session_id = resuming or nil,
    read_session_id = session and function(result)
      return (result.stderr or ""):match("session id: ([%w%-]+)")
    end or nil,
  }
end

--- Claude Code. Its usual tools with file edits allowed (commands that
--- need permission are refused, since nobody can answer in --print), and of
--- MCP servers only nvim-mcp, its tools allowed; the system prompt goes
--- in a file
--- and the request on stdin. `thinking` is passed as --effort (low, medium,
--- high, xhigh, max). A session starts with --session-id and continues with
--- --resume, since --session-id refuses an id that exists.
function M.claude(request)
  local session = request.session
  local session_id = session and (session.id or uuid())
  local mcp_config = vim.json.encode({
    mcpServers = { ["nvim-mcp"] = { command = request.mcp.command, args = request.mcp.args } },
  })
  local argv = {
    "claude",
    "--print",
    "--output-format",
    "text",
    "--permission-mode",
    "acceptEdits",
    "--mcp-config",
    mcp_config,
    "--strict-mcp-config",
    "--allowedTools",
    "mcp__nvim-mcp",
  }
  if not session then
    argv[#argv + 1] = "--no-session-persistence"
  elseif session.started then
    vim.list_extend(argv, { "--resume", session_id })
  else
    vim.list_extend(argv, { "--session-id", session_id })
  end
  if request.model then
    vim.list_extend(argv, { "--model", request.model })
  end
  if request.thinking then
    vim.list_extend(argv, { "--effort", request.thinking })
  end
  vim.list_extend(argv, request.args)
  vim.list_extend(argv, { "--system-prompt-file", system_prompt_file(request.system_prompt) })
  return { argv = argv, stdin = request.prompt, session_id = session_id }
end

--- OpenCode, with its default agent and its permissions auto-approved, since
--- nobody can answer a prompt, and the nvim-mcp server in its inline
--- config. --standalone runs it on a private server: the shared background
--- service would not see that config, which comes in the environment. It has no system prompt flag, so the system
--- prompt leads the request on stdin. `model` is OpenCode's provider/model.
--- --session creates the session the first time and continues it after; its
--- ids look like ses_<26 characters>.
function M.opencode(request)
  local session_id = request.session and (request.session.id or ("ses_" .. uuid():gsub("%-", ""):sub(1, 26)))
  local argv = { "opencode", "run", "--standalone", "--auto" }
  if session_id then
    vim.list_extend(argv, { "--session", session_id })
  end
  if request.model then
    vim.list_extend(argv, { "--model", request.model })
  end
  vim.list_extend(argv, request.args)
  local config = vim.json.encode({
    mcp = {
      ["nvim-mcp"] = {
        type = "local",
        command = vim.list_extend({ request.mcp.command }, request.mcp.args),
        enabled = true,
      },
    },
  })
  return {
    argv = argv,
    stdin = request.system_prompt .. "\n\n---\n\n" .. request.prompt,
    env = { OPENCODE_CONFIG_CONTENT = config },
    session_id = session_id,
  }
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
