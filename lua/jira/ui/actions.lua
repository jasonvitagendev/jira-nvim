-- Issue actions shared by the sidebar, grid, detail and timeline views.
--
-- Field changes are "ops": each one asks its questions once, then applies to one issue or many,
-- and hands back an undo step.
--
--   M.op('status', items, refresh)      items = normalized issues (at least { key = ... })
--   M.status(ctx)                       ctx = { key, item, refresh } shorthand for one issue
local a = require('jira.async')
local api = require('jira.api')
local config = require('jira.config')
local dates = require('jira.dates')
local editor = require('jira.ui.editor')
local store = require('jira.ui.store')

local M = {}

local KEY = '^%u[%u%d_]*%-%d+$'

local function input(opts)
  return a.await(function(cb)
    vim.ui.input(opts, function(v)
      cb(nil, v)
    end)
  end)
end

local function select(items, opts)
  return a.await(function(cb)
    vim.ui.select(items, opts, function(choice)
      cb(nil, choice)
    end)
  end)
end

local function info(msg)
  vim.notify('jira: ' .. msg, vim.log.levels.INFO)
end

local function warn(msg)
  vim.notify('jira: ' .. msg, vim.log.levels.WARN)
end

local function project_of(key)
  return key:match('^(%u[%u%d_]*)%-')
end

local function run(fn)
  a.run(fn)
end

local function yank(text, what, quiet)
  vim.fn.setreg('+', text)
  vim.fn.setreg('"', text)
  if not quiet then
    info('copied ' .. what .. ': ' .. text)
  end
end

-- PROJ-12-fix-the-login-page (git checks the git side; this keeps it short and safe)
local function branch_name(key, summary)
  local slug = (summary or ''):lower():gsub('[^%w]+', '-'):gsub('^%-+', ''):gsub('%-+$', '')
  slug = slug:sub(1, 50):gsub('%-+$', '')
  return key .. (slug ~= '' and ('-' .. slug) or '')
end

