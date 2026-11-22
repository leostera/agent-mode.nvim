-- The session: a side split, pinned to every tab, that logs each request
-- as blocks: what you asked, each tool call the agent makes (with its full
-- command and output folded under it), its Lua, edits, reloaded files, and
-- its answers. Lines are drawn with nui.nvim's NuiLine/NuiText; the buffer
-- and the windows are agent-mode's, so closing a window never loses the log.

local M = {}

local NAME = "agent-mode://session"
local ns = vim.api.nvim_create_namespace("agent_mode_session")
local anchors = vim.api.nvim_create_namespace("agent_mode_session_anchors")

local hl = {
  AgentModeSessionYou = { link = "CursorLine" },
  AgentModeSessionYouBar = { link = "Special" },
  AgentModeSessionYouName = { link = "Title" },
  AgentModeSessionTool = { link = "ColorColumn" },
  AgentModeSessionToolName = { link = "Function" },
  AgentModeSessionOk = { link = "DiagnosticOk" },
  AgentModeSessionError = { link = "DiagnosticError" },
  AgentModeSessionRunning = { link = "DiagnosticInfo" },
  AgentModeSessionDim = { link = "Comment" },
  AgentModeSessionFold = { link = "Comment" },
  AgentModeSessionAgent = { link = "Title" },
  AgentModeSessionSummary = { link = "Comment" },
}
for name, value in pairs(hl) do
  value.default = true
  vim.api.nvim_set_hl(0, name, value)
end

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local state = {
  buf = nil,
  blocks = {}, -- in buffer order: { anchor, height, build = fun(): rows }
  folds = {}, -- fold level by line: 0, or 1 inside a block's details
  visible = false, -- shown in every tab until hidden
  opts = { position = "right", width = 64 },
  last_request = nil,
  tools = {}, -- tool blocks by call id
  frame = 1,
  timer = nil,
}

local function NuiLine(...)
  return require("nui.line")(...)
end

local function NuiText(...)
  return require("nui.text")(...)
end

-- Buffer and windows -----------------------------------------------------------

--- The session buffer, created on first use.
--- @return integer
function M.buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  assert(buf ~= 0, "agent-mode: could not create the session buffer")
  state.buf, state.blocks, state.folds, state.tools = buf, {}, {}, {}
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, NAME)
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, desc = "agent-mode session: " .. desc })
  end
  map("<CR>", M.toggle_details, "open or close the details under this line")
  map("<Tab>", M.toggle_details, "open or close the details under this line")
  map("q", M.hide, "hide the session")
  -- As late as possible, so the user's FileType autocmds can adjust it.
  vim.bo[buf].filetype = "agentmode"
  return buf
end

local function window_in(tab)
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_buf(win) == state.buf then
      return win
    end
  end
  return nil
end

--- The window showing the session in the current tab, if any.
function M.win()
  return window_in(0)
end

local function style(win)
  local wo = vim.wo[win]
  wo.winfixwidth = true
  -- Like a file tree's sidebar: :e, :bnext or a picker open files in
  -- another window, never in this one.
  if vim.fn.has("nvim-0.10") == 1 then
    wo.winfixbuf = true
  end
  wo.wrap = true
  wo.linebreak = true
  wo.breakindent = true
  wo.breakindentopt = "shift:4"
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.cursorline = false
  wo.list = false
  wo.foldmethod = "expr"
  wo.foldexpr = "v:lua.require'agent_mode.session'.foldexpr(v:lnum)"
  wo.foldtext = "v:lua.require'agent_mode.session'.foldtext()"
  wo.foldlevel = 0
  wo.foldenable = true
  wo.fillchars = "fold: ,eob: "
  wo.winhighlight = "Folded:AgentModeSessionFold"
end

function M.scroll_to_end(win)
  pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(M.buf()), 0 })
end

--- Show the session in the current tab, keeping the cursor where it is.
local function open_here()
  local existing = M.win()
  if existing then
    return existing
  end
  local origin = vim.api.nvim_get_current_win()
  local placement = state.opts.position == "left" and "topleft" or "botright"
  vim.cmd(string.format("noautocmd %s vertical %dsplit", placement, state.opts.width))
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, M.buf())
  style(win)
  M.scroll_to_end(win)
  if vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  return win
end

local augroup = vim.api.nvim_create_augroup("agent_mode_session", { clear = true })

