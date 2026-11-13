-- Shared in-memory state: short-lived query cache, known epics, and a change counter that tells views to reload.
local a = require('jira.async')

local M = {}

M.version = 0
M.epics = {} -- key -> epic item, fed by every epic list we load (used by the "move to epic" picker)

local cache = {}
local inflight = {}

-- Coroutine: reuse a result for ttl seconds. Callers asking for the same key at the same time share one request.
function M.memo(key, ttl, fn)
  local hit = cache[key]
  if hit and hit.version == M.version and os.time() - hit.at < ttl then
    return hit.value
  end
  if not inflight[key] then
    inflight[key] = a.singleflight()
  end
  local version = M.version
  return inflight[key](function()
    local value = fn()
    cache[key] = { value = value, at = os.time(), version = version }
    inflight[key] = nil
    return value
  end)
end

function M.remember_epics(list)
  for _, e in ipairs(list) do
    M.epics[e.key] = e
  end
end

-- Call after any write so other open views reload when shown.
function M.changed()
  M.version = M.version + 1
  cache = {}
end

return M
