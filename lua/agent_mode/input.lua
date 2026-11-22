-- The instruction prompt: a one-line window right below the cursor, so you
-- type next to the code you are asking about.

local M = {}

vim.api.nvim_set_hl(0, "AgentModeInput", { link = "NormalFloat", default = true })
vim.api.nvim_set_hl(0, "AgentModeInputBorder", { link = "FloatBorder", default = true })
vim.api.nvim_set_hl(0, "AgentModeInputTitle", { link = "FloatTitle", default = true })

--- Open the prompt below the cursor of the current window. Calls
--- `on_submit(text)` with what was typed on <CR>, or nothing when cancelled
--- (<Esc> in normal mode, <C-c>, or leaving the window).
--- @param opts { title: string, width: integer|nil }
function M.open(opts, on_submit)
  local origin = vim.api.nvim_get_current_win()
  local origin_cursor = vim.api.nvim_win_get_cursor(origin)
  local available = vim.api.nvim_win_get_width(origin) - vim.fn.wincol() - 2
  local width = math.max(math.min(opts.width or 72, available), 30)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = { { " " .. opts.title .. " ", "AgentModeInputTitle" } },
    title_pos = "left",
    zindex = 60,
  })
  vim.wo[win].winhighlight = "Normal:AgentModeInput,FloatBorder:AgentModeInputBorder"

  local closed = false
  local function close(text)
    if closed then
      return
    end
    closed = true
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
      -- Leaving insert mode lands after the window switch and would move
      -- the cursor one column left; put it back where it was.
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(origin) then
          pcall(vim.api.nvim_win_set_cursor, origin, origin_cursor)
        end
      end)
    end
    if text then
      vim.schedule(function()
        on_submit(text)
      end)
    end
  end

  local function submit()
    close(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
  end

  local map = function(modes, key, fn)
    vim.keymap.set(modes, key, fn, { buffer = buf, nowait = true })
  end
  map({ "i", "n" }, "<CR>", submit)
  map({ "i", "n" }, "<C-c>", function()
    close(nil)
  end)
  map("n", "<Esc>", function()
    close(nil)
  end)
  map("n", "q", function()
    close(nil)
  end)
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      close(nil)
    end,
  })

  vim.cmd("startinsert")
  return win
end

return M
