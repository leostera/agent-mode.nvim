-- Tells the nvim-mcp server (bin/nvim-mcp) where this Neovim is,
-- so an agent finds it from any folder: a file per Neovim in the state
-- folder with its address, working folder, and when the user last used it
-- (the server prefers a Neovim in the agent's project, then the latest). Loaded at startup
-- by plugin/agent_mode.lua; it requires nothing else.

local M = {}

local path = vim.fs.joinpath(vim.fn.stdpath("state"), "nvim-mcp", "servers", vim.fn.getpid() .. ".json")

--- Write (or update) this Neovim's entry.
function M.register()
  if vim.v.servername == "" then
    return
  end
  local seconds, microseconds = vim.uv.gettimeofday()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  pcall(vim.fn.writefile, {
    vim.json.encode({
      address = vim.v.servername,
      cwd = vim.fn.getcwd(),
      pid = vim.fn.getpid(),
      used_at = seconds + microseconds / 1e6,
      file = vim.api.nvim_buf_get_name(0),
    }),
  }, path)
end

--- Remove the entries of Neovims that are gone (killed, or crashed before
--- VimLeavePre), so the folder does not fill up.
local function prune()
  local dir = vim.fs.dirname(path)
  for name in vim.fs.dir(dir) do
    local pid = tonumber(name:match("^(%d+)%.json$"))
    if pid and pid ~= vim.fn.getpid() then
      local alive = vim.uv.kill(pid, 0) == 0
      if not alive then
        pcall(os.remove, vim.fs.joinpath(dir, name))
      end
    end
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("agent_mode_server", { clear = true })
  -- FocusGained: switching to this Neovim makes it the one agents reach.
  -- BufEnter keeps the file it shows current, for picking it to pair with.
  vim.api.nvim_create_autocmd({ "DirChanged", "FocusGained", "BufEnter" }, { group = group, callback = M.register })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      pcall(os.remove, path)
    end,
  })
  M.register()
  pcall(prune)
end

return M
