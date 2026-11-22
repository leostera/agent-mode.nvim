-- agent-mode's MCP server, run by bin/agent-mode-mcp with Neovim's Lua.
-- Speaks MCP (JSON-RPC, one message per line) on stdin/stdout and carries
-- out tool calls in the user's Neovim over its RPC socket.

local plugin = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
package.path = plugin .. "/lua/?.lua;" .. package.path
local specs = require("agent_mode.tool_specs")

local server_flag = nil
for i, a in ipairs(_G.arg or {}) do
  if a == "--server" then
    server_flag = _G.arg[i + 1]
  end
end

local function send(message)
  io.stdout:write(vim.json.encode(message), "\n")
  io.stdout:flush()
end

--- Neovims running agent-mode, from the files each writes in the state folder.
local function registered()
  local dir = vim.fs.joinpath(vim.fn.stdpath("state"), "agent-mode", "servers")
  local found = {}
  for name in vim.fs.dir(dir) do
    local ok, info = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(vim.fs.joinpath(dir, name)), "\n"))
    end)
    if ok and type(info) == "table" and info.address then
      found[#found + 1] = info
    end
  end
  return found
end

--- The Neovim to talk to: given, inherited, or the one whose folder is the
--- closest one above the folder the agent runs in.
local function addresses()
  local list = {}
  for _, a in ipairs({ server_flag, os.getenv("AGENT_MODE_SERVER"), os.getenv("NVIM") }) do
    if a and a ~= "" then
      list[#list + 1] = a
    end
  end
  local cwd = vim.fs.normalize(vim.uv.cwd() or "")
  local candidates = vim.tbl_filter(function(info)
    local dir = vim.fs.normalize(info.cwd or "")
    return cwd == dir or vim.startswith(cwd, dir .. "/") or vim.startswith(dir, cwd .. "/")
  end, registered())
  table.sort(candidates, function(a, b)
    return #a.cwd > #b.cwd
  end)
  for _, info in ipairs(candidates) do
    list[#list + 1] = info.address
  end
  return list
end

local channel = nil
local function connect()
  if channel then
    local ok = pcall(vim.rpcrequest, channel, "nvim_get_api_info")
    if ok then
      return channel
    end
    channel = nil
  end
  for _, address in ipairs(addresses()) do
    local ok, chan = pcall(vim.fn.sockconnect, "pipe", address, { rpc = true })
    if ok and chan and chan > 0 then
      local alive = pcall(vim.rpcrequest, chan, "nvim_exec_lua", "return require('agent_mode') ~= nil", {})
      if alive then
        channel = chan
        return chan
      end
    end
  end
  return nil
end

local function call_tool(name, args)
  local chan = connect()
  if not chan then
    return "No Neovim with agent-mode was found for " .. (vim.uv.cwd() or "this folder")
      .. ". Open Neovim in the project (agent-mode loaded), or pass --server <address>.", true
  end
  local ok, ticket = pcall(vim.rpcrequest, chan, "nvim_exec_lua", "return require('agent_mode').tool_call(...)", { name, args or {} })
  if not ok then
    return "Neovim failed to take the call: " .. tostring(ticket), true
  end
  -- Tools may wait for the user (a Lua confirmation) or for a request, so poll.
  while true do
    local polled, result = pcall(vim.rpcrequest, chan, "nvim_exec_lua", "return require('agent_mode').tool_result(...)", { ticket })
    if not polled then
      return "Lost Neovim while waiting: " .. tostring(result), true
    end
    if result ~= "pending" then
      return result.text, result.error
    end
    vim.uv.sleep(100)
  end
end

local handlers = {}

function handlers.initialize(params)
  return {
    protocolVersion = params and params.protocolVersion or "2025-06-18",
    capabilities = { tools = { listChanged = false } },
    serverInfo = { name = "agent-mode", version = "0.1.0" },
    instructions = "Tools to work in the user's Neovim: their buffers, cursor, language servers, and inline answers."
      .. " To take requests the user makes at their cursor, call wait_for_request in a loop.",
  }
end

function handlers.ping()
  return vim.empty_dict()
end

handlers["tools/list"] = function()
  return { tools = specs }
end

handlers["tools/call"] = function(params)
  local text, is_error = call_tool(params.name, params.arguments)
  return { content = { { type = "text", text = text } }, isError = is_error and true or false }
end

while true do
  local line = io.stdin:read("*l")
  if not line then
    break
  end
  local ok, message = pcall(vim.json.decode, line)
  if ok and type(message) == "table" and message.method then
    local handler = handlers[message.method]
    if message.id ~= nil then
      if handler then
        local handled, result = pcall(handler, message.params)
        if handled then
          send({ jsonrpc = "2.0", id = message.id, result = result })
        else
          send({ jsonrpc = "2.0", id = message.id, error = { code = -32603, message = tostring(result) } })
        end
      else
        send({ jsonrpc = "2.0", id = message.id, error = { code = -32601, message = "unknown method " .. message.method } })
      end
    end
  end
end