-- Run fn(item) for every item, four at a time. Never raises: returns { { err = ..., value = ... }, ... }
local function pool(items, fn)
  local results = {}
  for i = 1, #items, 4 do
    local starters = {}
    for j = i, math.min(i + 3, #items) do
      starters[#starters + 1] = function(cb)
        a.run(function()
          return fn(items[j])
        end, function(err, value)
          results[j] = { err = err, value = value }
          cb(nil, true)
        end)
      end
    end
    a.all(starters)
  end
  return results
end

-- undo ----------------------------------------------------------------------

local undo_stack = {}

local function push_undo(label, fns)
  if #fns == 0 then
    return
  end
  undo_stack[#undo_stack + 1] = { label = label, fns = fns }
  if #undo_stack > 30 then
    table.remove(undo_stack, 1)
  end
end

function M.undo(refresh)
  local entry = table.remove(undo_stack)
  if not entry then
    return info('nothing to undo')
  end
  run(function()
    local failed = {}
    for _, res in ipairs(pool(entry.fns, function(fn)
      fn()
    end)) do
      if res.err then
        failed[#failed + 1] = tostring(res.err)
      end
    end
    store.changed()
    if #failed > 0 then
      warn(('undo of "%s" failed for %d: %s'):format(entry.label, #failed, failed[1]))
    else
      info('undid: ' .. entry.label)
    end
    if refresh then
      refresh()
    end
  end)
end

-- ops -----------------------------------------------------------------------
-- ops.<name>(items, arg) asks once and returns apply(item) plus a label, or nil when cancelled.
-- apply returns an undo function, or nil when the change cannot be undone.

local ops = {}

local function find_transition(key, status_name)
  for _, t in ipairs(api.transitions(key)) do
    if t.to and t.to.name == status_name then
      return t
    end
  end
end

function ops.status(items)
  local first = items[1]
  local list = api.transitions(first.key)
  if #list == 0 then
    info('no transitions available for ' .. first.key)
    return
  end
  local order = { new = 1, indeterminate = 2, done = 3 }
  table.sort(list, function(x, y)
    local cx, cy = order[(x.to.statusCategory or {}).key] or 9, order[(y.to.statusCategory or {}).key] or 9
    if cx ~= cy then
      return cx < cy
    end
    return x.to.name < y.to.name
  end)
  local pick = select(list, {
    prompt = (#items == 1 and first.key or (#items .. ' issues')) .. ' status' .. (#items == 1 and first.status and (' (now ' .. first.status .. ')') or ''),
    format_item = function(t)
      local label = require('jira.ui.render').status_icon((t.to.statusCategory or {}).key) .. ' ' .. t.to.name
      if t.name ~= t.to.name then
        label = label .. '  (' .. t.name .. ')'
      end
      return label
    end,
  })
  if not pick then
    return
  end
  local target = pick.to.name
  return function(it)
    local prev = it.status
    if prev == target then
      return nil
    end
    local id = pick.id
    if it.key ~= first.key then
      -- workflows differ per issue type, so match on the status the transition leads to
      local t = find_transition(it.key, target) or error('cannot move to ' .. target .. ' from ' .. tostring(prev), 0)
      id = t.id
    end
    api.transition(it.key, id)
    return prev and function()
      local back = find_transition(it.key, prev) or error(it.key .. ': no transition back to ' .. prev, 0)
      api.transition(it.key, back.id)
    end
  end,
    '→ ' .. target
end

local function assign_apply(account_id)
  return function(it)
    local prev = it.assignee_id
    api.assign(it.key, account_id)
    -- only undoable when we knew who had it before
    if it.assignee == nil or prev then
      return function()
        api.assign(it.key, prev)
      end
    end
  end
end

function ops.assign_me()
  return assign_apply(api.me()), 'assigned to you'
end

function ops.assign(items)
  local first = items[1]
  local q = input({ prompt = 'Assign to (name or email, empty = list all): ' })
  if q == nil then
    return
  end
  local users = api.assignable(first.key, q ~= '' and q or nil)
  local list = { { displayName = 'Unassigned' } }
  vim.list_extend(list, users)
  local pick = select(list, {
    prompt = 'Assign ' .. (#items == 1 and first.key or (#items .. ' issues')),
    format_item = function(u)
      return u.displayName .. (u.emailAddress and ('  <' .. u.emailAddress .. '>') or '')
    end,
  })
  if not pick then
    return
  end
  return assign_apply(pick.accountId), '→ ' .. pick.displayName
end

local DATE_HELP = 'YYYY-MM-DD · 11-20 · 20 · today · +3d · +2w · ++1w (from current) · fri · eow · eom · none'

-- arg = { which = 'start' | 'due', value = optional fixed value (skips the prompt) }
function ops.date(items, arg)
  local which = arg.which
  local label = which == 'start' and 'start' or 'due'
  local function current(it)
    return which == 'start' and it.start or it.due
  end
  local raw = arg.value
  if not raw then
    local first = items[1]
    local cur = #items == 1 and current(first) or nil
    raw = input({
      prompt = ('%s %s date [%s]: '):format(#items == 1 and first.key or (#items .. ' issues'), label, DATE_HELP),
      default = cur or '',
    })
    if raw == nil or vim.trim(raw) == '' or raw == cur then
      return
    end
    local value, err = dates.parse(raw, cur)
    if not value then
      warn(err)
      return
    end
    -- Guard the obvious mistake of due before start
    if #items == 1 and value ~= vim.NIL then
      local other = which == 'start' and first.due or first.start
      local bad = other and ((which == 'start' and value > other) or (which == 'due' and value < other))
      if bad and vim.fn.confirm(('%s date %s is %s the %s date %s. Save anyway?'):format(label, value, which == 'start' and 'after' or 'before', which == 'start' and 'due' or 'start', other), '&Yes\n&No', 2) ~= 1 then
        return
      end
    end
  end
  local shown
  return function(it)
    local prev = current(it)
    -- parsed per issue so ++1w pushes each one from its own date
    local value = assert(dates.parse(raw, prev))
    api.set_date(it.key, which, value)
    shown = value == vim.NIL and 'cleared' or (value .. ' (' .. os.date('%a', dates.to_time(value)) .. ')')
    return function()
      api.set_date(it.key, which, prev or vim.NIL)
    end
  end,
    function()
      return label .. ' date ' .. (#items == 1 and shown or ('set from "' .. raw .. '"'))
    end
end

function ops.summary(items)
  local it = items[1]
  if #items > 1 then
    warn('summary can only be edited one issue at a time')
    return
  end
  local v = input({ prompt = it.key .. ' summary: ', default = it.summary or '' })
  if not v or vim.trim(v) == '' or v == it.summary then
    return
  end
  local prev = it.summary
  return function()
    api.edit(it.key, { summary = vim.trim(v) })
    return prev and function()
      api.edit(it.key, { summary = prev })
    end
  end,
    'summary updated'
end

-- Pick a parent (epic or initiative) from everything loaded so far, or type a key.
function M.pick_epic(prompt, exclude)
  local list = {}
  for key, e in pairs(store.epics) do
    if key ~= exclude and e.cat ~= 'done' then
      list[#list + 1] = e
    end
  end
  table.sort(list, function(x, y)
    return x.key < y.key
  end)
  list[#list + 1] = { key = '', summary = 'Type a key…' }
  local pick = select(list, {
    prompt = prompt,
    format_item = function(e)
      return e.key == '' and e.summary or (e.key .. '  ' .. e.summary)
    end,
  })
  if not pick then
    return nil
  end
  if pick.key == '' then
    local k = input({ prompt = 'Key: ' })
    k = k and vim.trim(k):upper() or ''
    return k:match(KEY)
  end
  return pick.key
end

function ops.move_epic(items)
  local target = M.pick_epic('Move ' .. (#items == 1 and items[1].key or (#items .. ' issues')) .. ' under', #items == 1 and items[1].parent_key or nil)
  if not target then
    return
  end
  return function(it)
    local prev = it.parent_key
    if prev == target then
      return nil
    end
    api.set_parent(it.key, target)
    return prev and function()
      api.set_parent(it.key, prev)
    end
  end,
    'moved to ' .. target
end

function ops.priority(items)
  local names = api.priorities(project_of(items[1].key))
  if #names == 0 then
    warn('no priorities found for this project')
    return
  end
  local pick = select(names, { prompt = 'Priority' .. (#items == 1 and items[1].priority and (' (now ' .. items[1].priority .. ')') or '') })
  if not pick then
    return
  end
  return function(it)
    local prev = it.priority
    api.set_priority(it.key, pick)
    return prev and function()
      api.set_priority(it.key, prev)
    end
  end,
    'priority → ' .. pick
end

-- "a, b" replaces the labels; "+a -b" adds and removes.
function ops.labels(items)
  local single = #items == 1
  local cur = single and table.concat(items[1].labels or {}, ', ') or ''
  local raw = input({ prompt = single and 'Labels (a, b replaces · +a -b adds / removes): ' or 'Labels to change (+a adds, -b removes): ', default = cur })
  if raw == nil or raw == cur then
    return
  end
  local tokens = vim.split(raw, '[,%s]+', { trimempty = true })
  local relative = false
  for _, t in ipairs(tokens) do
    relative = relative or t:match('^[+-]') ~= nil
  end
  if not single and not relative then
    warn('with several issues, use +label or -label')
    return
  end
  return function(it)
    local prev = vim.deepcopy(it.labels or {})
    local set, list = {}, {}
    if relative then
      for _, l in ipairs(prev) do
        set[l] = true
      end
      for _, t in ipairs(tokens) do
        local sign, name = t:match('^([+-]?)(.+)$')
        set[name] = sign ~= '-' or nil
      end
      for l in pairs(set) do
        list[#list + 1] = l
      end
      table.sort(list)
    else
      list = tokens
    end
    api.set_labels(it.key, list)
    return function()
      api.set_labels(it.key, prev)
    end
  end,
    'labels updated'
end

-- story points: a number, or none to clear
function ops.points(items)
  local single = #items == 1
  local cur = single and items[1].points and tostring(items[1].points) or ''
  local raw = input({ prompt = ('%s story points (none clears): '):format(single and items[1].key or (#items .. ' issues')), default = cur })
  raw = raw and vim.trim(raw) or ''
  if raw == '' or raw == cur then
    return
  end
  local n = (raw == 'none' or raw == '-') and vim.NIL or tonumber(raw)
  if n == nil or (n ~= vim.NIL and n < 0) then
    warn('not a number: ' .. raw)
    return
  end
  return function(it)
    local prev = it.points
    api.set_points(it.key, n)
    return function()
      api.set_points(it.key, prev or vim.NIL)
    end
  end,
    n == vim.NIL and 'points cleared' or ('points → ' .. raw)
end

local function in_progress_transition(key)
  local first
  for _, t in ipairs(api.transitions(key)) do
    if (t.to and t.to.statusCategory or {}).key == 'indeterminate' then
      if t.to.name == 'In Progress' then
        return t
      end
      first = first or t
    end
  end
  return first
end

-- Assign to me, move to In Progress, set start to today (each only when needed), copy the branch name.
-- One undo step reverses all of it.
function ops.start_work(items)
  local me = api.me()
  local today = dates.fmt(dates.today())
  local branch, did
  return function(it)
    if not it.cat then
      it = api.issue(it.key)
    end
    local undo = {}
    -- assign first: some workflows refuse In Progress without an assignee
    if it.assignee_id ~= me then
      local prev = it.assignee_id
      api.assign(it.key, me)
      undo[#undo + 1] = function()
        api.assign(it.key, prev)
      end
    end
    if it.cat == 'new' then
      local t = in_progress_transition(it.key) or error('no transition to an in-progress status', 0)
      local prev = it.status
      api.transition(it.key, t.id)
      undo[#undo + 1] = function()
        local back = find_transition(it.key, prev) or error(it.key .. ': no transition back to ' .. prev, 0)
        api.transition(it.key, back.id)
      end
    end
    -- the start date field is optional on some sites, so a miss there does not fail the rest
    if not it.start and pcall(api.set_date, it.key, 'start', today) then
      undo[#undo + 1] = function()
        api.set_date(it.key, 'start', vim.NIL)
      end
    end
    if #items == 1 then
      branch = branch_name(it.key, it.summary)
    end
    if #undo == 0 then
      return nil
    end
    did = true
    return function()
      for i = #undo, 1, -1 do
        undo[i]()
      end
    end
  end,
    function()
      local msg = did and 'started' or 'already started'
      if branch then
        yank(branch, 'branch', true)
        return msg .. ' · branch copied: ' .. branch
      end
      return msg
    end
end

local board_choice = {}

-- Coroutine: the scrum board of a project (asks once per session when there are several), or nil.
function M.pick_board(project)
  if board_choice[project] then
    return board_choice[project]
  end
  local boards = api.sprint_boards(project)
  if #boards == 0 then
    warn(project .. ' has no sprint board (its boards are kanban), so it has no sprints')
    return nil
  end
  local board = boards[1]
  if #boards > 1 then
    board = select(boards, {
      prompt = 'Board',
      format_item = function(b)
        return b.name
      end,
    })
    if not board then
      return nil
    end
  end
  board_choice[project] = board
  return board
end

function ops.sprint(items)
  local board = M.pick_board(project_of(items[1].key))
  if not board then
    return
  end
  local sprint = api.active_sprint(board.id)
  return function(it)
    api.to_sprint(it.key, sprint.id)
  end,
    'moved to sprint ' .. tostring(sprint.name or sprint.id)
end

function ops.link(items)
  local choices = {}
  local rank = { Blocks = 1, Relates = 2, Duplicate = 3, Cloners = 4 }
  for _, t in ipairs(api.link_types()) do
    choices[#choices + 1] = { label = t.outward, type = t.name, out = true, rank = rank[t.name] or 9 }
    if t.inward ~= t.outward then
      choices[#choices + 1] = { label = t.inward, type = t.name, out = false, rank = rank[t.name] or 9 }
    end
  end
  table.sort(choices, function(x, y)
    if x.rank ~= y.rank then
      return x.rank < y.rank
    end
    return x.label < y.label
  end)
  local who = #items == 1 and items[1].key or (#items .. ' issues')
  local pick = select(choices, {
    prompt = who .. ' …',
    format_item = function(c)
      return c.label
    end,
  })
  if not pick then
    return
  end
  local other = input({ prompt = ('%s %s (issue key): '):format(who, pick.label) })
  other = other and vim.trim(other):upper() or ''
  if not other:match(KEY) then
    if other ~= '' then
      warn('not an issue key: ' .. other)
    end
    return
  end
  return function(it)
    if pick.out then
      api.link(pick.type, it.key, other)
    else
      api.link(pick.type, other, it.key)
    end
  end,
    pick.label .. ' ' .. other
end

-- Run an op over one or many issues.
function M.op(name, items, refresh, arg)
  if not items or #items == 0 then
    return warn('no issue selected')
  end
  run(function()
    local apply, label = ops[name](items, arg)
    if not apply then
      return
    end
    local undos, failed, changed = {}, {}, 0
    for i, res in ipairs(pool(items, apply)) do
      if res.err then
        failed[#failed + 1] = items[i].key .. ': ' .. tostring(res.err)
      else
        changed = changed + 1
        if res.value then
          undos[#undos + 1] = res.value
        end
      end
    end
    store.changed()
    if type(label) == 'function' then
      label = label()
    end
    local msg = (#items == 1 and items[1].key or (changed .. ' issues')) .. ' ' .. label
    if changed > 0 then
      push_undo(msg, undos)
      info(msg .. (#undos > 0 and '' or '  (cannot be undone)'))
    end
    if #failed > 0 then
      warn(('%d failed: %s'):format(#failed, table.concat(failed, '; ', 1, math.min(3, #failed))))
    end
    if refresh then
      refresh()
    end
  end)
end

local function one(ctx)
  return { ctx.item or { key = ctx.key } }
end

for _, name in ipairs({ 'status', 'assign_me', 'assign', 'summary', 'move_epic', 'priority', 'labels', 'sprint', 'link', 'points', 'start_work' }) do
  M[name] = function(ctx)
    M.op(name, one(ctx), ctx.refresh)
  end
end

function M.date(ctx, which, value)
  M.op('date', one(ctx), ctx.refresh, { which = which, value = value })
end

local function done(refresh, msg)
  store.changed()
  if msg then
    info(msg)
  end
  if refresh then
    refresh()
  end
end

-- worklog -------------------------------------------------------------------

-- "2h", "1h 30m", "1h30m", "90m", "1.5h", "2" (hours) -> "2h", "1h 30m", ... or nil + error
function M.parse_duration(s)
  s = (s or ''):lower():gsub('%s+', '')
  if s == '' then
    return nil, 'empty'
  end
  if s:match('^%d+%.?%d*$') then
    s = s .. 'h'
  end
  local out, pos = {}, 1
  while pos <= #s do
    local n, u, nxt = s:match('^(%d+%.?%d*)([wdhm])()', pos)
    if not n then
      return nil, 'could not read time "' .. s .. '" (try 2h, 1h 30m, 45m)'
    end
    local num = tonumber(n)
    if num % 1 ~= 0 then
      if u ~= 'h' then
        return nil, 'only hours can have decimals'
      end
      local h, m = math.floor(num), math.floor(num % 1 * 60 + 0.5)
      out[#out + 1] = h > 0 and (h .. 'h') or nil
      out[#out + 1] = m > 0 and (m .. 'm') or nil
    elseif num > 0 then
      out[#out + 1] = ('%d%s'):format(num, u)
    end
    pos = nxt
  end
  if #out == 0 then
    return nil, 'no time given'
  end
  return table.concat(out, ' ')
end

-- time and comment are asked for when nil
function M.log_work(ctx, time, comment)
  run(function()
    if not time then
      time = input({ prompt = ctx.key .. ' time spent (2h, 1h 30m, 45m): ' })
      if not time or vim.trim(time) == '' then
        return
      end
    end
    local t, err = M.parse_duration(time)
    if not t then
      return warn(err)
    end
    if comment == nil then
      comment = input({ prompt = 'What did you do (optional): ' })
      if comment == nil then
        return
      end
    end
    comment = vim.trim(comment)
    api.log_work(ctx.key, t, comment ~= '' and comment or nil)
    done(ctx.refresh, ('logged %s on %s'):format(t, ctx.key))
  end)
end

-- description ---------------------------------------------------------------

-- Bodies that came back as HTML (mentions, media, panels) are edited as HTML so nothing is lost.
function M.description(ctx)
  run(function()
    local issue = api.issue(ctx.key)
    local fmt = issue.format or 'markdown'
    local opened_at = issue.updated
    editor.open({
      name = ctx.key .. '/description',
      title = ctx.key .. ' description' .. (fmt == 'html' and ' (html, keeps mentions and media)' or ''),
      filetype = fmt == 'html' and 'html' or 'markdown',
      lines = vim.split(issue.description or '', '\n'),
      save = function(lines)
        local now = api.updated_at(ctx.key)
        if now and opened_at and now ~= opened_at then
          if vim.fn.confirm(ctx.key .. ' was changed in Jira after you opened it. Overwrite with your version?', '&Overwrite\n&Cancel', 2) ~= 1 then
            return false
          end
        end
        api.set_description(ctx.key, editor.body(lines), fmt)
        return ctx.key .. ' description saved'
      end,
      after = function()
        done(ctx.refresh)
      end,
    })
  end)
end

-- comments ------------------------------------------------------------------

-- Insert-mode @ opens a people picker. Returns the list of mentions made in this buffer.
local function enable_mentions(buf, key, fmt)
  local made = {}
  vim.keymap.set('i', '@', function()
    local win = vim.api.nvim_get_current_win()
    local row, col = unpack(vim.api.nvim_win_get_cursor(win))
    local before = col > 0 and vim.api.nvim_get_current_line():sub(col, col) or ''
    local function put(text)
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_buf_set_text(buf, row - 1, col, row - 1, col, { text })
      vim.api.nvim_win_set_cursor(win, { row, col + #text })
      -- back to insert mode right after the inserted text
      if col + #text >= #vim.api.nvim_get_current_line() then
        vim.cmd('startinsert!')
      else
        vim.cmd('startinsert')
      end
    end
    -- mid-word (an email address, say): just type the character
    if before:match('[%w]') then
      return put('@')
    end
    vim.cmd('stopinsert')
    a.run(function()
      local users = store.memo('users:' .. project_of(key), 600, function()
        return api.assignable(key)
      end)
      local list = vim.list_extend({}, users)
      list[#list + 1] = { displayName = 'Search everyone by name…', search = true }
      local pick = select(list, {
        prompt = 'Mention',
        format_item = function(u)
          return u.displayName
        end,
      })
      if pick and pick.search then
        local q = input({ prompt = 'Name: ' })
        if not q or vim.trim(q) == '' then
          return nil
        end
        pick = select(api.find_users(vim.trim(q)), {
          prompt = 'Mention',
          format_item = function(u)
            return u.displayName .. (u.emailAddress and ('  <' .. u.emailAddress .. '>') or '')
          end,
        })
      end
      return pick
    end, function(err, pick)
      if err then
        warn(tostring(err))
      end
      if not pick or not pick.accountId then
        return put('@')
      end
      if fmt == 'html' then
        put(('<span data-type="mention" data-user-id="%s">@%s</span> '):format(pick.accountId, pick.displayName))
      else
        made[#made + 1] = { name = pick.displayName, id = pick.accountId }
        put('@' .. pick.displayName .. ' ')
      end
    end)
  end, { buffer = buf, desc = 'jira: mention someone' })
  return made
end

-- opts.quote = a comment to quote (reply)
function M.comment(ctx, existing, opts)
  opts = opts or {}
  local fmt = existing and existing.format or 'markdown'
  local lines = existing and vim.split(existing.body, '\n') or { '' }
  local title = existing and (ctx.key .. ' edit comment') or (ctx.key .. ' new comment')
  if opts.quote then
    local q = opts.quote
    lines = { ('> **%s** wrote:'):format(q.author) }
    local body = vim.split(require('jira.ui.detail').plain(q.body, q.format), '\n')
    for i = 1, math.min(#body, 6) do
      lines[#lines + 1] = '> ' .. body[i]
    end
    if #body > 6 then
      lines[#lines + 1] = '> …'
    end
    vim.list_extend(lines, { '', '' })
    title = ctx.key .. ' reply to ' .. q.author .. ' (sent as a quoted comment)'
  end
  local made = {}
  editor.open({
    name = ctx.key .. '/comment/' .. (existing and existing.id or 'new'),
    title = title .. '  ·  @ mentions someone',
    filetype = fmt == 'html' and 'html' or 'markdown',
    lines = lines,
    cursor = opts.quote and { #lines, 0 } or nil,
    insert = not existing,
    on_open = function(buf)
      made = enable_mentions(buf, ctx.key, fmt)
    end,
    save = function(buf_lines)
      local body = editor.body(buf_lines)
      if body == '' then
        error('empty comment, nothing sent', 0)
      end
      local send_fmt = fmt
      -- Jira only takes mentions as HTML, so convert when the text still holds one we inserted
      local used = vim.tbl_filter(function(m)
        return body:find('@' .. m.name, 1, true) ~= nil
      end, made)
      if fmt == 'markdown' and #used > 0 then
        local html, why = require('jira.md').to_html(body, used)
        if not html then
          error(why, 0)
        end
        body, send_fmt = html, 'html'
      end
      api.comment(ctx.key, body, send_fmt, existing and existing.id or nil)
      return existing and 'comment updated' or ('comment added to ' .. ctx.key)
    end,
    after = function()
      done(ctx.refresh)
    end,
  })
end

function M.reply(ctx, comment)
  M.comment(ctx, nil, { quote = comment })
end

-- create --------------------------------------------------------------------

local function resolve_assignee(who, key, project)
  if who:lower() == 'me' then
    return api.me()
  end
  local users = api.assignable(key, who, project)
  if #users == 0 then
    error('no assignable user matches "' .. who .. '"', 0)
  end
  if #users == 1 then
    return users[1].accountId
  end
  for _, u in ipairs(users) do
    if u.displayName:lower() == who:lower() then
      return u.accountId
    end
  end
  local names = vim.tbl_map(function(u)
    return u.displayName
  end, users)
  error(('"%s" matches several people: %s'):format(who, table.concat(names, ', ', 1, math.min(5, #names))), 0)
end

-- Child type for a parent: epics go under initiatives, tasks under epics.
local function child_type(parent)
  return parent and parent.type == 'Initiative' and 'Epic' or config.default_issue_type
end

function M.quick_add(parent_key, after, parent)
  run(function()
    local kind = child_type(parent)
    local summary = input({ prompt = ('New %s in %s: '):format(kind:lower(), parent_key) })
    if not summary or vim.trim(summary) == '' then
      return
    end
    local key = api.create({ project = project_of(parent_key), parent = parent_key, summary = vim.trim(summary), type = kind })
    done(after, 'created ' .. tostring(key))
  end)
end

-- One form for tasks, epics and initiatives.
-- opts: type, project, parent, title, after(key)
function M.form(opts)
  local lines = {
    'Summary: ',
    'Type: ' .. opts.type,
    'Project: ' .. (opts.project or ''),
    'Parent: ' .. (opts.parent or ''),
    'Assignee: ',
    'Priority: ',
    'Labels: ',
    'Start: ',
    'Due: ',
    '--- description below (markdown) ---',
    '',
  }
  local created
  editor.open({
    name = 'new/' .. opts.type:lower() .. '/' .. (opts.parent or opts.project or 'x'),
    title = opts.title .. '  (Assignee: me, a name or blank · dates take +3d, fri, …)',
    filetype = 'markdown',
    lines = lines,
    cursor = { 1, 9 },
    insert = true,
    save = function(buf_lines)
      local head, body, in_body = {}, {}, false
      for _, l in ipairs(buf_lines) do
        if in_body then
          body[#body + 1] = l
        elseif l:match('^%-%-%-') then
          in_body = true
        else
          local k, v = l:match('^(%a+):%s*(.-)%s*$')
          if k then
            head[k:lower()] = v
          end
        end
      end
      local function val(name)
        return head[name] and head[name] ~= '' and head[name] or nil
      end
      if not val('summary') then
        error('Summary is required', 0)
      end
      local parent = val('parent') and val('parent'):upper() or nil
      if parent and not parent:match(KEY) then
        error('Parent is not an issue key: ' .. parent, 0)
      end
      local project = (val('project') or (parent and project_of(parent)) or ''):upper()
      if not project:match('^%u[%u%d_]*$') then
        error('Project is required (a key like PROJ)', 0)
      end
      local create = {
        project = project,
        parent = parent,
        summary = val('summary'),
        type = val('type') or opts.type,
        priority = val('priority'),
        description = editor.body(body),
      }
      if create.description == '' then
        create.description = nil
      end
      if val('labels') then
        create.labels = vim.split(val('labels'), '[,%s]+', { trimempty = true })
      end
      for _, f in ipairs({ 'start', 'due' }) do
        if val(f) then
          local v, err = dates.parse(val(f))
          if not v or v == vim.NIL then
            error(f .. ': ' .. (err or 'invalid'), 0)
          end
          create[f] = v
        end
      end
      if val('assignee') then
        create.assignee = resolve_assignee(val('assignee'), parent, project)
      end
      created = api.create(create)
      return 'created ' .. tostring(created)
    end,
    after = function()
      store.changed()
      if opts.after then
        opts.after(created)
      end
    end,
  })
end

-- New task (or epic, under an initiative) in a parent.
function M.add_form(parent_key, after, parent)
  local kind = child_type(parent)
  M.form({
    type = kind,
    project = project_of(parent_key),
    parent = parent_key,
    title = ('New %s in %s'):format(kind:lower(), parent_key),
    after = after,
  })
end

local function open_created(key)
  if key then
    require('jira').open_key(key)
  end
end

-- opts: project, parent (initiative key)
function M.new_epic(opts)
  opts = opts or {}
  run(function()
    local project = opts.project
    if not project then
      project = input({ prompt = 'Project key for the new epic: ', default = opts.guess or '' })
      project = project and vim.trim(project):upper() or ''
      if not project:match('^%u[%u%d_]*$') then
        return
      end
    end
    M.form({ type = 'Epic', project = project, parent = opts.parent, title = 'New epic in ' .. project, after = open_created })
  end)
end

function M.new_initiative(opts)
  opts = opts or {}
  run(function()
    local guess = opts.project or config.initiative_project
    if not guess then
      -- initiatives usually live where the loaded epics' parents live
      for _, e in pairs(store.epics) do
        if e.type == 'Epic' and e.parent_key then
          guess = project_of(e.parent_key)
          break
        end
      end
    end
    local project = input({ prompt = 'Project key for the new initiative: ', default = guess or '' })
    project = project and vim.trim(project):upper() or ''
    if not project:match('^%u[%u%d_]*$') then
      return
    end
    M.form({ type = 'Initiative', project = project, title = 'New initiative in ' .. project, after = open_created })
  end)
end

-- "New…" menu. ctx: parent (normalized issue or nil), refresh
function M.new_menu(ctx)
  run(function()
    local parent = ctx.parent
    local list = {}
    if parent then
      local kind = child_type(parent):lower()
      list[#list + 1] = { label = ('%s in %s'):format(kind:gsub('^%l', string.upper), parent.key), run = function()
        M.add_form(parent.key, ctx.refresh, parent)
      end }
      list[#list + 1] = { label = ('Many %ss in %s (one per line)'):format(kind, parent.key), run = function()
        M.plan(parent.key, ctx.refresh, parent)
      end }
    end
    local initiative = parent and (parent.type == 'Initiative' and parent.key or parent.type == 'Epic' and parent.parent_key) or nil
    list[#list + 1] = { label = 'Epic' .. (initiative and (' under ' .. initiative) or ''), run = function()
      M.new_epic({ parent = initiative, guess = parent and parent.type == 'Epic' and project_of(parent.key) or nil })
    end }
    list[#list + 1] = { label = 'Initiative', run = function()
      M.new_initiative()
    end }
    local pick = select(list, {
      prompt = 'New',
      format_item = function(x)
        return x.label
      end,
    })
    if pick then
      pick.run()
    end
  end)
end

-- plan: many issues from a list ------------------------------------------------

local TAGS = {
  { '^@(.+)$', 'assignee' },
  { '^due:(.+)$', 'due' },
  { '^start:(.+)$', 'start' },
  { '^!(.+)$', 'priority' },
  { '^type:(.+)$', 'type' },
}

-- "Fix login @me due:fri #auth" -> { summary = 'Fix login', assignee = 'me', due = 'fri', labels = { 'auth' } }
function M.parse_plan(lines)
  local tasks, cur = {}, nil
  for n, l in ipairs(lines) do
    -- comments: "# text", "## heading", and the "#✓ / #✗" marks left by a partial run
    if l:match('^#+%s') or l:match('^#+$') or l:match('^#✓') or l:match('^#✗') then
      cur = nil
    elseif l:match('^%s*$') then
      if cur and #cur.desc > 0 then
        cur.desc[#cur.desc + 1] = ''
      end
    elseif l:match('^%s+%S') and cur then
      cur.indent = cur.indent or #l:match('^%s+')
      cur.desc[#cur.desc + 1] = l:sub(math.min(cur.indent, #l:match('^%s+')) + 1)
      cur.last = n
    else
      -- pasted checklists: "- [ ] thing", "* thing", "1. thing"
      local text = l:gsub('^%s*[-*+]%s+%[.%]%s+', ''):gsub('^%s*[-*+]%s+', ''):gsub('^%s*%d+[.)]%s+', '')
      local words = vim.split(vim.trim(text), '%s+', { trimempty = true })
      cur = { line = n, last = n, desc = {}, labels = {} }
      while #words > 1 do
        local w, hit = words[#words], false
        local label = w:match('^#([%w_%-]+)$')
        if label then
          table.insert(cur.labels, 1, label)
          hit = true
        else
          for _, tag in ipairs(TAGS) do
            local v = w:match(tag[1])
            if v and not cur[tag[2]] then
              cur[tag[2]] = v
              hit = true
              break
            end
          end
        end
        if not hit then
          break
        end
        table.remove(words)
      end
      cur.summary = table.concat(words, ' ')
      tasks[#tasks + 1] = cur
    end
  end
  for _, t in ipairs(tasks) do
    while t.desc[#t.desc] == '' do
      table.remove(t.desc)
    end
  end
  return tasks
end

function M.plan(parent_key, after, parent)
  local kind = child_type(parent)
  local project = project_of(parent_key)
  editor.open({
    name = 'plan/' .. parent_key,
    title = ('Plan %s: one %s per line'):format(parent_key, kind:lower()),
    filetype = 'markdown',
    lines = {
      ('# One %s per line. :w creates them in %s, in this order.'):format(kind:lower(), parent_key),
      '# Tags at the end of a line:  @me  @name  due:fri  start:mon  !High  #label  type:Bug',
      '# Indented lines under a line become its description.',
      '',
      '',
    },
    cursor = { 5, 0 },
    insert = true,
    save = function(lines, buf)
      local tasks = M.parse_plan(lines)
      if #tasks == 0 then
        error('nothing to create: add one line per ' .. kind:lower(), 0)
      end
      -- check everything first, so a typo on line 9 does not leave eight issues created
      local problems, who = {}, {}
      local allowed
      for _, t in ipairs(tasks) do
        local function bad(msg)
          problems[#problems + 1] = ('line %d: %s'):format(t.line, msg)
        end
        for _, f in ipairs({ 'start', 'due' }) do
          if t[f] then
            local v, err = dates.parse(t[f])
            if not v or v == vim.NIL then
              bad(f .. ': ' .. (err or 'invalid date'))
            end
            t[f] = v
          end
        end
        if t.assignee then
          if who[t.assignee] == nil then
            local ok, res = pcall(resolve_assignee, t.assignee, parent_key, project)
            who[t.assignee] = ok and res or { err = res }
          end
          if type(who[t.assignee]) == 'table' then
            bad(who[t.assignee].err)
          else
            t.assignee = who[t.assignee]
          end
        end
        if t.priority then
          allowed = allowed or api.priorities(project)
          local match
          for _, p in ipairs(allowed) do
            if p:lower() == t.priority:lower() then
              match = p
            end
          end
          if not match then
            bad('priority "' .. t.priority .. '" is not one of: ' .. table.concat(allowed, ', '))
          end
          t.priority = match
        end
      end
      if #problems > 0 then
        error('nothing created.\n' .. table.concat(problems, '\n'), 0)
      end
      -- one at a time, so they keep this order in Jira
      local failed
      for _, t in ipairs(tasks) do
        local ok, res = pcall(api.create, {
          project = project,
          parent = parent_key,
          summary = t.summary,
          type = t.type or kind,
          assignee = t.assignee,
          priority = t.priority,
          labels = #t.labels > 0 and t.labels or nil,
          start = t.start,
          due = t.due,
          description = #t.desc > 0 and table.concat(t.desc, '\n') or nil,
        })
        if not ok then
          failed = { task = t, err = tostring(res) }
          break
        end
        t.key = res
      end
      local keys = {}
      for _, t in ipairs(tasks) do
        keys[#keys + 1] = t.key
      end
      if #keys > 0 then
        store.changed()
      end
      if not failed then
        return ('created %d: %s'):format(#keys, table.concat(keys, ', '))
      end
      -- Mark what was created so writing again cannot create it twice.
      if vim.api.nvim_buf_is_valid(buf) then
        for i = #tasks, 1, -1 do
          local t = tasks[i]
          if t.key then
            vim.api.nvim_buf_set_lines(buf, t.line - 1, t.last, false, { ('#✓ %s  %s'):format(t.key, t.summary) })
          elseif t == failed.task then
            vim.api.nvim_buf_set_lines(buf, t.line - 1, t.line - 1, false, { '#✗ ' .. failed.err:gsub('\n', ' ') })
          end
        end
      end
      warn(('created %d, then stopped: %s. Fix the marked line and :w again.'):format(#keys, failed.err))
      return false
    end,
    after = function()
      done(after)
    end,
  })
end

-- other ---------------------------------------------------------------------

function M.browser(ctx)
  run(function()
    vim.ui.open(api.browse_url(ctx.key))
  end)
end

M.yank = yank

function M.yank_key(ctx)
  yank(ctx.key, 'key')
end

function M.yank_url(ctx)
  run(function()
    yank(api.browse_url(ctx.key), 'URL')
  end)
end

function M.yank_branch(ctx)
  yank(branch_name(ctx.key, ctx.item and ctx.item.summary), 'branch')
end

return M
