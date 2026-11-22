-- What the agent gets to see: a snapshot of the buffer and cursor taken when
-- the user asked, rendered into the prompt.

local M = {}

--- Snapshot the editor state the request is about.
--- @param opts { bufnr: integer, position: { row: integer, col: integer }, selection: { start_row: integer, end_row: integer }|nil }
function M.capture(opts)
  local bufnr = opts.bufnr
  local position = opts.position
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  local cursor_line = lines[position.row] or ""

  return {
    bufnr = bufnr,
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    path = vim.api.nvim_buf_get_name(bufnr),
    filetype = vim.bo[bufnr].filetype,
    position = position,
    selection = opts.selection,
    word = M.word_at(cursor_line, position.col),
    lines = lines,
    diagnostics = vim.diagnostic.get(bufnr, { lnum = position.row - 1 }),
  }
end

--- The identifier-like word covering byte column `col` (0-based) of `line`.
function M.word_at(line, col)
  local index = col + 1
  if not line:sub(index, index):match("[%w_]") then
    return nil
  end
  local first, last = index, index
  while first > 1 and line:sub(first - 1, first - 1):match("[%w_]") do
    first = first - 1
  end
  while last < #line and line:sub(last + 1, last + 1):match("[%w_]") do
    last = last + 1
  end
  return line:sub(first, last)
end

--- The 1-based inclusive line range of the buffer to show the agent: the
--- whole buffer when it fits in `max_lines`, otherwise a window around the
--- cursor (and selection).
function M.visible_range(snapshot, max_lines)
  local total = #snapshot.lines
  if total <= max_lines then
    return 1, total
  end
  local focus_start = snapshot.selection and snapshot.selection.start_row or snapshot.position.row
  local focus_end = snapshot.selection and snapshot.selection.end_row or snapshot.position.row
  local margin = math.max(0, math.floor((max_lines - (focus_end - focus_start + 1)) / 2))
  local first = math.max(1, focus_start - margin)
  local last = math.min(total, first + max_lines - 1)
  first = math.max(1, last - max_lines + 1)
  return first, last
end

local function render_code_actions(code_actions)
  if #code_actions == 0 then
    return "Code actions at the cursor: none"
  end
  local out = { "Code actions at the cursor:" }
  for _, entry in ipairs(code_actions) do
    local kind = entry.kind and (" [" .. entry.kind .. "]") or ""
    out[#out + 1] = string.format("  %d. %s%s", entry.id, entry.title, kind)
  end
  return table.concat(out, "\n")
end

local function render_diagnostics(diagnostics)
  if #diagnostics == 0 then
    return nil
  end
  local severity_names = { "error", "warning", "info", "hint" }
  local out = { "Diagnostics on the cursor line:" }
  for _, d in ipairs(diagnostics) do
    out[#out + 1] = string.format("  - %s: %s", severity_names[d.severity] or "note", d.message)
  end
  return table.concat(out, "\n")
end

--- Render the prompt for an agent that works in its own session and edits
--- files itself (see agent_mode.axo). It can read the file, so this only
--- says where the user is and what they want.
--- @param snapshot table from M.capture
--- @param instruction string
--- @param nonce string tag the reply watcher looks for
--- @param extra_instructions string|nil the user's system_prompt
function M.render_session(snapshot, instruction, nonce, extra_instructions)
  local row, col = snapshot.position.row, snapshot.position.col
  local cursor_line = snapshot.lines[row] or ""
  local out = {
    string.format("[agent-mode request %s, from Neovim]", nonce),
    "",
    "Instruction: " .. instruction,
    "File: " .. snapshot.path,
    string.format("Cursor: line %d, column %d", row, col + 1),
    "Cursor line: " .. cursor_line,
  }
  if snapshot.word then
    out[#out + 1] = "Word under cursor: " .. snapshot.word
  end
  if snapshot.selection then
    out[#out + 1] =
      string.format("Selection: lines %d-%d", snapshot.selection.start_row, snapshot.selection.end_row)
  end
  local diagnostics = render_diagnostics(snapshot.diagnostics)
  if diagnostics then
    out[#out + 1] = diagnostics
  end
  vim.list_extend(out, {
    "",
    "The file is saved. If the instruction asks for a change, make it by editing",
    "the files directly; Neovim reloads the buffer when your turn ends. Make the",
    "smallest change that does what was asked, and reply with one short sentence",
    "saying what you did. If it is a question, do not edit anything: answer it,",
    "directly and without a preamble; your reply is shown inline under the line",
    "the user asked from, rendered as Markdown (inline code, short lists, and",
    "fenced code blocks with a language work well; skip headings).",
  })
  if extra_instructions and extra_instructions ~= "" then
    vim.list_extend(out, { "", extra_instructions })
  end
  return table.concat(out, "\n")
end

--- Render the prompt for `instruction` against `snapshot`.
--- @param snapshot table from M.capture
--- @param instruction string
--- @param capabilities { can_rename: boolean, code_actions: table[] }
--- @param max_lines integer
function M.render(snapshot, instruction, capabilities, max_lines)
  local first, last = M.visible_range(snapshot, max_lines)
  local cursor_line = snapshot.lines[snapshot.position.row] or ""

  local sections = {
    "Instruction: " .. instruction,
    "File: " .. (snapshot.path ~= "" and snapshot.path or "[unnamed buffer]"),
    "Filetype: " .. (snapshot.filetype ~= "" and snapshot.filetype or "unknown"),
    string.format(
      "Cursor: line %d, column %d, on the text %q",
      snapshot.position.row,
      snapshot.position.col + 1,
      cursor_line:sub(snapshot.position.col + 1, snapshot.position.col + 40)
    ),
  }
  if snapshot.word then
    sections[#sections + 1] = "Word under cursor: " .. snapshot.word
  end
  if snapshot.selection then
    sections[#sections + 1] = string.format(
      "Selection: lines %d-%d",
      snapshot.selection.start_row,
      snapshot.selection.end_row
    )
  end
  sections[#sections + 1] = "LSP rename: " .. (capabilities.can_rename and "available" or "not available")
  sections[#sections + 1] = render_code_actions(capabilities.code_actions)
  local diagnostics = render_diagnostics(snapshot.diagnostics)
  if diagnostics then
    sections[#sections + 1] = diagnostics
  end

  local width = #tostring(last)
  local numbered = {}
  for row = first, last do
    local marker = row == snapshot.position.row and ">" or " "
    numbered[#numbered + 1] = string.format("%" .. width .. "d%s| %s", row, marker, snapshot.lines[row])
  end
  local header = first == 1 and last == #snapshot.lines
      and string.format("Buffer (%d lines, cursor line marked with >):", #snapshot.lines)
    or string.format("Buffer lines %d-%d of %d (cursor line marked with >):", first, last, #snapshot.lines)
  sections[#sections + 1] = header .. "\n" .. table.concat(numbered, "\n")

  return table.concat(sections, "\n\n")
end

return M
