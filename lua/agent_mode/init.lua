-- agent-mode: ask an agent about, or to change, the code at your cursor.
--
-- Any number of requests can run at once. Each is tied to the line it was
-- asked on by its spinner's extmark, which follows that line as the buffer
-- changes, so its status, and later its answer, stay next to it.
--
-- A request with a spawned agent (pi, codex, custom):
--   1. snapshot the buffer, cursor, and selection (context.capture)
--   2. ask the language servers what they can do here (lsp.code_actions)
--   3. run the agent, streaming its progress into the spinner's status
--   4. parse its JSON reply and run the actions, each only if the code it
--      targets is still what the agent saw
--
-- With agent = "axo" the request is delegated to an Axo Session's agent,
-- one request at a time so each reply belongs to its question: save the
-- buffer, send the request, follow the turn in the transcript, then bring the
-- buffer up to date with the file, or show the reply inline if it was an
-- answer.

local agents = require("agent_mode.agents")
local answer = require("agent_mode.answer")
local axo = require("agent_mode.axo")
local context = require("agent_mode.context")
local edits = require("agent_mode.edits")
local input = require("agent_mode.input")
local lsp = require("agent_mode.lsp")
local protocol = require("agent_mode.protocol")
local run_lua = require("agent_mode.run_lua")
local introspect = require("agent_mode.introspect")
local spinner = require("agent_mode.spinner")

local M = {}

local defaults = {
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
  -- Normal and visual mode mapping that opens the prompt; false to skip.
  keymap = "<leader>a",
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
  -- then run one at a time, in order. :AgentModeNew starts a fresh one.
  -- false runs each request on its own, all at once.
  session = true,
}

M.config = vim.deepcopy(defaults)
M.defaults = defaults

--- The most recent request's log, for :AgentModeLog.
M.last = nil

local requests = {} -- running requests, in the order they were asked
local session = nil -- the conversation requests continue: { agent, id, started }
local session_queue = {} -- requests waiting for the session
local session_busy = false
local axo_queue = {} -- delegated requests waiting for the one in flight
local axo_busy = false

local function notify(message, level)
  vim.notify("agent-mode: " .. message, level or vim.log.levels.INFO)
end

--- The running requests, oldest first.
function M.requests()
  return vim.list_slice(requests, 1, #requests)
end

-- Agents ----------------------------------------------------------------------

local function system_prompt()
  local prompt = protocol.system_prompt
  if M.config.session then
    prompt = prompt .. protocol.session_prompt
  end
  if M.config.lua then
    prompt = prompt .. protocol.lua_prompt
  end
  if M.config.system_prompt and M.config.system_prompt ~= "" then
    prompt = prompt .. "\nAdditional instructions from the user:\n" .. M.config.system_prompt
  end
  return prompt
end

--- The command for this request, from the configured agent.
--- The session requests continue, started fresh when the agent changes.
local function current_session()
  if not M.config.session then
    return nil
  end
  if not session or session.agent ~= M.config.agent then
    session = { agent = M.config.agent, id = nil, started = false }
  end
  return session
end

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
  return request.spinner:row() or request.snapshot.position.row
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
    title = agent_name() .. ": " .. request.instruction,
    keys = M.config.answer_keymaps,
  })
end

local start_next_delegated -- defined with the Axo flow below
local run_lua_action -- defined with the actions below
local start_agent -- defined below; called again for each turn
local start_next_in_session -- defined with start_agent
local reload_changed -- defined with the Axo flow, next to sync_from_disk

local function finish(request, err)
  if request.finished then
    return
  end
  request.finished = true
  for i, r in ipairs(requests) do
    if r == request then
      table.remove(requests, i)
      break
    end
  end
  for i, r in ipairs(axo_queue) do
    if r == request then
      table.remove(axo_queue, i)
      break
    end
  end
  if request.timer then
    request.timer:stop()
    request.timer:close()
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
  for i, r in ipairs(session_queue) do
    if r == request then
      table.remove(session_queue, i)
      break
    end
  end
  if request.holds_session then
    session_busy = false
    vim.schedule(start_next_in_session)
  end
  if request.on_done then
    request.on_done(err)
  end
end

