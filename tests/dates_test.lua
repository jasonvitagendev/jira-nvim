-- Run: nvim -l tests/dates_test.lua
vim.opt.rtp:prepend('.')
local dates = require('jira.dates')

-- Fixed "now": Friday 2026-11-13 noon
local now = os.time({ year = 2026, month = 11, day = 13, hour = 12 })
local fails = 0

local function eq(input, want, base)
  local got = dates.parse(input, base, now)
  if got == vim.NIL then
    got = 'NIL'
  end
  if got ~= want then
    fails = fails + 1
    print(('FAIL parse(%q) = %s, want %s'):format(input, tostring(got), want))
  end
end

eq('2026-11-20', '2026-11-20')
eq('2026-2-3', '2026-02-03')
eq('11-20', '2026-11-20')
eq('01-15', '2027-01-15') -- far-past month rolls to next year
eq('20', '2026-11-20')
eq('5', '2026-12-05') -- day already passed this month
eq('today', '2026-11-13')
eq('tomorrow', '2026-11-14')
eq('+3d', '2026-11-16')
eq('+3', '2026-11-16')
eq('-1w', '2026-11-06')
eq('+1m', '2026-12-13')
eq('+3m', '2027-02-13')
eq('++1w', '2026-11-27', '2026-11-20')
eq('--2d', '2026-11-18', '2026-11-20')
eq('fri', '2026-11-20') -- today is Friday, so next one
eq('mon', '2026-11-16')
eq('monday', '2026-11-16')
eq('next mon', '2026-11-23')
eq('eow', '2026-11-13')
eq('eom', '2026-11-30')
eq('none', 'NIL')

local function check(name, got, want)
  if got ~= want then
    fails = fails + 1
    print(('FAIL %s = %s, want %s'):format(name, tostring(got), tostring(want)))
  end
end

-- month-end clamp: Jan 31 + 1m = Feb 28
check('+1m clamp', dates.parse('++1m', '2026-01-31', now), '2026-02-28')
check('days_until', dates.days_until('2026-11-20', now), 7)
check('health overdue', dates.health('2026-11-01', '2026-11-10', 'indeterminate', 3, now).level, 'overdue')
check('health soon', dates.health(nil, '2026-11-15', 'indeterminate', 3, now).level, 'soon')
check('health missing', dates.health('2026-11-01', nil, 'indeterminate', 3, now).level, 'missing')
check('health late start', dates.health('2026-11-01', '2026-11-30', 'new', 3, now).level, 'late_start')
check('health done', dates.health(nil, '2026-01-01', 'done', 3, now).level, 'done')
check('elapsed', dates.elapsed('2026-11-08', '2026-11-18', now), 0.5)
check('short', dates.short('2026-11-20', now), 'Nov 20')
check('short other year', dates.short('2027-01-02', now), "Jan 02 '27")

-- ensure the invalid-date case really returned nil
if dates.parse('2026-02-30', nil, now) ~= nil then
  fails = fails + 1
  print('FAIL invalid date accepted')
end

print(fails == 0 and 'dates: all passed' or ('dates: ' .. fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
