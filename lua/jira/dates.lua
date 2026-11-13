-- Date parsing, formatting and "is this epic on track" checks. Dates are plain YYYY-MM-DD strings.
local M = {}

local DAY = 24 * 60 * 60
local WEEKDAYS = { sun = 1, mon = 2, tue = 3, wed = 4, thu = 5, fri = 6, sat = 7 }
local MONTHS = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' }

-- Noon avoids DST edges when adding days.
local function to_time(y, m, d)
  return os.time({ year = y, month = m, day = d, hour = 12 })
end

function M.to_time(s)
  local y, m, d = (s or ''):match('^(%d%d%d%d)-(%d%d)-(%d%d)')
  if not y then
    return nil
  end
  return to_time(tonumber(y), tonumber(m), tonumber(d))
end

function M.fmt(t)
  return os.date('%Y-%m-%d', t)
end

function M.today(now)
  local d = os.date('*t', now or os.time())
  return to_time(d.year, d.month, d.day)
end

-- Days from today to s (negative = past).
function M.days_until(s, now)
  local t = M.to_time(s)
  if not t then
    return nil
  end
  return math.floor((t - M.today(now)) / DAY + 0.5)
end

-- "Nov 20", plus the year when it is not this year.
function M.short(s, now)
  local t = M.to_time(s)
  if not t then
    return '—'
  end
  local d, cur = os.date('*t', t), os.date('*t', now or os.time())
  local out = ('%s %02d'):format(MONTHS[d.month], d.day)
  if d.year ~= cur.year then
    out = out .. (" '%02d"):format(d.year % 100)
  end
  return out
end

-- Accepts: 2026-11-20, 11-20, 20, today, tomorrow, +3d, -1w, +2m, fri, next fri, eow, eom, none/clear/-
-- Returns 'YYYY-MM-DD', vim.NIL (clear), or nil + error.
function M.parse(input, base, now)
  local s = vim.trim((input or ''):lower())
  local today = M.today(now)
  local cur = os.date('*t', today)
  if s == '' then
    return nil, 'empty'
  end
  if s == 'none' or s == 'clear' or s == '-' or s == 'x' then
    return vim.NIL
  end
  if s == 'today' or s == 't' then
    return M.fmt(today)
  end
  if s == 'tomorrow' or s == 'tm' then
    return M.fmt(today + DAY)
  end
  local y, m, d = s:match('^(%d%d%d%d)-(%d%d?)-(%d%d?)$')
  if y then
    return M.validate(tonumber(y), tonumber(m), tonumber(d))
  end
  m, d = s:match('^(%d%d?)-(%d%d?)$')
  if m then
    local yy = cur.year
    -- A month already well past means next year
    if tonumber(m) < cur.month - 2 then
      yy = yy + 1
    end
    return M.validate(yy, tonumber(m), tonumber(d))
  end
  d = s:match('^(%d%d?)$')
  if d then
    -- Day of month: this month, or next month if that day has passed
    local mm = tonumber(d) < cur.day and cur.month + 1 or cur.month
    local t = os.date('*t', to_time(cur.year, mm, 1))
    return M.validate(t.year, t.month, tonumber(d))
  end
  -- Relative to the field's current value when the input starts with ++ / --, else to today.
  local sign2, n2, unit2 = s:match('^([+-])%1(%d+)([dwm]?)$')
  local origin = today
  local sign, n, unit = s:match('^([+-])(%d+)([dwm]?)$')
  if sign2 then
    sign, n, unit = sign2, n2, unit2
    origin = M.to_time(base) or today
  end
  if sign then
    n = tonumber(n) * (sign == '-' and -1 or 1)
    unit = unit == '' and 'd' or unit
    if unit == 'd' then
      return M.fmt(origin + n * DAY)
    elseif unit == 'w' then
      return M.fmt(origin + n * 7 * DAY)
    else
      local o = os.date('*t', origin)
      -- os.time normalises out-of-range months, and day 0 is the last day of the month before
      local last = os.date('*t', to_time(o.year, o.month + n + 1, 0)).day
      return M.fmt(to_time(o.year, o.month + n, math.min(o.day, last)))
    end
  end
  if s == 'eow' then
    -- this Friday (today if it is Friday)
    local diff = (WEEKDAYS.fri - cur.wday) % 7
    return M.fmt(today + diff * DAY)
  end
  if s == 'eom' then
    return M.fmt(to_time(cur.year, cur.month + 1, 0))
  end
  local nxt, wd = s:match('^(n?e?x?t?)%s*(%a%a%a)%a*$')
  if wd and WEEKDAYS[wd] then
    local diff = (WEEKDAYS[wd] - cur.wday) % 7
    if diff == 0 then
      diff = 7
    end
    if nxt == 'next' then
      diff = diff + 7
    end
    return M.fmt(today + diff * DAY)
  end
  return nil, 'could not read date "' .. input .. '"'
end

function M.validate(y, m, d)
  if m < 1 or m > 12 or d < 1 or d > 31 then
    return nil, 'invalid date'
  end
  local t = to_time(y, m, d)
  if tonumber(os.date('%d', t)) ~= d then
    return nil, 'invalid date'
  end
  return M.fmt(t)
end

-- Epoch seconds from a Jira timestamp like 2026-11-13T16:03:05.291+1100 (or ...Z for UTC, as sprints use).
function M.epoch(iso)
  local y, mo, d, h, mi, s, rest = (iso or ''):match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)[%.%d]*(.*)$')
  if not y then
    return nil
  end
  local sign, oh, om = rest:match('^([+-])(%d%d):?(%d%d)')
  if not sign then
    if not rest:match('^Z') then
      return nil
    end
    sign, oh, om = '+', '00', '00'
  end
  -- os.time reads the table as local time, so correct by the local offset, then by the stamp's own offset.
  local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s })
  local offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == '-' and -1 or 1)
  local now = os.time()
  local local_offset = os.difftime(now, os.time(os.date('!*t', now)))
  return t - offset + local_offset
end

-- Local YYYY-MM-DD of a timestamp (a sprint ending 13:00Z is already the next day at UTC+11).
function M.local_date(iso)
  local t = M.epoch(iso)
  return t and os.date('%Y-%m-%d', t) or nil
end

-- Whole days since a Jira timestamp.
function M.age_days(iso, now)
  local t = M.epoch(iso)
  return t and math.floor(((now or os.time()) - t) / DAY) or nil
end

-- Health of an item from its dates and status category ('new' | 'indeterminate' | 'done').
-- Returns { level = 'ok'|'soon'|'overdue'|'missing'|'late_start'|'done', text = '...' }
function M.health(start, due, cat, soon_days, now)
  if cat == 'done' then
    return { level = 'done', text = 'done' }
  end
  local left = M.days_until(due, now)
  if not left then
    return { level = 'missing', text = 'no due date' }
  end
  if left < 0 then
    return { level = 'overdue', text = ('%dd overdue'):format(-left) }
  end
  local until_start = M.days_until(start, now)
  if until_start and until_start < 0 and cat == 'new' then
    return { level = 'late_start', text = ('%dd left, not started'):format(left) }
  end
  if left <= (soon_days or 3) then
    return { level = 'soon', text = left == 0 and 'due today' or ('%dd left'):format(left) }
  end
  return { level = 'ok', text = ('%dd left'):format(left) }
end

-- Where today sits between start and due, 0..1 (nil when a date is missing).
function M.elapsed(start, due, now)
  local s, d = M.to_time(start), M.to_time(due)
  if not (s and d) or d <= s then
    return nil
  end
  return math.max(0, math.min(1, (M.today(now) - s) / (d - s)))
end

return M
