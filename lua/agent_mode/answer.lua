-- Answers shown inline, below the line the question was asked on.
--
-- An answer is virtual lines attached to that line, so it moves with the
-- code, scrolls with the buffer, and never changes the file. It stays until
-- dismissed. While a buffer shows answers, it maps keys to jump between them
-- and to dismiss the one nearest the cursor.

local M = {}

M.namespace = vim.api.nvim_create_namespace("agent_mode_answer")

vim.api.nvim_set_hl(0, "AgentModeAnswer", { link = "NormalFloat", default = true })
vim.api.nvim_set_hl(0, "AgentModeAnswerBorder", { link = "FloatBorder", default = true })
vim.api.nvim_set_hl(0, "AgentModeAnswerTitle", { link = "Title", default = true })
vim.api.nvim_set_hl(0, "AgentModeAnswerMore", { link = "Comment", default = true })

local BORDER = "│ "

local function is_fence(line)
  return line:match("^%s*```") or line:match("^%s*~~~")
end

--- Word-wrap one line of prose. Continuation lines keep the line's
--- indentation, or hang under the text of a list item.
local function wrap_line(line, width)
  local indent = line:match("^%s*")
  local marker = line:match("^%s*[-*+]%s+") or line:match("^%s*%d+[.)]%s+")
  local hang = marker and string.rep(" ", vim.fn.strdisplaywidth(marker)) or indent
  local room = math.max(width - vim.fn.strdisplaywidth(hang), 1)

  -- Split words too long for a line so nothing runs off the window.
  local words = {}
  for word in line:gmatch("%S+") do
    while vim.fn.strdisplaywidth(word) > room do
      local head = vim.fn.strcharpart(word, 0, room)
      words[#words + 1] = head
      word = vim.fn.strcharpart(word, vim.fn.strchars(head))
    end
    words[#words + 1] = word
  end

  local out, current = {}, nil
  for _, word in ipairs(words) do
    if not current then
      current = indent .. word
    elseif vim.fn.strdisplaywidth(current .. " " .. word) <= width then
      current = current .. " " .. word
    else
      out[#out + 1] = current
      current = hang .. word
    end
  end
  out[#out + 1] = current or ""
  return out
end

--- Word-wrap `text` to `width` columns, keeping its own line breaks. Lines
--- inside fenced code blocks are left as they are.
function M.wrap(text, width)
  width = math.max(width, 10)
  local out = {}
  local in_fence = false
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if is_fence(line) then
      in_fence = not in_fence
      out[#out + 1] = line
    elseif in_fence then
      out[#out + 1] = line
    else
      vim.list_extend(out, wrap_line(line, width))
    end
  end
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return out
end

-- Captures that carry no colour of their own.
local SKIPPED_CAPTURES = { spell = true, nospell = true, conceal = true, none = true }

--- Highlight `lines` as Markdown with tree-sitter, including injected
--- languages in fenced code blocks when their parsers are installed.
--- Returns, for each line, a list of virt_text chunks { text, hl_group }.
function M.highlight(lines, base_group)
  local text = table.concat(lines, "\n")
  -- groups[row][byte] = highlight group; later captures and injected
  -- languages win, as in a buffer.
  local groups = {}
  local fences = {}
  for row = 1, #lines do
    groups[row] = {}
    fences[row] = is_fence(lines[row]) and true or false
  end

  local ok, parser = pcall(vim.treesitter.get_string_parser, text, "markdown")
  if ok and parser then
    pcall(function()
      parser:parse(true)
      parser:for_each_tree(function(tree, language_tree)
        local lang = language_tree:lang()
        local query = vim.treesitter.query.get(lang, "highlights")
        if not query then
          return
        end
        for id, node in query:iter_captures(tree:root(), text, 0, -1) do
          local name = query.captures[id]
          if not SKIPPED_CAPTURES[name] and not name:match("^_") then
            local group = "@" .. name .. "." .. lang
            local injected = lang ~= "markdown" and lang ~= "markdown_inline"
            local start_row, start_col, end_row, end_col = node:range()
            for row = start_row, math.min(end_row, #lines - 1) do
              -- An injected language's range can spill onto the closing fence.
              if injected and fences[row + 1] then
                goto next_row
              end
              local line = lines[row + 1]
              local first = row == start_row and start_col or 0
              local last = row == end_row and end_col or #line
              for col = first + 1, math.min(last, #line) do
                groups[row + 1][col] = group
              end
              ::next_row::
            end
          end
        end
      end)
    end)
  end

  local result = {}
  for row, line in ipairs(lines) do
    local chunks = {}
    local start, current = 1, groups[row][1]
    for col = 2, #line + 1 do
      local group = groups[row][col]
      if col > #line or group ~= current then
        local hl = current and { base_group, current } or base_group
        chunks[#chunks + 1] = { line:sub(start, col - 1), hl }
        start, current = col, group
      end
    end
    if #chunks == 0 then
      chunks[1] = { "", base_group }
    end
    result[row] = chunks
  end
  return result
end

--- How wide answer text can be: the window's text area (without the number
--- and sign columns), less the border, and at most 100 columns.
function M.text_width(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    return 80
  end
  local info = vim.fn.getwininfo(win)[1]
  return math.min(info.width - info.textoff - vim.fn.strdisplaywidth(BORDER) - 1, 100)
end
local text_width = M.text_width

--- How many lines of an answer to show inline: what fits in the window
--- below a title, with a little of the code still in view.
function M.max_inline_lines(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  local height = win ~= -1 and vim.api.nvim_win_get_height(win) or 24
  return math.max(height - 4, 6)
end

local function marks(bufnr)
  return vim.api.nvim_buf_get_extmarks(bufnr, M.namespace, 0, -1, { details = true })
end

--- The answers visible in `bufnr`, top to bottom, as { id, row, lines }.
function M.list(bufnr)
  local answers = {}
  for _, mark in ipairs(marks(bufnr)) do
    local lines = {}
    for _, chunks in ipairs(mark[4].virt_lines or {}) do
      local parts = {}
      for _, chunk in ipairs(chunks) do
        parts[#parts + 1] = chunk[1]
      end
      lines[#lines + 1] = table.concat(parts)
    end
    answers[#answers + 1] = { id = mark[1], row = mark[2] + 1, lines = lines }
  end
  return answers
end

-- Keys mapped in a buffer while it shows answers, by buffer.
local mapped = {}

-- The text of each answer, by buffer and extmark id, for opening it.
local contents = {}

local function unmap(bufnr)
  for _, key in ipairs(mapped[bufnr] or {}) do
    pcall(vim.keymap.del, "n", key, { buffer = bufnr })
  end
  mapped[bufnr] = nil
end

local function after_change(bufnr)
  local alive = {}
  for _, mark in ipairs(marks(bufnr)) do
    alive[mark[1]] = true
  end
  for id in pairs(contents[bufnr] or {}) do
    if not alive[id] then
      contents[bufnr][id] = nil
    end
  end
  if next(alive) == nil then
    unmap(bufnr)
    contents[bufnr] = nil
  end
end

--- The answer anchored on `row`, if any (the last one when several are).
function M.at(bufnr, row)
  local found
  for _, a in ipairs(M.list(bufnr)) do
    if a.row == row then
      found = a
    end
  end
  return found
end

--- Open the answer anchored on the cursor line in a window laid over it, as
--- a Markdown buffer the cursor can move through, select, and yank from.
--- `q` or <Esc> closes it, and so does leaving it. Returns the window, or
--- nil when there is no answer on the cursor line.
function M.enter()
  local code_win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(code_win)[1]
  local a = M.at(bufnr, row)
  local content = a and contents[bufnr] and contents[bufnr][a.id]
  if not content then
    return nil
  end

  local lines = vim.list_extend({ content.title }, content.lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  -- Make room under the answer's line: scroll it to the top when the answer
  -- doesn't fit below it, then size the window to the space that is left so
  -- it covers the inline answer instead of being pushed up over the code.
  local function space_below()
    local screen_row = vim.fn.screenpos(code_win, row, 1).row
    local win_top = vim.api.nvim_win_get_position(code_win)[1]
    return vim.api.nvim_win_get_height(code_win) - (screen_row - win_top)
  end
  if space_below() < #lines then
    vim.api.nvim_win_call(code_win, function()
      vim.cmd("normal! zt")
    end)
  end
  local height = math.max(1, math.min(#lines, space_below()))

  local info = vim.fn.getwininfo(code_win)[1]
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "win",
    win = code_win,
    bufpos = { row - 1, 0 },
    row = 1,
    col = 0,
    -- The text area, less the border and the blank column after it.
    width = math.max(info.width - info.textoff - 2, 10),
    height = height,
    border = { "", "", "", "", "", "", "", { "│", "AgentModeAnswerBorder" } },
    style = "minimal",
    zindex = 10,
  })
  vim.wo[win].winhighlight = "Normal:AgentModeAnswer,FoldColumn:AgentModeAnswer"
  -- The lines are already wrapped like the inline answer; wrapping again
  -- would make the window taller than the space it covers.
  vim.wo[win].wrap = false
  -- One blank column after the border, where the inline answer has a space.
  vim.wo[win].foldcolumn = "1"

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, close, { buffer = buf, desc = "agent-mode: back to the code" })
  end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
  return win
end

--- The answer closest to `row`, preferring the one above it on a tie (you
--- read an answer from below its line).
function M.nearest(bufnr, row)
  local best, best_distance = nil, math.huge
  for _, a in ipairs(M.list(bufnr)) do
    local distance = math.abs(a.row - row) + (a.row > row and 0.5 or 0)
    if distance < best_distance then
      best, best_distance = a, distance
    end
  end
  return best
end

--- Clear the answer nearest to `row`, or every answer when `row` is nil.
function M.dismiss(bufnr, row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if row == nil then
    vim.api.nvim_buf_clear_namespace(bufnr, M.namespace, 0, -1)
  else
    local a = M.nearest(bufnr, row)
    if a then
      vim.api.nvim_buf_del_extmark(bufnr, M.namespace, a.id)
    end
  end
  after_change(bufnr)
end

--- Move the cursor to the next (direction 1) or previous (-1) answer's line.
function M.jump(direction)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local answers = M.list(vim.api.nvim_get_current_buf())
  local target
  for i = direction == 1 and 1 or #answers, direction == 1 and #answers or 1, direction do
    local a = answers[i]
    if (direction == 1 and a.row > row) or (direction == -1 and a.row < row) then
      target = a
      break
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target.row, 0 })
  end
end

local function map_keys(bufnr, keys)
  if mapped[bufnr] then
    return
  end
  mapped[bufnr] = {}
  local function map(key, fn, desc)
    if key then
      vim.keymap.set("n", key, fn, { buffer = bufnr, desc = "agent-mode: " .. desc })
      table.insert(mapped[bufnr], key)
    end
  end
  if keys.enter then
    -- Only on a line with an answer; elsewhere the key does what it did.
    vim.keymap.set("n", keys.enter, function()
      if M.at(bufnr, vim.api.nvim_win_get_cursor(0)[1]) then
        vim.schedule(M.enter)
        return ""
      end
      return keys.enter
    end, { buffer = bufnr, expr = true, replace_keycodes = true, desc = "agent-mode: open the answer on this line" })
    table.insert(mapped[bufnr], keys.enter)
  end
  map(keys.dismiss, function()
    M.dismiss(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  end, "dismiss the nearest answer")
  map(keys.next, function()
    M.jump(1)
  end, "next answer")
  map(keys.prev, function()
    M.jump(-1)
  end, "previous answer")
end

--- Show `text` below line `row` (1-based) of `bufnr`.
--- @param opts { title: string, keys: agent_mode.AnswerKeymaps|nil }
function M.show(bufnr, row, text, opts)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local virt_lines = {
    { { BORDER, "AgentModeAnswerBorder" }, { opts.title, "AgentModeAnswerTitle" } },
  }
  -- Neovim cannot scroll through virtual lines: an answer taller than the
  -- window could never be read to the end. Show what fits and say how to
  -- open the rest, which <CR> shows in a window that scrolls.
  local highlighted = M.highlight(M.wrap(text, text_width(bufnr)), "AgentModeAnswer")
  local fits = M.max_inline_lines(bufnr)
  local hidden = #highlighted > fits and #highlighted - (fits - 1) or 0
  for i, chunks in ipairs(highlighted) do
    if hidden > 0 and i > fits - 1 then
      break
    end
    table.insert(chunks, 1, { BORDER, "AgentModeAnswerBorder" })
    virt_lines[#virt_lines + 1] = chunks
  end
  if hidden > 0 then
    local key = opts.keys and opts.keys.enter
    virt_lines[#virt_lines + 1] = {
      { BORDER, "AgentModeAnswerBorder" },
      {
        string.format("… %d more line%s%s", hidden, hidden == 1 and "" or "s", key and (" · " .. key .. " on the line to read it all") or ""),
        "AgentModeAnswerMore",
      },
    }
  end
  -- A blank line after the answer, so it is easy to see where it ends.
  virt_lines[#virt_lines + 1] = { { "", "Normal" } }
  local last_row = vim.api.nvim_buf_line_count(bufnr)
  local id = vim.api.nvim_buf_set_extmark(bufnr, M.namespace, math.min(row, last_row) - 1, 0, {
    virt_lines = virt_lines,
  })
  contents[bufnr] = contents[bufnr] or {}
  contents[bufnr][id] = { title = opts.title, lines = M.wrap(text, text_width(bufnr)) }
  map_keys(bufnr, opts.keys or {})
end

return M
