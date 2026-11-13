-- The main table. Shows a parent's children (epic -> tasks, initiative -> epics), a list of epics, or any JQL result.
-- view = { kind = 'epic', key = 'PROJ-1' } | { kind = 'epics' | 'tasks', name = '...', jql = '...' }
-- view = { kind = 'sprint', name, jql, sprint = { name, goal, startDate, endDate }, board, group = 'status' }
local a = require('jira.async')
local actions = require('jira.ui.actions')
local api = require('jira.api')
local cache = require('jira.cache')
local checks = require('jira.checks')
local config = require('jira.config')
local dates = require('jira.dates')
local hl = require('jira.ui.hl')
local keys = require('jira.ui.keys')
local r = require('jira.ui.render')
local store = require('jira.ui.store')

local M = {}

M.states = {} -- buf -> state

local SORTS = { 'rank', 'status', 'due', 'assignee', 'updated', 'priority' }
local GROUPS = { 'none', 'status', 'assignee' }
local CAT_ORDER = { indeterminate = 1, new = 2, done = 3 }
local PRIORITY = { Highest = 1, Must = 1, Blocker = 1, Critical = 1, High = 2, Should = 2, Major = 2, Medium = 3, Could = 3, Low = 4, Minor = 4, Lowest = 5, Trivial = 5 }

local function is_container(kind)
  return vim.tbl_contains(config.container_types, kind)
end

-- columns -------------------------------------------------------------------

local function health_of(it)
  return checks.health(it)
end

