-- Unit tests for the pure parts: the reply protocol, line edits, context
-- rendering, and agent command building.
--   nvim --headless -l tests/unit_spec.lua

local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local protocol = require("agent_mode.protocol")
local edits = require("agent_mode.edits")
local context = require("agent_mode.context")
local agents = require("agent_mode.agents")

-- protocol ------------------------------------------------------------------

H.test("protocol parses every action type", function()
  local response = assert(protocol.parse(vim.json.encode({
    summary = "did things",
    actions = {
      { type = "edit", edits = { { start_line = 1, end_line = 2, text = "x" } } },
      { type = "lsp_rename", new_name = "presenter" },
      { type = "code_action", id = 3 },
      { type = "message", text = "hi" },
    },
  })))
  H.eq("did things", response.summary)
  H.eq({
    { type = "edit", edits = { { start_line = 1, end_line = 2, text = "x" } } },
    { type = "lsp_rename", new_name = "presenter" },
    { type = "code_action", id = 3 },
    { type = "message", text = "hi" },
  }, response.actions)
end)

H.test("protocol tolerates a markdown fence around the JSON", function()
  local response = assert(protocol.parse('Sure!\n```json\n{"actions":[{"type":"message","text":"ok"}]}\n```'))
  H.eq("ok", response.actions[1].text)
end)

H.test("protocol rejects replies it cannot trust", function()
  local cases = {
    ["no JSON"] = "I renamed it for you",
    ["broken JSON"] = '{"actions": [',
    ["no actions"] = '{"actions": []}',
    ["unknown type"] = '{"actions": [{"type": "delete_file"}]}',
    ["fractional line"] = '{"actions": [{"type": "edit", "edits": [{"start_line": 1.5, "end_line": 2, "text": ""}]}]}',
    ["end before start"] = '{"actions": [{"type": "edit", "edits": [{"start_line": 5, "end_line": 3, "text": ""}]}]}',
    ["empty rename"] = '{"actions": [{"type": "lsp_rename", "new_name": ""}]}',
    ["string id"] = '{"actions": [{"type": "code_action", "id": "1"}]}',
  }
  for name, reply in pairs(cases) do
    local response, err = protocol.parse(reply)
    H.eq(nil, response, name)
    H.truthy(err, name .. " should explain the failure")
  end
end)

-- edits ---------------------------------------------------------------------

H.test("edits apply bottom-up so line numbers stay valid", function()
  local buf = H.buffer({ "a", "b", "c", "d" })
  local err = edits.apply(buf, {
    { start_line = 1, end_line = 1, text = "A1\nA2" },
    { start_line = 3, end_line = 4, text = "CD" },
  })
  H.eq(nil, err)
  H.eq({ "A1", "A2", "b", "CD" }, H.lines(buf))
end)

H.test("edits insert, delete, and drop one trailing newline", function()
  local buf = H.buffer({ "a", "b", "c" })
  H.eq(nil, edits.apply(buf, { { start_line = 2, end_line = 1, text = "new\n" } }))
  H.eq({ "a", "new", "b", "c" }, H.lines(buf))
  H.eq(nil, edits.apply(buf, { { start_line = 3, end_line = 3, text = "" } }))
  H.eq({ "a", "new", "c" }, H.lines(buf))
  H.eq(nil, edits.apply(buf, { { start_line = 4, end_line = 3, text = "end" } }))
  H.eq({ "a", "new", "c", "end" }, H.lines(buf))
end)

H.test("edits refuse overlaps and out-of-range lines without touching the buffer", function()
  local buf = H.buffer({ "a", "b", "c" })
  H.truthy(edits.apply(buf, {
    { start_line = 1, end_line = 2, text = "x" },
    { start_line = 2, end_line = 3, text = "y" },
  }))
  H.truthy(edits.apply(buf, { { start_line = 3, end_line = 4, text = "x" } }))
  H.eq({ "a", "b", "c" }, H.lines(buf))
end)

