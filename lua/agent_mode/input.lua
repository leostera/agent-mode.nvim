-- The instruction prompt, right below the cursor so you type next to the
-- code you are asking about. It is snacks.nvim's input (Snacks.input):
-- moving to another window leaves it open with what you typed, <Up> and
-- <Down> go through what you asked before (cancelled prompts included),
-- and asking again while one is open goes back to it.

local M = {}

vim.api.nvim_set_hl(0, "AgentModeInput", { link = "SnacksInputNormal", default = true })
vim.api.nvim_set_hl(0, "AgentModeInputBorder", { link = "SnacksInputBorder", default = true })
vim.api.nvim_set_hl(0, "AgentModeInputTitle", { link = "SnacksInputTitle", default = true })

--- What agent-mode uses of the window Snacks.input returns.
--- @class agent_mode.SnacksWin
--- @field win integer
--- @field valid fun(self: agent_mode.SnacksWin): boolean
--- @field focus fun(self: agent_mode.SnacksWin)

--- @type agent_mode.SnacksWin|nil
local open_win = nil

--- The prompt that is open, if any.
--- @return integer|nil
function M.win()
  if open_win and open_win:valid() then
    return open_win.win
  end
  return nil
end

--- Open the prompt below the cursor of the current window. Calls
--- `on_submit(text)` with what was typed on <CR>, or nothing when cancelled
--- (<Esc> in normal mode, q, or <C-c>). When a prompt is already open, go
--- back to it instead.
--- @param opts { title: string, width: integer|nil }
--- @param on_submit fun(text: string|nil)
--- @return integer win
function M.open(opts, on_submit)
  local existing = M.win()
  if existing and open_win then
    open_win:focus()
    vim.cmd("startinsert!")
    return existing
  end
  local available = vim.api.nvim_win_get_width(0) - vim.fn.wincol() - 2
  local width = math.max(math.min(opts.width or 72, available), 30)
  local origin = vim.api.nvim_get_current_win()
  local origin_cursor = vim.api.nvim_win_get_cursor(origin)
  open_win = require("snacks").input({
    prompt = opts.title,
    icon = "",
    win = {
      relative = "cursor",
      row = 1,
      col = 0,
      width = width,
      title_pos = "left",
      wo = {
        winhighlight = "NormalFloat:AgentModeInput,FloatBorder:AgentModeInputBorder,FloatTitle:AgentModeInputTitle",
      },
    },
  }, function(text)
    open_win = nil
    -- Leaving insert mode lands after the window switch and would move the
    -- cursor one column left; put it back where it was.
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(origin) and vim.api.nvim_get_current_win() == origin then
        pcall(vim.api.nvim_win_set_cursor, origin, origin_cursor)
      end
    end)
    on_submit(text)
  end)
  -- Snacks starts insert mode a moment later; start it now, so keys typed
  -- right after the mapping (typeahead) land in the prompt.
  if vim.api.nvim_get_current_win() == open_win.win then
    vim.cmd("startinsert!")
  end
  return open_win.win
end

return M
