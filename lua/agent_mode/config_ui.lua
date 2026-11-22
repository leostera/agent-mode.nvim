-- :AgentMode config: the settings you change most, as a menu.
--
-- Menus and text entry are drawn by snacks.nvim (a dependency in lazy.lua):
-- a fuzzy-searchable picker and an input box. Without snacks they fall back
-- to vim.ui.select and vim.ui.input. Changes apply at once and last until
-- Neovim quits; "Copy as Lua" gives them to you for your config.

local M = {}

local function snacks()
  local ok, Snacks = pcall(require, "snacks")
  return ok and Snacks or nil
end

--- vim.ui.select, drawn by snacks' picker when it is installed.
local function select(items, opts, on_choice)
  local Snacks = snacks()
  if Snacks and Snacks.picker and Snacks.picker.select then
    return Snacks.picker.select(items, opts, on_choice)
  end
  return vim.ui.select(items, opts, on_choice)
end

--- vim.ui.input, drawn by snacks' input box when it is installed.
local function input(opts, on_confirm)
  local Snacks = snacks()
  if Snacks and Snacks.input then
    return Snacks.input(opts, on_confirm)
  end
  return vim.ui.input(opts, on_confirm)
end

M._select, M._input = select, input

--- Reasoning levels each agent takes, lowest first.
M.thinking_levels = {
  pi = { "off", "minimal", "low", "medium", "high", "xhigh" },
  codex = { "minimal", "low", "medium", "high" },
  claude = { "low", "medium", "high", "xhigh", "max" },
}

--- Models an agent can list, for the model menu.
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

-- Models every Claude Code install knows by alias.
local known_models = { claude = { "sonnet", "opus", "haiku" } }

local DEFAULT_MODEL = "default (the agent's own)"
local TYPE_MODEL = "type a model…"

local function agent_mode()
  return require("agent_mode")
end

--- Replace settings, including clearing them to nil (vim.NIL), which
--- configure()'s merge cannot do.
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
  for _, key in ipairs({ "agent", "model", "thinking", "lua", "session", "input", "transcript" }) do
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
    local items, seen = {}, {}
    for _, model in ipairs(vim.list_extend({ DEFAULT_MODEL, TYPE_MODEL, config.model }, models)) do
      if not seen[model] then
        seen[model], items[#items + 1] = true, model
      end
    end
    select(items, { prompt = "Model for " .. agent_label(config.agent) }, function(choice)
      if choice == TYPE_MODEL then
        return input({ prompt = "Model: ", default = config.model or "" }, function(text)
          if text then
            set({ model = text ~= "" and text or vim.NIL })
          end
          done()
        end)
      end
      if choice == DEFAULT_MODEL then
        set({ model = vim.NIL })
      elseif choice then
        set({ model = choice })
      end
      done()
    end)
  end
  local list = model_lists[config.agent]
  if not list then
    return choose(known_models[config.agent] or {})
  end
  vim.system(list.argv, { text = true }, function(result)
    vim.schedule(function()
      choose(result.code == 0 and list.parse(result.stdout or "") or {})
    end)
  end)
end

--- The menu's entries: a label, the value now, and how to change it. Each
--- change calls `done()` when it is over, to come back to the menu.
local function entries()
  local config = agent_mode().config
  local levels = M.thinking_levels[config.agent]
  local list = {
    {
      label = "Agent",
      value = agent_label(config.agent),
      change = function(done)
        select(agent_mode().agent_names, { prompt = "Agent" }, function(choice)
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
      label = "Axo Session",
      value = config.axo.session,
      change = function(done)
        input({ prompt = "Axo Session id (self: this one): ", default = config.axo.session }, function(text)
          if text and text ~= "" then
            agent_mode().configure({ axo = { session = text } })
          end
          done()
        end)
      end,
    }
  else
    list[#list + 1] = { label = "Model", value = config.model or "default", change = pick_model }
    if levels then
      list[#list + 1] = {
        label = "Thinking",
        value = config.thinking or "default",
        change = function(done)
          select(vim.list_extend({ "default" }, levels), { prompt = "Thinking" }, function(choice)
            if choice then
              set({ thinking = choice == "default" and vim.NIL or choice })
            end
            done()
          end)
        end,
      }
    end
    local lua_choices = { { "ask first", "confirm" }, { "allow", "allow" }, { "off", false } }
    list[#list + 1] = {
      label = "Run Lua",
      value = config.lua == "allow" and "allow" or config.lua == "confirm" and "ask first" or "off",
      change = function(done)
        select(lua_choices, {
          prompt = "Let the agent run Lua in Neovim",
          format_item = function(item)
            return item[1]
          end,
        }, function(choice)
          if choice then
            set({ lua = choice[2] })
          end
          done()
        end)
      end,
    }
    list[#list + 1] = {
      label = "Conversation",
      value = config.session and "one per Neovim" or "none (requests run at once)",
      change = function(done)
        set({ session = not config.session })
        done()
      end,
    }
  end
  list[#list + 1] = {
    label = "Prompt",
    value = config.input == "cmdline" and "command line" or "below the cursor",
    change = function(done)
      set({ input = config.input == "cmdline" and "cursor" or "cmdline" })
      done()
    end,
  }
  list[#list + 1] = {
    label = "Transcript",
    value = config.transcript.enabled and ("on, " .. config.transcript.position) or "off (answers inline)",
    change = function(done)
      local choices = { { "off (answers inline)", false }, { "on, right", "right" }, { "on, left", "left" } }
      select(choices, {
        prompt = "Transcript split",
        format_item = function(item)
          return item[1]
        end,
      }, function(choice)
        if choice then
          local t = vim.deepcopy(config.transcript)
          t.enabled = choice[2] ~= false
          t.position = choice[2] or t.position
          set({ transcript = t })
        end
        done()
      end)
    end,
  }
  local session = agent_mode().session()
  list[#list + 1] = {
    label = "New conversation",
    value = session and ("now " .. session.id:sub(1, 12) .. "…") or "none yet",
    change = function(done)
      agent_mode().new_session()
      done()
    end,
  }
  list[#list + 1] = {
    label = "Copy as Lua",
    value = "for your config",
    change = function()
      local snippet = M.snippet()
      vim.fn.setreg("+", snippet)
      vim.fn.setreg('"', snippet)
      vim.notify("agent-mode: copied the settings as Lua")
    end,
  }
  return list
end

--- Open the settings menu. It comes back after each change until cancelled.
function M.open()
  local list = entries()
  local width = 0
  for _, entry in ipairs(list) do
    width = math.max(width, vim.fn.strdisplaywidth(entry.label))
  end
  select(list, {
    prompt = "agent-mode",
    kind = "agent_mode.config",
    format_item = function(entry)
      return entry.label .. string.rep(" ", width - vim.fn.strdisplaywidth(entry.label) + 2) .. entry.value
    end,
  }, function(entry)
    if entry then
      entry.change(vim.schedule_wrap(M.open))
    end
  end)
end

return M
