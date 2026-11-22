-- :AgentModeConfig: a window listing the settings you change most, each on
-- its own key. Changes apply at once and last until Neovim quits; `y` copies
-- them as Lua for your config.

local M = {}

vim.api.nvim_set_hl(0, "AgentModeConfigKey", { link = "Special", default = true })
vim.api.nvim_set_hl(0, "AgentModeConfigLabel", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "AgentModeConfigValue", { link = "Normal", default = true })
vim.api.nvim_set_hl(0, "AgentModeConfigTitle", { link = "FloatTitle", default = true })

--- Reasoning levels each agent takes, lowest first.
M.thinking_levels = {
  pi = { "off", "minimal", "low", "medium", "high", "xhigh" },
  codex = { "minimal", "low", "medium", "high" },
  claude = { "low", "medium", "high", "xhigh", "max" },
}

--- Models the agent can list, for the picker; nil when it cannot.
local model_lists = {
  pi = {
    argv = { "pi", "--list-models" },
    parse = function(stdout)
      local models = {}
      for line in stdout:gmatch("[^\n]+") do
        local provider, model = line:match("^(%S+)%s+(%S+)")
        if provider and provider ~= "provider" then
          models[#models + 1] = provider .. "/" .. model
        end
      end
      return models
    end,
  },
}

local function agent_mode()
  return require("agent_mode")
end

--- Replace settings, including clearing them to nil, which configure()'s
--- merge cannot do.
local function set(changes)
  local config = vim.deepcopy(agent_mode().config)
  for key, value in pairs(changes) do
    if value == vim.NIL then
      config[key] = nil
    else
      config[key] = value
    end
  end
  agent_mode().setup(config)
end

local function agent_label(agent)
  return type(agent) == "string" and agent or "custom function"
end

--- The settings as Lua for a config file: only what differs from the defaults.
function M.snippet()
  local config = agent_mode().config
  local defaults = agent_mode().defaults
  local lines = { 'require("agent_mode").setup({' }
  for _, key in ipairs({ "agent", "model", "thinking", "lua", "session", "input", "keymap" }) do
    local value = config[key]
    if type(value) ~= "function" and not vim.deep_equal(value, defaults[key]) then
      lines[#lines + 1] = string.format("  %s = %s,", key, vim.inspect(value))
    end
  end
  lines[#lines + 1] = "})"
  return table.concat(lines, "\n")
end

local function pick_model(done)
  local config = agent_mode().config
  local function choose(models)
    local items = { "(the agent's default)", "type a model…" }
    vim.list_extend(items, models)
    vim.ui.select(items, { prompt = "Model for " .. agent_label(config.agent) }, function(choice, index)
      if not choice then
        return done()
      end
      if index == 1 then
        set({ model = vim.NIL })
        return done()
      end
      if index == 2 then
        return vim.ui.input({ prompt = "Model: ", default = config.model or "" }, function(text)
          if text then
            set({ model = text ~= "" and text or vim.NIL })
          end
          done()
        end)
      end
      set({ model = choice })
      done()
    end)
  end
  local list = model_lists[config.agent]
  if not list then
    return choose({})
  end
  vim.notify("agent-mode: listing models…")
  vim.system(list.argv, { text = true }, function(result)
    vim.schedule(function()
      choose(result.code == 0 and list.parse(result.stdout or "") or {})
    end)
  end)
end

--- Each row: its key, its label, how its value reads, and how to change it.
local function rows()
  local config = agent_mode().config
  local levels = M.thinking_levels[config.agent]
  local list = {
    {
      key = "a",
      label = "Agent",
      value = agent_label(config.agent),
      change = function(done)
        vim.ui.select(agent_mode().agent_names, { prompt = "Agent" }, function(choice)
          if choice and choice ~= config.agent then
            -- Models and reasoning levels are per agent.
            set({ agent = choice, model = vim.NIL, thinking = vim.NIL })
          end
          done()
        end)
      end,
    },
  }
  if config.agent == "axo" then
    list[#list + 1] = {
      key = "s",
      label = "Axo Session",
      value = config.axo.session,
      change = function(done)
        vim.ui.input({ prompt = "Axo Session id (self: this one): ", default = config.axo.session }, function(text)
          if text and text ~= "" then
            agent_mode().configure({ axo = { session = text } })
          end
          done()
        end)
      end,
    }
  else
    list[#list + 1] = { key = "m", label = "Model", value = config.model or "default", change = pick_model }
    list[#list + 1] = {
      key = "t",
      label = "Thinking",
      value = levels and (config.thinking or "default") or "n/a",
      change = function(done)
        if not levels then
          return done()
        end
        local items = vim.list_extend({ "default" }, levels)
        vim.ui.select(items, { prompt = "Thinking" }, function(choice)
          if choice then
            set({ thinking = choice == "default" and vim.NIL or choice })
          end
          done()
        end)
      end,
    }
    list[#list + 1] = {
      key = "l",
      label = "Run Lua",
      value = config.lua == "allow" and "allow" or config.lua == "confirm" and "ask first" or "off",
      change = function(done)
        -- ask first -> allow -> off -> ask first
        local next = "confirm"
        if config.lua == "confirm" then
          next = "allow"
        elseif config.lua == "allow" then
          next = false
        end
        set({ lua = next })
        done()
      end,
    }
    list[#list + 1] = {
      key = "c",
      label = "Conversation",
      value = config.session and "one per Neovim" or "none (requests at once)",
      change = function(done)
        set({ session = not config.session })
        done()
      end,
    }
  end
  list[#list + 1] = {
    key = "i",
    label = "Prompt",
    value = config.input == "cmdline" and "command line" or "below the cursor",
    change = function(done)
      set({ input = config.input == "cmdline" and "cursor" or "cmdline" })
      done()
    end,
  }
  return list
end

local LABEL_WIDTH = 14

--- Open the settings window. Returns its window.
function M.open()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local ns = vim.api.nvim_create_namespace("agent_mode_config")
  local footer = " <CR> change · n new conversation · y copy as Lua · q close "
  local width = math.min(vim.fn.strdisplaywidth(footer) + 4, vim.o.columns - 4)
  local win

  local current = {}
  local function render()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    current = rows()
    local session = agent_mode().session()
    local lines = {}
    for _, row in ipairs(current) do
      lines[#lines + 1] = string.format("  %s  %-" .. LABEL_WIDTH .. "s%s", row.key, row.label, row.value)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "     " .. (session and ("conversation " .. session.id:sub(1, 12) .. "…") or "no conversation yet")
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i = 1, #current do
      vim.hl.range(buf, ns, "AgentModeConfigKey", { i - 1, 2 }, { i - 1, 3 })
      vim.hl.range(buf, ns, "AgentModeConfigLabel", { i - 1, 5 }, { i - 1, 5 + LABEL_WIDTH })
    end
    vim.hl.range(buf, ns, "AgentModeConfigLabel", { #lines - 1, 0 }, { #lines - 1, -1 })
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_height(win, #lines)
    end
  end
  render()

  win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - #current - 4) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = #current + 2,
    style = "minimal",
    border = "rounded",
    title = { { " agent-mode ", "AgentModeConfigTitle" } },
    title_pos = "left",
    footer = { { footer, "AgentModeConfigTitle" } },
    footer_pos = "right",
    zindex = 60,
  })
  vim.wo[win].cursorline = true
  render()

  local function refocus()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      render()
    end
  end
  local function change(row)
    if row then
      row.change(vim.schedule_wrap(refocus))
    end
  end
  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true })
  end
  map("<CR>", function()
    change(current[vim.api.nvim_win_get_cursor(win)[1]])
  end)
  for _, key in ipairs({ "a", "m", "t", "l", "c", "i", "s" }) do
    map(key, function()
      for i, row in ipairs(current) do
        if row.key == key then
          vim.api.nvim_win_set_cursor(win, { i, 0 })
          return change(row)
        end
      end
    end)
  end
  map("n", function()
    agent_mode().new_session()
    render()
  end)
  map("y", function()
    local snippet = M.snippet()
    vim.fn.setreg("+", snippet)
    vim.fn.setreg('"', snippet)
    vim.notify("agent-mode: copied the settings as Lua")
  end)
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  map("q", close)
  map("<Esc>", close)
  return win
end

return M
