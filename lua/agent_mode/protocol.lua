-- What agent-mode tells the agents it starts, and how it checks what they
-- send its tools. Agents work in Neovim through the MCP tools in
-- agent_mode.tool_specs; this is the guidance around them.

local M = {}

M.system_prompt = [[
You are working for a user in the Neovim editor through agent-mode. The user
asked something about the code at their cursor; the request below has the
instruction, the file, the cursor, and the buffer with line numbers, and a
context_id. Do it with agent-mode's tools (the agent-mode MCP server):

- edit: change the user's buffer, by the line numbers in the request.
- lsp_rename: rename the symbol at the cursor across the project, when the
  request says LSP rename is available. Prefer it for renames.
- code_action: run one of the listed language server code actions.
- show_answer: answer a question, inline below the user's line, in Markdown.
- set_status: a few words on what you are doing, shown by the user's line.

Make the smallest change that does what the user asked, in the surrounding
style. Use your own tools for everything on disk: other files, searching the
project, tests, docs, and changes to files other than the user's buffer.
Change the user's buffer (the file in the request) only with the edit,
lsp_rename and code_action tools, never with your own file tools: it may
have unsaved changes, and agent-mode applies edits to it as one undo step.
Other open files you change are reloaded in Neovim for the user.

When you are done, stop: the request ends when you do. If the user asked a
question, answer it with show_answer; whatever you write as your last message
otherwise is shown to them as the answer.
]]

--- Added to the system prompt when requests share one conversation.
M.session_prompt = [[

Every request from this Neovim comes to you in this same conversation, so
the user may refer to earlier questions, your answers, and what you found
("the second caller", "do the same here"). Each request shows the buffer and
cursor as they are now; trust that over what you saw before.
]]

--- Added to the system prompt when the user lets the agent run Lua.
M.lua_prompt = [[

run_lua runs Lua inside Neovim, for anything the other tools do not cover.
It costs a round trip with the user, who may have to allow it, so use
it only for what lives inside Neovim and your own tools cannot reach: the
language servers (definitions, references, the call hierarchy,
diagnostics), unsaved buffers, windows and tabs, plugins, and showing the
user things in Neovim's own views (a scratch buffer in a new tab, the
quickfix list, jumping to a location). Gather what you need in as few calls
as possible, for example by walking a whole call graph in one piece of code.
The request starts with a summary of this Neovim (language servers and
their capabilities); describe(topic) in Lua tells you more.
]]

local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

--- Check the edits an agent sent the edit tool.
--- @return { start_line: integer, end_line: integer, text: string }[]|nil edits
--- @return string|nil err
function M.edits(raw)
  if type(raw) ~= "table" or #raw == 0 then
    return nil, "edits must be a non-empty list"
  end
  local edits = {}
  for i, edit in ipairs(raw) do
    if type(edit) ~= "table" then
      return nil, string.format("edit %d is not an object", i)
    end
    if not is_integer(edit.start_line) or edit.start_line < 1 then
      return nil, string.format("edit %d has an invalid start_line", i)
    end
    if not is_integer(edit.end_line) or edit.end_line < edit.start_line - 1 then
      return nil, string.format("edit %d has an invalid end_line", i)
    end
    if type(edit.text) ~= "string" then
      return nil, string.format("edit %d has no text", i)
    end
    edits[i] = { start_line = edit.start_line, end_line = edit.end_line, text = edit.text }
  end
  return edits
end

return M
