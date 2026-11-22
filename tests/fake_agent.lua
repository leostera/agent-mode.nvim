-- Stands in for an agent in the tests, run with `nvim -l`: records the
-- prompt it was sent on stdin, then makes the tool calls in
-- $AGENT_MODE_FAKE_CALLS (JSON: a list of { name, arguments }, or
-- { sleep = seconds }) through the nvim-mcp server, with "@ID@" in the
-- arguments replaced by the request's context_id (from the prompt, or from
-- the last tool result that had one, as wait_for_request returns). Records each result in
-- $AGENT_MODE_FAKE_RESULTS, prints $AGENT_MODE_FAKE_TEXT, and exits with
-- $AGENT_MODE_FAKE_EXIT.

local prompt = io.stdin:read("*a") or ""
if os.getenv("AGENT_MODE_FAKE_STDIN") then
  vim.fn.writefile(vim.split(prompt, "\n", { plain = true }), os.getenv("AGENT_MODE_FAKE_STDIN"))
end
local id = prompt:match("context_id: (%x+)") or ""
local mcp = vim.json.decode(os.getenv("AGENT_MODE_FAKE_MCP"))
local calls = vim.json.decode(os.getenv("AGENT_MODE_FAKE_CALLS") or "[]")

local function substitute(value)
  if type(value) == "string" then
    return (value:gsub("@ID@", id))
  elseif type(value) == "table" then
    local out = {}
    for k, v in pairs(value) do
      out[k] = substitute(v)
    end
    return out
  end
  return value
end

local results = {}
for _, call in ipairs(calls) do
  if call.sleep then
    vim.uv.sleep(call.sleep * 1000)
  else
    local lines = {
      vim.json.encode({ jsonrpc = "2.0", id = 1, method = "initialize", params = { protocolVersion = "2025-06-18" } }),
      vim.json.encode({ jsonrpc = "2.0", id = 2, method = "tools/call", params = { name = call.name, arguments = substitute(call.arguments or {}) } }),
    }
    local cmd = vim.list_extend({ mcp.command }, mcp.args)
    local out = vim.system(cmd, { stdin = table.concat(lines, "\n") .. "\n", text = true }):wait()
    for line in (out.stdout or ""):gmatch("[^\n]+") do
      local ok, message = pcall(vim.json.decode, line)
      if ok and message.id == 2 then
        local result = message.result or {}
        local text = ((result.content or {})[1] or {}).text or ""
        id = text:match("context_id: (%x+)") or id
        results[#results + 1] = (result.isError and "ERROR " or "") .. text
      end
    end
  end
end
if os.getenv("AGENT_MODE_FAKE_RESULTS") then
  vim.fn.writefile(vim.split(table.concat(results, "\n---\n"), "\n", { plain = true }), os.getenv("AGENT_MODE_FAKE_RESULTS"))
end
io.stdout:write(os.getenv("AGENT_MODE_FAKE_TEXT") or "")
os.exit(tonumber(os.getenv("AGENT_MODE_FAKE_EXIT") or "0"))
