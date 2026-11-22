-- Delegating a request to the agent of an Axo Session.
--
-- Instead of spawning a fresh agent, agent-mode sends the request to the pi
-- already running in an Axo Session (usually the pane next to Neovim) with
-- `axo session prompt`. That agent makes the change with its own tools, in
-- view, with its whole conversation as context. agent-mode only needs to know
-- when it is done, which it learns from the Session's transcript: the turn is
-- over when an assistant message after our prompt stops for a reason other
-- than calling a tool.

local M = {}

local POLL_MS = 200

--- Read `path` from byte `offset`; returns the new text and the new offset.
local function read_from(path, offset)
  local file = io.open(path, "rb")
  if not file then
    return "", offset
  end
  local size = file:seek("end")
  if size <= offset then
    file:close()
    return "", offset
  end
  file:seek("set", offset)
  local text = file:read(size - offset)
  file:close()
  return text, size
end

local function file_size(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.size or 0
end

local function message_text(message)
  if type(message.content) == "string" then
    return message.content
  end
  local parts = {}
  for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
    if block.type == "text" and type(block.text) == "string" then
      parts[#parts + 1] = block.text
    end
  end
  return table.concat(parts, "\n")
end

local function basename(path)
  return type(path) == "string" and vim.fn.fnamemodify(path, ":t") or nil
end

--- A one-line status for an intermediate assistant message: what tool it is
--- calling on what, or the gist of its thinking or text.
function M.describe_step(message)
  local status = nil
  for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
    if block.type == "toolCall" then
      local args = type(block.arguments) == "table" and block.arguments or {}
      local name = block.name or "tool"
      if name == "edit" or name == "write" then
        status = "editing " .. (basename(args.path) or "a file")
      elseif name == "read" then
        status = "reading " .. (basename(args.path) or "a file")
      elseif name == "bash" and type(args.command) == "string" then
        status = "running " .. args.command:match("[^\n]*")
      else
        status = "using " .. name
      end
    elseif not status and block.type == "thinking" and type(block.thinking) == "string" then
      status = "thinking: " .. vim.trim(block.thinking):match("[^\n]*")
    elseif not status and block.type == "text" and type(block.text) == "string" and block.text ~= "" then
      status = vim.trim(block.text):match("[^\n]*")
    end
  end
  return status
end

local function tool_names(message)
  local names = {}
  for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
    if block.type == "toolCall" and block.name then
      names[#names + 1] = block.name
    end
  end
  return names
end

--- Follows a transcript for the turn answering the prompt tagged `nonce`.
--- `feed(text)` takes newly appended transcript text and returns events:
---   { kind = "progress", text = "editing greet.js" }
---   { kind = "reply", text = "...", stop_reason = "stop", tools = { "read", "edit" } }
--- The reply event comes once, when the turn has finished.
function M.reply_watcher(nonce)
  local pending = "" -- a partial last line, completed by the next read
  local seen_prompt = false
  local tools = {}

  return function(text)
    local events = {}
    pending = pending .. text
    while true do
      local newline = pending:find("\n", 1, true)
      if not newline then
        return events
      end
      local line = pending:sub(1, newline - 1)
      pending = pending:sub(newline + 1)

      local ok, entry = pcall(vim.json.decode, line)
      local message = ok and type(entry) == "table" and entry.type == "message" and entry.message or nil
      if message then
        if not seen_prompt then
          seen_prompt = message.role == "user" and message_text(message):find(nonce, 1, true) ~= nil
        elseif message.role == "assistant" and message.stopReason == "toolUse" then
          vim.list_extend(tools, tool_names(message))
          events[#events + 1] = { kind = "progress", text = M.describe_step(message) }
        elseif message.role == "assistant" then
          events[#events + 1] =
            { kind = "reply", text = message_text(message), stop_reason = message.stopReason, tools = tools }
          return events
        end
      end
    end
  end
end

--- Send `prompt` (which must contain `nonce`) to Axo Session `session` and
--- call `on_done(err, reply)` when its agent finishes the turn, where reply
--- is { text = string, tools = string[] }. `opts.on_progress(status)` hears
--- about each step on the way. Returns a function that stops waiting.
--- @param opts { cmd: string, session: string, prompt: string, nonce: string, on_progress: fun(status: string)|nil }
function M.run(opts, on_done)
  local stopped = false
  local timer = nil

  local function done(err, text)
    if stopped then
      return
    end
    stopped = true
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    vim.schedule(function()
      on_done(err, text)
    end)
  end

  local function stop()
    stopped = true
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
  end

  local function fail(what, result)
    local reason = vim.trim((result.stderr or "") .. (result.stdout or ""))
    done(string.format("axo %s failed (exit %d): %s", what, result.code, reason:sub(1, 300)))
  end

  vim.system({ opts.cmd, "--json", "session", "show", "--sid", opts.session }, { text = true }, function(shown)
    if stopped then
      return
    end
    if shown.code ~= 0 then
      return fail("session show", shown)
    end
    local ok, session = pcall(vim.json.decode, shown.stdout)
    if not ok or type(session) ~= "table" or type(session.piSessionFile) ~= "string" then
      return done("axo session show returned no transcript for session " .. opts.session)
    end

    local transcript = session.piSessionFile
    local offset = file_size(transcript)
    local watch = M.reply_watcher(opts.nonce)

    vim.system(
      { opts.cmd, "--json", "session", "prompt", "--sid", opts.session, "--message-file", "-" },
      { text = true, stdin = opts.prompt },
      function(sent)
        if stopped then
          return
        end
        if sent.code ~= 0 then
          return fail("session prompt", sent)
        end
        if opts.on_progress then
          vim.schedule(function()
            opts.on_progress("waiting for the session's agent…")
          end)
        end
        timer = assert(vim.uv.new_timer())
        timer:start(POLL_MS, POLL_MS, vim.schedule_wrap(function()
          if stopped then
            return
          end
          local text
          text, offset = read_from(transcript, offset)
          if text == "" then
            return
          end
          for _, event in ipairs(watch(text)) do
            if event.kind == "progress" and event.text and opts.on_progress then
              vim.schedule(function()
                opts.on_progress(event.text)
              end)
            elseif event.kind == "reply" then
              if event.stop_reason == "stop" or event.stop_reason == "length" then
                return done(nil, { text = event.text, tools = event.tools })
              end
              return done(
                string.format("the session's agent stopped (%s): %s", event.stop_reason, event.text:sub(1, 200))
              )
            end
          end
        end))
      end
    )
  end)

  return stop
end

return M
