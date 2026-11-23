-- Run: nvim -l tests/actions_test.lua
-- Write actions against a fake api: what gets called, in what order, and what undo reverses.
vim.opt.rtp:prepend('.')
local fails = 0
local function eq(name, got, want)
  if not vim.deep_equal(got, want) then
    fails = fails + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local api = require('jira.api')
local calls = {}
local function log(...)
  calls[#calls + 1] = table.concat(vim.tbl_map(tostring, { ... }), ' ')
end
api.me = function()
  return 'me-1'
end
api.issue = function(key)
  return { key = key, summary = 'Fix the login page', status = 'To Do', cat = 'new', assignee_id = 'other-9' }
end
api.assign = function(key, id)
  log('assign', key, id)
end
api.transitions = function()
  return {
    { id = '11', to = { name = 'To Do', statusCategory = { key = 'new' } } },
    { id = '21', to = { name = 'Doing', statusCategory = { key = 'indeterminate' } } },
    { id = '31', to = { name = 'In Progress', statusCategory = { key = 'indeterminate' } } },
  }
end
api.transition = function(key, id)
  log('transition', key, id)
end
api.set_date = function(key, which, v)
  log('date', key, which, v == vim.NIL and 'none' or v)
end
api.set_points = function(key, n)
  log('points', key, n == vim.NIL and 'none' or n)
end
api.log_work = function(key, time, comment)
  log('worklog', key, time, comment)
end

local actions = require('jira.ui.actions')
local today = os.date('%Y-%m-%d')
local function settle()
  vim.wait(500, function()
    return false
  end, 10)
end

-- start work: assign, In Progress (preferred over other in-progress statuses), start today, branch copied
actions.start_work({ key = 'P-1' })
settle()
eq('start work calls', calls, { 'assign P-1 me-1', 'transition P-1 31', 'date P-1 start ' .. today })
eq('start work branch', vim.fn.getreg('"'), 'P-1-fix-the-login-page')
calls = {}
actions.undo()
settle()
eq('start work undo, newest first', calls, { 'date P-1 start none', 'transition P-1 11', 'assign P-1 other-9' })

-- already started: nothing to change, nothing to undo
calls = {}
actions.op('start_work', { { key = 'P-2', summary = 'x', status = 'In Progress', cat = 'indeterminate', assignee_id = 'me-1', start = '2026-11-01' } })
settle()
eq('start work no-op', calls, {})

-- points on two rows, then undo back to each row's own value
local orig_input = vim.ui.input
vim.ui.input = function(_, cb)
  cb('5')
end
calls = {}
actions.op('points', { { key = 'P-3', points = 2 }, { key = 'P-4' } })
settle()
table.sort(calls)
eq('points set', calls, { 'points P-3 5', 'points P-4 5' })
calls = {}
actions.undo()
settle()
table.sort(calls)
eq('points undo', calls, { 'points P-3 2', 'points P-4 none' })
vim.ui.input = orig_input

-- log work with time and comment given: no prompts, time normalised
calls = {}
actions.log_work({ key = 'P-5' }, '1h30m', 'paired on the fix')
settle()
eq('log work', calls, { 'worklog P-5 1h 30m paired on the fix' })
calls = {}
actions.log_work({ key = 'P-5' }, 'soon', '')
settle()
eq('log work bad time sends nothing', calls, {})

-- watch: a mixed selection watches only the unwatched row; undo unwatches just that one
local watching = { ['P-6'] = true }
api.watched = function()
  return vim.deepcopy(watching)
end
api.watch = function(key, action)
  log(action, key)
  watching[key] = action == 'watch' or nil
end
calls = {}
actions.op('watch', { { key = 'P-6' }, { key = 'P-7' } })
settle()
eq('watch mixed', calls, { 'watch P-7' })
calls = {}
actions.undo()
settle()
eq('watch undo', calls, { 'unwatch P-7' })

-- watch: when every row is watched, the same key unwatches them all
watching = { ['P-6'] = true, ['P-7'] = true }
calls = {}
actions.op('watch', { { key = 'P-6' }, { key = 'P-7' } })
settle()
table.sort(calls)
eq('unwatch all', calls, { 'unwatch P-6', 'unwatch P-7' })

print(fails == 0 and 'actions: all passed' or ('actions: ' .. fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
