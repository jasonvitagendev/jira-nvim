-- "◐ PROJ-49 In Progress" for the issue in the current git branch. Never blocks and never raises:
-- the branch is read in the background, and the status is fetched at most once per statusline_ttl.
local config = require('jira.config')
local git = require('jira.git')

local M = {}

local issues = {} -- key -> { at, status, cat, loading, version }

local function redraw()
  pcall(vim.cmd.redrawstatus)
end

local function fetch(key, e)
  e.loading = true
  local store = require('jira.ui.store')
  require('jira.async').run(function()
    return require('jira.api').status_of(key)
  end, function(err, s)
    e.loading, e.at, e.version = false, os.time(), store.version
    -- logged out or offline: keep the key only, try again after the ttl
    if not err and s then
      e.status, e.cat = s.status, s.cat
    end
    redraw()
  end)
end

-- { key, status, cat } or nil, for custom components
function M.data()
  local key = git.cached_key(git.dir(), redraw)
  if not key then
    return nil
  end
  local e = issues[key]
  if not e then
    e = { at = 0 }
    issues[key] = e
  end
  local stale = os.time() - e.at >= (config.statusline_ttl or 120) or e.version ~= require('jira.ui.store').version
  if stale and not e.loading then
    fetch(key, e)
  end
  return { key = key, status = e.status, cat = e.cat }
end

function M.get()
  local ok, out = pcall(function()
    local d = M.data()
    if not d then
      return ''
    end
    if not d.status then
      return d.key
    end
    return require('jira.ui.render').status_icon(d.cat) .. ' ' .. d.key .. ' ' .. d.status
  end)
  return ok and out or ''
end

return M
