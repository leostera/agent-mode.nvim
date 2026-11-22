-- The transcript: a Markdown buffer in a side split that logs every request,
-- what the agent did on the way (tool calls, its Lua, edits, reloaded
-- files), and its answers. With it on, answers go here instead of inline.

local M = {}

local NAME = "agent-mode://transcript"

local bufnr = nil
local last_request = nil -- the request the last entry belongs to

--- The transcript buffer, created on first use.
function M.buf()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  pcall(vim.api.nvim_buf_set_name, bufnr, NAME)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "# agent-mode", "" })
  vim.bo[bufnr].modifiable = false
  -- As late as possible, so ftplugins and the user's FileType autocmds
  -- can adjust the buffer.
  vim.bo[bufnr].filetype = "markdown"
  return bufnr
end

--- The window showing the transcript in the current tab, if any.
function M.win()
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

--- Show the transcript in a side split of the current tab, keeping the
--- cursor where it is.
--- @param opts { position: "right"|"left", width: integer }
function M.open(opts)
  local existing = M.win()
  if existing then
    return existing
  end
  local origin = vim.api.nvim_get_current_win()
  local placement = opts.position == "left" and "topleft" or "botright"
  vim.cmd(string.format("%s vertical %dsplit", placement, opts.width))
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, M.buf())
  vim.wo[win].winfixwidth = true
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].conceallevel = 2
  M.scroll_to_end(win)
  if vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  return win
end

function M.close()
  local win = M.win()
  if win and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.api.nvim_win_close(win, false)
  end
end

--- Open or close the transcript; returns whether it is open now.
--- @param opts { position: "right"|"left", width: integer }
function M.toggle(opts)
  if M.win() then
    M.close()
    return false
  end
  M.open(opts)
  return true
end

function M.scroll_to_end(win)
  local count = vim.api.nvim_buf_line_count(M.buf())
  pcall(vim.api.nvim_win_set_cursor, win, { count, 0 })
end

--- Windows showing the transcript whose cursor is on its last line: they
--- follow new entries; the others stay where the user scrolled to.
local function following()
  local wins = {}
  local count = vim.api.nvim_buf_line_count(M.buf())
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == M.buf() and vim.api.nvim_win_get_cursor(win)[1] >= count then
      wins[#wins + 1] = win
    end
  end
  return wins
end

--- Append Markdown lines.
--- @param lines string[]
function M.append(lines)
  local buf = M.buf()
  local follow = following()
  -- One blank line between entries, never two.
  local last = vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1]
  while lines[1] == "" and last == "" do
    table.remove(lines, 1)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  vim.bo[buf].modifiable = false
  for _, win in ipairs(follow) do
    M.scroll_to_end(win)
  end
end

--- The lines so far, for tests and :AgentMode log.
function M.lines()
  return vim.api.nvim_buf_get_lines(M.buf(), 0, -1, false)
end

local function split(text)
  return vim.split(text, "\n", { plain = true })
end

local function where(snapshot)
  local file = snapshot.path ~= "" and vim.fn.fnamemodify(snapshot.path, ":~:.") or "[unnamed]"
  if snapshot.selection then
    return string.format("%s:%d-%d", file, snapshot.selection.start_row, snapshot.selection.end_row)
  end
  return string.format("%s:%d", file, snapshot.position.row)
end

--- Lines for `request`; when another request wrote in between, say whose
--- they are again.
local function entry(request, lines)
  if last_request ~= request then
    last_request = request
    if request.transcript_started then
      table.insert(lines, 1, string.format("*#%d, continued*", request.id))
      table.insert(lines, 2, "")
    end
  end
  M.append(lines)
end

--- A request starts: what was asked, and where.
function M.request(request)
  last_request = request
  request.transcript_started = true
  local lines = { string.format("## #%d you · %s", request.id, where(request.snapshot)), "" }
  for _, line in ipairs(split(request.instruction)) do
    lines[#lines + 1] = "> " .. line
  end
  lines[#lines + 1] = ""
  M.append(lines)
end

--- A step on the way: a tool call, an edit, a reloaded file.
function M.step(request, text)
  entry(request, { "- " .. text })
end

--- What the agent said it is doing.
function M.summary(request, text)
  entry(request, { "", "*" .. text .. "*", "" })
end

--- The agent's answer, in full.
function M.answer(request, agent, text)
  local lines = { "", string.format("**%s**", agent), "" }
  vim.list_extend(lines, split(text))
  lines[#lines + 1] = ""
  entry(request, lines)
end

--- Lua the agent ran, and what came back.
function M.lua(request, code, report)
  local lines = { "", "Lua in Neovim:", "", "```lua" }
  vim.list_extend(lines, split(code))
  vim.list_extend(lines, { "```", "", "```" })
  vim.list_extend(lines, split(report))
  vim.list_extend(lines, { "```", "" })
  entry(request, lines)
end

--- The request is over.
function M.done(request, err, seconds)
  if err then
    entry(request, { "", string.format("**Error:** %s", err), "" })
  end
  entry(request, { string.format("*#%d done in %.1fs*", request.id, seconds), "", "---", "" })
end

return M
