-- The contract between agent-mode and the agent.
--
-- The agent never touches files. It answers with one JSON object describing
-- actions, and this module turns that untrusted text into a list of typed
-- actions, or an error explaining why it could not.
--
-- Response shape:
--   { "summary": "...", "actions": [ <action>, ... ] }
--
-- Actions:
--   { "type": "edit", "edits": [ { "start_line": 3, "end_line": 4, "text": "..." } ] }
--       Replace buffer lines start_line..end_line (1-based, inclusive) with
--       text. end_line = start_line - 1 inserts before start_line. An empty
--       text deletes the lines.
--   { "type": "lsp_rename", "new_name": "presenter" }
--       Rename the symbol under the cursor through the language server.
--   { "type": "code_action", "id": 2 }
--       Run one of the code actions listed in the prompt.
--   { "type": "message", "text": "..." }
--       Tell the user something instead of changing code.

local M = {}

M.system_prompt = [[
You are agent-mode, an assistant embedded in the Neovim editor. The user is
editing a file and has given you a short instruction about the code at their
cursor. You change the code by answering with exactly one JSON object and
nothing else: no prose, no markdown fences.

The object has this shape, with the summary first:
{"summary": "<what you are doing, in a few words>", "actions": [<action>, ...]}

The summary is shown to the user while you write the rest, so write it
first and make it say what you are about to do, like "Renaming message to
presenter" or "Explaining the retry loop".

Available actions:

1. {"type": "lsp_rename", "new_name": "<identifier>"}
   Renames the symbol under the cursor across the whole project using the
   language server. Prefer this for renames whenever the prompt says
   "LSP rename: available".

2. {"type": "code_action", "id": <number>}
   Runs one of the language server code actions listed in the prompt. Prefer
   this when one of the listed actions does exactly what the user asked.

3. {"type": "edit", "edits": [{"start_line": <n>, "end_line": <m>, "text": "<replacement>"}]}
   Replaces lines n..m (1-based, inclusive) of the current buffer with the
   replacement text. Lines are separated by "\n" in the text. Use
   end_line = start_line - 1 to insert before start_line, and "" as the text
   to delete lines. Always give the complete new content of every line in the
   range, with the original indentation. Edits must not overlap. Use the line
   numbers shown in the prompt; never include those line numbers in the text.

4. {"type": "message", "text": "<text>"}
   Says something to the user without changing code. Use it to answer a
   question about the code or to explain why you cannot do what was asked.
   It is shown inline, below the line the user asked from, rendered as
   Markdown: use `inline code` for identifiers, short lists, and fenced code
   blocks with a language (```lua) for snippets. Answer directly and
   completely, without a preamble or headings.

Make the smallest change that does what the user asked. Change only what the
instruction covers, and keep the surrounding style.
]]

local function fail(fmt, ...)
  return nil, string.format(fmt, ...)
end

local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

local function is_nonempty_string(value)
  return type(value) == "string" and value ~= ""
end

--- Pull the JSON object out of the agent's text. Models sometimes wrap it in
--- a markdown fence or a sentence despite being told not to.
local function extract_object(text)
  local first = text:find("{", 1, true)
  local last
  for i = #text, 1, -1 do
    if text:sub(i, i) == "}" then
      last = i
      break
    end
  end
  if not first or not last or last < first then
    return nil
  end
  return text:sub(first, last)
end

local function parse_edit(raw, index)
  if type(raw) ~= "table" then
    return fail("edit %d is not an object", index)
  end
  if not is_integer(raw.start_line) or raw.start_line < 1 then
    return fail("edit %d has an invalid start_line", index)
  end
  if not is_integer(raw.end_line) or raw.end_line < raw.start_line - 1 then
    return fail("edit %d has an invalid end_line", index)
  end
  if type(raw.text) ~= "string" then
    return fail("edit %d has no text", index)
  end
  return { start_line = raw.start_line, end_line = raw.end_line, text = raw.text }
end

local function parse_action(raw, index)
  if type(raw) ~= "table" then
    return fail("action %d is not an object", index)
  end

  if raw.type == "edit" then
    if type(raw.edits) ~= "table" or #raw.edits == 0 then
      return fail("edit action %d has no edits", index)
    end
    local edits = {}
    for i, raw_edit in ipairs(raw.edits) do
      local edit, err = parse_edit(raw_edit, i)
      if not edit then
        return nil, err
      end
      edits[#edits + 1] = edit
    end
    return { type = "edit", edits = edits }
  end

  if raw.type == "lsp_rename" then
    if not is_nonempty_string(raw.new_name) then
      return fail("lsp_rename action %d has no new_name", index)
    end
    return { type = "lsp_rename", new_name = raw.new_name }
  end

  if raw.type == "code_action" then
    if not is_integer(raw.id) then
      return fail("code_action action %d has no numeric id", index)
    end
    return { type = "code_action", id = raw.id }
  end

  if raw.type == "message" then
    if not is_nonempty_string(raw.text) then
      return fail("message action %d has no text", index)
    end
    return { type = "message", text = raw.text }
  end

  return fail("action %d has unknown type %s", index, vim.inspect(raw.type))
end

--- Parse the agent's raw output into { summary = string?, actions = {...} }.
--- @param text string
--- @return table|nil response
--- @return string|nil err
function M.parse(text)
  local object = extract_object(text or "")
  if not object then
    return fail("agent reply has no JSON object: %s", vim.trim(text or ""):sub(1, 200))
  end

  local ok, decoded = pcall(vim.json.decode, object, { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= "table" then
    return fail("agent reply is not valid JSON: %s", object:sub(1, 200))
  end
  if type(decoded.actions) ~= "table" or #decoded.actions == 0 then
    return fail("agent reply has no actions")
  end

  local actions = {}
  for i, raw in ipairs(decoded.actions) do
    local action, err = parse_action(raw, i)
    if not action then
      return nil, err
    end
    actions[#actions + 1] = action
  end

  local summary = is_nonempty_string(decoded.summary) and decoded.summary or nil
  return { summary = summary, actions = actions }
end

return M
