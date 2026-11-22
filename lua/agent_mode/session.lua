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
  AgentModeSessionInput = { link = "NormalFloat" },
  AgentModeSessionInputTitle = { link = "Title" },
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
  input_buf = nil,
  code_win = nil, -- the code window a message from the sidebar asks about
  label = "ask the agent", -- the input's title
  on_submit = nil, -- fun(text: string, win: integer)
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

--- The input at the bottom of the sidebar: a buffer you type into, kept
--- across requests, so nothing typed there is lost.
--- @return integer
function M.input_buf()
  if state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf) then
    return state.input_buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  assert(buf ~= 0, "agent-mode: could not create the session input")
  state.input_buf = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, NAME .. "/input")
  local function map(modes, key, fn, desc)
    vim.keymap.set(modes, key, fn, { buffer = buf, nowait = true, desc = "agent-mode session: " .. desc })
  end
  map({ "n", "i" }, "<CR>", M.submit, "send the message")
  map("i", "<C-j>", "<CR>", "a new line in the message")
  map("i", "<S-CR>", "<CR>", "a new line in the message")
  map("n", "q", M.hide, "hide the session")
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter" }, {
    buffer = buf,
    callback = M.placeholder,
  })
  vim.bo[buf].filetype = "agentmodeinput"
  M.placeholder()
  return buf
end

--- The empty split at the bottom of the sidebar that keeps room for the
--- input, which floats over it with a border like the inline prompt's.
--- @return integer
local function host_buf()
  if state.host_buf and vim.api.nvim_buf_is_valid(state.host_buf) then
    return state.host_buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  assert(buf ~= 0, "agent-mode: could not create the session input")
  state.host_buf = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "agentmodeinputhost"
  return buf
end

local function is_sidebar(win)
  local buf = vim.api.nvim_win_get_buf(win)
  return buf == state.buf or buf == state.input_buf or buf == state.host_buf
end

local function window_in(tab, buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

--- The window showing the session's log in the current tab, if any.
function M.win()
  return window_in(0, state.buf)
end

--- The window with the session's input in the current tab, if any.
function M.input_win()
  return window_in(0, state.input_buf)
end

local function host_win()
  return window_in(0, state.host_buf)
end

local function sidebar_style(win)
  local wo = vim.wo[win]
  wo.winfixwidth = true
  -- Like a file tree's sidebar: :e, :bnext or a picker open files in
  -- another window, never in this one.
  wo.winfixbuf = true
  wo.wrap = true
  wo.linebreak = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.cursorline = false
  wo.list = false
  wo.fillchars = "fold: ,eob: "
end

local function style(win)
  sidebar_style(win)
  local wo = vim.wo[win]
  wo.breakindent = true
  wo.breakindentopt = "shift:4"
  wo.foldmethod = "expr"
  wo.foldexpr = "v:lua.require'agent_mode.session'.foldexpr(v:lnum)"
  wo.foldtext = "v:lua.require'agent_mode.session'.foldtext()"
  wo.foldlevel = 0
  wo.foldenable = true
  wo.winhighlight = "Folded:AgentModeSessionFold"
end

local INPUT_LINES = 3

--- Where the input floats: over its host split and its status line, inside
--- a rounded border.
local function input_config(host)
  local width = vim.api.nvim_win_get_width(host)
  return {
    relative = "win",
    win = host,
    row = 0,
    col = 0,
    width = math.max(width - 2, 10),
    height = INPUT_LINES,
    border = "rounded",
    title = { { " " .. state.label .. " ", "AgentModeInputTitle" } },
    title_pos = "left",
    footer = { { " <CR> send · <C-j> new line ", "AgentModeSessionDim" } },
    footer_pos = "right",
    zindex = 40,
  }
end

local function input_style(win)
  local wo = vim.wo[win]
  wo.winfixbuf = true
  wo.wrap = true
  wo.linebreak = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.cursorline = false
  wo.fillchars = "eob: "
  wo.winhighlight = "NormalFloat:AgentModeInput,FloatBorder:AgentModeInputBorder,FloatTitle:AgentModeInputTitle"
end

function M.scroll_to_end(win)
  pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(M.buf()), 0 })
end

--- Put the input back over its host, sized to it.
local function place_input()
  local host, input = host_win(), M.input_win()
  if host and input then
    vim.api.nvim_win_set_config(input, input_config(host))
  end
end

