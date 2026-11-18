-- The named jira:// buffers each view draws into.
local M = {}

-- Exact name match. vim.fn.bufnr() also takes part of a name, so jira://epic/P-12 could find P-123.
function M.find(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
  return -1
end

-- A scratch buffer called name. A buffer that already has the name but no view state (a session
-- restore runs `:edit jira://…`) is taken over: wiping it would close the windows showing it.
function M.scratch(name)
  local buf = M.find(name)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
    return buf
  end
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.bo[buf].modified = false
  return buf
end

return M
