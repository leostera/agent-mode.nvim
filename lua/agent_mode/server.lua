-- Tells agent-mode's MCP server (bin/agent-mode-mcp) where this Neovim is,
-- so an agent finds it from any folder: a file per Neovim in the state
-- folder with its address, working folder, and when the user last used it
-- (the server prefers a Neovim in the agent's project, then the latest). Loaded at startup
-- by plugin/agent_mode.lua; it requires nothing else.

local M = {}

local path = vim.fs.joinpath(vim.fn.stdpath("state"), "agent-mode", "servers", vim.fn.getpid() .. ".json")

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
    }),
  }, path)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("agent_mode_server", { clear = true })
  -- FocusGained: switching to this Neovim makes it the one agents reach.
  vim.api.nvim_create_autocmd({ "DirChanged", "FocusGained" }, { group = group, callback = M.register })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      pcall(os.remove, path)
    end,
  })
  M.register()
end

return M