--- Finish `request` with a timeout error if it runs longer than `timeout_ms`.
--- Our own timer rather than vim.system's, so the request finishes even if a
--- killed agent's children keep its output pipe open.
local function start_timeout(request, timeout_ms)
  if request.timer then
    request.timer:stop()
    request.timer:close()
  end
  request.timer = vim.uv.new_timer()
  request.timer:start(timeout_ms, 0, vim.schedule_wrap(function()
    finish(request, string.format("agent timed out after %d ms", timeout_ms))
  end))
end

-- Spawned agents --------------------------------------------------------------

--- A one-line status from what the agent has streamed so far: its summary
--- once it starts writing one, otherwise the tail of its thinking.
local function progress_status(stream)
  local summary = stream.text:match('"summary"%s*:%s*"([^"]*)')
  if summary and summary ~= "" then
    return summary
  end
  if stream.tool ~= "" then
    return "looking around: " .. stream.tool
  end
  if stream.text ~= "" then
    return "writing reply…"
  end
  if stream.thinking ~= "" then
    local tail = vim.trim(stream.thinking:gsub("%s+", " "))
    return "thinking: …" .. vim.fn.strcharpart(tail, math.max(0, vim.fn.strchars(tail) - 55))
  end
  return nil
end

local function action_status(action, code_actions)
  if action.type == "edit" then
    return string.format("editing %d place%s", #action.edits, #action.edits == 1 and "" or "s")
  elseif action.type == "lsp_rename" then
    return "renaming to " .. action.new_name .. " with the language server"
  elseif action.type == "code_action" then
    local entry = code_actions[action.id]
    return "running code action: " .. (entry and entry.title or tostring(action.id))
  elseif action.type == "lua" then
    return "running Lua in Neovim"
  end
  return nil
end

--- Where the user is now, for the agent's Lua.
local function lua_context(request)
  local snapshot = request.snapshot
  local bufnr = snapshot.bufnr
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    win = vim.fn.bufwinid(bufnr)
  end
  local moved = shift(request)
  local selection = snapshot.selection
      and { start_row = snapshot.selection.start_row + moved, end_row = snapshot.selection.end_row + moved }
    or nil
  return {
    bufnr = bufnr,
    win = win ~= -1 and win or nil,
    row = current_row(request),
    col = snapshot.position.col,
    file = snapshot.path,
    filetype = snapshot.filetype,
    selection = selection,
    instruction = request.instruction,
  }
end

--- Run the agent's Lua, asking first unless allowed, and keep the report for
--- its next turn. Declining is not an error: the agent is told and goes on.
run_lua_action = function(request, action, on_done)
  local function record(result)
    request.lua_results[#request.lua_results + 1] = result
    on_done(nil)
  end
  local function run()
    request.spinner:set_status("running Lua in Neovim")
    run_lua.run(action.code, lua_context(request), M.config.lua_timeout_ms, function(report, ok)
      if not ok then
        -- The agent gets the error and may fix it; say so, so it is not silent.
        local first = report:match("error: ([^\n]*)") or report
        notify("the agent's Lua failed, so it was told and may try again: " .. first, vim.log.levels.WARN)
      end
      record(report)
    end)
  end
  if M.config.lua == "allow" or request.lua_allowed then
    return run()
  end
  request.spinner:set_status("waiting for you to allow its Lua…")
  run_lua.confirm(action.code, agent_name() .. " wants to run Lua", function(choice)
    if request.finished then
      return
    end
    if choice == "skip" then
      return record("the user declined to run this code")
    end
    request.lua_allowed = choice == "always"
    run()
  end)
end

--- Run one action against the buffer as it is now. Calls `on_done(err)`.
local function run_action(request, action, on_done)
  local snapshot = request.snapshot
  local bufnr = snapshot.bufnr

  if action.type == "edit" then
    local rebased, err = edits.rebase(action.edits, snapshot.lines, bufnr, shift(request))
    return on_done(err or edits.apply(bufnr, rebased))
  end

  if action.type == "lsp_rename" then
    -- Rename whatever is at the cursor's spot now, if it is still the word
    -- the agent was asked about.
    local row = current_row(request)
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
    local entry = request.code_actions[action.id]
    if not entry then
      return on_done(string.format("the agent picked code action %d, which does not exist", action.id))
    end
    return lsp.run_code_action(bufnr, entry, on_done)
  end

  if action.type == "message" then
    show_answer(request, action.text)
    return on_done(nil)
  end

  if action.type == "lua" then
    return run_lua_action(request, action, on_done)
  end
end

--- Run `actions` one after another; each may be asynchronous.
local function run_actions(request, actions, on_done, index)
  index = index or 1
  local action = actions[index]
  if not action then
    return on_done(nil)
  end
  request.spinner:set_status(action_status(action, request.code_actions))
  run_action(request, action, function(err)
    if err then
      return on_done(err)
    end
    vim.schedule(function()
      run_actions(request, actions, on_done, index + 1)
    end)
  end)
end

local function handle_reply(request, result, reply)
  local log = request.log
  log.stdout = (log.stdout and log.stdout .. "\n\n--- next turn ---\n\n" or "") .. reply
  log.stderr = result.stderr

  if request.finished then
    return -- cancelled or timed out; the reply came too late
  end
  if result.code ~= 0 then
    return finish(
      request,
      string.format("agent exited with code %d: %s", result.code, vim.trim(result.stderr or ""):sub(-500))
    )
  end

  if request.session and request.command then
    local id = request.command.session_id
      or (request.command.read_session_id and request.command.read_session_id(result))
    if id and request.session == session then
      session.id, session.started = id, true
      log.session = id
    end
  end

  local response, parse_err = protocol.parse(reply)
  if not response then
    return finish(request, parse_err)
  end
  log.response = response

  if not vim.api.nvim_buf_is_valid(request.snapshot.bufnr) then
    return finish(request, "the buffer was closed while the agent was working")
  end

  local function has(kind)
    return vim.iter(response.actions):any(function(action)
      return action.type == kind
    end)
  end
  if has("lua") and not M.config.lua then
    return finish(request, "the agent sent Lua to run, but `lua` is off")
  end

  request.lua_results = {}
  run_actions(request, response.actions, function(err)
    if err then
      return finish(request, err)
    end
    -- Lua without an answer is a step: the agent gets the results and goes on.
    if has("lua") and not has("message") and not request.finished then
      request.turns[#request.turns + 1] = { reply = reply, results = request.lua_results }
      if #request.turns >= M.config.max_turns then
        return finish(request, string.format("the agent used all %d steps without finishing", M.config.max_turns))
      end
      return start_agent(request)
    end
    if response.summary and not has("message") then
      notify(response.summary)
    end
    finish(request, nil)
  end)
end

--- The first prompt, followed by every earlier reply and what its Lua did.
local function turn_prompt(request)
  -- In a session the agent remembers its replies; send only what is new.
  if request.session and #request.turns > 0 then
    local parts = {}
    for j, result in ipairs(request.turns[#request.turns].results) do
      parts[#parts + 1] = string.format("Result of lua action %d:\n%s\n\n", j, result)
    end
    parts[#parts + 1] = string.format(
      "Continue with your next reply (step %d of at most %d). Reply with exactly one JSON object in the"
        .. " same format as before, {\"summary\": ..., \"actions\": [...]}, and nothing else.",
      #request.turns + 1,
      M.config.max_turns
    )
    return table.concat(parts)
  end
  local parts = { request.first_prompt }
  for i, turn in ipairs(request.turns) do
    parts[#parts + 1] = string.format("\n\nYour reply %d:\n%s", i, vim.trim(turn.reply))
    for j, result in ipairs(turn.results) do
      parts[#parts + 1] = string.format("\n\nResult of lua action %d:\n%s", j, result)
    end
  end
  if #request.turns > 0 then
    parts[#parts + 1] = string.format(
      "\n\nContinue with your next reply (step %d of at most %d). Reply with exactly one JSON object in the"
        .. " same format as before, {\"summary\": ..., \"actions\": [...]}, and nothing else.",
      #request.turns + 1,
      M.config.max_turns
    )
  end
  return table.concat(parts)
end

start_agent = function(request)
  local snapshot = request.snapshot
  if not request.first_prompt then
    request.first_prompt = context.render(snapshot, request.instruction, {
      can_rename = lsp.can_rename(snapshot.bufnr),
      code_actions = request.code_actions,
    }, M.config.max_lines)
    if M.config.lua then
      request.first_prompt = "Neovim: " .. introspect.summary(snapshot.bufnr) .. "\n" .. request.first_prompt
    end
    request.turns = {}
  end
  local prompt = turn_prompt(request)
  request.log.prompt = prompt
  start_timeout(request, M.config.timeout_ms)

  request.session = current_session()
  local command, command_err = agent_command(prompt)
  if not command then
    return finish(request, command_err)
  end
  request.command = command
  request.log.argv = command.argv

  local make_decoder = agents.decoders[command.output or "text"]
  if not make_decoder then
    return finish(request, "unknown agent output format " .. vim.inspect(command.output))
  end
  local decoder = make_decoder()
  local stream = { text = "", thinking = "", tool = "" }
  request.spinner:set_status("waiting for the agent…")

  local ok, process = pcall(vim.system, command.argv, {
    stdin = command.stdin,
    text = true,
    stdout = function(_, chunk)
      if not chunk then
        return
      end
      vim.schedule(function()
        for _, event in ipairs(decoder.feed(chunk)) do
          if event.kind == "tool" then
            stream.tool = event.delta
          else
            stream[event.kind] = stream[event.kind] .. event.delta
          end
        end
        if not request.finished then
          request.spinner:set_status(progress_status(stream))
        end
      end)
    end,
  }, function(result)
    vim.schedule(function()
      handle_reply(request, result, decoder.reply())
    end)
  end)
  if not ok then
    return finish(request, "could not start the agent: " .. tostring(process))
  end
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

-- Axo Sessions ----------------------------------------------------------------

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

  local nonce = string.format("%x%04x", os.time(), math.random(0, 0xffff))
  local prompt = context.render_session(moved, request.instruction, nonce, M.config.system_prompt)
  request.log.prompt = prompt
  request.log.argv = { M.config.axo.cmd, "session", "prompt", "--sid", M.config.axo.session }
  start_timeout(request, M.config.axo.timeout_ms)
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

  local delegated = M.config.agent == "axo"
  if delegated and vim.api.nvim_buf_get_name(bufnr) == "" then
    return notify("save the buffer to a file first; the session's agent edits files", vim.log.levels.ERROR)
  end

  local request = {
    instruction = instruction,
    -- The session's agent's turn reloads files itself; spawned agents may
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
    if not M.config.session then
      return start_agent(request)
    end
    if session_busy then
      request.spinner:set_status("queued behind another request…")
    end
    session_queue[#session_queue + 1] = request
    start_next_in_session()
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
    if instruction then
      M.run(instruction, {
        bufnr = bufnr,
        position = { row = cursor[1], col = cursor[2] },
        selection = selection,
      })
    end
  end
  if M.config.input == "cmdline" then
    vim.ui.input({ prompt = agent_name() .. ": " }, submit)
  else
    input.open({ title = "ask " .. agent_name() }, submit)
  end
end

--- Start a fresh conversation for the next request. Requests already
--- running finish in the old one.
function M.new_session()
  session = nil
  notify("the next request starts a new conversation")
end

--- The conversation requests continue, if one has started.
function M.session()
  return session and session.started and vim.deepcopy(session) or nil
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

--- Merge `opts` over `base` into a checked config, or raise.
local function build_config(base, opts)
  local config = vim.tbl_deep_extend("force", vim.deepcopy(base), opts)
  -- Lists merge index by index; given args replace the old ones.
  config.args = opts.args or config.args
  if config.agent ~= "axo" then
    local _, err = agents.resolve(config.agent)
    if err then
      error("agent-mode: " .. err, 3)
    end
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
    vim.keymap.set({ "n", "x" }, config.keymap, M.prompt, { desc = "agent-mode: ask the agent" })
    mapped_keymap = config.keymap
  end
  M.config = config
end

--- Configure agent-mode from scratch: `opts` over the defaults.
function M.setup(opts)
  apply(build_config(defaults, opts or {}))
end

--- Change some settings at runtime, keeping the rest, e.g.
---   require("agent_mode").configure({ agent = "axo" })
---   require("agent_mode").configure({ model = "sonnet", thinking = "low" })
--- Running requests keep the settings they started with.
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

--- The agents :AgentModeAgent can switch to.
M.agent_names = vim.list_extend(vim.deepcopy(agents.presets), { "axo" })

return M
