-- Running the Lua an agent sends, and turning what happened into text the
-- agent reads on its next turn.
--
-- The code runs as a function body with a global `ctx` describing where the
-- user is. It finishes when it returns, unless it called `ctx.async()`: then
-- it finishes when it calls the `done` function that returned, or times out.

local introspect = require("agent_mode.introspect")

local M = {}

--- The `am` helpers the agent's code gets, so it writes less boilerplate.
local function helpers(ctx, guard)
  local am = {}
  am.docs = {
    ["am.scratch(lines, opts)"] = "Show lines (a list or a string) in a new scratch buffer and return its number. "
      .. "opts.open: 'tab' (default), 'split' or 'vsplit'; opts.name; opts.filetype (e.g. 'markdown'). q closes it.",
    ["am.lsp(method, params, callback)"] = "Ask every language server on ctx.bufnr, e.g. 'textDocument/references'. "
      .. "params nil means the cursor position. callback gets a list of { client, result, error }; "
      .. "an empty list means no server supports the method.",
    ["am.position_params()"] = "LSP TextDocumentPositionParams for the cursor in ctx.bufnr.",
    ["am.lines(path_or_bufnr)"] = "The lines of a buffer or a file on disk.",
  }

  local function encoding()
    local client = vim.lsp.get_clients({ bufnr = ctx.bufnr })[1]
    return client and client.offset_encoding or "utf-16"
  end

  function am.position_params()
    local line = vim.api.nvim_buf_get_lines(ctx.bufnr, ctx.row - 1, ctx.row, false)[1] or ""
    return {
      textDocument = { uri = vim.uri_from_bufnr(ctx.bufnr) },
      position = { line = ctx.row - 1, character = vim.str_utfindex(line, encoding(), ctx.col, false) },
    }
  end

  function am.lsp(method, params, callback)
    -- buf_request_all never calls back when no server supports the method.
    local supported = vim.tbl_filter(function(client)
      return client:supports_method(method, ctx.bufnr)
    end, vim.lsp.get_clients({ bufnr = ctx.bufnr }))
    if #supported == 0 then
      return vim.schedule(function()
        callback({})
      end)
    end
    callback = guard(callback)
    vim.lsp.buf_request_all(ctx.bufnr, method, params or am.position_params(), function(responses)
      local results = {}
      for id, response in pairs(responses) do
        local client = vim.lsp.get_client_by_id(id)
        results[#results + 1] = { client = client and client.name or id, result = response.result, error = response.err }
      end
      callback(results)
    end)
  end

  function am.lines(source)
    if type(source) == "number" then
      return vim.api.nvim_buf_get_lines(source, 0, -1, false)
    end
    local bufnr = vim.fn.bufnr(source)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
      return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end
    return vim.fn.readfile(vim.fn.expand(source))
  end

  function am.scratch(lines, opts)
    opts = opts or {}
    if type(lines) == "string" then
      lines = vim.split(lines, "\n", { plain = true })
    end
    local open = opts.open or "tab"
    vim.cmd(open == "tab" and "tabnew" or open == "vsplit" and "vnew" or "new")
    local bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    if opts.filetype then
      vim.bo[bufnr].filetype = opts.filetype
    end
    if opts.name then
      pcall(vim.api.nvim_buf_set_name, bufnr, opts.name)
    end
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = bufnr, nowait = true })
    return bufnr
  end

  return am
end

-- What goes back to the agent is cut to this many bytes.
M.max_result_bytes = 12000

