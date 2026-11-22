-- The tools nvim-mcp gives agents, as MCP tool definitions. Shared by
-- bin/nvim-mcp (which lists them even before it finds a Neovim) and
-- Neovim (which carries them out, in agent_mode.tools).
--
-- Everything an agent does in Neovim is about a context: a snapshot of a
-- buffer, cursor and selection. A request from the user (,,a) is a context;
-- get_context makes one for wherever the user is. Edits are checked against
-- the context's snapshot, so they land on the right lines even if the user
-- kept typing, and are refused if the lines they replace changed.

local context_id = {
  type = "string",
  description = "The context to act on: a request's id (from the prompt or wait_for_request), or one from get_context.",
}

return {
  {
    name = "wait_for_request",
    description = "Wait for the user's next request from Neovim (they ask at their cursor). Returns the request: its"
      .. " context_id, the instruction, and the buffer around the cursor. Handle it with the other tools, then call"
      .. " wait_for_request again to keep listening; that also finishes the request before if you did not. Returns"
      .. " 'no request yet' after timeout_seconds, after which you call it again.",
    inputSchema = {
      type = "object",
      properties = {
        timeout_seconds = { type = "number", description = "How long to wait (default 300)." },
      },
    },
  },
  {
    name = "get_context",
    description = "Where the user is in Neovim: the file, cursor, selection and the lines around them, with line"
      .. " numbers. Given a context_id, that context as it was when it was taken. Returns a context_id for the"
      .. " other tools.",
    inputSchema = {
      type = "object",
      properties = { context_id = context_id },
    },
  },
  {
    name = "edit",
    description = "Replace lines of the context's buffer: each edit replaces start_line..end_line (1-based,"
      .. " inclusive, as numbered in the context) with text (lines separated by \\n; empty deletes them;"
      .. " end_line = start_line - 1 inserts before start_line). Give the complete new lines with their"
      .. " indentation. Edits must not overlap. Applied as one undo step, only if the lines are still what the"
      .. " context showed. Use this, never your file tools, for the user's buffer: it may have unsaved changes.",
    inputSchema = {
      type = "object",
      properties = {
        context_id = context_id,
        edits = {
          type = "array",
          items = {
            type = "object",
            properties = {
              start_line = { type = "integer" },
              end_line = { type = "integer" },
              text = { type = "string" },
            },
            required = { "start_line", "end_line", "text" },
          },
        },
      },
      required = { "context_id", "edits" },
    },
  },
  {
    name = "lsp_rename",
    description = "Rename the symbol under the context's cursor across the project with the language server."
      .. " Prefer it for renames when the context says LSP rename is available.",
    inputSchema = {
      type = "object",
      properties = { context_id = context_id, new_name = { type = "string" } },
      required = { "context_id", "new_name" },
    },
  },
  {
    name = "code_action",
    description = "Run one of the language server code actions listed in the context, by its id.",
    inputSchema = {
      type = "object",
      properties = { context_id = context_id, id = { type = "integer" } },
      required = { "context_id", "id" },
    },
  },
  {
    name = "show_answer",
    description = "Show the user an answer inline, below the line they asked from, rendered as Markdown (inline"
      .. " code, short lists, fenced code blocks with a language). Answer directly, without a preamble.",
    inputSchema = {
      type = "object",
      properties = { context_id = context_id, text = { type = "string" } },
      required = { "context_id", "text" },
    },
  },
  {
    name = "run_lua",
    description = "Run Lua in the user's Neovim (0.12, LuaJIT) and get what it returned, printed, or raised. For"
      .. " what lives in Neovim: language servers (definitions, references, call hierarchy, diagnostics),"
      .. " unsaved buffers, windows, plugins, and showing things (a scratch buffer in a tab, the quickfix list)."
      .. " The code is a function body; the global ctx has bufnr, win, row, col, file, filetype, selection and"
      .. " instruction of the context; describe() and describe(topic) list what this Neovim has; helpers in am:"
      .. " am.scratch(lines, {open=, filetype=, name=}), am.lsp(method, params, callback),"
      .. " am.position_params(), am.lines(path_or_bufnr). For asynchronous work call local done = ctx.async()"
      .. " and done(value) later; never block with vim.wait. The user may be asked to allow it first.",
    inputSchema = {
      type = "object",
      properties = { context_id = context_id, code = { type = "string" } },
      required = { "code" },
    },
  },
  {
    name = "set_status",
    description = "Say what you are doing, in a few words; shown next to the user's line while you work.",
    inputSchema = {
      type = "object",
      properties = { context_id = context_id, text = { type = "string" } },
      required = { "context_id", "text" },
    },
  },
  {
    name = "finish",
    description = "Finish the request: its spinner stops. Optionally with a short summary of what you did.",
    inputSchema = {
      type = "object",
      properties = { context_id = context_id, summary = { type = "string" } },
      required = { "context_id" },
    },
  },
}
