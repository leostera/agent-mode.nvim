-- Applying the agent's line edits to a buffer.

local M = {}

--- Check that `edits` fit in a buffer of `line_count` lines and do not
--- overlap, and return them sorted bottom-up so applying one never shifts the
--- line numbers of the next.
--- @return table[]|nil sorted
--- @return string|nil err
function M.plan(edits, line_count)
  local sorted = vim.deepcopy(edits)
  table.sort(sorted, function(a, b)
    if a.start_line ~= b.start_line then
      return a.start_line > b.start_line
    end
    return a.end_line > b.end_line
  end)

  local floor = math.huge -- first line already claimed by a later edit
  for _, edit in ipairs(sorted) do
    if edit.start_line > line_count + 1 or edit.end_line > line_count then
      return nil,
        string.format(
          "edit of lines %d-%d is outside the buffer (%d lines)",
          edit.start_line,
          edit.end_line,
          line_count
        )
    end
    if edit.end_line >= floor then
      return nil, string.format("edits overlap at line %d", edit.end_line)
    end
    floor = edit.start_line
  end
  return sorted
end

--- Move `edits`, written against `snapshot_lines`, onto the buffer as it is
--- now. Lines may have moved since the snapshot (other requests, the user);
--- `shift` is how far the request's own line moved. Each edit is shifted by
--- that much and kept only if the lines it replaces are still exactly what
--- the agent saw. Returns the shifted edits, or an error naming the first
--- edit whose lines changed.
--- @return table[]|nil
--- @return string|nil err
function M.rebase(edits, snapshot_lines, bufnr, shift)
  local rebased = {}
  for _, edit in ipairs(edits) do
    local seen = vim.list_slice(snapshot_lines, edit.start_line, edit.end_line)
    local start_line = edit.start_line + shift
    local end_line = edit.end_line + shift
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local now = {}
    if start_line >= 1 and end_line <= line_count then
      now = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    end
    if start_line < 1 or end_line > line_count or not vim.deep_equal(seen, now) then
      return nil,
        string.format(
          "lines %d-%d changed while the agent was working; its edit was not applied",
          edit.start_line,
          edit.end_line
        )
    end
    rebased[#rebased + 1] = { start_line = start_line, end_line = end_line, text = edit.text }
  end
  return rebased
end

--- The lines `text` stands for. "" deletes; one trailing newline is
--- dropped because models often end the last line with one.
function M.lines_of(text)
  if text == "" then
    return {}
  end
  return vim.split(text:gsub("\n$", ""), "\n", { plain = true })
end

--- Apply `edits` (already validated by the protocol) to `bufnr` as a single
--- undo step.
--- @return string|nil err
function M.apply(bufnr, edits)
  local sorted, err = M.plan(edits, vim.api.nvim_buf_line_count(bufnr))
  if not sorted then
    return err
  end
  for i, edit in ipairs(sorted) do
    local replacement = M.lines_of(edit.text)
    if i > 1 then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent! undojoin")
      end)
    end
    vim.api.nvim_buf_set_lines(bufnr, edit.start_line - 1, edit.end_line, true, replacement)
  end
  return nil
end

return M
