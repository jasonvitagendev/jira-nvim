-- Date and progress checks between a parent (epic / initiative) and its children.
local config = require('jira.config')
local dates = require('jira.dates')

local M = {}

-- Flags for one child row: { late = true, stale = days, blocked = { keys } }
function M.row(parent, it, now)
  local f = {}
  if it.cat == 'done' then
    return f
  end
  if parent and parent.due and it.due and it.due > parent.due then
    f.late = true
  end
  if it.cat == 'indeterminate' then
    local days = dates.age_days(it.updated, now)
    if days and days >= config.stale_days then
      f.stale = days
    end
  end
  if it.blocked_by and #it.blocked_by > 0 then
    f.blocked = it.blocked_by
  end
  return f
end

-- Health for an epic row in a list: date health, plus "all tasks done but still open".
function M.health(epic, now)
  local h = dates.health(epic.start, epic.due, epic.cat, config.due_soon_days, now)
  local p = epic.progress
  if epic.cat ~= 'done' and p and p.total > 0 and p.done == p.total then
    return { level = 'soon', text = 'all tasks done, still open' }
  end
  return h
end

function M.needs_attention(epic, now)
  local level = M.health(epic, now).level
  return level == 'overdue' or level == 'missing' or level == 'late_start' or (level == 'soon' and epic.progress and epic.progress.total > 0 and epic.progress.done == epic.progress.total)
end

-- Findings for the header of a parent's grid.
-- Returns list of { level = 'warn' | 'info', text = '...' } and a suggested due date (or nil).
function M.parent(parent, children, now)
  local out, suggest = {}, nil
  if not parent or parent.cat == 'done' then
    return out, nil
  end
  local open, late, stale, blocked = 0, {}, {}, {}
  local latest, latest_key, earliest
  for _, c in ipairs(children) do
    if c.cat ~= 'done' then
      open = open + 1
      local f = M.row(parent, c, now)
      if f.late then
        late[#late + 1] = c.key
      end
      if f.stale then
        stale[#stale + 1] = c.key
      end
      if f.blocked then
        blocked[#blocked + 1] = c.key
      end
      if c.due and (not latest or c.due > latest) then
        latest, latest_key = c.due, c.key
      end
    end
    if c.start and c.cat ~= 'new' and (not earliest or c.start < earliest) then
      earliest = c.start
    end
  end
  if #children > 0 and open == 0 then
    out[#out + 1] = { level = 'warn', text = ('All %d are done but this is still %s. Close it with s.'):format(#children, parent.status) }
  end
  if latest and (not parent.due or latest > parent.due) then
    suggest = latest
    out[#out + 1] = {
      level = 'warn',
      text = parent.due and ('%d due after the %s due date. Latest is %s (%s).'):format(#late, parent.type:lower(), dates.short(latest, now), latest_key)
        or ('No due date. Latest child is due %s (%s).'):format(dates.short(latest, now), latest_key),
      apply_due = latest,
    }
  end
  local started = false
  for _, c in ipairs(children) do
    started = started or c.cat ~= 'new'
  end
  if not parent.start and started then
    out[#out + 1] = { level = 'warn', text = 'Work has started but there is no start date. Set it with ds.' }
  end
  if #stale > 0 then
    out[#out + 1] = { level = 'info', text = ('%d in progress with no update for %d+ days: %s'):format(#stale, config.stale_days, table.concat(stale, ', ', 1, math.min(4, #stale)) .. (#stale > 4 and ' …' or '')) }
  end
  if #blocked > 0 then
    out[#out + 1] = { level = 'info', text = ('%d blocked: %s'):format(#blocked, table.concat(blocked, ', ', 1, math.min(4, #blocked)) .. (#blocked > 4 and ' …' or '')) }
  end
  return out, suggest
end

return M
