-- agent-mode's entry points: one <Plug> mapping and one :AgentMode command.
-- The rest is required when they are used; only the small registration that
-- lets a paired agent find this Neovim runs now.

if vim.g.loaded_agent_mode then
  return
end
vim.g.loaded_agent_mode = true

require("agent_mode.server").setup()

-- Map it yourself, e.g.: vim.keymap.set({ "n", "x" }, "<leader>a", "<Plug>(AgentMode)")
vim.keymap.set({ "n", "x" }, "<Plug>(AgentMode)", function()
  require("agent_mode").prompt()
end, { desc = "agent-mode: ask the agent about, or to change, the code at the cursor" })

---@class agent_mode.Subcommand
---@field run fun(args: string[], bang: boolean)
---@field complete? fun(lead: string): string[]
---@field desc string

---@type table<string, agent_mode.Subcommand>
local subcommands = {
  ask = {
    desc = "ask, or run an instruction, about the code at the cursor",
    run = function(args)
      local agent_mode = require("agent_mode")
      if #args > 0 then
        agent_mode.run(table.concat(args, " "))
      else
        agent_mode.prompt()
      end
    end,
  },
  cancel = {
    desc = "stop the requests on the cursor line, or all of them",
    run = function()
      require("agent_mode").cancel()
    end,
  },
  dismiss = {
    desc = "clear the answer nearest the cursor (! for all)",
    run = function(_, bang)
      require("agent_mode").dismiss(bang)
    end,
  },
  agent = {
    desc = "show or switch the agent",
    run = function(args)
      local agent_mode = require("agent_mode")
      if args[1] then
        agent_mode.configure({ agent = args[1] })
      end
      local config = agent_mode.config
      local agent = type(config.agent) == "string" and config.agent or "custom function"
      local details = config.agent == "axo" and ("session " .. config.axo.session)
        or string.format("model %s, thinking %s", config.model or "default", config.thinking or "default")
      vim.notify(string.format("agent-mode: %s (%s)", agent, details))
    end,
    complete = function(lead)
      return vim.tbl_filter(function(name)
        return vim.startswith(name, lead)
      end, require("agent_mode").agent_names)
    end,
  },
  config = {
    desc = "change the agent, model, and other settings from a menu",
    run = function()
      require("agent_mode").open_config()
    end,
  },
  new = {
    desc = "start a new session, and unpair the paired agent",
    run = function()
      require("agent_mode").new_session()
    end,
  },
  pair = {
    desc = "pair an agent you run yourself with this Neovim (pi: /nvim), or see which is paired",
    run = function()
      require("agent_mode").pair()
    end,
  },
  log = {
    desc = "show the last prompt, command, session, and reply",
    run = function()
      require("agent_mode").show_log()
    end,
  },
}

vim.api.nvim_create_user_command("AgentMode", function(opts)
  local name, args = opts.fargs[1], vim.list_slice(opts.fargs, 2)
  if not name then
    return require("agent_mode").prompt()
  end
  local subcommand = subcommands[name]
  if not subcommand then
    return vim.notify(
      string.format("agent-mode: unknown subcommand %q; try :AgentMode ask %s", name, opts.args),
      vim.log.levels.ERROR
    )
  end
  subcommand.run(args, opts.bang)
end, {
  nargs = "*",
  bang = true,
  desc = "agent-mode: ask the agent, or :AgentMode {ask|cancel|dismiss|agent|config|new|pair|log}",
  complete = function(lead, line)
    local words = vim.split(line:gsub("^%S+%s*", ""), "%s+")
    if #words <= 1 then
      return vim.tbl_filter(function(name)
        return vim.startswith(name, lead)
      end, vim.fn.sort(vim.tbl_keys(subcommands)))
    end
    local subcommand = subcommands[words[1]]
    return subcommand and subcommand.complete and subcommand.complete(lead) or {}
  end,
})
