-- What the agent's Lua can find out about this Neovim, in the spirit of
-- describing a namespace before calling into it: `describe()` gives an
-- overview and the topics, `describe(topic)` the details of one.

local M = {}

local function sorted_keys(t)
  local keys = vim.tbl_keys(t)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function lazy_plugins()
  local ok, lazy = pcall(require, "lazy")
  if not ok or type(lazy.plugins) ~= "function" then
    return nil
  end
  local plugins = {}
  for _, plugin in ipairs(lazy.plugins()) do
    plugins[#plugins + 1] = { name = plugin.name, loaded = plugin._ and plugin._.loaded ~= nil or false, dir = plugin.dir }
  end
  table.sort(plugins, function(a, b)
    return a.name < b.name
  end)
  return plugins
end

--- The language servers attached to `bufnr`, with the requests they answer.
local function lsp_clients(bufnr)
  local clients = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    local methods = {}
    for key, value in pairs(client.server_capabilities or {}) do
      if value and value ~= vim.NIL then
        methods[#methods + 1] = key
      end
    end
    table.sort(methods)
    clients[#clients + 1] = { name = client.name, id = client.id, root_dir = client.root_dir, capabilities = methods }
  end
  return clients
end

--- The functions and values a module exports, with each function's arity.
local function module_shape(name)
  local ok, mod = pcall(require, name)
  if not ok then
    return nil, "no module " .. name .. ": " .. tostring(mod):match("^[^\n]*")
  end
  if type(mod) ~= "table" then
    return { [name] = type(mod) }
  end
  local shape = {}
  for _, key in ipairs(sorted_keys(mod)) do
    local value = mod[key]
    if type(value) == "function" then
      local info = debug.getinfo(value, "u")
      local params = {}
      for i = 1, info.nparams or 0 do
        params[i] = debug.getlocal(value, i) or ("arg" .. i)
      end
      if info.isvararg then
        params[#params + 1] = "..."
      end
      shape[tostring(key)] = "function(" .. table.concat(params, ", ") .. ")"
    else
      shape[tostring(key)] = type(value)
    end
  end
  return shape
end

local TOPICS = {
  "lsp",
  "plugins",
  "commands",
  "keymaps",
  "treesitter",
  "am",
  "<module name> (e.g. 'telescope.builtin', 'vim.lsp.buf')",
}

--- A short overview for the prompt, so the agent need not spend a step on it.
function M.summary(bufnr)
  local version = vim.version()
  local parts = { string.format("Neovim %d.%d.%d", version.major, version.minor, version.patch) }
  local notable = {
    { "callHierarchyProvider", "call hierarchy" },
    { "referencesProvider", "references" },
    { "definitionProvider", "definition" },
    { "typeHierarchyProvider", "type hierarchy" },
  }
  local servers = vim.tbl_map(function(client)
    local caps = client.server_capabilities or {}
    local has = {}
    for _, cap in ipairs(notable) do
      has[#has + 1] = (caps[cap[1]] and "" or "no ") .. cap[2]
    end
    return client.name .. " (" .. table.concat(has, ", ") .. ")"
  end, vim.lsp.get_clients({ bufnr = bufnr }))
  parts[#parts + 1] = "language servers on this buffer: " .. (#servers > 0 and table.concat(servers, ", ") or "none")
  local plugins = lazy_plugins()
  if plugins then
    parts[#parts + 1] = "plugins (lazy.nvim): " .. table.concat(vim.tbl_map(function(p)
      return p.name
    end, plugins), ", ")
  end
  return table.concat(parts, "; ")
end

--- What `describe(topic)` answers inside the agent's Lua.
--- @param ctx table
--- @param helpers table the `am` helpers, to describe them
function M.describe(ctx, helpers, topic)
  if topic == nil then
    return {
      neovim = tostring(vim.version()),
      cwd = vim.fn.getcwd(),
      buffer = { file = ctx.file, filetype = ctx.filetype },
      language_servers = vim.tbl_map(function(c)
        return c.name
      end, lsp_clients(ctx.bufnr)),
      plugins = lazy_plugins() and vim.tbl_map(function(p)
        return p.name
      end, lazy_plugins()) or nil,
      helpers = M.describe(ctx, helpers, "am"),
      topics = TOPICS,
    }
  end
  if topic == "lsp" then
    return lsp_clients(ctx.bufnr)
  end
  if topic == "plugins" then
    return lazy_plugins() or vim.tbl_filter(function(name)
      return not name:match("^vim[%.%_]") and not name:find("%.")
    end, sorted_keys(package.loaded))
  end
  if topic == "commands" then
    local commands = {}
    for name, def in pairs(vim.api.nvim_get_commands({})) do
      commands[name] = def.definition ~= "" and def.definition or "(lua)"
    end
    for name, def in pairs(vim.api.nvim_buf_get_commands(ctx.bufnr, {})) do
      commands[name] = def.definition ~= "" and def.definition or "(lua)"
    end
    return commands
  end
  if topic == "keymaps" then
    local maps = {}
    local function add(list)
      for _, map in ipairs(list) do
        maps[#maps + 1] = string.format("%s %s  %s", map.mode, map.lhs, map.desc or map.rhs or "(lua)")
      end
    end
    add(vim.api.nvim_get_keymap("n"))
    add(vim.api.nvim_buf_get_keymap(ctx.bufnr, "n"))
    return maps
  end
  if topic == "treesitter" then
    local lang = vim.treesitter.language.get_lang(ctx.filetype or "") or ctx.filetype
    local ok = pcall(vim.treesitter.get_parser, ctx.bufnr, lang)
    return { language = lang, parser = ok and "available" or "not available" }
  end
  if topic == "am" then
    return helpers.docs
  end
  local shape, err = module_shape(topic)
  if not shape then
    error(err, 0)
  end
  return shape
end

return M
