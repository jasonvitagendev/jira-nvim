-- Last known lists on disk, so the sidebar can draw before the network answers.
-- Holds issue summaries (no tokens), in a 0600 file inside the 0700 data dir.
local config = require('jira.config')

local M = {}

local DATA_DIR = vim.fn.stdpath('data') .. '/jira-nvim'
-- only what the lists draw; descriptions and raw payloads stay out
local KEEP = { 'id', 'key', 'project', 'summary', 'status', 'cat', 'assignee', 'assignee_id', 'priority', 'type', 'due', 'start', 'points', 'updated', 'labels', 'parent_key', 'parent_summary', 'progress' }

local mem -- decoded file, per site
local mem_site

local function path()
  local site = require('jira.api').site_cached()
  return site and site.id and (DATA_DIR .. '/views-' .. site.id:gsub('[^%w%-]', '') .. '.json') or nil, site and site.id
end

local function load()
  local p, site = path()
  if not p then
    return nil
  end
  if mem and mem_site == site then
    return mem
  end
  mem, mem_site = { views = {} }, site
  local f = io.open(p, 'r')
  if f then
    local v = require('jira.http').decode(f:read('*a'))
    f:close()
    if type(v) == 'table' and type(v.views) == 'table' then
      mem = v
    end
  end
  return mem
end

local function save()
  local p = path()
  if not (p and mem) then
    return
  end
  vim.fn.mkdir(DATA_DIR, 'p', 448)
  -- write then rename, so a crash never leaves half a file
  local tmp = p .. '.tmp'
  local fd = vim.uv.fs_open(tmp, 'w', 384)
  if not fd then
    return
  end
  vim.uv.fs_write(fd, vim.json.encode(mem))
  vim.uv.fs_close(fd)
  vim.uv.fs_chmod(tmp, 384)
  vim.uv.fs_rename(tmp, p)
end

function M.strip(items)
  local out = {}
  for i, it in ipairs(items) do
    local s = {}
    for _, k in ipairs(KEEP) do
      s[k] = it[k]
    end
    out[i] = s
  end
  return out
end

-- { items, at } or nil
function M.get(id)
  if not config.offline_cache then
    return nil
  end
  local c = load()
  local v = c and c.views[id]
  return v and type(v.items) == 'table' and v or nil
end

function M.put(id, items)
  if not config.offline_cache or not load() then
    return
  end
  mem.views[id] = { at = os.time(), items = M.strip(items) }
  save()
end

function M.me()
  local c = config.offline_cache and load()
  return c and c.me
end

function M.set_me(id)
  if config.offline_cache and load() and mem.me ~= id then
    mem.me = id
    save()
  end
end

-- :Jira logout and site changes
function M.clear()
  mem = nil
  for _, f in ipairs(vim.fn.glob(DATA_DIR .. '/views-*.json', false, true)) do
    os.remove(f)
  end
end

return M