--- Show the session's log and input in the current tab, without moving
--- the cursor: nothing switches windows, so a prompt open elsewhere stays.
local function open_here()
  local log, host, input = M.win(), host_win(), M.input_win()
  if log and host and input then
    return log
  end
  -- Rebuild a half-open sidebar (a piece of it was closed alone).
  for _, win in ipairs({ input, host, log }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  log = vim.api.nvim_open_win(M.buf(), false, {
    split = state.opts.position == "left" and "left" or "right",
    win = -1,
    width = state.opts.width,
  })
  style(log)
  M.scroll_to_end(log)
  -- The input and its border are one row taller than the host, so they
  -- also cover the host's status line.
  host = vim.api.nvim_open_win(host_buf(), false, { split = "below", win = log, height = INPUT_LINES + 1 })
  sidebar_style(host)
  vim.wo[host].winfixheight = true
  vim.wo[host].statusline = " "
  input = vim.api.nvim_open_win(M.input_buf(), false, input_config(host))
  input_style(input)
  return log
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
  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      local buf = vim.api.nvim_win_get_buf(win)
      if buf == state.host_buf then
        -- Moving into the input's room goes into the input.
        local input = M.input_win()
        if input then
          vim.schedule(function()
            if vim.api.nvim_win_is_valid(input) then
              vim.api.nvim_set_current_win(input)
            end
          end)
        end
      elseif vim.api.nvim_win_get_config(win).relative == "" and not is_sidebar(win) then
        -- Where a message typed in the sidebar asks about: the code window
        -- you were in last.
        state.code_win = win
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = augroup,
    callback = function()
      place_input()
    end,
  })
  -- :q in the sidebar hides it everywhere, as q does.
  vim.api.nvim_create_autocmd("QuitPre", {
    group = augroup,
    callback = function()
      if is_sidebar(vim.api.nvim_get_current_win()) then
        state.quitting = true
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(event)
      local was_sidebar = event.buf == state.buf or event.buf == state.input_buf or event.buf == state.host_buf
      vim.schedule(function()
        if was_sidebar and state.quitting then
          state.quitting = false
          return M.hide()
        end
        state.quitting = false
        -- A tab left with only the sidebar in it is done: close it, or quit
        -- when it is the last one (as :q would, so unsaved changes stop it).
        if M.close_if_alone() then
          return
        end
        -- Pinned: :only or <C-w>o elsewhere does not take the sidebar away.
        if was_sidebar and state.visible then
          open_here()
        end
      end)
    end,
  })
  local origin = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(origin).relative == "" and not is_sidebar(origin) then
    state.code_win = origin
  end
  return open_here()
end

--- If only the sidebar is left in the current tab, close the tab (or quit).
--- @return boolean closed
function M.close_if_alone()
  local others = 0
  local sidebar = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      if is_sidebar(win) then
        sidebar = sidebar + 1
      else
        others = others + 1
      end
    end
  end
  if others > 0 or sidebar == 0 then
    return false
  end
  if #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd("tabclose")
  else
    pcall(vim.cmd.qall)
  end
  return true
end

--- Hide the session in every tab, until it is opened again.
function M.hide()
  state.visible = false
  vim.api.nvim_clear_autocmds({ group = augroup })
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, buf in ipairs({ state.input_buf, state.host_buf, state.buf }) do
      local win = window_in(tab, buf)
      if win and #vim.api.nvim_tabpage_list_wins(tab) > 1 then
        vim.api.nvim_win_close(win, false)
      end
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

-- Input ------------------------------------------------------------------------

local input_ns = vim.api.nvim_create_namespace("agent_mode_session_input")

--- What a message sent from the sidebar does, and the input's title.
--- @param label string e.g. "ask pi"
--- @param on_submit fun(text: string, win: integer)
function M.on_submit(label, on_submit)
  state.label, state.on_submit = label, on_submit
  place_input()
  M.placeholder()
end

--- Show what to do in the input while it is empty.
function M.placeholder()
  local buf = state.input_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, input_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    vim.api.nvim_buf_set_extmark(buf, input_ns, 0, 0, {
      virt_text = { { "a message about the code you were in…", "AgentModeSessionDim" } },
      virt_text_pos = "overlay",
    })
  end
end

--- The code window a message from the sidebar asks about: the one you were
--- in last in this tab, or any other.
local function code_window()
  local win = state.code_win
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage() then
    return win
  end
  for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(candidate).relative == "" and not is_sidebar(candidate) then
      return candidate
    end
  end
  return nil
end

--- Send what is in the input, about the cursor in the last code window.
function M.submit()
  local buf = M.input_buf()
  local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  if text == "" or not state.on_submit then
    return
  end
  local win = code_window()
  if not win then
    vim.notify("agent-mode: no code window to ask about", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  M.placeholder()
  state.on_submit(text, win)
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