--- Show the session, pinned: in this tab and in every tab entered until
--- it is hidden.
--- @param opts { position: "right"|"left", width: integer }
function M.open(opts)
  state.opts = opts or state.opts
  state.visible = true
  vim.api.nvim_clear_autocmds({ group = augroup })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = augroup,
    callback = function()
      if state.visible then
        vim.schedule(open_here)
      end
    end,
  })
  -- :q in the session hides it everywhere, as q does.
  vim.api.nvim_create_autocmd("QuitPre", {
    group = augroup,
    callback = function()
      if vim.api.nvim_get_current_buf() == state.buf then
        state.quitting = true
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(event)
      local was_session = event.buf == state.buf
      vim.schedule(function()
        if was_session and state.quitting then
          state.quitting = false
          return M.hide()
        end
        state.quitting = false
        -- A tab left with only the session in it is done: close it, or quit
        -- when it is the last one (as :q would, so unsaved changes stop it).
        if M.close_if_alone() then
          return
        end
        -- Pinned: :only or <C-w>o elsewhere does not take the session away.
        if was_session and state.visible then
          open_here()
        end
      end)
    end,
  })
  return open_here()
end

--- If the session is the only window left in the current tab, close it.
--- @return boolean closed
function M.close_if_alone()
  local wins = vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative == ""
  end, vim.api.nvim_tabpage_list_wins(0))
  if #wins ~= 1 or vim.api.nvim_win_get_buf(wins[1]) ~= state.buf then
    return false
  end
  if #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd("tabclose")
  else
    pcall(vim.cmd.quit)
  end
  return true
end

--- Hide the session in every tab, until it is opened again.
function M.hide()
  state.visible = false
  vim.api.nvim_clear_autocmds({ group = augroup })
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local win = window_in(tab)
    if win and #vim.api.nvim_tabpage_list_wins(tab) > 1 then
      vim.api.nvim_win_close(win, false)
    end
  end
end
M.close = M.hide

--- Open or close the session; returns whether it is showing now.
function M.toggle(opts)
  if state.visible and M.win() then
    M.hide()
    return false
  end
  M.open(opts)
  return true
end

-- Folds ------------------------------------------------------------------------

function M.foldexpr(lnum)
  local level = state.folds[lnum] or 0
  if level == 0 then
    return "0"
  end
  return (state.folds[lnum - 1] or 0) == 0 and ">1" or "1"
end

function M.foldtext()
  local count = vim.v.foldend - vim.v.foldstart + 1
  return string.format("    ⋯ %d more line%s · <CR>", count, count == 1 and "" or "s")
end

--- Open or close the details of the entry under the cursor: on a tool's
--- first line, the folded lines right below it.
function M.toggle_details()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if (state.folds[row] or 0) == 0 and (state.folds[row + 1] or 0) == 1 then
    row = row + 1
  end
  if (state.folds[row] or 0) == 0 then
    return
  end
  if vim.fn.foldclosed(row) ~= -1 then
    vim.cmd(row .. "foldopen")
  else
    vim.cmd(row .. "foldclose")
  end
end

-- Rendering --------------------------------------------------------------------

--- A row: its texts { { text, group } ... }, and optionally a background
--- group for the whole line, text aligned right, and whether it folds.
--- @alias agent_mode.TranscriptRow { texts: string[][], bg: string|nil, right: string[][]|nil, fold: boolean|nil }

local function block_start(block)
  return vim.api.nvim_buf_get_extmark_by_id(state.buf, anchors, block.anchor, {})[1]
end

local function rebuild_folds()
  local folds = {}
  for _, block in ipairs(state.blocks) do
    local start = block_start(block)
    for i, row in ipairs(block.rows or {}) do
      folds[start + i] = row.fold and 1 or 0
    end
  end
  state.folds = folds
end