local function truncate(text)
  if #text <= M.max_result_bytes then
    return text
  end
  return text:sub(1, M.max_result_bytes) .. string.format("\n… (%d more bytes cut)", #text - M.max_result_bytes)
end

local function describe(value)
  if type(value) == "string" then
    return value
  end
  return vim.inspect(value, { depth = 8 })
end

--- The report the agent gets: what was printed, then what was returned or
--- the error.
local function report(printed, outcome)
  local parts = {}
  if #printed > 0 then
    parts[#parts + 1] = "printed:\n" .. table.concat(printed, "\n")
  end
  if outcome.error then
    parts[#parts + 1] = "error: " .. outcome.error
  elseif outcome.value ~= nil then
    parts[#parts + 1] = "returned:\n" .. describe(outcome.value)
  elseif #parts == 0 then
    parts[#parts + 1] = "returned nothing"
  end
  return truncate(table.concat(parts, "\n"))
end

--- Run `code` with `ctx`, then call `on_done(report)` once, asynchronously.
--- @param code string
--- @param ctx table where the user is; gets an `async` function added
--- @param timeout_ms integer how long asynchronous code may take
--- @param on_done fun(report: string, ok: boolean)
function M.run(code, ctx, timeout_ms, on_done)
  local printed = {}
  local finished = false
  local timer

  local function finish(outcome)
    if finished then
      return
    end
    finished = true
    if timer then
      timer:stop()
      timer:close()
    end
    vim.schedule(function()
      on_done(report(printed, outcome), outcome.error == nil)
    end)
  end

  local pending = false
  ctx = vim.tbl_extend("force", {}, ctx, {
    async = function()
      pending = true
      return function(value)
        finish({ value = value })
      end
    end,
  })
  -- Errors in callbacks happen after the code returned, outside the pcall
  -- below. Catch them, so the agent hears about them instead of the user
  -- getting a bare "Lua callback" error.
  local function guard(fn)
    return function(...)
      local ok, err = xpcall(fn, debug.traceback, ...)
      if ok then
        return err
      end
      if finished then
        vim.notify("agent-mode: the agent's Lua failed after it finished: " .. tostring(err), vim.log.levels.WARN)
      else
        finish({ error = "in a callback: " .. tostring(err) })
      end
    end
  end
  -- And run callbacks that come in fast event contexts (vim.system's) on the
  -- main loop, where vim.fn and the API work.
  local function scheduled(fn)
    local guarded = guard(fn)
    return function(...)
      local args = vim.F.pack_len(...)
      vim.schedule(function()
        guarded(vim.F.unpack_len(args))
      end)
    end
  end
  local safe_vim = setmetatable({
    system = function(cmd, opts, on_exit)
      if type(opts) == "function" then
        opts, on_exit = nil, opts
      end
      opts = opts and vim.tbl_extend("force", {}, opts) or nil
      for _, stream in ipairs({ "stdout", "stderr" }) do
        if opts and type(opts[stream]) == "function" then
          opts[stream] = scheduled(opts[stream])
        end
      end
      return vim.system(cmd, opts, on_exit and scheduled(on_exit))
    end,
    schedule = function(fn)
      return vim.schedule(guard(fn))
    end,
    schedule_wrap = function(fn)
      return vim.schedule_wrap(guard(fn))
    end,
    defer_fn = function(fn, timeout)
      return vim.defer_fn(guard(fn), timeout)
    end,
    lsp = setmetatable({
      buf_request = function(bufnr, method, params, handler, ...)
        return vim.lsp.buf_request(bufnr, method, params, handler and guard(handler), ...)
      end,
      buf_request_all = function(bufnr, method, params, handler)
        return vim.lsp.buf_request_all(bufnr, method, params, guard(handler))
      end,
    }, { __index = vim.lsp }),
  }, { __index = vim })

  local am = helpers(ctx, guard)
  local env = setmetatable({
    ctx = ctx,
    am = am,
    vim = safe_vim,
    describe = function(topic)
      return introspect.describe(ctx, am, topic)
    end,
    print = function(...)
      local args = { ... }
      for i = 1, select("#", ...) do
        args[i] = describe(args[i])
      end
      printed[#printed + 1] = table.concat(args, "\t")
    end,
  }, { __index = _G })

  local chunk, compile_err = load(code, "=agent-lua", "t", env)
  if not chunk then
    return finish({ error = compile_err })
  end

  local ok, value = xpcall(chunk, debug.traceback)
  if not ok then
    return finish({ error = tostring(value) })
  end
  if not pending then
    return finish({ value = value })
  end
  timer = assert(vim.uv.new_timer())
  timer:start(timeout_ms, 0, function()
    finish({ error = string.format("ctx.async() was called but done() was not, after %d ms", timeout_ms) })
  end)
end

vim.api.nvim_set_hl(0, "AgentModeLuaBorder", { link = "FloatBorder", default = true })
vim.api.nvim_set_hl(0, "AgentModeLuaTitle", { link = "FloatTitle", default = true })

--- Show `code` and ask whether to run it. Calls `on_choice(choice)` with
--- "run", "always" (run, and don't ask again for this request) or "skip".
--- @param code string
--- @param title string
function M.confirm(code, title, on_choice)
  local lines = vim.split(code, "\n", { plain = true })
  local width = 20
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, vim.o.columns - 8)
  local height = math.min(#lines, vim.o.lines - 8)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "lua"
  vim.bo[buf].modifiable = false
  local origin = vim.api.nvim_get_current_win()
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = { { " " .. title .. " ", "AgentModeLuaTitle" } },
    title_pos = "left",
    footer = { { " y run · a run all for this request · n skip ", "AgentModeLuaTitle" } },
    footer_pos = "right",
    zindex = 70,
  })
  vim.wo[win].winhighlight = "FloatBorder:AgentModeLuaBorder"

  local chosen = false
  local function choose(choice)
    if chosen then
      return
    end
    chosen = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
    vim.schedule(function()
      on_choice(choice)
    end)
  end
  local function map(key, choice)
    vim.keymap.set("n", key, function()
      choose(choice)
    end, { buffer = buf, nowait = true })
  end
  map("y", "run")
  map("<CR>", "run")
  map("a", "always")
  map("n", "skip")
  map("q", "skip")
  map("<Esc>", "skip")
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      choose("skip")
    end,
  })
  return win
end

return M
