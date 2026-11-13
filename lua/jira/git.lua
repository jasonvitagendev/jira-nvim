-- The issue key in the current git branch, e.g. feature/PROJ-12-fix-login -> PROJ-12.
local M = {}

-- Upper case only, so branch names like release-2024 are never read as a key.
local KEY = '%f[%w](%u[%u%d_]*%-%d+)'
local TTL = 5

local cache = {} -- dir -> { key = ..., at = epoch, loading = bool }

function M.key_from_branch(branch)
  return branch and branch:match(KEY) or nil
end

-- Directory of the current file, or the cwd for jira:// and other non-file buffers.
function M.dir(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  if name ~= '' and not name:match('^%a[%w+.-]*://') then
    local d = vim.fs.dirname(name)
    if d and vim.uv.fs_stat(d) then
      return d
    end
  end
  return vim.uv.cwd()
end

local function cmd(dir)
  return { 'git', '-C', dir, 'symbolic-ref', '--short', '-q', 'HEAD' }
end

-- Blocking (up to 1s): the key in the branch of dir, or nil.
function M.key(dir)
  dir = dir or M.dir()
  local ok, res = pcall(function()
    return vim.system(cmd(dir), { text = true }):wait(1000)
  end)
  local key = ok and res.code == 0 and M.key_from_branch(vim.trim(res.stdout or '')) or nil
  cache[dir] = { key = key, at = os.time() }
  return key
end

-- Never blocks: the last known key for dir, refreshed in the background when older than a few seconds.
-- on_change() runs when the key changes.
function M.cached_key(dir, on_change)
  dir = dir or M.dir()
  local c = cache[dir]
  if not c or (os.time() - c.at >= TTL and not c.loading) then
    c = c or { at = 0 }
    cache[dir] = c
    c.loading = true
    local ok = pcall(vim.system, cmd(dir), { text = true }, function(res)
      local key = res.code == 0 and M.key_from_branch(vim.trim(res.stdout or '')) or nil
      local changed = key ~= c.key
      c.key, c.at, c.loading = key, os.time(), false
      if changed and on_change then
        vim.schedule(on_change)
      end
    end)
    if not ok then
      c.at, c.loading = os.time(), false
    end
  end
  return c.key
end

return M