H.test("all edits of one reply undo in a single step", function()
  local buf = H.buffer({ "a", "b", "c" })
  vim.bo[buf].undolevels = 100
  H.eq(nil, edits.apply(buf, {
    { start_line = 1, end_line = 1, text = "A" },
    { start_line = 3, end_line = 3, text = "C" },
  }))
  H.eq({ "A", "b", "C" }, H.lines(buf))
  vim.cmd("silent undo")
  H.eq({ "a", "b", "c" }, H.lines(buf))
end)

-- context -------------------------------------------------------------------

H.test("word_at finds the identifier under the cursor", function()
  H.eq("user_name", context.word_at("local user_name = 1", 8))
  H.eq("user_name", context.word_at("local user_name = 1", 6))
  H.eq(nil, context.word_at("local user_name = 1", 5))
end)

H.test("visible_range windows long buffers around the cursor", function()
  local lines = {}
  for i = 1, 100 do
    lines[i] = "line " .. i
  end
  local function range(row, max)
    return { context.visible_range({ lines = lines, position = { row = row, col = 0 } }, max) }
  end
  H.eq({ 1, 100 }, range(50, 200))
  H.eq({ 46, 55 }, range(50, 10))
  H.eq({ 1, 10 }, range(2, 10))
  H.eq({ 91, 100 }, range(99, 10))
end)

H.test("the prompt carries the instruction, cursor, capabilities, and numbered buffer", function()
  local buf = H.buffer({ "local x = 1", "print(x)" }, "lua")
  local snapshot = context.capture({ bufnr = buf, position = { row = 2, col = 6 } })
  local prompt = context.render(snapshot, "rename to presenter", {
    can_rename = false,
    code_actions = { { id = 1, title = "Extract variable", kind = "refactor.extract" } },
  }, 2000)
  H.contains(prompt, "Instruction: rename to presenter")
  H.contains(prompt, "Filetype: lua")
  H.contains(prompt, "Cursor: line 2, column 7")
  H.contains(prompt, "Word under cursor: x")
  H.contains(prompt, "LSP rename: not available")
  H.contains(prompt, "1. Extract variable [refactor.extract]")
  H.contains(prompt, "1 | local x = 1")
  H.contains(prompt, "2>| print(x)")
end)

-- agents --------------------------------------------------------------------

local request = {
  system_prompt = "SYSTEM",
  prompt = "PROMPT",
  model = "some-model",
  thinking = "high",
  args = { "--extra" },
}

