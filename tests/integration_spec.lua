-- End-to-end tests of a request, with a scripted agent standing in for the
-- model (tests/fake_agent.sh) and, when installed, a real Lua language server.
--   nvim --headless -l tests/integration_spec.lua

local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local agent_mode = require("agent_mode")

local stdin_file = vim.fn.tempname()

--- Configure agent-mode to use the fake agent, which replies with `reply`
--- after `delay` seconds.
local function fake_agent(reply, delay)
  vim.env.AGENT_MODE_FAKE_REPLY = type(reply) == "table" and vim.json.encode(reply) or reply
  vim.env.AGENT_MODE_FAKE_DELAY = tostring(delay or 0)
  vim.env.AGENT_MODE_FAKE_STDIN = stdin_file
  agent_mode.setup({
    keymap = false,
    code_action_timeout_ms = 3000,
    agent = function(request)
      return { argv = { H.root .. "/tests/fake_agent.sh" }, stdin = request.system_prompt .. "\n---\n" .. request.prompt }
    end,
  })
end

local function sent_prompt()
  return table.concat(vim.fn.readfile(stdin_file), "\n")
end

H.test("an edit reply updates the buffer in place", function()
  local buf = H.buffer({ "local foo = 1", "print(foo)" }, "lua")
  fake_agent({
    summary = "Renamed foo to presenter",
    actions = { { type = "edit", edits = {
      { start_line = 1, end_line = 2, text = "local presenter = 1\nprint(presenter)" },
    } } },
  })
  local err = H.run_agent("rename to presenter", { position = { row = 1, col = 6 } })
  H.eq(nil, err)
  H.eq({ "local presenter = 1", "print(presenter)" }, H.lines(buf))
  H.contains(sent_prompt(), "Instruction: rename to presenter")
  H.contains(sent_prompt(), "Word under cursor: foo")
  H.contains(sent_prompt(), "agent-mode")
end)

H.test("the prompt opens right below the cursor and <CR> sends it", function()
  local buf = H.buffer({ "local a = 1", "local b = 2", "local c = 3" }, "lua")
  fake_agent({ actions = { { type = "message", text = "ok" } } })
  agent_mode.configure({ keymap = "<F5>" })
  local code_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(code_win, { 2, 6 })

  -- Watch the prompt window as it opens.
  local input = require("agent_mode.input")
  local open = input.open
  local seen = {}
  input.open = function(opts, on_submit)
    local win = open(opts, on_submit)
    seen.win, seen.title = win, vim.api.nvim_win_get_config(win).title[1][1]
    seen.top = vim.api.nvim_win_get_position(win)[1]
    return win
  end
  local screen = vim.fn.screenpos(code_win, 2, 7)

  -- Type it the way a user does: the key, the question, <CR>. Nothing is
  -- lost, so the prompt is in insert mode as soon as it opens.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<F5>what is b?<CR>", true, false, true), "xt", false)
  input.open = open
  H.truthy(seen.win and seen.win ~= code_win, "a prompt window opened")
  H.eq(screen.row, seen.top, "its top border sits on the row below the cursor")
  H.contains(seen.title, "ask agent")
  H.eq(code_win, vim.api.nvim_get_current_win(), "back in the code")
  vim.wait(50)
  H.eq({ 2, 6 }, vim.api.nvim_win_get_cursor(code_win), "the cursor did not move")
  H.truthy(vim.wait(5000, function()
    return #agent_mode.requests() == 0 and agent_mode.last and agent_mode.last.instruction == "what is b?"
  end, 20), "the request ran")
  H.contains(sent_prompt(), "Instruction: what is b?")
  H.contains(sent_prompt(), "Cursor: line 2")
  agent_mode.dismiss(true)
  H.eq({ "local a = 1", "local b = 2", "local c = 3" }, H.lines(buf))
end)

H.test("<Esc> in the prompt cancels without asking anything", function()
  H.buffer({ "x" })
  local code_win = vim.api.nvim_get_current_win()
  local before = agent_mode.last
  agent_mode.configure({ keymap = "<F5>" })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<F5>never sent<Esc><Esc>", true, false, true), "xt", false)
  H.eq(code_win, vim.api.nvim_get_current_win())
  vim.wait(200)
  H.eq(before, agent_mode.last, "no request was made")
end)

