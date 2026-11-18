-- Weekly digest: for each of your epics, what got done, started and added, what is overdue,
-- and changes to the epic's own dates and status. Drawn as markdown so `Y` copies it ready to paste.
local a = require('jira.async')
local api = require('jira.api')
local bufs = require('jira.ui.bufs')
local checks = require('jira.checks')
local config = require('jira.config')
local dates = require('jira.dates')
local keys = require('jira.ui.keys')
local r = require('jira.ui.render')
local store = require('jira.ui.store')

local M = {}

M.states = {}

local DAY = 24 * 60 * 60
local KEY = '%u[%u%d_]*%-%d+'
local EPIC_FIELDS = { duedate = 'Due date', ['start date'] = 'Start date', status = 'Status' }

local function since_date(days)
  return dates.fmt(dates.today() - days * DAY)
end

local function since_epoch(days)
  local t = os.date('*t', dates.today() - days * DAY)
  return os.time({ year = t.year, month = t.month, day = t.day, hour = 0 })
end

-- Coroutine: { epics = { { epic, done, started, added, overdue, changes } }, days }
function M.collect(days)
  local epics = api.epics(config.digest.jql)
  local by, list = {}, {}
  for _, e in ipairs(epics) do
    by[e.key] = { epic = e, done = {}, started = {}, added = {}, overdue = {}, changes = {} }
    list[#list + 1] = by[e.key]
  end
  if #list == 0 then
    return { epics = list, days = days }
  end
  local since = since_date(days)
  local queries = {
    { 'done', ('statusCategory = Done AND statusCategoryChangedDate >= "%s"'):format(since) },
    { 'started', ('statusCategory = "In Progress" AND statusCategoryChangedDate >= "%s"'):format(since) },
    { 'added', ('created >= "%s"'):format(since) },
    { 'overdue', 'statusCategory != Done AND duedate < startOfDay()' },
  }
  local starters, names = {}, {}
  for i = 1, #epics, 40 do
    local chunk = table.concat(
      vim.tbl_map(function(e)
        return e.key
      end, vim.list_slice(epics, i, i + 39)),
      ','
    )
    for _, q in ipairs(queries) do
      names[#names + 1] = q[1]
      starters[#starters + 1] = a.starter(api.search, ('parent in (%s) AND %s ORDER BY updated DESC'):format(chunk, q[2]), {
        fields = { 'summary', 'status', 'parent', 'duedate', 'assignee' },
        limit = 500,
      })
    end
  end
  for i, found in ipairs(a.all(starters)) do
    for _, it in ipairs(found) do
      local slot = by[it.parent_key]
      if slot then
        table.insert(slot[names[i]], it)
      end
    end
  end
  -- the epic's own date and status changes, only for epics touched in the window
  local cutoff = since_epoch(days)
  local touched = vim.tbl_filter(function(s)
    local at = dates.epoch(s.epic.updated)
    return at and at >= cutoff
  end, list)
  for i = 1, #touched, 4 do
    local batch = {}
    for j = i, math.min(i + 3, #touched) do
      local s = touched[j]
      batch[#batch + 1] = a.starter(function()
        local ok, events = pcall(api.changelog, s.epic.key, cutoff)
        for _, e in ipairs(ok and events or {}) do
          local name = EPIC_FIELDS[(e.field or ''):lower()]
          if name then
            s.changes[#s.changes + 1] = { field = name, from = e.from, to = e.to }
          end
        end
      end)
    end
    a.all(batch)
  end
  return { epics = list, days = days }
end

local function value(v)
  if not v or v == '' then
    return 'none'
  end
  local d = v:match('^(%d%d%d%d%-%d%d%-%d%d)')
  return d and dates.short(d) or v
end

local function activity(s)
  return #s.done + #s.started + #s.added + #s.changes
end

-- Markdown lines for a collected digest. now is for tests.
function M.render(data, now)
  local today = dates.today(now)
  local lines = {
    ('# Weekly digest · %s – %s'):format(dates.short(dates.fmt(today - data.days * DAY), now), dates.short(dates.fmt(today), now)),
    '',
  }
  local totals = { done = 0, started = 0, added = 0 }
  for _, s in ipairs(data.epics) do
    for k in pairs(totals) do
      totals[k] = totals[k] + #s[k]
    end
  end
  if #data.epics == 0 then
    lines[#lines + 1] = '_No epics match the digest JQL._'
    return lines
  end
  lines[#lines + 1] = ('_%d epics · %d done · %d started · %d added_'):format(#data.epics, totals.done, totals.started, totals.added)
  local busy = vim.tbl_filter(function(s)
    return activity(s) > 0 or #s.overdue > 0
  end, data.epics)
  table.sort(busy, function(x, y)
    return activity(x) > activity(y)
  end)
  for _, s in ipairs(busy) do
    local e = s.epic
    local p = e.progress or { total = 0, done = 0 }
    local h = checks.health(e, now)
    lines[#lines + 1] = ''
    lines[#lines + 1] = ('## %s %s'):format(e.key, e.summary)
    lines[#lines + 1] = ('%s · %d%% (%d/%d) · due %s · %s'):format(e.status, r.percent(p), p.done, p.total, e.due and dates.short(e.due, now) or 'not set', h.text)
    for _, c in ipairs(s.changes) do
      lines[#lines + 1] = ('- %s: %s → %s'):format(c.field, value(c.from), value(c.to))
    end
    for _, part in ipairs({ { 'done', 'Done' }, { 'started', 'Started' }, { 'added', 'New' }, { 'overdue', 'Overdue' } }) do
      local items = s[part[1]]
      if #items > 0 then
        lines[#lines + 1] = ('- %s (%d)'):format(part[2], #items)
        for _, it in ipairs(items) do
          local extra = part[1] == 'overdue' and it.due and (' (due ' .. dates.short(it.due, now) .. ')') or ''
          lines[#lines + 1] = ('  - %s %s%s'):format(it.key, it.summary, extra)
        end
      end
    end
  end
  local quiet = vim.tbl_filter(function(s)
    return activity(s) == 0 and #s.overdue == 0
  end, data.epics)
  if #quiet > 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## No changes'
    for _, s in ipairs(quiet) do
      lines[#lines + 1] = ('- %s %s'):format(s.epic.key, s.epic.summary)
    end
  end
  return lines
end

local function set_lines(st, lines)
  if not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  vim.bo[st.buf].modifiable = true
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
  vim.bo[st.buf].modifiable = false
  vim.bo[st.buf].modified = false
  local win = vim.fn.bufwinid(st.buf)
  if win ~= -1 then
    vim.wo[win].winbar = ('%%#JiraTitle# Digest %%#JiraDim# last %d days%%=%%#JiraHint#Y copy · - / + days · ? help '):format(st.days)
  end
end

function M.load(st)
  set_lines(st, { ('# Weekly digest · last %d days'):format(st.days), '', '_loading…_' })
  a.run(function()
    return M.collect(st.days)
  end, function(err, data)
    st.version = store.version
    if err then
      return set_lines(st, { '# Weekly digest', '', 'Could not load: ' .. tostring(err) })
    end
    set_lines(st, M.render(data))
  end)
end

local function key_under_cursor()
  return vim.api.nvim_get_current_line():match(KEY)
end

function M.open(days, win)
  win = win or vim.api.nvim_get_current_win()
  days = days or config.digest.days
  local name = 'jira://digest'
  local buf = bufs.find(name)
  local prev = vim.api.nvim_win_get_buf(win)
  local st = buf ~= -1 and M.states[buf] or nil
  if st then
    vim.api.nvim_win_set_buf(win, buf)
    st.back = prev ~= buf and prev or st.back
    if days ~= st.days or st.version ~= store.version then
      st.days = days
      M.load(st)
    end
    return st
  end
  buf = bufs.scratch(name)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].bufhidden = 'hide'
  st = { buf = buf, days = days, back = prev }
  M.states[buf] = st
  vim.api.nvim_win_set_buf(win, buf)
  r.own_window(buf, { wrap = false, cursorline = true, number = false, relativenumber = false, signcolumn = 'no', foldenable = false, spell = false, list = false, conceallevel = 2 })
  keys.apply(buf, 'digest', {
    open = function()
      local key = key_under_cursor()
      if key then
        require('jira').open_key(key)
      end
    end,
    back = function()
      if st.back and vim.api.nvim_buf_is_valid(st.back) then
        vim.api.nvim_win_set_buf(0, st.back)
      end
    end,
    earlier = function()
      st.days = st.days + 1
      M.load(st)
    end,
    later = function()
      st.days = math.max(1, st.days - 1)
      M.load(st)
    end,
    copy = function()
      require('jira.ui.actions').yank(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'), 'digest', true)
      vim.notify('jira: digest copied', vim.log.levels.INFO)
    end,
    browser = function()
      local key = key_under_cursor()
      if key then
        require('jira.ui.actions').browser({ key = key })
      end
    end,
    refresh = function()
      M.load(st)
    end,
    help = function()
      keys.help('digest')
    end,
    close = function()
      require('jira.ui.layout').close()
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    callback = function()
      M.states[buf] = nil
    end,
  })
  M.load(st)
  return st
end

return M