--- Windows showing the session with the cursor on its last line: they
--- follow new entries; the others stay where the user scrolled to.
local function following()
  local wins = {}
  local count = vim.api.nvim_buf_line_count(state.buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == state.buf and vim.api.nvim_win_get_cursor(win)[1] >= count then
      wins[#wins + 1] = win
    end
  end
  return wins
end

local function render(block)
  local buf = M.buf()
  local rows = block.build()
  local start = block_start(block)
  local follow = following()
  local lines = {}
  local nui = {}
  for i, row in ipairs(rows) do
    local line = NuiLine()
    for _, text in ipairs(row.texts) do
      -- A stack of groups (Treesitter captures) goes in as the extmark's.
      local group = text[2]
      line:append(NuiText(text[1], type(group) == "table" and { hl_group = group } or group))
    end
    nui[i] = line
    lines[i] = line:content()
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, start, start + block.height, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, start, start + #rows)
  for i, row in ipairs(rows) do
    local linenr = start + i
    nui[i]:highlight(buf, ns, linenr)
    if row.bg or row.right then
      vim.api.nvim_buf_set_extmark(buf, ns, linenr - 1, 0, {
        line_hl_group = row.bg,
        virt_text = row.right,
        virt_text_pos = row.right and "right_align" or nil,
        priority = 50,
      })
    end
  end
  vim.api.nvim_buf_set_extmark(buf, anchors, start, 0, { id = block.anchor, right_gravity = false })
  block.height, block.rows = #rows, rows
  rebuild_folds()
  -- Neovim caches fold levels; recompute them where the session shows.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_win_call(win, function()
        vim.cmd("silent! normal! zx")
      end)
    end
  end
  for _, win in ipairs(follow) do
    M.scroll_to_end(win)
  end
end

--- Add a block at the end, drawn by `build`; returns it, to redraw later.
local function add(build)
  local buf = M.buf()
  local first = #state.blocks == 0
  local start = first and 0 or vim.api.nvim_buf_line_count(buf)
  local block = {
    anchor = vim.api.nvim_buf_set_extmark(buf, anchors, start, 0, { right_gravity = false }),
    -- The first block replaces the empty line a new buffer has.
    height = first and 1 or 0,
    build = build,
  }
  state.blocks[#state.blocks + 1] = block
  render(block)
  return block
end

local function split_lines(text)
  return vim.split(vim.trim(text or ""), "\n", { plain = true })
end

--- Highlighted rows for `text` in `lang` (Markdown when nil), indented.
local function highlighted(text, lang, indent, opts)
  local answer = require("agent_mode.answer")
  local lines = split_lines(text)
  local fenced = lang ~= nil
  if fenced then
    table.insert(lines, 1, "```" .. lang)
    lines[#lines + 1] = "```"
  end
  local rows = {}
  for i, chunks in ipairs(answer.highlight(lines, "Normal", { conceal = true })) do
    if not fenced or (i > 1 and i < #lines) then
      local texts = { { indent, "Normal" } }
      for _, chunk in ipairs(chunks) do
        texts[#texts + 1] = { chunk[1], chunk[2] }
      end
      rows[#rows + 1] = vim.tbl_extend("force", { texts = texts }, opts or {})
    end
  end
  return rows
end

local function where(snapshot)
  local file = snapshot.path ~= "" and vim.fn.fnamemodify(snapshot.path, ":~:.") or "[unnamed]"
  if snapshot.selection then
    return string.format("%s:%d-%d", file, snapshot.selection.start_row, snapshot.selection.end_row)
  end
  return string.format("%s:%d", file, snapshot.position.row)
end

local function duration(ms)
  if not ms then
    return nil
  end
  return ms < 1000 and string.format("%dms", ms) or string.format("%.1fs", ms / 1000)
end

--- When another request wrote in between, say whose blocks these are again.
local function belongs(request)
  if state.last_request ~= request then
    state.last_request = request
    if request.session_started then
      add(function()
        return { { texts = { { string.format("  #%d, continued", request.id), "AgentModeSessionDim" } } } }
      end)
    end
  end
end

-- Spinner for running tools ----------------------------------------------------

local function any_running()
  for _, block in pairs(state.tools) do
    if block.call.running then
      return true
    end
  end
  return false
end

local function spin()
  if state.timer then
    return
  end
  state.timer = vim.uv.new_timer()
  state.timer:start(100, 100, vim.schedule_wrap(function()
    if not any_running() then
      if state.timer then
        state.timer:stop()
        state.timer:close()
        state.timer = nil
      end
      return
    end
    state.frame = state.frame % #SPINNER + 1
    for _, block in pairs(state.tools) do
      if block.call.running then
        render(block)
      end
    end
  end))
end

-- Entries ----------------------------------------------------------------------

--- A request starts: what was asked, and where.
function M.request(request)
  state.last_request = request
  request.session_started = true
  local time = os.date("%H:%M")
  add(function()
    local rows = {
      { texts = { { "", "Normal" } } },
      {
        texts = {
          { "▍ ", "AgentModeSessionYouBar" },
          { "you", "AgentModeSessionYouName" },
          { "  " .. where(request.snapshot), "AgentModeSessionDim" },
        },
        bg = "AgentModeSessionYou",
        right = { { string.format("#%d · %s ", request.id, time), "AgentModeSessionDim" } },
      },
    }
    for _, line in ipairs(split_lines(request.instruction)) do
      rows[#rows + 1] = { texts = { { "▍ ", "AgentModeSessionYouBar" }, { line, "Normal" } }, bg = "AgentModeSessionYou" }
    end
    rows[#rows + 1] = { texts = { { "", "Normal" } } }
    return rows
  end)
end

--- How to show a tool's arguments: its main one, and the language to
--- highlight it in.
local function tool_detail(call)
  local args = type(call.args) == "table" and call.args or {}
  if type(args.code) == "string" then
    return args.code, "typescript"
  end
  if type(args.command) == "string" then
    return args.command, "bash"
  end
  local main = args.path or args.pattern or args.query or args.file_path
  if type(main) == "string" then
    local rest = vim.deepcopy(args)
    rest.path, rest.pattern, rest.query, rest.file_path = nil, nil, nil, nil
    if next(rest) then
      return main .. "  " .. vim.json.encode(rest), nil
    end
    return main, nil
  end
  return next(args) and vim.json.encode(args) or "", nil
end

local function build_tool(call)
  return function()
    local icon, icon_hl
    if call.running then
      icon, icon_hl = SPINNER[state.frame], "AgentModeSessionRunning"
    elseif call.error then
      icon, icon_hl = "✗", "AgentModeSessionError"
    else
      icon, icon_hl = "✓", "AgentModeSessionOk"
    end
    local detail, lang = tool_detail(call)
    local detail_lines = split_lines(detail)
    local bg = "AgentModeSessionTool"
    local rows = {
      {
        texts = {
          { "  " .. icon .. " ", icon_hl },
          { call.name, "AgentModeSessionToolName" },
          { call.ms and (" " .. duration(call.ms)) or "", "AgentModeSessionDim" },
          { "  " .. (detail_lines[1] or ""), "Normal" },
        },
        bg = bg,
      },
    }
    -- The rest of the command, then the output: folded, never cut.
    if #detail_lines > 1 then
      vim.list_extend(rows, highlighted(table.concat(detail_lines, "\n", 2), lang, "      ", { bg = bg, fold = true }))
    end
    if call.output and call.output ~= "" then
      for _, line in ipairs(split_lines(call.output)) do
        rows[#rows + 1] = {
          texts = { { "    │ ", "AgentModeSessionDim" }, { line, call.error and "AgentModeSessionError" or "AgentModeSessionDim" } },
          bg = bg,
          fold = true,
        }
      end
    end
    return rows
  end
end

--- The agent started a tool: { id, name, args }.
function M.tool_start(request, call)
  belongs(request)
  call = vim.tbl_extend("force", {}, call, { running = true })
  local block = add(build_tool(call))
  block.call = call
  if call.id then
    state.tools[call.id] = block
  end
  spin()
end

--- A tool finished: { id, name, output, error, ms }.
function M.tool_end(request, call)
  local block = call.id and state.tools[call.id]
  if not block then
    M.tool_start(request, call)
    block = call.id and state.tools[call.id]
    if not block then
      return
    end
  end
  block.call.running = false
  block.call.output, block.call.error, block.call.ms = call.output, call.error, call.ms
  block.build = build_tool(block.call)
  render(block)
  state.tools[call.id] = nil
end

--- A step that is not a tool call: an edit, a reload, a rename.
function M.step(request, text)
  belongs(request)
  add(function()
    return { { texts = { { "  • ", "AgentModeSessionDim" }, { text, "Normal" } } } }
  end)
end

--- What the agent said it is doing.
function M.summary(request, text)
  belongs(request)
  add(function()
    return { { texts = { { "  " .. text, "AgentModeSessionSummary" } } } }
  end)
end

--- The agent's answer, as Markdown.
function M.answer(request, agent, text)
  belongs(request)
  add(function()
    local rows = { { texts = { { "", "Normal" } } }, { texts = { { "  " .. agent, "AgentModeSessionAgent" } } } }
    vim.list_extend(rows, highlighted(text, nil, "  "))
    return rows
  end)
end

--- Lua the agent ran in Neovim, and what came back (folded).
function M.lua(request, code, report)
  belongs(request)
  local failed = report:match("^error:") or report:match("\nerror:")
  add(function()
    local bg = "AgentModeSessionTool"
    local rows = {
      {
        texts = {
          { "  " .. (failed and "✗" or "✓") .. " ", failed and "AgentModeSessionError" or "AgentModeSessionOk" },
          { "lua", "AgentModeSessionToolName" },
          { "  in Neovim", "AgentModeSessionDim" },
        },
        bg = bg,
      },
    }
    vim.list_extend(rows, highlighted(code, "lua", "      ", { bg = bg }))
    for _, line in ipairs(split_lines(report)) do
      rows[#rows + 1] = {
        texts = { { "    │ ", "AgentModeSessionDim" }, { line, failed and "AgentModeSessionError" or "AgentModeSessionDim" } },
        bg = bg,
        fold = true,
      }
    end
    return rows
  end)
end

--- The request is over.
--- @param label string|nil e.g. "pi · claude-sonnet-5-5"
function M.done(request, err, seconds, label)
  belongs(request)
  add(function()
    local rows = { { texts = { { "", "Normal" } } } }
    if err then
      rows[#rows + 1] = { texts = { { "  ✗ ", "AgentModeSessionError" }, { err, "AgentModeSessionError" } } }
    end
    rows[#rows + 1] = {
      texts = {
        { err and "  " or "  ✓ ", "AgentModeSessionOk" },
        { string.format("%s%.1fs", label and (label .. " · ") or "", seconds), "AgentModeSessionDim" },
      },
    }
    return rows
  end)
end

--- The text so far, for tests.
function M.lines()
  return vim.api.nvim_buf_get_lines(M.buf(), 0, -1, false)
end

return M