H.test("the user's system prompt is appended to the protocol", function()
  H.buffer({ "x" })
  fake_agent({ actions = { { type = "message", text = "ok" } } })
  agent_mode.config.system_prompt = "Always use snake_case."
  H.eq(nil, H.run_agent("anything", { position = { row = 1, col = 0 } }))
  H.contains(sent_prompt(), "Additional instructions from the user:\nAlways use snake_case.")
end)

H.test("an edit whose lines changed meanwhile is not applied", function()
  local buf = H.buffer({ "local foo = 1" }, "lua")
  fake_agent({ actions = { { type = "edit", edits = { { start_line = 1, end_line = 1, text = "local bar = 1" } } } } }, 0.3)
  local done, result = false, nil
  agent_mode.run("rename to bar", {
    position = { row = 1, col = 6 },
    on_done = function(err)
      done, result = true, err
    end,
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, true, { "local foo = 2" })
  H.truthy(vim.wait(5000, function()
    return done
  end, 20))
  H.contains(result, "changed while the agent was working")
  H.eq({ "local foo = 2" }, H.lines(buf))
end)

--- Configure agent-mode with an agent that picks its reply and delay by the
--- instruction: replies[instruction] = { reply, delay }.
local function scripted_agent(replies, extra)
  agent_mode.setup(vim.tbl_extend("force", {
    keymap = false,
    code_action_timeout_ms = 3000,
    agent = function(request)
      local instruction = request.prompt:match("Instruction: ([^\n]*)")
      local script = replies[instruction]
      return {
        argv = { H.root .. "/tests/fake_agent.sh", vim.json.encode(script[1]), tostring(script[2]) },
        stdin = request.prompt,
        output = script.output,
      }
    end,
  }, extra or {}))
end

--- Start requests without waiting; returns a table of results by instruction
--- and a function that waits for all of them.
local function start_all(list)
  local results, pending = {}, #list
  for _, item in ipairs(list) do
    agent_mode.run(item[1], {
      position = item[2],
      on_done = function(err)
        results[item[1]] = err or "ok"
        pending = pending - 1
      end,
    })
  end
  return results, function()
    H.truthy(vim.wait(10000, function()
      return pending == 0
    end, 20), "requests did not finish")
  end
end

H.test("requests run at once and each edit lands on its own line as lines move", function()
  local buf = H.buffer({ "local a = 1", "local b = 2", "local c = 3" }, "lua")
  scripted_agent({
    -- Finishes first and adds two lines above the other request's line.
    ["document a"] = { { actions = { { type = "edit", edits = {
      { start_line = 1, end_line = 0, text = "-- a is one\n-- really" },
    } } } }, 0.1 },
    -- Finishes later, written against the original line numbers.
    ["rename c"] = { { actions = { { type = "edit", edits = {
      { start_line = 3, end_line = 3, text = "local see = 3" },
    } } } }, 0.6 },
  })
  local results, wait = start_all({
    { "rename c", { row = 3, col = 6 } },
    { "document a", { row = 1, col = 6 } },
  })
  vim.wait(50)
  H.eq(2, #agent_mode.requests(), "both requests are running")
  wait()
  H.eq({ ["rename c"] = "ok", ["document a"] = "ok" }, results)
  H.eq({ "-- a is one", "-- really", "local a = 1", "local b = 2", "local see = 3" }, H.lines(buf))
end)

H.test("a question's answer shows inline below its line, and the dismiss key clears it", function()
  local buf = H.buffer({ "local a = 1", "local b = a + 1", "return b" }, "lua")
  local answer = require("agent_mode.answer")
  scripted_agent({
    ["what is b?"] = { { summary = "Explaining b", actions = { { type = "message", text = "b is a plus one, so 2." } } }, 0.2 },
    ["what is a?"] = { { actions = { { type = "message", text = "a is 1." } } }, 0.1 },
  })
  local results, wait = start_all({
    { "what is b?", { row = 2, col = 6 } },
    { "what is a?", { row = 1, col = 6 } },
  })
  wait()
  H.eq({ ["what is b?"] = "ok", ["what is a?"] = "ok" }, results)
  H.eq({ "local a = 1", "local b = a + 1", "return b" }, H.lines(buf), "answers do not touch the code")
  local shown = answer.list(buf)
  H.eq(2, #shown)
  H.eq(1, shown[1].row)
  H.contains(table.concat(shown[1].lines, "\n"), "a is 1.")
  H.contains(shown[2].lines[1], "agent: what is b?", "titled with the agent's name")
  H.contains(table.concat(shown[2].lines, "\n"), "b is a plus one, so 2.")

  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  shown = answer.list(buf)
  H.eq(1, #shown)
  H.eq(1, shown[1].row)
  agent_mode.dismiss(true)
  H.eq(0, #answer.list(buf))
end)

H.test("the spinner shows the summary while the agent is still writing", function()
  H.buffer({ "local a = 1" }, "lua")
  local function event(update)
    return vim.json.encode({ type = "message_update", assistantMessageEvent = update })
  end
  local final = '{"summary": "Renaming a to alpha", "actions": [{"type": "message", "text": "ok"}]}'
  local stream = table.concat({
    event({ type = "thinking_delta", delta = "The user wants a rename" }),
    event({ type = "text_delta", delta = '{"summary": "Renaming a to alpha", ' }),
    event({ type = "text_delta", delta = '"actions": [{"type": "message", "text": "ok"}]}' }),
    vim.json.encode({ type = "message_end", message = { role = "assistant", content = { { type = "text", text = final } } } }),
  }, "\n")
  vim.env.AGENT_MODE_FAKE_LINES = "0.4"
  agent_mode.setup({
    keymap = false,
    agent = function(request)
      return { argv = { H.root .. "/tests/fake_agent.sh", stream, "0" }, stdin = request.prompt, output = "pi-json" }
    end,
  })
  local seen = {}
  local done = false
  agent_mode.run("rename a to alpha", {
    position = { row = 1, col = 6 },
    on_done = function()
      done = true
    end,
  })
  vim.wait(5000, function()
    local request = agent_mode.requests()[1]
    if request then
      seen[request.spinner:status()] = true
    end
    return done
  end, 20)
  vim.env.AGENT_MODE_FAKE_LINES = nil
  H.truthy(seen["thinking: …The user wants a rename"], "thinking shown: " .. vim.inspect(seen))
  H.truthy(seen["Renaming a to alpha"], "summary shown: " .. vim.inspect(seen))
end)

H.test("an unparseable reply leaves the buffer alone and is logged", function()
  local buf = H.buffer({ "local foo = 1" }, "lua")
  fake_agent("I have renamed the variable for you!")
  local err = H.run_agent("rename to bar", { position = { row = 1, col = 6 } })
  H.contains(err, "no JSON object")
  H.eq({ "local foo = 1" }, H.lines(buf))
  H.eq("I have renamed the variable for you!", agent_mode.last.stdout)
end)

H.test("an agent that fails reports its stderr", function()
  H.buffer({ "x" })
  fake_agent("")
  vim.env.AGENT_MODE_FAKE_EXIT = "3"
  local err = H.run_agent("anything", { position = { row = 1, col = 0 } })
  vim.env.AGENT_MODE_FAKE_EXIT = nil
  H.contains(err, "exited with code 3")
end)

H.test("a slow agent times out", function()
  H.buffer({ "x" })
  fake_agent({ actions = { { type = "message", text = "late" } } }, 5)
  agent_mode.config.timeout_ms = 300
  local err = H.run_agent("anything", { position = { row = 1, col = 0 } }, 3000)
  H.contains(err, "timed out")
end)

H.test("cancel stops a running request", function()
  local buf = H.buffer({ "local foo = 1" }, "lua")
  fake_agent({ actions = { { type = "edit", edits = { { start_line = 1, end_line = 1, text = "nope" } } } } }, 5)
  local done, result = false, nil
  agent_mode.run("anything", {
    position = { row = 1, col = 0 },
    on_done = function(err)
      done, result = true, err
    end,
  })
  vim.wait(200)
  agent_mode.cancel()
  H.truthy(vim.wait(3000, function()
    return done
  end, 20), "cancel did not stop the request")
  H.eq("cancelled", result)
  H.eq({ "local foo = 1" }, H.lines(buf))
end)

-- Delegating to an Axo Session ---------------------------------------------

--- A saved file holding `lines`, open in the current buffer, and agent-mode
--- configured to delegate to the fake axo CLI.
local function axo_session(lines, reply, stop_reason)
  local path = vim.fn.tempname() .. ".js"
  vim.fn.writefile(lines, path)
  vim.cmd("edit " .. path)
  vim.env.AGENT_MODE_FAKE_TRANSCRIPT = vim.fn.tempname()
  vim.fn.writefile({ '{"type":"session","id":"fake"}' }, vim.env.AGENT_MODE_FAKE_TRANSCRIPT)
  vim.env.AGENT_MODE_FAKE_STDIN = stdin_file
  vim.env.AGENT_MODE_FAKE_REPLY = reply or "Renamed message to presenter."
  vim.env.AGENT_MODE_FAKE_STOP = stop_reason
  vim.env.AGENT_MODE_FAKE_EDIT_FILE = path
  agent_mode.setup({ agent = "axo", keymap = false, axo = { cmd = H.root .. "/tests/fake_axo.sh", session = "fake" } })
  return vim.api.nvim_get_current_buf(), path
end

H.test("axo: the session's agent edits the file and the buffer reloads", function()
  local buf = axo_session({ "const message = 1;", "log(message);" })
  vim.env.AGENT_MODE_FAKE_EDIT_CONTENT = "const presenter = 1;\nlog(presenter);"
  -- An unsaved change is written before the agent sees the file.
  vim.api.nvim_buf_set_lines(buf, 1, 2, true, { "console.log(message);" })
  local err = H.run_agent("rename to presenter", { position = { row = 1, col = 7 } })
  H.eq(nil, err)
  H.contains(sent_prompt(), "Instruction: rename to presenter")
  H.contains(sent_prompt(), "File: " .. vim.api.nvim_buf_get_name(buf))
  H.contains(sent_prompt(), "Word under cursor: message")
  H.eq({ "const presenter = 1;", "log(presenter);" }, H.lines(buf))
  H.eq(false, vim.bo[buf].modified)
  H.eq("Renamed message to presenter.", agent_mode.last.stdout)
end)

H.test("axo: the buffer was saved before the prompt went out", function()
  local buf, path = axo_session({ "a" })
  vim.env.AGENT_MODE_FAKE_EDIT_FILE = ""
  vim.api.nvim_buf_set_lines(buf, 0, -1, true, { "unsaved" })
  H.eq(nil, H.run_agent("anything", { position = { row = 1, col = 0 } }))
  H.eq({ "unsaved" }, vim.fn.readfile(path))
end)

H.test("axo: a reply without edits is an answer, shown inline", function()
  local buf = axo_session({ "const message = 1;" }, "It holds the greeting.")
  vim.env.AGENT_MODE_FAKE_EDIT_FILE = ""
  H.eq(nil, H.run_agent("what is message for?", { position = { row = 1, col = 7 } }))
  local shown = require("agent_mode.answer").list(buf)
  H.eq(1, #shown)
  H.contains(shown[1].lines[1], "axo: what is message for?")
  H.contains(table.concat(shown[1].lines, "\n"), "It holds the greeting.")
  H.eq({ "const message = 1;" }, H.lines(buf))
  agent_mode.dismiss(true)
end)

H.test("axo: requests to the session go one at a time", function()
  axo_session({ "a", "b" }, "Answer.")
  vim.env.AGENT_MODE_FAKE_EDIT_FILE = ""
  local done = 0
  for row = 1, 2 do
    agent_mode.run("question " .. row, {
      position = { row = row, col = 0 },
      on_done = function()
        done = done + 1
      end,
    })
  end
  local statuses = vim.tbl_map(function(r)
    return r.spinner:status()
  end, agent_mode.requests())
  H.contains(statuses[2], "queued")
  H.truthy(vim.wait(10000, function()
    return done == 2
  end, 20))
  H.contains(sent_prompt(), "Instruction: question 2")
  agent_mode.dismiss(true)
end)

H.test("axo: an aborted turn is reported and nothing reloads", function()
  local buf = axo_session({ "a" }, "Operation aborted", "aborted")
  vim.env.AGENT_MODE_FAKE_EDIT_FILE = ""
  local err = H.run_agent("anything", { position = { row = 1, col = 0 } })
  H.contains(err, "stopped (aborted)")
  H.eq({ "a" }, H.lines(buf))
end)

H.test("axo: an unnamed buffer is refused", function()
  agent_mode.setup({ agent = "axo", keymap = false })
  H.buffer({ "x" })
  local messages = {}
  local notify = vim.notify
  vim.notify = function(message)
    messages[#messages + 1] = message
  end
  agent_mode.run("anything", { position = { row = 1, col = 0 } })
  vim.notify = notify
  H.contains(messages[1], "save the buffer")
end)

-- With a real language server -------------------------------------------------

local luals = vim.fn.exepath("lua-language-server")
if luals == "" then
  luals = vim.fn.stdpath("data") .. "/mason/bin/lua-language-server"
end

local function lsp_buffer()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/presenter.lua"
  vim.fn.writefile({
    "local function render(view)",
    "  return view.title",
    "end",
    "",
    "local view = { title = 'hi' }",
    "print(render(view))",
  }, path)
  vim.cmd("edit " .. path)
  local buf = vim.api.nvim_get_current_buf()
  local client_id = vim.lsp.start({ name = "lua_ls", cmd = { luals }, root_dir = dir })
  H.truthy(vim.wait(20000, function()
    local client = vim.lsp.get_client_by_id(client_id)
    return client and client.initialized
  end, 50), "lua-language-server did not start")
  -- Give the server a moment to index the file before asking it things.
  vim.wait(1500)
  return buf, client_id
end

if vim.fn.executable(luals) == 1 then
  H.test("lsp_rename renames through the language server", function()
    local buf, client_id = lsp_buffer()
    fake_agent({ actions = { { type = "lsp_rename", new_name = "presenter" } } })
    local err = H.run_agent("rename to presenter", { bufnr = buf, position = { row = 5, col = 6 } }, 20000)
    H.eq(nil, err)
    H.contains(sent_prompt(), "LSP rename: available")
    H.eq({
      "local function render(view)",
      "  return view.title",
      "end",
      "",
      "local presenter = { title = 'hi' }",
      "print(render(presenter))",
    }, H.lines(buf))
    vim.lsp.get_client_by_id(client_id):stop(true)
  end)

  H.test("code_action runs the action the agent picked from the list", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "print(undefined_thing)" }, dir .. "/globals.lua")
    vim.cmd("edit " .. dir .. "/globals.lua")
    local buf = vim.api.nvim_get_current_buf()
    local client_id = vim.lsp.start({ name = "lua_ls", cmd = { luals }, root_dir = dir })
    H.truthy(vim.wait(20000, function()
      return #vim.diagnostic.get(buf) > 0
    end, 50), "lua-language-server reported no diagnostics")

    -- Find the action's id the way the agent would: by its title in the list.
    local listed
    require("agent_mode.lsp").code_actions(buf, { row = 1, col = 7 }, 3000, function(actions)
      listed = actions
    end)
    H.truthy(vim.wait(4000, function()
      return listed
    end))
    local pick
    for _, entry in ipairs(listed) do
      if entry.title:find("on this line", 1, true) then
        pick = entry.id
      end
    end
    H.truthy(pick, "no 'disable on this line' action offered")

    fake_agent({ actions = { { type = "code_action", id = pick } } })
    H.eq(nil, H.run_agent("silence this warning", { bufnr = buf, position = { row = 1, col = 7 } }, 20000))
    H.contains(sent_prompt(), "Code actions at the cursor:")
    H.eq({ "---@diagnostic disable-next-line: undefined-global", "print(undefined_thing)" }, H.lines(buf))
    vim.lsp.get_client_by_id(client_id):stop(true)
  end)
else
  io.stdout:write("skip lsp tests: lua-language-server not found\n")
end

--- An agent that answers each turn with the next of `replies`, and keeps
--- the prompts it was sent.
local function scripted_agent(replies, opts)
  local prompts = {}
  agent_mode.setup(vim.tbl_extend("force", {
    keymap = false,
    lua = "allow",
    session = false,
    agent = function(request)
      prompts[#prompts + 1] = request.prompt
      local reply = replies[#prompts] or replies[#replies]
      return { argv = { H.root .. "/tests/fake_agent.sh", vim.json.encode(reply), "0" }, stdin = "" }
    end,
  }, opts or {}))
  return prompts
end

H.test("requests share one session and run one at a time", function()
  local buf = H.buffer({ "local a = 1", "local b = 2" }, "lua")
  local calls = {}
  agent_mode.setup({
    keymap = false,
    agent = function(request)
      calls[#calls + 1] = { session = request.session, at = vim.uv.hrtime() }
      return {
        argv = { H.root .. "/tests/fake_agent.sh", '{"actions":[{"type":"message","text":"ok"}]}', "0.3" },
        stdin = "",
        session_id = request.session.id or "sess-1",
      }
    end,
  })
  local done = 0
  for row = 1, 2 do
    agent_mode.run("q" .. row, { bufnr = buf, position = { row = row, col = 0 }, on_done = function() done = done + 1 end })
  end
  H.truthy(vim.wait(5000, function() return done == 2 end, 20))
  H.eq({ started = false }, calls[1].session, "the first request starts it")
  H.eq({ id = "sess-1", started = true }, calls[2].session, "the second continues it")
  H.truthy((calls[2].at - calls[1].at) / 1e6 >= 300, "the second waited for the first")
  H.eq("sess-1", agent_mode.session().id)
  agent_mode.new_session()
  H.eq(nil, agent_mode.session())
  agent_mode.dismiss(true)
end)

H.test(":AgentMode config is a vim.ui.select menu that comes back after each change", function()
  agent_mode.setup({ keymap = false, agent = "pi", model = "m1", thinking = "high" })
  local select, input = vim.ui.select, vim.ui.input
  -- Each step picks the item whose text starts with the given string, from
  -- the menu with that prompt; then the menu reopens.
  local script = {
    { "agent-mode", "Agent" }, { "Agent", "claude" },
    { "agent-mode", "Model" }, { "Model for claude", "type a model" },
    { "agent-mode", "Thinking" }, { "Thinking", "max" },
    { "agent-mode", "Run Lua" }, { "Let the agent run Lua in Neovim", "off" },
    { "agent-mode", "Conversation" },
    { "agent-mode", "Copy as Lua" }, -- copies and closes the menu
  }
  local menus = {}
  vim.ui.select = function(items, opts, on_choice)
    local step = table.remove(script, 1)
    H.eq(step[1], opts.prompt)
    local format = opts.format_item or tostring
    menus[#menus + 1] = vim.tbl_map(format, items)
    for _, item in ipairs(items) do
      if step[2] and vim.startswith(format(item), step[2]) then
        return on_choice(item)
      end
    end
    on_choice(nil)
  end
  vim.ui.input = function(_, on_confirm)
    on_confirm("opus")
  end
  agent_mode.open_config()
  H.truthy(vim.wait(2000, function() return #script == 0 end), "the menu did not come back after each change")
  vim.ui.select, vim.ui.input = select, input
  H.contains(table.concat(menus[1], "\n"), "Agent             pi")
  H.eq("claude", agent_mode.config.agent)
  H.eq("opus", agent_mode.config.model)
  H.eq("max", agent_mode.config.thinking)
  H.eq(false, agent_mode.config.lua)
  H.eq(false, agent_mode.config.session)
  H.eq('require("agent_mode").setup({\n  agent = "claude",\n  model = "opus",\n  thinking = "max",\n  lua = false,\n  session = false,\n})', vim.fn.getreg('"'))
end)

H.test("files the agent changed on disk are reloaded, unless they have unsaved changes", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local other, dirty = dir .. "/other.lua", dir .. "/dirty.lua"
  vim.fn.writefile({ "local old = 1" }, other)
  vim.fn.writefile({ "local a = 1" }, dirty)
  vim.cmd("edit " .. vim.fn.fnameescape(other))
  local other_buf = vim.api.nvim_get_current_buf()
  vim.cmd("edit " .. vim.fn.fnameescape(dirty))
  local dirty_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(dirty_buf, 0, -1, false, { "local mine = 1" })
  local here = H.buffer({ "x" }, "lua")
  -- The "agent" rewrites both files, then answers.
  local script = string.format(
    "sleep 1.1; echo 'local new = 2' > %s; echo 'local theirs = 2' > %s; printf '%%s' '{\"actions\":[{\"type\":\"message\",\"text\":\"ok\"}]}'",
    other, dirty
  )
  agent_mode.setup({ keymap = false, session = false, agent = function()
    return { argv = { "sh", "-c", script }, stdin = "" }
  end })
  H.eq(nil, H.run_agent("change the other files", { bufnr = here, position = { row = 1, col = 0 } }))
  H.eq({ "local new = 2" }, H.lines(other_buf), "reloaded")
  H.eq({ "local mine = 1" }, H.lines(dirty_buf), "unsaved changes kept")
  agent_mode.dismiss(true)
  vim.cmd("bwipeout! " .. other_buf .. " " .. dirty_buf)
end)

H.test("lua results go back to the agent until it answers", function()
  local buf = H.buffer({ "local a = 1" }, "lua")
  local prompts = scripted_agent({
    { summary = "Looking", actions = { { type = "lua", code = "return { line = ctx.row, n = 41 + 1 }" } } },
    { actions = { { type = "message", text = "it is 42" } } },
  })
  H.eq(nil, H.run_agent("what is it?", { position = { row = 1, col = 0 } }))
  H.eq(2, #prompts)
  H.contains(prompts[1], "Neovim: Neovim 0.")
  H.contains(prompts[2], "Your reply 1:", "without a session, the transcript is resent")
  H.contains(prompts[2], "Result of lua action 1:\nreturned:\n{\n  line = 1,\n  n = 42\n}")
  H.contains(prompts[2], "step 2 of at most 8). Reply with exactly one JSON object")
  agent_mode.dismiss(true)
end)

H.test("a request stops after max_turns rounds of lua", function()
  H.buffer({ "local a = 1" }, "lua")
  local prompts = scripted_agent({ { actions = { { type = "lua", code = "return 1" } } } }, { max_turns = 3 })
  H.contains(H.run_agent("loop", { position = { row = 1, col = 0 } }), "used all 3 steps")
  H.eq(3, #prompts)
end)

H.test("with lua = confirm, declining tells the agent; with lua off, it is not offered", function()
  H.buffer({ "local a = 1" }, "lua")
  local run_lua = require("agent_mode.run_lua")
  local confirm = run_lua.confirm
  run_lua.confirm = function(_, _, on_choice)
    vim.schedule(function() on_choice("skip") end)
  end
  local prompts = scripted_agent({
    { actions = { { type = "lua", code = "vim.g.ran = true" } } },
    { actions = { { type = "message", text = "ok" } } },
  }, { lua = "confirm" })
  H.eq(nil, H.run_agent("try", { position = { row = 1, col = 0 } }))
  run_lua.confirm = confirm
  H.eq(nil, vim.g.ran)
  H.contains(prompts[2], "the user declined to run this code")
  agent_mode.dismiss(true)

  local seen
  agent_mode.setup({ keymap = false, lua = false, agent = function(request)
    seen = request.system_prompt
    return { argv = { H.root .. "/tests/fake_agent.sh", '{"actions":[{"type":"lua","code":"return 1"}]}', "0" }, stdin = "" }
  end })
  H.contains(H.run_agent("try", { position = { row = 1, col = 0 } }), "`lua` is off")
  H.truthy(not seen:find('"type": "lua"', 1, true), "lua offered while off")
end)

H.run()
