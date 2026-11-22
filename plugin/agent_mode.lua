if vim.g.loaded_agent_mode then
  return
end
vim.g.loaded_agent_mode = true

vim.api.nvim_create_user_command("AgentMode", function(args)
  if args.args ~= "" then
    require("agent_mode").run(args.args)
  else
    require("agent_mode").prompt()
  end
end, { nargs = "*", desc = "agent-mode: ask the agent to change the code at the cursor" })

vim.api.nvim_create_user_command("AgentModeCancel", function()
  require("agent_mode").cancel()
end, { desc = "agent-mode: stop the requests on the cursor line, or all of them" })

vim.api.nvim_create_user_command("AgentModeDismiss", function(args)
  require("agent_mode").dismiss(args.bang)
end, { bang = true, desc = "agent-mode: clear the inline answer nearest the cursor (! for all)" })

vim.api.nvim_create_user_command("AgentModeNew", function()
  require("agent_mode").new_session()
end, { desc = "agent-mode: start a new conversation with the agent" })

vim.api.nvim_create_user_command("AgentModeLog", function()
  require("agent_mode").show_log()
end, { desc = "agent-mode: show the last prompt and reply" })

vim.api.nvim_create_user_command("AgentModeAgent", function(args)
  local agent_mode = require("agent_mode")
  if args.args ~= "" then
    agent_mode.configure({ agent = args.args })
  end
  local config = agent_mode.config
  local agent = type(config.agent) == "string" and config.agent or "custom function"
  local details = config.agent == "axo" and ("session " .. config.axo.session)
    or string.format("model %s, thinking %s", config.model or "default", config.thinking or "default")
  vim.notify(string.format("agent-mode: %s (%s)", agent, details))
end, {
  nargs = "?",
  complete = function()
    return require("agent_mode").agent_names
  end,
  desc = "agent-mode: show or switch the agent (pi, claude, codex, opencode, axo)",
})