local function flag_parts(it)
  local f, i, parts = it._flags or {}, config.icons, {}
  if f.blocked then
    parts[#parts + 1] = { i.blocked, 'JiraOverdue' }
  end
  if f.late then
    parts[#parts + 1] = { i.late, 'JiraOverdue' }
  end
  if f.stale then
    parts[#parts + 1] = { i.stale, 'JiraSoon' }
  end
  return parts
end

local COLUMNS = {
  rank = {
    title = '#',
    align = 'right',
    get = function(it)
      return tostring(it._rank)
    end,
    group = 'JiraDim',
  },
  flags = {
    title = '!',
    show = function(rows)
      for _, it in ipairs(rows) do
        if next(it._flags or {}) then
          return true
        end
      end
      return false
    end,
    get = function(it)
      local s = ''
      for _, p in ipairs(flag_parts(it)) do
        s = s .. p[1]
      end
      return s
    end,
    draw = function(b, it, w)
      local used = 0
      for _, p in ipairs(flag_parts(it)) do
        b:add(p[1], p[2])
        used = used + r.width(p[1])
      end
      b:add(string.rep(' ', math.max(0, w - used)))
    end,
  },
  key = {
    title = 'Key',
    get = function(it)
      return it.key
    end,
    group = 'JiraKey',
  },
  type = {
    title = 'Type',
    max = 9,
    get = function(it)
      return it.type
    end,
    group = 'JiraDim',
  },
  status = {
    title = 'Status',
    max = 22,
    get = function(it)
      return r.status_icon(it.cat) .. ' ' .. it.status
    end,
    -- tint only the text, like a status lozenge
    draw = function(b, it, w)
      local t = r.trunc(r.status_icon(it.cat) .. ' ' .. it.status, w)
      b:add(t, hl.CHIP[it.cat]):add(string.rep(' ', w - r.width(t)))
    end,
  },
  assignee = {
    title = 'Assignee',
    max = 18,
    get = function(it)
      return it.assignee or '—'
    end,
    group = function(it, st)
      if not it.assignee then
        return 'JiraDim'
      end
      return st.me and it.assignee_id == st.me and 'JiraMe' or nil
    end,
  },
  priority = {
    title = 'Pri',
    max = 8,
    get = function(it)
      return it.priority or '—'
    end,
  },
  points = {
    title = 'Pts',
    align = 'right',
    show = function(rows)
      for _, it in ipairs(rows) do
        if it.points then
          return true
        end
      end
      return false
    end,
    get = function(it)
      return it.points and tostring(it.points) or ''
    end,
  },
  start = {
    title = 'Start',
    get = function(it)
      return it.start and dates.short(it.start) or '—'
    end,
    group = function(it)
      return it.start and nil or 'JiraDim'
    end,
  },
  due = {
    title = 'Due',
    get = function(it)
      return it.due and dates.short(it.due) or '—'
    end,
    group = function(it)
      if not it.due then
        return 'JiraDim'
      end
      if it._flags and it._flags.late then
        return 'JiraOverdue'
      end
      local h = health_of(it)
      return (h.level == 'overdue' or h.level == 'soon') and hl.HEALTH[h.level] or nil
    end,
  },
  left = {
    title = 'Health',
    max = 26,
    get = function(it)
      local h = health_of(it)
      return (h.level ~= 'ok' and h.level ~= 'done' and (config.icons.warn .. ' ') or '') .. h.text
    end,
    group = function(it)
      return hl.HEALTH[health_of(it).level]
    end,
  },
  updated = {
    title = 'Upd',
    align = 'right',
    get = function(it)
      return r.ago(it.updated)
    end,
    group = function(it)
      return it._flags and it._flags.stale and 'JiraSoon' or 'JiraDim'
    end,
  },
  parent = {
    title = 'Epic',
    get = function(it)
      return it.parent_key or '—'
    end,
    group = 'JiraEpic',
  },
  progress = {
    title = 'Progress',
    width = 19,
    draw = function(b, it, w)
      local p = it.progress
      local label = p and p.total > 0 and (' %3d%%'):format(r.percent(p)) or '    —'
      r.progress_bar(b, p, w - #label)
      b:add(label, 'JiraDim')
    end,
  },
  summary = {
    title = 'Summary',
    flex = true,
    get = function(it)
      return it.summary
    end,
  },
}

-- Rows are epics (or other containers) when the view lists epics, or the parent is an initiative.
local function rows_are_parents(st)
  return st.view.kind == 'epics' or st.child_parents
end

local function columns_for(st, rows)
  local list = vim.deepcopy(config.columns[rows_are_parents(st) and 'epics' or 'tasks'])
  if (st.view.kind == 'tasks' or st.view.kind == 'sprint') and not vim.tbl_contains(list, 'parent') then
    list[#list + 1] = 'parent'
  end
  return vim.tbl_filter(function(name)
    local c = COLUMNS[name]
    return c and (not c.show or c.show(rows))
  end, list)
end

-- data ----------------------------------------------------------------------

local function visible(st)
  local out = {}
  local needle = st.filter and st.filter:lower()
  for i, it in ipairs(st.items) do
    it._rank = i
    it._flags = (st.view.kind == 'epic' or st.view.kind == 'sprint') and checks.row(st.epic, it) or {}
    local keep = not (st.hide_done and it.cat == 'done')
    if keep and needle then
      local hay = table.concat({ it.key, it.summary, it.assignee or '', it.status, it.type, table.concat(it.labels or {}, ' ') }, ' '):lower()
      keep = hay:find(needle, 1, true) ~= nil
    end
    if keep then
      out[#out + 1] = it
    end
  end
  local s = st.sort
  if s ~= 'rank' then
    local function k(it)
      if s == 'status' then
        return ('%d%s'):format(CAT_ORDER[it.cat] or 9, it.status)
      elseif s == 'due' then
        return it.due or '9999'
      elseif s == 'assignee' then
        return (it.assignee or '~'):lower()
      elseif s == 'updated' then
        return it.updated or ''
      elseif s == 'priority' then
        return tostring(PRIORITY[it.priority] or 9)
      end
      return ''
    end
    table.sort(out, function(x, y)
      local kx, ky = k(x), k(y)
      if kx == ky then
        return x._rank < y._rank
      end
      if s == 'updated' then
        return kx > ky
      end
      return kx < ky
    end)
  end
  if st.reverse then
    local n = #out
    for i = 1, math.floor(n / 2) do
      out[i], out[n - i + 1] = out[n - i + 1], out[i]
    end
  end
  return out
end

local function group_name(st, it)
  if st.group == 'status' then
    return it.status
  elseif st.group == 'assignee' then
    return it.assignee or 'Unassigned'
  end
end

-- { { name = 'In Progress', cat = 'indeterminate', rows = {...} }, ... } in display order
local function grouped(st, rows)
  if st.group == 'none' then
    return { { rows = rows } }
  end
  local by, list = {}, {}
  for _, it in ipairs(rows) do
    local name = group_name(st, it)
    if not by[name] then
      by[name] = { name = name, cat = it.cat, rows = {} }
      list[#list + 1] = by[name]
    end
    table.insert(by[name].rows, it)
  end
  table.sort(list, function(x, y)
    if st.group == 'status' then
      local cx, cy = CAT_ORDER[x.cat] or 9, CAT_ORDER[y.cat] or 9
      if cx ~= cy then
        return cx < cy
      end
    elseif (x.name == 'Unassigned') ~= (y.name == 'Unassigned') then
      return y.name == 'Unassigned'
    end
    return x.name:lower() < y.name:lower()
  end)
  return list
end

-- drawing -------------------------------------------------------------------

local function draw_progress(b, p, bar)
  b:nl():add('   Progress  ', 'JiraLabel')
  r.progress_bar(b, p, bar)
  b:add(('  %d%%  '):format(r.percent(p)), 'JiraHeader')
  b:add(('%d done'):format(p.done), 'JiraDone'):add(' · ', 'JiraDim')
  b:add(('%d in progress'):format(p.indeterminate), 'JiraProgress'):add(' · ', 'JiraDim')
  b:add(('%d to do'):format(p.new), 'JiraTodo')
  if p.points > 0 then
    b:add(('   %s/%s pts'):format(p.points_done, p.points), 'JiraDim')
  end
end

local function draw_parent_header(b, st)
  local e = st.epic
  if not e then
    return
  end
  local width = st.width
  local function mark()
    st.header_rows[b:row()] = true
  end
  b:nl():add(' ' .. config.icons.epic .. ' ', 'JiraEpic'):add(e.key, 'JiraKey'):add('  '):add(r.trunc(e.summary, width - #e.key - 8), 'JiraTitle')
  mark()
  b:nl():add('   '):add(' ' .. r.status_icon(e.cat) .. ' ' .. e.status .. ' ', hl.CHIP[e.cat])
  b:add('  ' .. e.type, 'JiraDim')
  b:add('  ·  ', 'JiraDim'):add(e.assignee or 'Unassigned', e.assignee and 'JiraHeader' or 'JiraDim')
  if e.priority then
    b:add('  ·  ', 'JiraDim'):add(e.priority)
  end
  if e.parent_key then
    b:add('  ·  ', 'JiraDim'):add('↑ ' .. e.parent_key, 'JiraEpic'):add(' ' .. r.trunc(e.parent_summary or '', 40), 'JiraDim')
  end
  mark()
  b:nl()
  mark()
  local bar = math.max(10, math.min(40, width - 50))
  b:nl():add('   Timeline  ', 'JiraLabel')
  r.timeline(b, e.start, e.due, e.cat, bar)
  mark()
  draw_progress(b, api.progress_of(st.items), bar)
  mark()
  -- date and progress checks between the parent and its children
  local findings, suggest = checks.parent(e, st.items)
  st.suggest_due = suggest
  for i, f in ipairs(findings) do
    b:nl():add(i == 1 and '   Checks    ' or '             ', 'JiraLabel')
    b:add((f.level == 'warn' and config.icons.warn or '·') .. ' ', f.level == 'warn' and 'JiraSoon' or 'JiraDim')
    b:add(r.trunc(f.text, width - 34), f.level == 'warn' and 'JiraSoon' or 'JiraDim')
    if f.apply_due then
      b:add('  D', 'JiraKey'):add(' sets it', 'JiraHint')
    end
    mark()
  end
  b:nl()
end

local function draw_sprint_header(b, st)
  local s = st.view.sprint
  if not s then
    return
  end
  local width = st.width
  local bar = math.max(10, math.min(40, width - 50))
  b:nl():add(' ' .. config.icons.stale .. ' ', 'JiraEpic'):add(s.name or 'Sprint', 'JiraTitle')
  if st.view.board then
    b:add('  ' .. st.view.board.name, 'JiraDim')
  end
  if s.goal and s.goal ~= '' then
    b:nl():add('   Goal      ', 'JiraLabel'):add(r.trunc(s.goal, width - 16))
  end
  local finish = dates.local_date(s.endDate)
  b:nl():add('   Sprint    ', 'JiraLabel')
  r.timeline(b, dates.local_date(s.startDate), finish, 'indeterminate', bar)
  local p = api.progress_of(st.items)
  draw_progress(b, p, bar)
  local left = dates.days_until(finish)
  local stale = 0
  for _, it in ipairs(st.items) do
    stale = stale + (checks.row(nil, it).stale and 1 or 0)
  end
  local found = {}
  if left and p.new > 0 and left <= config.due_soon_days then
    local when = left < 0 and ('the sprint ended %dd ago'):format(-left) or left == 0 and 'the sprint ends today' or (left .. 'd left in the sprint')
    found[#found + 1] = ('%d not started, %s'):format(p.new, when)
  end
  if stale > 0 then
    found[#found + 1] = ('%d in progress with no update for %d+ days'):format(stale, config.stale_days)
  end
  for i, text in ipairs(found) do
    b:nl():add(i == 1 and '   Checks    ' or '             ', 'JiraLabel'):add(config.icons.warn .. ' ' .. r.trunc(text, width - 18), 'JiraSoon')
  end
  b:nl()
end

-- list views come from the disk cache first, so they draw before the network answers
local function cache_id(view)
  if view.kind == 'epics' or view.kind == 'tasks' then
    return view.kind .. ':' .. view.jql
  end
end

local function draw(st)
  local buf = st.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local win = vim.fn.bufwinid(buf)
  st.width = win ~= -1 and vim.api.nvim_win_get_width(win) or vim.o.columns
  local cursor_key = st.cursor_key
  st.cursor_key = nil
  if not cursor_key and win ~= -1 and st.row_items then
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    local it = st.row_items[row]
    cursor_key = it and it.key or (st.group_rows[row] and ('group:' .. st.group_rows[row])) or nil
  end

  local b = r.builder()
  st.row_items, st.header_rows, st.group_rows = {}, {}, {}
  if st.view.kind == 'epic' then
    draw_parent_header(b, st)
  elseif st.view.kind == 'sprint' then
    draw_sprint_header(b, st)
  end

  local rows = visible(st)
  local cols = columns_for(st, rows)
  local widths, fixed = {}, 0
  for _, name in ipairs(cols) do
    local c = COLUMNS[name]
    -- room for the sort arrow
    local w = c.width or (r.width(c.title) + (name == st.sort and 2 or 0))
    if not c.width and not c.flex then
      for _, it in ipairs(rows) do
        w = math.max(w, r.width(c.get(it)))
      end
      w = math.min(w, c.max or 99)
    end
    widths[name] = w
    if not c.flex then
      fixed = fixed + w + 3
    end
  end
  -- Summary takes what is left (borders take 1 + 3 per column), but no more than its longest text,
  -- so columns after it stay close instead of being pushed to the window edge.
  local longest = r.width(COLUMNS.summary.title)
  for _, it in ipairs(rows) do
    longest = math.max(longest, r.width(it.summary))
  end
  -- at least 30 wide: on a narrow window the last columns scroll off rather than the titles
  widths.summary = math.max(math.min(30, longest), math.min(longest, st.width - fixed - 4 - 2))
  local inner = #cols - 1
  for _, name in ipairs(cols) do
    inner = inner + widths[name] + 2
  end

  local function border(l, m, rgt)
    b:nl():add(' ')
    local parts = {}
    for _, name in ipairs(cols) do
      parts[#parts + 1] = string.rep('─', widths[name] + 2)
    end
    b:add(l .. table.concat(parts, m) .. rgt, 'JiraBorder')
  end

  local any_flags = false
  if #st.items == 0 and not st.loading then
    b:nl():add('   ' .. (st.error or 'Nothing here.'), st.error and 'JiraOverdue' or 'JiraDim')
    if st.view.kind == 'epic' and not st.error then
      b:nl():add('   a', 'JiraKey'):add(' add one   ', 'JiraHint'):add('P', 'JiraKey'):add(' add many (one per line)   ', 'JiraHint')
      b:add('A', 'JiraKey'):add(' add with all fields', 'JiraHint')
    end
  else
    border('╭', '┬', '╮')
    b:nl():add(' ')
    b:add('│', 'JiraBorder')
    for _, name in ipairs(cols) do
      local c = COLUMNS[name]
      local title = c.title
      if name == st.sort then
        title = title .. (st.reverse and ' ↑' or ' ↓')
      end
      b:add(' ' .. r.pad(title, widths[name], c.align == 'right') .. ' ', 'JiraHeaderRow'):add('│', 'JiraBorder')
    end
    border('├', '┼', '┤')
    local n = 0
    for _, g in ipairs(grouped(st, rows)) do
      local closed = g.name and st.collapsed[g.name]
      if g.name then
        local icon = closed and config.icons.collapsed or config.icons.expanded
        b:nl():add(' '):add('│', 'JiraBorder')
        b:add(' ' .. icon .. ' ', 'JiraDim')
        local label = (st.group == 'status' and (r.status_icon(g.cat) .. ' ') or '') .. g.name
        b:add(label, st.group == 'status' and hl.CAT[g.cat] or 'JiraHeader')
        b:add(('  %d'):format(#g.rows), 'JiraDim')
        b:add(string.rep(' ', math.max(0, inner - 3 - r.width(label) - #tostring(#g.rows) - 2)))
        b:add('│', 'JiraBorder')
        b:line_hl('JiraHeaderRow')
        st.group_rows[b:row()] = g.name
        n = 0
      end
      for _, it in ipairs(closed and {} or g.rows) do
        n = n + 1
        b:nl():add(' ')
        b:add('│', 'JiraBorder')
        for _, name in ipairs(cols) do
          local c = COLUMNS[name]
          b:add(' ')
          if c.draw then
            c.draw(b, it, widths[name])
          else
            local group = type(c.group) == 'function' and c.group(it, st) or c.group
            b:add(r.pad(c.get(it), widths[name], c.align == 'right'), group)
          end
          b:add(' '):add('│', 'JiraBorder')
        end
        if n % 2 == 0 then
          b:line_hl('JiraZebra')
        end
        any_flags = any_flags or next(it._flags or {}) ~= nil
        st.row_items[b:row()] = it
      end
    end
    border('╰', '┴', '╯')
    local foot = {}
    if #rows < #st.items then
      foot[#foot + 1] = ('%d of %d shown'):format(#rows, #st.items)
    end
    if any_flags then
      local i = config.icons
      foot[#foot + 1] = ('%s due after the %s   %s no update for %d+ days   %s blocked'):format(i.late, st.epic and st.epic.type:lower() or 'parent', i.stale, config.stale_days, i.blocked)
    end
    if #foot > 0 then
      b:nl():add('   ' .. table.concat(foot, '   ·   '), 'JiraDim')
    end
  end
  b:render(buf)

  -- keep the cursor on the same issue (or group header) across redraws
  if win ~= -1 then
    local target
    for row, it in pairs(st.row_items) do
      if it.key == cursor_key then
        target = row
      end
    end
    for row, name in pairs(st.group_rows) do
      if ('group:' .. name) == cursor_key then
        target = row
      end
    end
    if not target then
      for row in pairs(st.row_items) do
        target = math.min(target or row, row)
      end
      for row in pairs(st.group_rows) do
        target = math.min(target or row, row)
      end
    end
    pcall(vim.api.nvim_win_set_cursor, win, { (target or 0) + 1, 2 })
  end
  M.winbar(st)
end

function M.winbar(st)
  local win = vim.fn.bufwinid(st.buf)
  if win == -1 then
    return
  end
  local title = st.view.kind == 'epic' and st.view.key or st.view.name
  local parts = { '%#JiraTitle# ' .. title:gsub('%%', '%%%%') .. ' ' }
  if st.loading and st.cached_at then
    parts[#parts + 1] = ('%%#JiraHint# %d %s · saved %s, refreshing…'):format(#st.items, rows_are_parents(st) and 'epics' or 'issues', r.age_text(st.cached_at))
  elseif st.loading then
    parts[#parts + 1] = '%#JiraHint# loading…'
  else
    parts[#parts + 1] = ('%%#JiraDim# %d %s'):format(#st.items, rows_are_parents(st) and 'epics' or 'issues')
  end
  parts[#parts + 1] = '%#JiraDim# · sort ' .. st.sort .. (st.reverse and ' ↑' or '')
  if st.group ~= 'none' then
    parts[#parts + 1] = '%#JiraSoon# · grouped by ' .. st.group
  end
  if st.filter then
    parts[#parts + 1] = '%#JiraSoon# · filter "' .. st.filter:gsub('%%', '%%%%') .. '"'
  end
  if st.hide_done then
    parts[#parts + 1] = '%#JiraSoon# · done hidden'
  end
  parts[#parts + 1] = '%=%#JiraHint#V select rows · ? help '
  vim.wo[win].winbar = table.concat(parts)
end

-- loading -------------------------------------------------------------------

-- Coroutine: the data behind a view. Returns { parent, items, child_parents }.
function M.fetch(view)
  if view.kind == 'epic' then
    local key = view.key
    local list = a.all({
      a.starter(api.issue, key),
      a.starter(api.children, key),
      -- blockers are a nice-to-have: never fail the grid over them
      a.starter(function()
        local ok, res = pcall(api.blocked, key)
        return ok and res or {}
      end),
    })
    local parent, items, blocked = list[1], list[2], list[3]
    local parents = false
    for _, it in ipairs(items) do
      it.blocked_by = blocked[it.key]
      parents = parents or is_container(it.type)
    end
    if parents then
      api.attach_progress(items)
      store.remember_epics(items)
    end
    parent.progress = api.progress_of(items)
    store.remember_epics({ parent })
    return { parent = parent, items = items, child_parents = parents }
  elseif view.kind == 'epics' then
    local items = store.memo('epics:' .. view.jql, 30, function()
      return api.epics(view.jql)
    end)
    store.remember_epics(items)
    return { items = items }
  end
  return { items = api.search(view.jql) }
end

function M.load(st)
  st.loading = true
  st.error = nil
  M.winbar(st)
  a.run(function()
    local data = M.fetch(st.view)
    st.epic, st.items, st.child_parents = data.parent, data.items, data.child_parents
    pcall(function()
      st.me = api.me()
    end)
  end, function(err)
    st.loading = false
    st.version = store.version
    if err then
      st.error = tostring(err)
      st.items = st.items or {}
      vim.notify('jira: ' .. st.error, vim.log.levels.ERROR)
    else
      st.cached_at = nil
      if cache_id(st.view) then
        cache.put(cache_id(st.view), st.items)
      end
    end
    draw(st)
  end)
end

-- row helpers ---------------------------------------------------------------

local function current(st)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local it = st.row_items[row]
  if it then
    return it
  end
  if st.header_rows[row] and st.epic then
    return st.epic
  end
end

-- The issues an action applies to: the visual selection, or the row under the cursor.
local function targets(st)
  local mode = vim.fn.mode()
  if mode == 'v' or mode == 'V' or mode == '\22' then
    local from, to = vim.fn.line('v'), vim.fn.line('.')
    if from > to then
      from, to = to, from
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
    local items = {}
    for row = from - 1, to - 1 do
      if st.row_items[row] then
        items[#items + 1] = st.row_items[row]
      end
    end
    return items
  end
  local it = current(st)
  return it and { it } or {}
end

local function reload(st)
  return function()
    M.load(st)
  end
end

local function ctx_for(st, it)
  return { key = it.key, item = it, refresh = reload(st) }
end

local function with_item(st, fn)
  return function()
    local it = current(st)
    if not it then
      return vim.notify('jira: no issue on this line', vim.log.levels.WARN)
    end
    fn(it)
  end
end

-- The parent that new issues go under: this grid's parent, the epic on the row, or the row's parent.
local function parent_for_new(st)
  if st.view.kind == 'epic' then
    return st.view.key, st.epic
  end
  local it = current(st)
  if it and is_container(it.type) then
    return it.key, it
  end
  if it and it.parent_key then
    return it.parent_key, store.epics[it.parent_key]
  end
end

-- Swap with the visible neighbour and tell Jira to rank before / after it.
local function move(st, dir)
  if st.view.kind ~= 'epic' then
    return vim.notify('jira: reordering works inside an epic', vim.log.levels.WARN)
  end
  if st.sort ~= 'rank' or st.reverse or st.group ~= 'none' then
    return vim.notify('jira: reordering needs sort = rank (o) and no grouping (gs)', vim.log.levels.WARN)
  end
  local it = st.row_items[vim.api.nvim_win_get_cursor(0)[1] - 1]
  if not it then
    return
  end
  local rows = visible(st)
  local idx
  for i, x in ipairs(rows) do
    if x == it then
      idx = i
    end
  end
  local other = rows[idx + dir]
  if not other then
    return
  end
  -- optimistic local reorder
  local from, to
  for i, x in ipairs(st.items) do
    if x == it then
      from = i
    elseif x == other then
      to = i
    end
  end
  table.remove(st.items, from)
  if from < to then
    to = to - 1
  end
  table.insert(st.items, dir > 0 and to + 1 or to, it)
  st.cursor_key = it.key
  draw(st)
  a.run(function()
    api.rank(it.key, dir > 0 and 'after' or 'before', other.key)
    store.changed()
    st.version = store.version
  end, function(err)
    if err then
      vim.notify('jira: reorder failed, reloading: ' .. tostring(err), vim.log.levels.ERROR)
      M.load(st)
    end
  end)
end

-- which = 'toggle' | true (open) | false (close); all = every group
local function fold(st, which, all)
  if st.group == 'none' then
    return vim.notify('jira: group rows first with gs, then fold the groups', vim.log.levels.INFO)
  end
  local names = {}
  if all then
    for _, g in ipairs(grouped(st, visible(st))) do
      names[#names + 1] = g.name
    end
  else
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local name = st.group_rows[row] or (st.row_items[row] and group_name(st, st.row_items[row]))
    if not name then
      return
    end
    names = { name }
    st.cursor_key = 'group:' .. name
  end
  for _, name in ipairs(names) do
    if which == 'toggle' then
      st.collapsed[name] = not st.collapsed[name] or nil
    else
      st.collapsed[name] = not which or nil
    end
  end
  draw(st)
end

-- Float with the description of the issue under the cursor.
local function peek(st)
  local it = current(st)
  if not it then
    return
  end
  a.run(function()
    local issue = api.issue(it.key)
    local body = require('jira.ui.detail').plain(issue.description or '', issue.format)
    local lines = { '# ' .. issue.summary, '' }
    vim.list_extend(lines, vim.split(body ~= '' and body or '_No description._', '\n'))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = 'markdown'
    vim.bo[buf].bufhidden = 'wipe'
    local width = math.min(100, math.floor(vim.o.columns * 0.6))
    local win = vim.api.nvim_open_win(buf, false, {
      relative = 'cursor',
      row = 1,
      col = 2,
      width = width,
      height = math.min(#lines + 1, math.floor(vim.o.lines * 0.5)),
      style = 'minimal',
      border = 'rounded',
      title = ' ' .. it.key .. ' · ' .. it.status .. ' ',
      title_pos = 'left',
    })
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].conceallevel = 2
    vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufLeave', 'InsertEnter' }, {
      buffer = st.buf,
      once = true,
      callback = function()
        pcall(vim.api.nvim_win_close, win, true)
      end,
    })
  end)
end

-- open ----------------------------------------------------------------------

local function buf_name(view)
  if view.kind == 'epic' then
    return 'jira://epic/' .. view.key
  end
  return 'jira://' .. view.kind .. '/' .. view.name
end

function M.open(view, win)
  win = win or vim.api.nvim_get_current_win()
  local name = buf_name(view)
  local buf = vim.fn.bufnr(name)
  local st = buf ~= -1 and M.states[buf] or nil
  local prev = vim.api.nvim_win_get_buf(win)
  if st then
    vim.api.nvim_win_set_buf(win, buf)
    st.back = prev ~= buf and prev or st.back
    if st.version ~= store.version then
      M.load(st)
    else
      draw(st)
    end
    return st
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].filetype = 'jira'
  vim.bo[buf].bufhidden = 'hide'
  st = {
    buf = buf,
    view = view,
    items = {},
    row_items = {},
    header_rows = {},
    group_rows = {},
    collapsed = {},
    sort = 'rank',
    group = view.group or 'none',
    hide_done = config.hide_done,
    back = prev,
  }
  local saved = cache_id(view) and cache.get(cache_id(view))
  if saved then
    st.items, st.cached_at = vim.deepcopy(saved.items), saved.at
  end
  M.states[buf] = st
  vim.api.nvim_win_set_buf(win, buf)
  -- folds off: the global foldmethod (often indent) would fold the table's border lines
  r.own_window(buf, {
    wrap = false,
    cursorline = true,
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    list = false,
    foldcolumn = '0',
    foldenable = false,
    spell = false,
    conceallevel = 0,
  })

  local function act(action)
    return with_item(st, function(it)
      actions[action](ctx_for(st, it))
    end)
  end

  -- field changes: work on the row under the cursor, or on every selected row
  local function op(op_name, arg)
    return function()
      local items = targets(st)
      if #items == 0 then
        return vim.notify('jira: no issue on this line', vim.log.levels.WARN)
      end
      actions.op(op_name, items, reload(st), arg)
    end
  end

  local function new_child(fn)
    return function()
      local key, parent = parent_for_new(st)
      if not key then
        return vim.notify('jira: open an epic first, or use N for a new epic', vim.log.levels.WARN)
      end
      fn(key, reload(st), parent)
    end
  end

  keys.apply(buf, 'grid', {
    open = with_item(st, function(it)
      if is_container(it.type) and not (st.view.kind == 'epic' and st.view.key == it.key) then
        M.open({ kind = 'epic', key = it.key })
      else
        require('jira.ui.detail').open(it.key)
      end
    end),
    peek = function()
      peek(st)
    end,
    back = function()
      if st.back and vim.api.nvim_buf_is_valid(st.back) then
        vim.api.nvim_win_set_buf(0, st.back)
      end
    end,
    sidebar = function()
      require('jira.ui.layout').focus_sidebar()
    end,
    find = function()
      require('jira.ui.finder').open()
    end,
    timeline = function()
      require('jira.ui.timeline').open(st.view)
    end,
    changes = function()
      local key = parent_for_new(st)
      if not key then
        return vim.notify('jira: put the cursor on an epic', vim.log.levels.WARN)
      end
      require('jira.ui.changes').open(key)
    end,
    sprint_view = function()
      local it = current(st)
      local key = (it and it.key) or (st.view.kind == 'epic' and st.view.key) or nil
      require('jira').sprint(key and key:match('^(%u[%u%d_]*)%-') or nil)
    end,
    digest = function()
      require('jira.ui.layout').show_digest()
    end,
    status = op('status'),
    assign_me = op('assign_me'),
    assign = op('assign'),
    priority = op('priority'),
    points = op('points'),
    start_work = op('start_work'),
    log_work = act('log_work'),
    labels = op('labels'),
    sprint = op('sprint'),
    link = op('link'),
    move_epic = op('move_epic'),
    start = op('date', { which = 'start' }),
    due = op('date', { which = 'due' }),
    summary = act('summary'),
    description = act('description'),
    comment = act('comment'),
    apply_due = function()
      if not (st.epic and st.suggest_due) then
        return vim.notify('jira: no later child due date to apply', vim.log.levels.INFO)
      end
      local e = st.epic
      local msg = ('Set %s due date to %s%s?'):format(e.key, st.suggest_due, e.due and (' (now ' .. e.due .. ')') or '')
      if vim.fn.confirm(msg, '&Yes\n&No', 1) == 1 then
        actions.date(ctx_for(st, e), 'due', st.suggest_due)
      end
    end,
    undo = function()
      actions.undo(reload(st))
    end,
    add = new_child(actions.quick_add),
    add_form = new_child(actions.add_form),
    plan = new_child(actions.plan),
    new = function()
      local _, parent = parent_for_new(st)
      actions.new_menu({ parent = parent, refresh = reload(st) })
    end,
    move_down = function()
      move(st, 1)
    end,
    move_up = function()
      move(st, -1)
    end,
    group = function()
      local i = 1
      for n, g in ipairs(GROUPS) do
        if g == st.group then
          i = n
        end
      end
      st.group = GROUPS[i % #GROUPS + 1]
      st.collapsed = {}
      draw(st)
    end,
    fold_toggle = function()
      fold(st, 'toggle')
    end,
    fold_open = function()
      fold(st, true)
    end,
    fold_close = function()
      fold(st, false)
    end,
    fold_open_all = function()
      fold(st, true, true)
    end,
    fold_close_all = function()
      fold(st, false, true)
    end,
    sort = function()
      local i = 1
      for n, s in ipairs(SORTS) do
        if s == st.sort then
          i = n
        end
      end
      st.sort = SORTS[i % #SORTS + 1]
      st.reverse = false
      draw(st)
    end,
    reverse = function()
      st.reverse = not st.reverse
      draw(st)
    end,
    filter = function()
      vim.ui.input({ prompt = 'Filter: ', default = st.filter or '' }, function(v)
        if v == nil then
          return
        end
        st.filter = v ~= '' and v or nil
        draw(st)
      end)
    end,
    clear_filter = function()
      st.filter = nil
      draw(st)
    end,
    hide_done = function()
      st.hide_done = not st.hide_done
      draw(st)
    end,
    browser = act('browser'),
    yank_key = act('yank_key'),
    yank_url = act('yank_url'),
    yank_branch = act('yank_branch'),
    refresh = function()
      store.changed()
      M.load(st)
    end,
    help = function()
      keys.help('grid')
    end,
    close = function()
      require('jira.ui.layout').close()
    end,
  })

  local group = vim.api.nvim_create_augroup('jira_grid_' .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = group,
    callback = function()
      local w = vim.fn.bufwinid(buf)
      if w ~= -1 and vim.api.nvim_win_get_width(w) ~= st.width then
        draw(st)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    buffer = buf,
    callback = function()
      if st.version and st.version ~= store.version and not st.loading then
        M.load(st)
      else
        M.winbar(st)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      M.states[buf] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  draw(st)
  M.load(st)
  return st
end

-- for tests
M._draw = draw
M._visible = visible

return M
