-- :checkhealth agent_mode

local M = {}

function M.check()
  local health = vim.health
  local settings = require("agent_mode.config")
  local agent_mode = require("agent_mode")
  local config = agent_mode.config

  health.start("agent-mode: Neovim")
  if vim.fn.has("nvim-0.12") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.12 or newer is required; this is " .. tostring(vim.version()))
  end

  health.start("agent-mode: settings")
  local err = settings.check(config)
  if err then
    health.error(err)
  else
    health.ok("settings are valid")
  end
  local unknown = settings.unknown_keys(settings.from_globals())
  if #unknown > 0 then
    health.warn("unknown keys in vim.g.agent_mode, ignored: " .. table.concat(unknown, ", "))
  end
  if config.keymap then
    health.warn("`keymap` is deprecated", { 'Map it yourself: vim.keymap.set({ "n", "x" }, "<key>", "<Plug>(AgentMode)")' })
  end
  if vim.fn.hasmapto("<Plug>(AgentMode)", "n") == 0 then
    health.info('No key is mapped to <Plug>(AgentMode); e.g. vim.keymap.set({ "n", "x" }, "<leader>a", "<Plug>(AgentMode)")')
  end
  if config.lua == "allow" then
    health.warn("lua = \"allow\": the agent's Lua runs without asking, with your editor's permissions")
  end

  health.start("agent-mode: agent")
  local agent = config.agent
  if type(agent) == "function" then
    health.ok("a custom agent function")
  elseif agent == "axo" then
    local cmd = config.axo.cmd
    if vim.fn.executable(cmd) == 1 then
      health.ok("axo CLI: " .. vim.fn.exepath(cmd))
    else
      health.error("the axo CLI (" .. cmd .. ") is not on PATH")
    end
    if config.axo.session == "self" and not vim.env.AXO_SESSION_ID then
      health.warn('axo.session is "self", but Neovim is not running in an Axo Session')
    end
  else
    local cmd = config.cmd or agent
    if vim.fn.executable(cmd) == 1 then
      health.ok(string.format("%s: %s", agent, vim.fn.exepath(cmd)))
    else
      health.error(
        string.format("%s is not on Neovim's PATH", cmd),
        { "Install it, or point at it with cmd = vim.fn.expand('~/path/to/" .. agent .. "')" }
      )
    end
  end

  health.start("agent-mode: optional")
  if pcall(require, "snacks") then
    health.ok("snacks.nvim: :AgentMode config uses its picker")
  else
    health.info("snacks.nvim is not installed: :AgentMode config falls back to vim.ui.select")
  end
  if vim.fn.executable("rg") == 1 then
    health.ok("ripgrep, for the agent's Lua")
  else
    health.info("ripgrep is not installed; the agent's Lua falls back to slower searches")
  end
end

return M
