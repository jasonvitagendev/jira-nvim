-- Small view settings that outlive a session (which grids are wide, column order). No issue data, no secrets.
local M = {}

local DIR = vim.fn.stdpath('data') .. '/jira-nvim'
M.path = DIR .. '/prefs.json'

local mem

local function load()
  if mem then
    return mem
  end
  mem = { wide = {}, order = {} }
  local f = io.open(M.path, 'r')
  if f then
    local ok, v = pcall(vim.json.decode, f:read('*a'))
    f:close()
    if ok and type(v) == 'table' then
      mem.wide = type(v.wide) == 'table' and v.wide or {}
      mem.order = type(v.order) == 'table' and v.order or {}
    end
  end
  return mem
end

local function save()
  vim.fn.mkdir(DIR, 'p', 448)
  -- write then rename, so a crash never leaves half a file
  local tmp = M.path .. '.tmp'
  local fd = vim.uv.fs_open(tmp, 'w', 384)
  if not fd then
    return
  end
  vim.uv.fs_write(fd, vim.json.encode(mem))
  vim.uv.fs_close(fd)
  vim.uv.fs_chmod(tmp, 384)
  vim.uv.fs_rename(tmp, M.path)
end

-- true / false when set for this grid, nil to use the config default
function M.wide(id)
  return load().wide[id]
end

-- on = nil forgets it, so the grid follows the config again
function M.set_wide(id, on)
  if load().wide[id] ~= on then
    mem.wide[id] = on
    save()
  end
end

-- column names for 'tasks' | 'epics', nil when never moved (or the file was edited into something else)
function M.order(kind)
  local list = load().order[kind]
  if type(list) ~= 'table' or not vim.islist(list) then
    return nil
  end
  for _, n in ipairs(list) do
    if type(n) ~= 'string' then
      return nil
    end
  end
  return list
end

-- list = nil forgets it, so the grid follows config.columns again
function M.set_order(kind, list)
  if not vim.deep_equal(load().order[kind], list) then
    mem.order[kind] = list
    save()
  end
end

-- for tests
function M._reset()
  mem = nil
end

return M
