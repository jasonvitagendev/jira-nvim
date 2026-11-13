-- macOS Keychain storage via `security`. Values are base64'd and chunked because `security -i` caps a line near 4k.
local M = {}

local SERVICE = 'jira.nvim'
local CHUNK = 3000

function M.available()
  return vim.fn.has('mac') == 1 and vim.fn.executable('security') == 1
end

local function delete(account)
  return vim.system({ 'security', 'delete-generic-password', '-s', SERVICE, '-a', account }):wait().code == 0
end

function M.get(name)
  local parts, i = {}, 0
  while true do
    local r = vim.system({ 'security', 'find-generic-password', '-s', SERVICE, '-a', name .. '.' .. i, '-w' }, { text = true }):wait()
    if r.code ~= 0 then
      break
    end
    parts[#parts + 1] = vim.trim(r.stdout)
    i = i + 1
  end
  if #parts == 0 then
    return nil
  end
  local ok, value = pcall(vim.base64.decode, table.concat(parts))
  return ok and value or nil
end

function M.clear(name, from)
  local i = from or 0
  while delete(name .. '.' .. i) do
    i = i + 1
  end
end

-- Secret goes through stdin, never argv.
function M.set(name, value)
  local b64, i = vim.base64.encode(value), 0
  for pos = 1, #b64, CHUNK do
    local cmd = ('add-generic-password -U -s "%s" -a "%s.%d" -w "%s"\n'):format(SERVICE, name, i, b64:sub(pos, pos + CHUNK - 1))
    if vim.system({ 'security', '-i' }, { stdin = cmd, text = true }):wait().code ~= 0 then
      error('keychain write failed', 0)
    end
    i = i + 1
  end
  M.clear(name, i)
  if M.get(name) ~= value then
    error('keychain read-back mismatch', 0)
  end
end

return M
