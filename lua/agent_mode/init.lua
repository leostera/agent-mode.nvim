-- agent-mode: ask an agent about, or to change, the code at your cursor.
--
-- Agents work in Neovim through agent-mode's MCP server (bin/agent-mode-mcp),
-- whose tool calls land in M.tool_call: edit the buffer, rename with the
-- language server, show an answer inline, run Lua. Each tool acts on a
-- context, a snapshot of a buffer, cursor and selection; a request is a
-- context with a spinner on its line, and edits are checked against the
-- snapshot so they land on the right lines as the user keeps typing.
--
-- Where a request goes:
--   - to an attached agent, when one is listening (wait_for_request), always;
--   - otherwise by session.mode: "start" a new agent for it (one session per
--     Neovim, or one agent per request without a session), "attach" (wait
--     for an agent and say how to attach one), or "ask" which;
--   - with agent = "axo", to an Axo Session.

local agents = require("agent_mode.agents")
local answer = require("agent_mode.answer")
local axo = require("agent_mode.axo")
local context = require("agent_mode.context")
local edits = require("agent_mode.edits")
local input = require("agent_mode.input")
local introspect = require("agent_mode.introspect")
local lsp = require("agent_mode.lsp")
local protocol = require("agent_mode.protocol")
local run_lua = require("agent_mode.run_lua")
local spinner = require("agent_mode.spinner")

local M = {}

local settings = require("agent_mode.config")
local defaults = settings.defaults

M.defaults = defaults

--- The most recent request's log, for :AgentMode log.
M.last = nil

--- The plugin's folder, and the MCP server agents talk to Neovim through.
local ROOT = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))))
M.mcp_server = vim.fs.joinpath(ROOT, "bin", "agent-mode-mcp")
M.pi_extension = vim.fs.joinpath(ROOT, "pi", "agent-mode.ts")

local requests = {} -- running requests, in the order they were asked
local contexts = {} -- what tools act on, by id: requests and get_context snapshots
---@type { agent: agent_mode.AgentName|function, id: string|nil, started: boolean }|nil
local conversation = nil -- the conversation requests continue
local session_queue = {} -- requests waiting for the conversation
local session_busy = false
local axo_queue = {} -- delegated requests waiting for the one in flight
local axo_busy = false

-- Attached agents: they listen with wait_for_request.
local waiters = {} -- pending wait_for_request calls: { settle = fun(text), timer }
local attach_queue = {} -- requests waiting for an attached agent
local attached_request = nil -- the request an attached agent is working on
local attached_seen = nil -- when an attached agent last asked for a request

local function notify(message, level)
  vim.notify("agent-mode: " .. message, level or vim.log.levels.INFO)
end

