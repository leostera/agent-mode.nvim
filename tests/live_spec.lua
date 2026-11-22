-- Live tests against real agents and models. They cost tokens and take
-- seconds, so they only run when asked:
--   AGENT_MODE_LIVE=pi,claude,codex,opencode nvim --headless -l tests/live_spec.lua
-- "axo" delegates to the Axo Session AGENT_MODE_AXO_SESSION, whose agent must
-- be able to edit files in AGENT_MODE_AXO_DIR (default: a temp dir).

local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local agent_mode = require("agent_mode")

local live = vim.split(vim.env.AGENT_MODE_LIVE or "", ",", { trimempty = true })

local source = {
  "function greet(user) {",
  "  const message = `Hello, ${user.name}!`;",
  "  console.log(message);",
  "  return message;",
  "}",
}

for _, agent in ipairs(vim.tbl_filter(function(a)
  return a ~= "axo"
end, live)) do
  H.test(agent .. ": rename the variable under the cursor without a language server", function()
    agent_mode.setup({ agent = agent, keymap = false })
    local buf = H.buffer(source, "javascript")
    local err = H.run_agent("rename to presenter", { position = { row = 2, col = 9 } }, 120000)
    H.eq(nil, err, "agent-mode failed; prompt and reply:\n" .. vim.inspect(agent_mode.last))
    H.eq({
      "function greet(user) {",
      "  const presenter = `Hello, ${user.name}!`;",
      "  console.log(presenter);",
      "  return presenter;",
      "}",
    }, H.lines(buf))
  end)
end

for _, agent in ipairs(vim.tbl_filter(function(a)
  return a ~= "codex" and a ~= "opencode"
end, live)) do
  H.test(agent .. ": a question is answered inline and the code is left alone", function()
    local opts = { agent = agent, keymap = false }
    if agent == "axo" then
      opts.axo = { session = assert(vim.env.AGENT_MODE_AXO_SESSION, "set AGENT_MODE_AXO_SESSION") }
    end
    agent_mode.setup(opts)
    local dir = vim.env.AGENT_MODE_AXO_DIR or vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(source, dir .. "/question.js")
    vim.cmd("edit " .. dir .. "/question.js")
    local buf = vim.api.nvim_get_current_buf()
    require("agent_mode.answer").dismiss(buf)
    local err = H.run_agent("what does this function return?", { position = { row = 4, col = 2 } }, 300000)
    H.eq(nil, err, vim.inspect(agent_mode.last))
    H.eq(source, H.lines(buf))
    local shown = require("agent_mode.answer").list(buf)
    H.eq(1, #shown, "one inline answer")
    H.eq(4, shown[1].row)
    io.stdout:write("     answer: " .. table.concat(shown[1].lines, " / ") .. "\n")
  end)
end

local luals = vim.fn.stdpath("data") .. "/mason/bin/lua-language-server"
if vim.tbl_contains(live, "pi") and vim.fn.executable(luals) == 1 then
  H.test("pi: rename picks the language server when one is attached", function()
    agent_mode.setup({ agent = "pi", keymap = false })
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "local message = 'hi'", "print(message)" }, dir .. "/a.lua")
    vim.cmd("edit " .. dir .. "/a.lua")
    local buf = vim.api.nvim_get_current_buf()
    local client_id = vim.lsp.start({ name = "lua_ls", cmd = { luals }, root_dir = dir })
    H.truthy(vim.wait(20000, function()
      local client = vim.lsp.get_client_by_id(client_id)
      return client and client.initialized
    end, 50))
    vim.wait(1500)
    local err = H.run_agent("rename to presenter", { bufnr = buf, position = { row = 1, col = 6 } }, 120000)
    H.eq(nil, err)
    H.eq("lsp_rename", agent_mode.last.response.actions[1].type)
    H.eq({ "local presenter = 'hi'", "print(presenter)" }, H.lines(buf))
  end)
end

if vim.tbl_contains(live, "axo") then
  H.test("axo: the session's agent renames the variable and the buffer reloads", function()
    local session = assert(vim.env.AGENT_MODE_AXO_SESSION, "set AGENT_MODE_AXO_SESSION")
    agent_mode.setup({ agent = "axo", keymap = false, axo = { session = session } })
    local dir = vim.env.AGENT_MODE_AXO_DIR or vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/greet.js"
    vim.fn.writefile(source, path)
    vim.cmd("edit " .. path)
    local buf = vim.api.nvim_get_current_buf()
    local err = H.run_agent("rename to presenter", { position = { row = 2, col = 9 } }, 300000)
    H.eq(nil, err, "agent-mode failed:\n" .. vim.inspect(agent_mode.last))
    H.eq({
      "function greet(user) {",
      "  const presenter = `Hello, ${user.name}!`;",
      "  console.log(presenter);",
      "  return presenter;",
      "}",
    }, H.lines(buf))
  end)
end

H.run()
