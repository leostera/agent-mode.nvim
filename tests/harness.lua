-- A tiny test harness: `test(name, fn)` registers a test, `run()` runs them
-- all and exits nonzero on failure. Run with `nvim --headless -l <file>`.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
for _, dep in ipairs({ vim.env.AGENT_MODE_SNACKS }) do
  if dep then
    vim.opt.rtp:append(dep)
  end
end
vim.cmd("runtime plugin/agent_mode.lua")

local H = { root = root }

vim.notify = function(message)
  io.stdout:write("     " .. message .. "\n")
end
local tests = {}

function H.test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

function H.eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(
      string.format("%s\nexpected: %s\nactual:   %s", message or "not equal", vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

function H.truthy(value, message)
  if not value then
    error(message or "expected a truthy value", 2)
  end
end

function H.contains(haystack, needle, message)
  if not (haystack or ""):find(needle, 1, true) then
    error(string.format("%s\n%q not found in:\n%s", message or "missing text", needle, haystack), 2)
  end
end

--- A scratch buffer holding `lines`, made current.
function H.buffer(lines, filetype)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  vim.api.nvim_set_current_buf(buf)
  return buf
end

--- Type each group of keys as a user would, letting Neovim run what it
--- scheduled in between. Each group ends in normal mode (feedkeys "x").
function H.type(...)
  for _, keys in ipairs({ ... }) do
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
    vim.wait(20)
  end
end

function H.lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, true)
end

--- Run agent_mode.run and wait for it to finish. Returns the error, if any.
function H.run_agent(instruction, opts, timeout_ms)
  local done, result = false, nil
  opts = vim.tbl_extend("force", opts or {}, {
    on_done = function(err)
      done, result = true, err
    end,
  })
  require("agent_mode").run(instruction, opts)
  H.truthy(vim.wait(timeout_ms or 10000, function()
    return done
  end, 20), "agent request did not finish in time")
  return result
end

function H.run()
  local failed = 0
  for _, t in ipairs(tests) do
    local ok, err = xpcall(t.fn, debug.traceback)
    if ok then
      io.stdout:write("ok   " .. t.name .. "\n")
    else
      failed = failed + 1
      io.stdout:write("FAIL " .. t.name .. "\n" .. err .. "\n")
    end
  end
  io.stdout:write(string.format("\n%d passed, %d failed\n", #tests - failed, failed))
  os.exit(failed == 0 and 0 or 1)
end

return H