--- The running requests, oldest first.
function M.requests()
  return vim.list_slice(requests, 1, #requests)
end

local function new_id()
  return string.format("%x%04x", os.time(), math.random(0, 0xffff))
end

--- Whether an agent is attached: listening now, working on a request it
--- took, or between the two.
local function attached()
  return #waiters > 0 or attached_request ~= nil or (attached_seen ~= nil and vim.uv.now() - attached_seen < 15000)
end

-- Agents ----------------------------------------------------------------------

local function system_prompt()
  local prompt = protocol.system_prompt
  if M.config.session.enabled then
    prompt = prompt .. protocol.session_prompt
  end
  if M.config.luamode then
    prompt = prompt .. protocol.lua_prompt
  end
  if M.config.system_prompt and M.config.system_prompt ~= "" then
    prompt = prompt .. "\nAdditional instructions from the user:\n" .. M.config.system_prompt
  end
  return prompt
end

--- The session requests continue, started fresh when the agent changes.
local function current_session()
  if not M.config.session.enabled then
    return nil
  end
  if not conversation or conversation.agent ~= M.config.agent then
    conversation = { agent = M.config.agent, id = nil, started = false }
  end
  return conversation
end

--- The command for this request, from the configured agent.
local function agent_command(prompt)
  local agent, err = agents.resolve(M.config.agent)
  if not agent then
    return nil, err
  end
  local active = current_session()
  local ok, command = pcall(agent, {
    session = active and { id = active.id, started = active.started } or nil,
    system_prompt = system_prompt(),
    prompt = prompt,
    model = M.config.model,
    thinking = M.config.thinking,
    args = vim.deepcopy(M.config.args),
    mcp = {
      command = M.mcp_server,
      args = { "--server", vim.v.servername },
      server = vim.v.servername,
      pi_extension = M.pi_extension,
    },
  })
  if not ok then
    return nil, "the agent function failed: " .. tostring(command)
  end
  if type(command) ~= "table" or type(command.argv) ~= "table" or #command.argv == 0 then
    return nil, "the agent function must return { argv = {...}, stdin = \"...\" }"
  end
  if M.config.cmd then
    command.argv[1] = M.config.cmd
  end
  return command
end

-- Request lifecycle -----------------------------------------------------------

--- The request's line now: it moves as lines are added or removed above it.
local function current_row(request)
  return request.spinner and request.spinner:row() or request.snapshot.position.row
end

--- How far the request's line has moved since the snapshot.
local function shift(request)
  return current_row(request) - request.snapshot.position.row
end

--- The line an answer goes under: the end of the selection, or the cursor line.
local function answer_row(request)
  local snapshot = request.snapshot
  local row = snapshot.selection and snapshot.selection.end_row or snapshot.position.row
  return row + shift(request)
end

--- The name answers are signed with: the configured agent ("pi", "codex",
--- "axo"), or "agent" for a custom function.
local function agent_name()
  return type(M.config.agent) == "string" and M.config.agent or "agent"
end

local function show_answer(request, text)
  answer.show(request.snapshot.bufnr, answer_row(request), text, {
    title = agent_name() .. ": " .. (request.instruction or "answer"),
    keys = M.config.answer_keymaps,
  })
end

local start_next_delegated -- defined with the Axo flow below
local start_next_in_session -- defined with start_agent
local reload_changed -- defined next to sync_from_disk

local function finish(request, err)
  if request.finished then
    return
  end
  request.finished = true
  for _, list in ipairs({ requests, axo_queue, session_queue, attach_queue }) do
    for i, r in ipairs(list) do
      if r == request then
        table.remove(list, i)
        break
      end
    end
  end
  if attached_request == request then
    attached_request = nil
  end
  if request.stop then
    pcall(request.stop)
  end
  request.spinner:stop()
  if request.mtimes then
    reload_changed(request.mtimes)
  end
  request.log.error = err
  if err then
    notify(err, vim.log.levels.ERROR)
  end
  if request.delegated and request.sent then
    axo_busy = false
    vim.schedule(start_next_delegated)
  end
  if request.holds_session then
    session_busy = false
    vim.schedule(start_next_in_session)
  end
  if request.on_done then
    request.on_done(err)
  end
end

local function action_status(action, code_actions)
  if action.type == "edit" then
    return string.format("editing %d place%s", #action.edits, #action.edits == 1 and "" or "s")
  elseif action.type == "lsp_rename" then
    return "renaming to " .. action.new_name .. " with the language server"
  elseif action.type == "code_action" then
    local entry = (code_actions or {})[action.id]
    return "running code action: " .. (entry and entry.title or tostring(action.id))
  end
  return nil
end

--- Where the user is now, for the agent's Lua.
local function lua_context(ctx)
  local snapshot = ctx.snapshot
  local bufnr = snapshot.bufnr
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    win = vim.fn.bufwinid(bufnr)
  end
  local moved = shift(ctx)
  local selection = snapshot.selection
      and { start_row = snapshot.selection.start_row + moved, end_row = snapshot.selection.end_row + moved }
    or nil
  return {
    bufnr = bufnr,
    win = win ~= -1 and win or nil,
    row = current_row(ctx),
    col = snapshot.position.col,
    file = snapshot.path,
    filetype = snapshot.filetype,
    selection = selection,
    instruction = ctx.instruction,
  }
end

--- Run the agent's Lua, asking first unless allowed. Calls `on_done(report)`
--- with what it returned, printed or raised, or that the user declined.
local function run_agent_lua(ctx, code, on_done)
  local function set_status(text)
    if ctx.spinner and not ctx.finished then
      ctx.spinner:set_status(text)
    end
  end
  local function run()
    set_status("running Lua in Neovim")
    run_lua.run(code, lua_context(ctx), M.config.luamode_timeout_ms, function(report, ok)
      if not ok then
        local first = report:match("error: ([^\n]*)") or report
        notify("the agent's Lua failed, so it was told and may try again: " .. first, vim.log.levels.WARN)
      end
      on_done(report)
    end)
  end
  if M.config.luamode == "allow" or ctx.lua_allowed then
    return run()
  end
  set_status("waiting for you to allow its Lua…")
  run_lua.confirm(code, agent_name() .. " wants to run Lua", function(choice)
    if choice == "skip" then
      return on_done("the user declined to run this code")
    end
    ctx.lua_allowed = choice == "always"
    run()
  end)
end

--- Run one action against the buffer as it is now. Calls `on_done(err)`.
local function run_action(ctx, action, on_done)
  local snapshot = ctx.snapshot
  local bufnr = snapshot.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return on_done("the buffer was closed")
  end
  if ctx.spinner and not ctx.finished then
    ctx.spinner:set_status(action_status(action, ctx.code_actions))
  end

  if action.type == "edit" then
    local rebased, err = edits.rebase(action.edits, snapshot.lines, bufnr, shift(ctx))
    err = err or edits.apply(bufnr, rebased)
    return on_done(err)
  end

  if action.type == "lsp_rename" then
    -- Rename whatever is at the cursor's spot now, if it is still the word
    -- the agent was asked about.
    local row = current_row(ctx)
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    if snapshot.word and context.word_at(line, snapshot.position.col) ~= snapshot.word then
      return on_done(string.format("%s is no longer under the cursor; nothing renamed", snapshot.word))
    end
    return lsp.rename(bufnr, { row = row, col = snapshot.position.col }, action.new_name, on_done)
  end

  if action.type == "code_action" then
    -- Code actions carry positions from when they were listed.
    if vim.api.nvim_buf_get_changedtick(bufnr) ~= snapshot.changedtick then
      return on_done("the buffer changed since the code actions were listed; nothing was run")
    end
    local entry = (ctx.code_actions or {})[action.id]
    if not entry then
      return on_done(string.format("there is no code action %d", action.id))
    end
    return lsp.run_code_action(bufnr, entry, on_done)
  end
end

-- Files the agent changed -----------------------------------------------------

local function read_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or nil
end

--- Bring an unmodified buffer up to date with its file by applying only the
--- lines that differ, so marks elsewhere (other requests, answers) stay put
--- and the change is one undo step.
local function sync_from_disk(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].modified then
    return notify("the buffer has unsaved changes, so it was not reloaded", vim.log.levels.WARN)
  end
  local disk = read_lines(vim.api.nvim_buf_get_name(bufnr))
  if not disk then
    return
  end
  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  local hunks = vim.text.diff(table.concat(current, "\n") .. "\n", table.concat(disk, "\n") .. "\n", {
    result_type = "indices",
  })
  ---@cast hunks integer[][]
  for i = #hunks, 1, -1 do
    local start_a, count_a, start_b, count_b = unpack(hunks[i])
    local replacement = vim.list_slice(disk, start_b, start_b + count_b - 1)
    local first = count_a == 0 and start_a or start_a - 1
    if i < #hunks then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent! undojoin")
      end)
    end
    vim.api.nvim_buf_set_lines(bufnr, first, first + count_a, false, replacement)
  end
  vim.bo[bufnr].modified = false
end

--- When each open file was last written, to tell later which the agent
--- changed.
local function file_mtimes()
  local mtimes = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" and name ~= "" then
      local stat = vim.uv.fs_stat(name)
      mtimes[bufnr] = stat and (stat.mtime.sec .. "." .. stat.mtime.nsec) or false
    end
  end
  return mtimes
end

--- Reload the buffers whose files changed on disk since `mtimes`: the
--- agent's tools wrote them. Buffers with unsaved changes are left alone.
reload_changed = function(mtimes)
  for bufnr, before in pairs(mtimes) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local stat = vim.uv.fs_stat(vim.api.nvim_buf_get_name(bufnr))
      local now = stat and (stat.mtime.sec .. "." .. stat.mtime.nsec) or false
      if now and now ~= before then
        if vim.bo[bufnr].modified then
          notify(
            vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:.")
              .. " changed on disk, but has unsaved changes, so it was not reloaded",
            vim.log.levels.WARN
          )
        else
          sync_from_disk(bufnr)
        end
      end
    end
  end
end

-- Requests as the agent sees them ---------------------------------------------

--- The request or context as text for the agent: its id, then where the
--- user is and what they asked.
local function render(ctx)
  local snapshot = ctx.snapshot
  local body = context.render(snapshot, ctx.instruction or "(none: the agent asked where the user is)", {
    can_rename = lsp.can_rename(snapshot.bufnr),
    code_actions = ctx.code_actions,
  }, M.config.max_lines)
  local head = string.format("context_id: %s", ctx.id)
  if ctx.spinner then
    head = string.format("Request from Neovim. context_id: %s", ctx.id)
  end
  if M.config.luamode then
    head = head .. "\nNeovim: " .. introspect.summary(snapshot.bufnr)
  end
  return head .. "\n\n" .. body
end

-- Starting an agent -----------------------------------------------------------

--- Run a new agent for the request; it works through the MCP tools and the
--- request ends when it exits.
local function start_agent(request)
  local prompt = render(request)
  request.log.prompt = prompt
  request.session = current_session()
  local command, command_err = agent_command(prompt)
  if not command then
    return finish(request, command_err)
  end
  request.log.argv = command.argv
  request.spinner:set_status(agent_name() .. " is working…")

  local ok, process = pcall(vim.system, command.argv, {
    stdin = command.stdin,
    text = true,
    env = command.env,
  }, function(result)
    vim.schedule(function()
      request.log.stdout, request.log.stderr = result.stdout, result.stderr
      if request.session and result.code == 0 then
        local id = command.session_id or (command.read_session_id and command.read_session_id(result))
        if id and request.session == conversation then
          conversation.id, conversation.started = id, true
          request.log.session = id
        end
      end
      if request.finished then
        return
      end
      if result.code ~= 0 then
        return finish(
          request,
          string.format("agent exited with code %d: %s", result.code, vim.trim(result.stderr or ""):sub(-500))
        )
      end
      if not request.acted and request.last_error then
        return finish(request, request.last_error)
      end
      -- An agent that answered in words instead of with show_answer.
      local text = vim.trim(result.stdout or "")
      if not request.acted and text ~= "" and vim.api.nvim_buf_is_valid(request.snapshot.bufnr) then
        show_answer(request, text)
      end
      finish(request, nil)
    end)
  end)
  if not ok then
    return finish(request, "could not start the agent: " .. tostring(process))
  end
  ---@cast process vim.SystemObj
  request.stop = function()
    process:kill(15)
  end
end

--- Start the oldest request waiting for the session, if it is free.
start_next_in_session = function()
  if session_busy then
    return
  end
  local request = table.remove(session_queue, 1)
  if not request then
    return
  end
  if request.finished then
    return start_next_in_session()
  end
  session_busy = true
  request.holds_session = true
  start_agent(request)
end

-- Attached agents -------------------------------------------------------------

--- Hand waiting requests to listening agents.
local function deliver()
  while #waiters > 0 and #attach_queue > 0 do
    local request = table.remove(attach_queue, 1)
    if not request.finished then
      local waiter = table.remove(waiters, 1)
      waiter.timer:stop()
      waiter.timer:close()
      attached_request = request
      request.spinner:set_status("with the attached agent…")
      request.log.prompt = render(request)
      waiter.settle(request.log.prompt)
    end
  end
end

--- Wait for an attached agent to take the request.
local function hand_to_attached(request)
  request.attached = true
  attach_queue[#attach_queue + 1] = request
  request.spinner:set_status("waiting for an attached agent…")
  deliver()
end

--- Where the request goes when no agent is attached: by session.mode.
local function start_or_attach(request, choice)
  choice = choice or M.config.session.mode
  if choice == "attach" then
    hand_to_attached(request)
    return M.attach()
  end
  if choice == "ask" then
    request.spinner:set_status("start an agent or attach one?")
    local start = "Start a new " .. agent_name() .. (M.config.session.enabled and " session" or "")
    return vim.ui.select({ start, "Attach an agent" }, { prompt = "agent-mode: no agent is attached" }, function(item)
      if request.finished then
        return
      end
      if not item then
        return finish(request, "cancelled")
      end
      start_or_attach(request, item == start and "start" or "attach")
    end)
  end
  if not M.config.session.enabled then
    return start_agent(request)
  end
  if session_busy then
    request.spinner:set_status("queued behind another request…")
  end
  session_queue[#session_queue + 1] = request
  start_next_in_session()
end

-- Tools -----------------------------------------------------------------------

local results = {} -- tool results by ticket: "pending" or { text, error }
local ticket_count = 0
local tools = {}

--- The context a tool acts on, or an error.
local function context_for(args)
  local id = args.context_id
  if type(id) ~= "string" or id == "" then
    return nil, "context_id is required"
  end
  local ctx = contexts[id]
  if not ctx then
    return nil, string.format("there is no context %s; take one with get_context", id)
  end
  if not vim.api.nvim_buf_is_valid(ctx.snapshot.bufnr) then
    return nil, "the user closed that buffer"
  end
  return ctx
end

--- Take a context where the user is now, with its code actions.
local function take_context(on_done)
  local win = vim.api.nvim_get_current_win()
  -- Not a prompt or another float: the window the user works in.
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    win = vim.fn.win_getid(vim.fn.winnr("#"))
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local ctx = {
    id = new_id(),
    snapshot = context.capture({ bufnr = bufnr, position = { row = cursor[1], col = cursor[2] } }),
  }
  contexts[ctx.id] = ctx
  lsp.code_actions(bufnr, ctx.snapshot.position, M.config.code_action_timeout_ms, function(code_actions)
    ctx.code_actions = code_actions
    on_done(ctx)
  end)
end

function tools.wait_for_request(args, done)
  -- Asking for the next request finishes the one before.
  if attached_request and not attached_request.finished then
    finish(attached_request, nil)
  end
  attached_seen = vim.uv.now()
  local timeout = math.max(1, math.min(tonumber(args.timeout_seconds) or 300, 3600))
  local waiter = { settle = done, timer = assert(vim.uv.new_timer()) }
  waiters[#waiters + 1] = waiter
  waiter.timer:start(timeout * 1000, 0, vim.schedule_wrap(function()
    for i, w in ipairs(waiters) do
      if w == waiter then
        table.remove(waiters, i)
        waiter.timer:close()
        attached_seen = vim.uv.now()
        done(string.format("No request yet (waited %ds). Call wait_for_request again to keep listening.", timeout))
        return
      end
    end
  end))
  deliver()
end

function tools.get_context(args, done)
  if args.context_id then
    local ctx, err = context_for(args)
    if not ctx then
      return done(err, true)
    end
    return done(render(ctx))
  end
  take_context(function(ctx)
    done(render(ctx))
  end)
end

local function act(ctx, action, done, success)
  run_action(ctx, action, function(err)
    if err then
      -- The agent may try again; if it ends without anything succeeding,
      -- the request ends with this error.
      ctx.last_error = err
      return done("error: " .. err, true)
    end
    ctx.acted = true
    done(success)
  end)
end

function tools.edit(args, done)
  local ctx, err = context_for(args)
  if not ctx then
    return done(err, true)
  end
  local list, edits_err = protocol.edits(args.edits)
  if not list then
    return done(edits_err, true)
  end
  act(ctx, { type = "edit", edits = list }, done, string.format("Applied %d edit%s.", #list, #list == 1 and "" or "s"))
end

function tools.lsp_rename(args, done)
  local ctx, err = context_for(args)
  if not ctx then
    return done(err, true)
  end
  if type(args.new_name) ~= "string" or not args.new_name:match("^[%a_][%w_]*$") then
    return done("new_name must be an identifier", true)
  end
  act(ctx, { type = "lsp_rename", new_name = args.new_name }, done, "Renamed to " .. args.new_name .. ".")
end

function tools.code_action(args, done)
  local ctx, err = context_for(args)
  if not ctx then
    return done(err, true)
  end
  local id = tonumber(args.id)
  if not id then
    return done("id must be a number", true)
  end
  act(ctx, { type = "code_action", id = id }, done, "Ran code action " .. id .. ".")
end

function tools.show_answer(args, done)
  local ctx, err = context_for(args)
  if not ctx then
    return done(err, true)
  end
  if type(args.text) ~= "string" or vim.trim(args.text) == "" then
    return done("text is required", true)
  end
  show_answer(ctx, args.text)
  ctx.acted = true
  done("Shown to the user.")
end

function tools.run_lua(args, done)
  if not M.config.luamode then
    return done("the user does not allow Lua", true)
  end
  if type(args.code) ~= "string" or vim.trim(args.code) == "" then
    return done("code is required", true)
  end
  local function run(ctx)
    run_agent_lua(ctx, args.code, function(report)
      done(report)
    end)
  end
  if args.context_id then
    local ctx, err = context_for(args)
    if not ctx then
      return done(err, true)
    end
    return run(ctx)
  end
  take_context(run)
end

function tools.set_status(args, done)
  local ctx, err = context_for(args)
  if not ctx then
    return done(err, true)
  end
  if ctx.spinner and not ctx.finished and type(args.text) == "string" then
    ctx.spinner:set_status(args.text)
  end
  done("ok")
end

function tools.finish(args, done)
  local ctx, err = context_for(args)
  if not ctx then
    return done(err, true)
  end
  if type(args.summary) == "string" and args.summary ~= "" and not ctx.acted then
    notify(args.summary)
  end
  ctx.acted = true
  if ctx.spinner then
    finish(ctx, nil)
  end
  done("Finished.")
end

--- Carry out an MCP tool call (from bin/agent-mode-mcp). Returns a ticket
--- for M.tool_result, since tools may wait for the user or for a request.
--- @param name string
--- @param args table
--- @return string ticket
function M.tool_call(name, args)
  ticket_count = ticket_count + 1
  local ticket = tostring(ticket_count)
  results[ticket] = "pending"
  -- The request's log keeps each call and how it went, for :AgentMode log.
  local ctx = type(args) == "table" and type(args.context_id) == "string" and contexts[args.context_id] or nil
  local function done(text, is_error)
    if results[ticket] == "pending" then
      results[ticket] = { text = text, error = is_error or false }
      if ctx and ctx.log then
        ctx.log.tools = ctx.log.tools or {}
        table.insert(ctx.log.tools, { name = name, error = is_error and text or nil })
      end
    end
  end
  local tool = tools[name]
  if not tool then
    done("unknown tool " .. tostring(name), true)
    return ticket
  end
  local ok, err = pcall(tool, type(args) == "table" and args or {}, done)
  if not ok then
    done("error: " .. tostring(err), true)
  end
  return ticket
end

--- What came of a tool call: "pending" until it is done.
--- @param ticket string
--- @return "pending"|{ text: string, error: boolean }
function M.tool_result(ticket)
  local result = results[ticket]
  if result == nil then
    return { text = "unknown ticket " .. tostring(ticket), error = true }
  end
  if result ~= "pending" then
    results[ticket] = nil
  end
  return result
end

-- Axo Sessions ----------------------------------------------------------------

--- Send a queued delegated request to the Axo Session.
local function send_delegated(request)
  local snapshot = request.snapshot
  local bufnr = snapshot.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return finish(request, "the buffer was closed before the request was sent")
  end
  axo_busy = true
  request.sent = true

  -- The session's agent works on the file, so it must see what we see.
  if vim.bo[bufnr].modified then
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent write")
    end)
  end

  -- Requests to the session run one at a time, so a change to the file
  -- between now and the end of the turn is this request's doing.
  local before = read_lines(snapshot.path)

  -- Lines may have moved while the request was queued.
  local moved = vim.deepcopy(snapshot)
  moved.position = { row = current_row(request), col = snapshot.position.col }
  if snapshot.selection then
    local delta = shift(request)
    moved.selection = { start_row = snapshot.selection.start_row + delta, end_row = snapshot.selection.end_row + delta }
  end

  local nonce = new_id()
  local prompt = context.render_session(moved, request.instruction, nonce, M.config.system_prompt)
  request.log.prompt = prompt
  request.log.argv = { M.config.axo.cmd, "session", "prompt", "--sid", M.config.axo.session }
  request.spinner:set_status("sending to the Axo Session…")

  request.stop = axo.run({
    cmd = M.config.axo.cmd,
    session = M.config.axo.session,
    prompt = prompt,
    nonce = nonce,
    on_progress = function(status)
      if not request.finished then
        request.spinner:set_status(status)
      end
    end,
  }, function(err, reply)
    request.log.stdout = reply and reply.text
    if request.finished then
      return
    end
    if err then
      return finish(request, err)
    end
    local edited = not vim.deep_equal(read_lines(snapshot.path), before)
    sync_from_disk(bufnr)
    local text = vim.trim(reply.text or "")
    if edited then
      local summary = text:match("[^\n]+")
      if summary then
        notify(summary)
      end
    elseif text ~= "" then
      show_answer(request, text)
    end
    finish(request, nil)
  end)
end

start_next_delegated = function()
  if axo_busy then
    return
  end
  local request = table.remove(axo_queue, 1)
  if request then
    send_delegated(request)
  end
end

-- Public API ------------------------------------------------------------------

--- Ask the agent to carry out `instruction` at the cursor. Returns at once;
--- the request runs alongside any others.
--- @param instruction string
--- @param opts? { bufnr?: integer, position?: { row: integer, col: integer }, selection?: { start_row: integer, end_row: integer }, on_done?: fun(err: string|nil) }
function M.run(instruction, opts)
  opts = opts or {}
  instruction = vim.trim(instruction or "")
  if instruction == "" then
    return
  end

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local position = opts.position
  if not position then
    local cursor = vim.api.nvim_win_get_cursor(0)
    position = { row = cursor[1], col = cursor[2] }
  end

  local delegated = M.config.agent == "axo" and not attached()
  if delegated and vim.api.nvim_buf_get_name(bufnr) == "" then
    return notify("save the buffer to a file first; the session's agent edits files", vim.log.levels.ERROR)
  end

  local request = {
    id = new_id(),
    instruction = instruction,
    -- The session's agent's turn reloads files itself; other agents may
    -- change files with their tools.
    mtimes = not delegated and file_mtimes() or nil,
    snapshot = context.capture({ bufnr = bufnr, position = position, selection = opts.selection }),
    on_done = opts.on_done,
    delegated = delegated,
    spinner = spinner.start(bufnr, position.row),
    log = { instruction = instruction, started_at = os.date("%Y-%m-%d %H:%M:%S") },
  }
  M.last = request.log
  requests[#requests + 1] = request
  contexts[request.id] = request

  if delegated then
    request.spinner:set_status(axo_busy and "queued behind another request…" or "sending…")
    axo_queue[#axo_queue + 1] = request
    return start_next_delegated()
  end

  request.spinner:set_status("asking the language servers…")
  lsp.code_actions(bufnr, position, M.config.code_action_timeout_ms, function(code_actions)
    request.code_actions = code_actions
    if request.finished then
      return
    end
    if attached() then
      return hand_to_attached(request)
    end
    start_or_attach(request)
  end)
end

--- Stop running requests: those on the cursor line if there are any,
--- otherwise all of them.
function M.cancel()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local here = vim.tbl_filter(function(r)
    return r.snapshot.bufnr == bufnr and current_row(r) == row
  end, requests)
  for _, request in ipairs(#here > 0 and here or M.requests()) do
    finish(request, "cancelled")
  end
end

--- Prompt for an instruction and run it. In visual mode the selection is
--- sent along with the cursor.
function M.prompt()
  local mode = vim.api.nvim_get_mode().mode
  local selection = nil
  if mode == "v" or mode == "V" or mode == "\22" then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    selection = { start_row = math.min(a, b), end_row = math.max(a, b) }
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local bufnr = vim.api.nvim_get_current_buf()
  local function submit(instruction)
    if instruction and vim.trim(instruction) ~= "" then
      M.run(instruction, {
        bufnr = bufnr,
        position = { row = cursor[1], col = cursor[2] },
        selection = selection,
      })
    end
  end
  local who = attached() and "attached agent" or agent_name()
  if M.config.input == "cmdline" then
    vim.ui.input({ prompt = who .. ": " }, submit)
  else
    input.open({ title = "ask " .. who }, submit)
  end
end

--- How to attach an agent to this Neovim: what to add to the agent once,
--- and what to tell it. Shown in a scratch window; the instruction is
--- copied to the clipboard.
function M.attach()
  local listen = "Listen to Neovim: call agent-mode's wait_for_request tool, handle each request it returns with"
    .. " agent-mode's tools, and call wait_for_request again after each one, until I say stop."
  local lines = {
    "# Attach an agent to this Neovim",
    "",
    "Neovim: `" .. vim.v.servername .. "`, in `" .. vim.fn.fnamemodify(vim.fn.getcwd(), ":~") .. "`",
    "",
    "1. Add agent-mode's MCP server to your agent, once:",
    "",
    "   pi:        pi install " .. M.pi_extension,
    "   Claude:    claude mcp add --scope user agent-mode -- " .. M.mcp_server,
    "   Codex:     codex mcp add agent-mode -- " .. M.mcp_server,
    "   OpenCode:  in ~/.config/opencode/opencode.json, under \"mcp\":",
    '              "agent-mode": { "type": "local", "command": ["' .. M.mcp_server .. '"] }',
    "",
    "   Run the agent in this project's folder, and it finds this Neovim.",
    "",
    "2. Tell it (copied to your clipboard):",
    "",
    "   " .. listen,
    "",
    "Requests you make at your cursor go to it while it listens.",
  }
  pcall(vim.fn.setreg, "+", listen)
  vim.fn.setreg('"', listen)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(1, math.floor((vim.o.lines - #lines) / 2) - 1),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = #lines,
    border = "rounded",
    title = " agent-mode ",
    style = "minimal",
  })
  vim.wo[win].wrap = true
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf, nowait = true })
  return win
end

--- Whether an agent is attached and listening.
function M.attached()
  return attached()
end

--- Start fresh: the next request starts a new session, and an attached
--- agent is let go (its wait_for_request returns).
function M.new_session()
  conversation = nil
  for _, waiter in ipairs(waiters) do
    waiter.timer:stop()
    waiter.timer:close()
    waiter.settle("The user detached you from Neovim. Stop listening.")
  end
  waiters, attached_seen = {}, nil
  notify("the next request starts a new session")
end

--- The conversation requests continue, if one has started.
function M.session()
  return conversation and conversation.started and vim.deepcopy(conversation) or nil
end

--- Clear the inline answer nearest the cursor, or all of them with `all`.
function M.dismiss(all)
  local bufnr = vim.api.nvim_get_current_buf()
  answer.dismiss(bufnr, not all and vim.api.nvim_win_get_cursor(0)[1] or nil)
end

--- Show the last request's prompt and reply in a scratch buffer.
function M.show_log()
  if not M.last then
    return notify("no request yet")
  end
  local log = M.last
  local lines = { "# agent-mode request at " .. log.started_at, "", "Instruction: " .. log.instruction }
  local function section(title, text)
    if text and text ~= "" then
      vim.list_extend(lines, { "", "## " .. title, "" })
      vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
    end
  end
  section("Error", log.error)
  section("Session", log.session)
  section("Command", log.argv and table.concat(log.argv, " "):sub(1, 400))
  section("Tool calls", log.tools and table.concat(vim.tbl_map(function(call)
    return "- " .. call.name .. (call.error and (": " .. call.error) or "")
  end, log.tools), "\n"))
  section("Prompt", log.prompt)
  section("Agent stdout", log.stdout)
  section("Agent stderr", log.stderr)
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

-- Settings --------------------------------------------------------------------

--- Merge `opts` over `base` into a checked config, or raise.
local function build_config(base, opts)
  local config = vim.tbl_deep_extend("force", vim.deepcopy(base), opts)
  -- Lists merge index by index; given args replace the old ones.
  config.args = opts.args or config.args
  local err = settings.check(config)
  if err then
    error("agent-mode: " .. err, 3)
  end
  local unknown = settings.unknown_keys(opts)
  if #unknown > 0 then
    notify("unknown settings, ignored: " .. table.concat(unknown, ", "), vim.log.levels.WARN)
  end
  return config
end

local mapped_keymap = nil

local function apply(config)
  if mapped_keymap and mapped_keymap ~= config.keymap then
    pcall(vim.keymap.del, { "n", "x" }, mapped_keymap)
    mapped_keymap = nil
  end
  if config.keymap and config.keymap ~= mapped_keymap then
    vim.deprecate("agent-mode's `keymap` setting", 'vim.keymap.set({ "n", "x" }, "<key>", "<Plug>(AgentMode)")', "1.0", "agent-mode", false)
    vim.keymap.set({ "n", "x" }, config.keymap, "<Plug>(AgentMode)", { desc = "agent-mode: ask the agent" })
    mapped_keymap = config.keymap
  end
  M.config = config
end

--- Set agent-mode's settings: `opts` over `vim.g.agent_mode` over the
--- defaults. Optional: without it the plugin uses `vim.g.agent_mode` and the
--- defaults. Only configures; nothing else is started.
---@param opts agent_mode.Config|nil
function M.setup(opts)
  apply(build_config(defaults, vim.tbl_deep_extend("force", settings.from_globals(), opts or {})))
end

--- Change some settings at runtime, keeping the rest, e.g.
---   require("agent_mode").configure({ agent = "axo" })
---   require("agent_mode").configure({ model = "sonnet", thinking = "low" })
--- Running requests keep the settings they started with.
---@param opts agent_mode.Config|nil
function M.configure(opts)
  apply(build_config(M.config, opts or {}))
  if M.config.agent == "axo" and M.config.axo.session == "self" and not vim.env.AXO_SESSION_ID then
    notify("agent is axo with session \"self\", but Neovim is not running in an Axo Session", vim.log.levels.WARN)
  end
end

--- Open the settings window.
function M.open_config()
  return require("agent_mode.config_ui").open()
end

--- The agents `:AgentMode agent` can switch to.
M.agent_names = vim.list_extend(vim.deepcopy(agents.presets), { "axo" })

-- Finding this Neovim ---------------------------------------------------------

--- Tell agent-mode's MCP server where this Neovim is: a file per Neovim in
--- the state folder with its address and working folder.
local registration = vim.fs.joinpath(vim.fn.stdpath("state"), "agent-mode", "servers", vim.fn.getpid() .. ".json")
local function register()
  if vim.v.servername == "" then
    return
  end
  vim.fn.mkdir(vim.fs.dirname(registration), "p")
  pcall(vim.fn.writefile, {
    vim.json.encode({ address = vim.v.servername, cwd = vim.fn.getcwd(), pid = vim.fn.getpid() }),
  }, registration)
end
local group = vim.api.nvim_create_augroup("agent_mode_server", { clear = true })
vim.api.nvim_create_autocmd("DirChanged", { group = group, callback = register })
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    pcall(os.remove, registration)
  end,
})
register()

-- Start from the defaults and vim.g.agent_mode; setup() is optional.
apply(build_config(defaults, settings.from_globals()))

return M