H.test("the pi agent passes model, thinking, args, and system prompt", function()
  local command = agents.pi(request)
  local argv = table.concat(command.argv, " ")
  H.contains(argv, "pi --print --mode json --tools +codemode")
  H.eq("pi-json", command.output)
  H.contains(argv, "--thinking high")
  H.contains(argv, "--model some-model")
  H.contains(argv, "--extra --system-prompt ")
  H.eq({ "SYSTEM" }, vim.fn.readfile(command.argv[#command.argv]))
  H.eq("PROMPT", command.stdin)
end)

H.test("the codex agent writes only in the workspace and puts the system prompt on stdin", function()
  local command = agents.codex(request)
  local argv = table.concat(command.argv, " ")
  H.contains(argv, "codex exec --skip-git-repo-check --sandbox workspace-write --color never --ephemeral")
  H.contains(argv, 'model_reasoning_effort="high"')
  H.contains(argv, 'model="some-model" --extra -')
  H.contains(command.stdin, "SYSTEM")
  H.contains(command.stdin, "PROMPT")
end)

H.test("the claude agent runs without tools or a saved session", function()
  local command = agents.claude(request)
  local argv = table.concat(command.argv, " ")
  H.contains(argv, "claude --print --output-format text --permission-mode acceptEdits --strict-mcp-config --no-session-persistence")
  H.contains(argv, "--model some-model --effort high --extra --system-prompt-file ")
  H.eq({ "SYSTEM" }, vim.fn.readfile(command.argv[#command.argv]))
  H.eq("PROMPT", command.stdin)
end)

H.test("the opencode agent auto-approves, since nobody can answer", function()
  local command = agents.opencode(request)
  H.eq({ "opencode", "run", "--auto", "--model", "some-model", "--extra" }, command.argv)
  H.contains(command.stdin, "SYSTEM")
  H.contains(command.stdin, "PROMPT")
end)

H.test("each agent starts a session and then continues it", function()
  local function with(session)
    return vim.tbl_extend("force", request, { session = session })
  end
  -- pi and opencode create the session on first use and continue it after.
  local pi = agents.pi(with({ started = false }))
  H.truthy(pi.session_id:match("^%x+%-%x+%-4%x+%-a%x+%-%x+$"), pi.session_id)
  H.contains(table.concat(pi.argv, " "), "--session-id " .. pi.session_id)
  H.truthy(not table.concat(pi.argv, " "):find("--no-session", 1, true))
  H.contains(table.concat(agents.pi(with({ id = "s1", started = true })).argv, " "), "--session-id s1")
  local opencode = agents.opencode(with({ started = false }))
  H.truthy(opencode.session_id:match("^ses_%x+$") and #opencode.session_id == 30, opencode.session_id)
  -- claude refuses --session-id for an existing session, so it resumes.
  local claude = agents.claude(with({ started = false }))
  H.contains(table.concat(claude.argv, " "), "--session-id " .. claude.session_id)
  H.contains(table.concat(agents.claude(with({ id = "c1", started = true })).argv, " "), "--resume c1")
  -- codex says its id on stderr, and resumes with settings as -c.
  local codex = agents.codex(with({ started = false }))
  H.truthy(not table.concat(codex.argv, " "):find("--ephemeral", 1, true))
  H.eq("0199-ab", codex.read_session_id({ stderr = "model: x\nsession id: 0199-ab\n" }))
  local resumed = table.concat(agents.codex(with({ id = "0199-ab", started = true })).argv, " ")
  H.contains(resumed, 'codex exec resume --skip-git-repo-check -c sandbox_mode="workspace-write"')
  H.contains(resumed, "--extra 0199-ab -")
end)

H.test("cmd replaces the agent's executable", function()
  local agent_mode = require("agent_mode")
  agent_mode.setup({ keymap = false, agent = "claude", cmd = "/opt/bin/claude" })
  local captured
  local system = vim.system
  vim.system = function(argv)
    captured = argv
    error("stop here")
  end
  H.buffer({ "x" })
  local err = H.run_agent("anything", { position = { row = 1, col = 0 } })
  vim.system = system
  H.eq("/opt/bin/claude", captured[1])
  H.contains(err, "could not start the agent")
  agent_mode.setup({ keymap = false })
end)

H.test("agents default to quick reasoning when thinking is unset", function()
  local quick = { system_prompt = "SYSTEM", prompt = "PROMPT", args = {} }
  H.contains(table.concat(agents.pi(quick).argv, " "), "--thinking off")
  H.contains(table.concat(agents.codex(quick).argv, " "), 'model_reasoning_effort="low"')
  H.truthy(not table.concat(agents.pi(quick).argv, " "):find("--model", 1, true))
end)

H.test("configure changes only what it is given, at runtime", function()
  local agent_mode = require("agent_mode")
  agent_mode.setup({ agent = "pi", model = "m1", keymap = "<leader><leader>a" })
  agent_mode.configure({ agent = "codex" })
  H.eq("codex", agent_mode.config.agent)
  H.eq("m1", agent_mode.config.model, "other settings are kept")
  H.eq("<leader><leader>a", agent_mode.config.keymap)
  H.truthy(vim.fn.maparg("<leader><leader>a", "n") ~= "", "the keymap is still mapped")

  -- Changing the keymap moves the mapping.
  agent_mode.configure({ keymap = "<leader>q" })
  H.eq("", vim.fn.maparg("<leader><leader>a", "n"))
  H.truthy(vim.fn.maparg("<leader>q", "n") ~= "")

  -- A bad value is refused and the config is left alone.
  H.truthy(not pcall(agent_mode.configure, { agent = "clippy" }))
  H.eq("codex", agent_mode.config.agent)

  vim.cmd("silent AgentModeAgent pi")
  H.eq("pi", agent_mode.config.agent)
  H.eq({ "pi", "claude", "codex", "opencode", "axo" }, vim.fn.getcompletion("AgentModeAgent ", "cmdline"))
  agent_mode.setup({ keymap = false })
end)

H.test("setup rejects an unknown agent", function()
  local ok, err = pcall(require("agent_mode").setup, { agent = "clippy", keymap = false })
  H.truthy(not ok)
  H.contains(err, "unknown agent")
end)

-- decoders -------------------------------------------------------------------

H.test("the pi-json decoder streams thinking and text and returns the final message", function()
  local decoder = agents.decoders["pi-json"]()
  local function event(update)
    return vim.json.encode({ type = "message_update", assistantMessageEvent = update }) .. "\n"
  end
  local stream = event({ type = "thinking_delta", delta = "Let me see" })
    .. event({ type = "text_delta", delta = '{"summary": "Ren' })
    .. event({ type = "text_delta", delta = 'aming"' })
    .. vim.json.encode({
      type = "message_end",
      message = { role = "assistant", content = { { type = "text", text = '{"summary": "Renaming"}' } } },
    })
    .. "\n"
  -- Feed it in awkward pieces, as a pipe would.
  local events = {}
  for i = 1, #stream, 7 do
    vim.list_extend(events, decoder.feed(stream:sub(i, i + 6)))
  end
  H.eq({
    { kind = "thinking", delta = "Let me see" },
    { kind = "text", delta = '{"summary": "Ren' },
    { kind = "text", delta = 'aming"' },
  }, events)
  H.eq('{"summary": "Renaming"}', decoder.reply())
end)

H.test("the pi-json decoder stays fast on long lines arriving in pieces", function()
  -- pi's events repeat the whole prompt; a buffer-sized prompt makes lines
  -- of hundreds of KB that arrive over many reads.
  local decoder = agents.decoders["pi-json"]()
  local line = vim.json.encode({ type = "agent_end", messages = { { role = "user", content = string.rep("x", 400000) } } })
  local start = vim.uv.hrtime()
  for i = 1, #line, 8192 do
    decoder.feed(line:sub(i, i + 8191))
  end
  decoder.feed("\n")
  local ms = (vim.uv.hrtime() - start) / 1e6
  H.truthy(ms < 200, string.format("feeding a 400 KB line took %.0f ms", ms))
end)

H.test("the text decoder passes stdout through", function()
  local decoder = agents.decoders.text()
  H.eq({ { kind = "text", delta = "ab" } }, decoder.feed("ab"))
  decoder.feed("c")
  H.eq("abc", decoder.reply())
end)

-- rebase ---------------------------------------------------------------------

H.test("rebase shifts edits by how far the request's line moved", function()
  local seen = { "a", "b", "c" }
  local buf = H.buffer({ "new 1", "new 2", "a", "b", "c" })
  local rebased = assert(edits.rebase({ { start_line = 2, end_line = 2, text = "B" } }, seen, buf, 2))
  H.eq({ { start_line = 4, end_line = 4, text = "B" } }, rebased)
end)

H.test("rebase refuses edits whose lines changed", function()
  local buf = H.buffer({ "a", "CHANGED", "c" })
  local rebased, err = edits.rebase({ { start_line = 2, end_line = 2, text = "B" } }, { "a", "b", "c" }, buf, 0)
  H.eq(nil, rebased)
  H.contains(err, "lines 2-2 changed")
end)

-- answers --------------------------------------------------------------------

local answer = require("agent_mode.answer")

H.test("answers wrap words to the width and keep line breaks and indentation", function()
  H.eq({ "one two", "three", "", "  four", "  five" }, answer.wrap("one two three\n\n  four five", 10))
  H.eq({ "aaaaaaaaaa", "aaaaa" }, answer.wrap(string.rep("a", 15), 10))
end)

H.test("wrapped list items hang under their text", function()
  H.eq({ "- one two", "  three", "1. four", "   five" }, answer.wrap("- one two three\n1. four five", 10))
end)

H.test("answers fit between the number column and the window's edge", function()
  local buf = H.buffer({ "x" })
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].number = true
  vim.wo[win].signcolumn = "yes"
  vim.cmd("vsplit")
  vim.api.nvim_win_set_width(0, 60)
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  local width = answer.text_width(buf)
  H.truthy(info.textoff > 0, "the window has a number column")
  -- Border "│ " plus the text must end before the window's right edge.
  H.truthy(info.textoff + 2 + width <= info.width, string.format("textoff %d + 2 + %d > %d", info.textoff, width, info.width))
  vim.cmd("only")
end)

H.test("answers leave fenced code blocks unwrapped", function()
  H.eq({ "```lua", "local a_long_name = another_long_name", "```" }, answer.wrap("```lua\nlocal a_long_name = another_long_name\n```", 10))
end)

H.test("answers are highlighted as Markdown, with code blocks in their language", function()
  local lines = { "Use `foo()` and **bold**.", "", "```lua", "local x = 1", "```" }
  local function groups(row)
    local out = {}
    for _, chunk in ipairs(answer.highlight(lines, "Base")[row]) do
      out[chunk[1]] = type(chunk[2]) == "table" and chunk[2][2] or chunk[2]
    end
    return out
  end
  local prose = groups(1)
  H.eq("Base", prose["Use "])
  H.eq("@markup.raw.markdown_inline", prose["`foo()`"])
  H.eq("@markup.strong.markdown_inline", prose["**bold**"])
  local code = groups(4)
  H.eq("@keyword.lua", code["local"])
  H.eq("@number.lua", code["1"])
  H.eq("@markup.raw.block.markdown", groups(5)["```"], "the closing fence stays a fence")
  -- Every chunk is drawn over the answer's own background.
  H.eq({ "Base", "@markup.raw.markdown_inline" }, answer.highlight(lines, "Base")[1][2][2])
end)

H.test("a long answer is entered without covering its line", function()
  local lines = {}
  for i = 1, 60 do
    lines[i] = "line " .. i
  end
  local buf = H.buffer(lines)
  local code_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(code_win, 20)
  local body = {}
  for i = 1, 40 do
    body[i] = "answer line " .. i
  end
  answer.show(buf, 15, table.concat(body, "\n"), { title = "long", keys = {} })
  vim.api.nvim_win_set_cursor(code_win, { 15, 0 })
  vim.cmd("normal! zb")
  local win = answer.enter()
  H.truthy(win, "entered")
  local anchor = vim.fn.screenpos(code_win, 15, 1).row
  H.truthy(anchor > 0, "the answer's line is still on screen")
  H.eq(anchor, vim.api.nvim_win_get_position(win)[1], "the window starts below the line")
  H.truthy(vim.api.nvim_win_get_height(win) < 41, "the window fits the space left and scrolls")
  vim.api.nvim_win_close(win, true)
  answer.dismiss(buf)
end)

H.test("answers show below their line and dismiss nearest first", function()
  local buf = H.buffer({ "1", "2", "3", "4", "5", "6" })
  local keys = { dismiss = "<Esc>", next = "]a", prev = "[a" }
  answer.show(buf, 2, "first answer", { title = "t", keys = keys })
  answer.show(buf, 5, "second answer", { title = "t", keys = keys })
  local shown = answer.list(buf)
  H.eq({ 2, 5 }, { shown[1].row, shown[2].row })
  H.contains(table.concat(shown[1].lines, "\n"), "first answer")
  H.eq("", shown[1].lines[#shown[1].lines], "a blank line closes each answer")
  H.truthy(vim.fn.maparg("<Esc>", "n", false, true).buffer == 1, "dismiss key is mapped in the buffer")

  -- Jumping moves between answer lines.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  answer.jump(1)
  H.eq(2, vim.api.nvim_win_get_cursor(0)[1])
  answer.jump(1)
  H.eq(5, vim.api.nvim_win_get_cursor(0)[1])
  answer.jump(-1)
  H.eq(2, vim.api.nvim_win_get_cursor(0)[1])

  -- Reading below the second answer, the dismiss key clears that one.
  answer.dismiss(buf, 6)
  H.eq(1, #answer.list(buf))
  H.eq(2, answer.list(buf)[1].row)
  answer.dismiss(buf, 1)
  H.eq(0, #answer.list(buf))
  H.eq(vim.empty_dict(), vim.fn.maparg("<Esc>", "n", false, true), "keys are unmapped with the last answer")
end)

H.test("<CR> on an answer's line opens it for the cursor; elsewhere it is <CR>", function()
  local buf = H.buffer({ "1", "2", "3", "4" })
  local code_win = vim.api.nvim_get_current_win()
  answer.show(buf, 2, "It is **two**.\n\n```lua\nreturn 2\n```", { title = "what is it?", keys = { enter = "<CR>" } })

  -- On a line without an answer, <CR> still moves down.
  vim.api.nvim_win_set_cursor(code_win, { 1, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  H.eq(2, vim.api.nvim_win_get_cursor(code_win)[1])

  -- On the answer's line it opens the answer.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.wait(100, function()
    return vim.api.nvim_get_current_win() ~= code_win
  end)
  local win = vim.api.nvim_get_current_win()
  H.truthy(win ~= code_win, "the answer window has the cursor")
  H.eq("win", vim.api.nvim_win_get_config(win).relative)
  local answer_buf = vim.api.nvim_get_current_buf()
  H.eq("markdown", vim.bo[answer_buf].filetype)
  H.eq({ "what is it?", "It is **two**.", "", "```lua", "return 2", "```" }, H.lines(answer_buf))

  -- Text can be yanked from it.
  vim.api.nvim_win_set_cursor(win, { 5, 0 })
  vim.cmd("normal! yy")
  H.eq("return 2\n", vim.fn.getreg('"'))

  -- The window starts right under the answer's line and does not cover it.
  local position = vim.api.nvim_win_get_position(win)[1]
  local anchor = vim.fn.screenpos(code_win, 2, 1).row
  H.eq(anchor, position, "the answer window sits right below its line")

  -- q goes back to the code, and the answer is still shown inline.
  vim.api.nvim_feedkeys("q", "x", false)
  H.eq(code_win, vim.api.nvim_get_current_win())
  H.eq(1, #answer.list(buf))
  answer.dismiss(buf)
end)

-- axo transcript ---------------------------------------------------------------

local axo = require("agent_mode.axo")

H.test("axo describes each step of the session's turn", function()
  local function step(content)
    return axo.describe_step({ role = "assistant", content = content })
  end
  H.eq("editing greet.js", step({ { type = "toolCall", name = "edit", arguments = { path = "/x/greet.js" } } }))
  H.eq("reading a.lua", step({ { type = "toolCall", name = "read", arguments = { path = "a.lua" } } }))
  H.eq("running rg foo", step({ { type = "toolCall", name = "bash", arguments = { command = "rg foo\nls" } } }))
  H.eq("thinking: find the callers", step({ { type = "thinking", thinking = "find the callers\nthen" } }))
end)

H.test("axo's watcher ignores other turns and reports progress, then the reply", function()
  local watch = axo.reply_watcher("abc123")
  local function line(message)
    return vim.json.encode({ type = "message", message = message }) .. "\n"
  end
  local events = watch(
    line({ role = "user", content = "someone else" })
      .. line({ role = "assistant", content = { { type = "text", text = "not ours" } }, stopReason = "stop" })
      .. line({ role = "user", content = { { type = "text", text = "[agent-mode request abc123, from Neovim]" } } })
      .. line({
        role = "assistant",
        content = { { type = "toolCall", name = "edit", arguments = { path = "a.js" } } },
        stopReason = "toolUse",
      })
  )
  H.eq({ { kind = "progress", text = "editing a.js" } }, events)
  local final = line({ role = "assistant", content = { { type = "text", text = "Done." } }, stopReason = "stop" })
  H.eq({}, watch(final:sub(1, 20)))
  H.eq({ { kind = "reply", text = "Done.", stop_reason = "stop", tools = { "edit" } } }, watch(final:sub(21)))
end)

-- run_lua --------------------------------------------------------------------

local run_lua = require("agent_mode.run_lua")

local function run_code(code, ctx, timeout_ms)
  local report
  run_lua.run(code, ctx or { bufnr = vim.api.nvim_get_current_buf(), row = 1, col = 0 }, timeout_ms or 2000, function(r)
    report = r
  end)
  H.truthy(vim.wait(3000, function()
    return report ~= nil
  end, 10), "lua did not finish")
  return report
end

H.test("the protocol accepts lua actions with code", function()
  local response = assert(protocol.parse('{"actions":[{"type":"lua","code":"return 1"}]}'))
  H.eq({ { type = "lua", code = "return 1" } }, response.actions)
  local _, err = protocol.parse('{"actions":[{"type":"lua","code":""}]}')
  H.contains(err, "lua action 1 has no code")
end)

H.test("pi's tool calls show up as what the agent is looking at", function()
  local decoder = agents.decoders["pi-json"]()
  local events = decoder.feed(vim.json.encode({
    type = "tool_execution_start",
    toolName = "grep",
    args = { pattern = "function M.plan" },
  }) .. "\n")
  H.eq({ { kind = "tool", delta = "grep function M.plan" } }, events)
  H.eq("read " .. string.rep("x", 39) .. "…", agents.describe_tool("read", { path = string.rep("x", 50) }))
  H.eq("codemode", agents.describe_tool("codemode", {}))
end)

H.test("a summary without actions is the answer", function()
  local response = assert(protocol.parse('{"summary":"Mango","actions":[]}'))
  H.eq({ { type = "message", text = "Mango" } }, response.actions)
  local _, err = protocol.parse('{"actions":[]}')
  H.contains(err, "no actions")
end)

H.test("tool-call markup reads as the same actions", function()
  local response = assert(protocol.parse(
    '<invoke name="lua">\n<parameter name="code">local t = {}\nreturn t</parameter>\n</invoke>\n'
      .. '<invoke name="code_action"><parameter name="id">2</parameter></invoke>'
  ))
  H.eq({ { type = "lua", code = "local t = {}\nreturn t" }, { type = "code_action", id = 2 } }, response.actions)
end)

H.test("am.lsp calls back at once when no server supports the method", function()
  H.eq("returned:\n{}", run_code("local done = ctx.async() am.lsp('callHierarchy/incomingCalls', {}, done)"))
end)

H.test("agent lua reports what it printed and returned, or its error", function()
  H.eq("printed:\nhi\t2\nreturned:\n{\n  a = 1\n}", run_code("print('hi', 2) return { a = 1 }"))
  H.eq("returned nothing", run_code("local x = 1"))
  H.contains(run_code("error('boom')"), "error: agent-lua:1: boom")
  H.contains(run_code("return +"), "error: agent-lua")
  H.eq("returned:\n7", run_code("return ctx.row", { bufnr = 0, row = 7, col = 0 }))
end)

H.test("agent lua that calls ctx.async() finishes when done() is called, or times out", function()
  H.eq("returned:\nlater", run_code("local done = ctx.async() vim.defer_fn(function() done('later') end, 50)"))
  H.contains(run_code("ctx.async()", nil, 100), "done() was not")
end)

H.test("callbacks run on the main loop, and their errors come back", function()
  H.eq("returned:\n/", run_code("local done = ctx.async() vim.system({ 'true' }, {}, function() done(vim.fn.fnamemodify('/', ':p')) end)"))
  H.contains(run_code("local done = ctx.async() vim.system({ 'true' }, function() error('late') end)"), "error: in a callback: agent-lua:1: late")
  H.contains(run_code("local done = ctx.async() vim.defer_fn(function() local x = nil; x() end, 10)"), "error: in a callback:")
end)

H.test("describe() lists what Neovim has, and the shape of any module", function()
  local overview = run_code("return describe()")
  for _, key in ipairs({ "neovim", "topics", "helpers", "language_servers" }) do
    H.contains(overview, key)
  end
  H.contains(run_code("return describe('agent_mode.edits')"), 'plan = "function(edits, line_count)"')
  H.contains(run_code("return describe('am')"), "am.scratch")
  H.contains(run_code("return describe('no.such.module')"), "error: no module no.such.module")
end)

H.test("am.scratch opens the lines in a new tab", function()
  local tabs = #vim.api.nvim_list_tabpages()
  H.contains(run_code("local b = am.scratch('a\\nb', { filetype = 'markdown' }) return vim.api.nvim_buf_get_lines(b, 0, -1, false)"), '{ "a", "b" }')
  H.eq(tabs + 1, #vim.api.nvim_list_tabpages())
  vim.cmd("tabclose")
end)

H.run()
