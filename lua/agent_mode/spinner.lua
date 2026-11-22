-- An "agent is working" marker at the end of the line a request is about,
-- with a one-line status of what the agent is doing.
--
-- The marker is an extmark, so it follows its line when the buffer changes,
-- including edits made by other requests.

local M = {}

local namespace = vim.api.nvim_create_namespace("agent_mode")
local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

M.namespace = namespace

local MAX_STATUS = 70

--- Show the spinner on `row` (1-based) of `bufnr`.
function M.start(bufnr, row, status)
  local frame = 1
  local stopped = false
  status = status or "agent working…"
  local timer = vim.uv.new_timer()
  local mark = vim.api.nvim_buf_set_extmark(bufnr, namespace, row - 1, 0, {})

  local function draw()
    if stopped or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, mark, {})
    if not pos[1] then
      return
    end
    pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, pos[1], 0, {
      id = mark,
      virt_text = { { " " .. frames[frame] .. " " .. status, "Comment" } },
      virt_text_pos = "eol",
    })
    frame = frame % #frames + 1
  end

  draw()
  timer:start(100, 100, vim.schedule_wrap(draw))

  local self = {}

  --- The 1-based row the spinner is on now.
  function self:row()
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, mark, {})
    return pos[1] and pos[1] + 1 or nil
  end

  --- Replace the status next to the spinner; nil or blank keeps the old one.
  function self:set_status(text)
    text = vim.trim((text or ""):gsub("%s+", " "))
    if text == "" then
      return
    end
    if vim.fn.strchars(text) > MAX_STATUS then
      text = vim.fn.strcharpart(text, 0, MAX_STATUS - 1) .. "…"
    end
    status = text
    draw()
  end

  function self:status()
    return status
  end

  function self:stop()
    if stopped then
      return
    end
    stopped = true
    timer:stop()
    timer:close()
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, mark)
    end
  end

  return self
end

return M
