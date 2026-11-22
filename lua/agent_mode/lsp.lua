-- The language server side of agent-mode: what the servers attached to the
-- buffer can do at the cursor, and running the rename or code action the
-- agent picked.

local M = {}

local function clients_supporting(bufnr, method)
  return vim.lsp.get_clients({ bufnr = bufnr, method = method })
end

--- Position params for `position`, encoded for `client`.
local function position_params(client, bufnr, position)
  local line = vim.api.nvim_buf_get_lines(bufnr, position.row - 1, position.row, true)[1]
  local character = vim.str_utfindex(line, client.offset_encoding, position.col, false)
  return {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = position.row - 1, character = character },
  }
end

function M.can_rename(bufnr)
  return #clients_supporting(bufnr, "textDocument/rename") > 0
end

local function diagnostics_at(bufnr, row)
  local diagnostics = vim.diagnostic.get(bufnr, { lnum = row - 1 })
  local ok, lsp_diagnostics = pcall(vim.lsp.diagnostic.from, diagnostics)
  return ok and lsp_diagnostics or {}
end

--- Ask every attached server for code actions at `position` and call
--- `on_done(actions)` once all have answered or `timeout_ms` has passed.
--- Each action is { id = n, title = string, client_id = n, action = table }.
function M.code_actions(bufnr, position, timeout_ms, on_done)
  local clients = clients_supporting(bufnr, "textDocument/codeAction")
  if #clients == 0 then
    return on_done({})
  end

  local results = {}
  local pending = #clients
  local finished = false

  local function finish()
    if finished then
      return
    end
    finished = true
    local actions = {}
    for _, client in ipairs(clients) do
      for _, action in ipairs(results[client.id] or {}) do
        actions[#actions + 1] = {
          id = #actions + 1,
          title = action.title,
          kind = action.kind,
          client_id = client.id,
          action = action,
        }
      end
    end
    on_done(actions)
  end

  for _, client in ipairs(clients) do
    local params = position_params(client, bufnr, position)
    params.range = { start = params.position, ["end"] = params.position }
    params.position = nil
    params.context = { diagnostics = diagnostics_at(bufnr, position.row), triggerKind = 1 }
    client:request("textDocument/codeAction", params, function(err, result)
      if not err and type(result) == "table" then
        results[client.id] = result
      end
      pending = pending - 1
      if pending == 0 then
        vim.schedule(finish)
      end
    end, bufnr)
  end

  vim.defer_fn(finish, timeout_ms)
end

--- Rename the symbol at `position` to `new_name`. Calls `on_done(err)`.
function M.rename(bufnr, position, new_name, on_done)
  local client = clients_supporting(bufnr, "textDocument/rename")[1]
  if not client then
    return on_done("no language server attached to this buffer can rename")
  end
  local params = position_params(client, bufnr, position)
  params.newName = new_name
  client:request("textDocument/rename", params, function(err, result)
    if err then
      return on_done("rename failed: " .. (err.message or vim.inspect(err)))
    end
    if not result then
      return on_done("the language server found nothing to rename here")
    end
    vim.lsp.util.apply_workspace_edit(result, client.offset_encoding)
    on_done(nil)
  end, bufnr)
end

local function run_resolved(client, bufnr, action, on_done)
  if action.edit then
    vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
  end
  local command = type(action.command) == "table" and action.command
    or (type(action.command) == "string" and action)
    or nil
  if command then
    client:exec_cmd(command, { bufnr = bufnr })
  end
  on_done(nil)
end

--- Run a code action gathered by `M.code_actions`. Calls `on_done(err)`.
function M.run_code_action(bufnr, entry, on_done)
  local client = vim.lsp.get_client_by_id(entry.client_id)
  if not client then
    return on_done("the language server for this code action has stopped")
  end
  local action = entry.action
  if action.edit or not client:supports_method("codeAction/resolve") then
    return run_resolved(client, bufnr, action, on_done)
  end
  client:request("codeAction/resolve", action, function(err, resolved)
    if err then
      return on_done("resolving the code action failed: " .. (err.message or vim.inspect(err)))
    end
    run_resolved(client, bufnr, resolved or action, on_done)
  end, bufnr)
end

return M
