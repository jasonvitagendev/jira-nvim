-- Left drawer: sections of epics (with progress and date health) and task lists.
local a = require('jira.async')
local actions = require('jira.ui.actions')
local api = require('jira.api')
local bufs = require('jira.ui.bufs')
local cache = require('jira.cache')
local config = require('jira.config')
local dates = require('jira.dates')
local hl = require('jira.ui.hl')
local keys = require('jira.ui.keys')
local r = require('jira.ui.render')
local store = require('jira.ui.store')
local checks = require('jira.checks')

local function is_container(t)
  return vim.tbl_contains(config.container_types, t)
end

local M = {}

local st = { buf = nil, sections = nil, rows = {}, warned = false, site = nil, me = nil }

local function cache_id(sec)
  return not sec.search and (sec.view.kind .. ':' .. sec.view.jql) or nil
end

local function sections()
  if not st.sections then
    st.sections = {}
    for _, v in ipairs(config.views) do
      local sec = { view = v, expanded = v.expanded ~= false and v.kind == 'epics', items = nil }
      -- last known list from disk, shown until the fresh one arrives
      local saved = cache.get(cache_id(sec))
      if saved then
        sec.items, sec.cached_at = saved.items, saved.at
        store.remember_epics(v.kind == 'epics' and saved.items or {})
      end
      st.sections[#st.sections + 1] = sec
    end
  end
  return st.sections
end

-- drawing -------------------------------------------------------------------

local function draw()
  local buf = st.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local win = vim.fn.bufwinid(buf)
  local width = win ~= -1 and vim.api.nvim_win_get_width(win) or config.sidebar_width
  local keep
  if win ~= -1 then
    local row = st.rows[vim.api.nvim_win_get_cursor(win)[1] - 1]
    keep = row and (row.item and row.item.key or ('section:' .. row.section))
  end

  local b = r.builder()
  st.rows = {}
  b:nl():add(' ' .. config.icons.epic .. ' Jira', 'JiraTitle'):add(st.site and ('  ' .. st.site) or '', 'JiraDim')
  b:nl():add(' ' .. string.rep('─', width - 2), 'JiraBorder')
  for si, sec in ipairs(sections()) do
    b:nl()
    b:nl():add(' ' .. (sec.expanded and config.icons.expanded or config.icons.collapsed) .. ' ', 'JiraDim')
    b:add(sec.view.name, 'JiraSection')
    if sec.items and sec.cached_at then
      b:add('  ' .. #sec.items, 'JiraDim'):add('  ' .. r.age_text(sec.cached_at) .. (sec.loading and ' ↻' or ''), 'JiraHint')
    elseif sec.loading then
      b:add('  …', 'JiraDim')
    elseif sec.items then
      b:add('  ' .. #sec.items, 'JiraDim')
    end
    st.rows[b:row()] = { section = si }
    if sec.expanded then
      if sec.error then
        b:nl():add('   ' .. r.trunc(sec.error, width - 4), 'JiraOverdue')
      elseif sec.items and #sec.items == 0 then
        b:nl():add('   nothing here', 'JiraDim')
      end
      for _, it in ipairs(sec.items or {}) do
        local mine = st.me and it.assignee_id == st.me
        if sec.view.kind == 'epics' then
          local h = checks.health(it)
          local flag = mine and checks.needs_attention(it)
          b:nl():add('  ' .. r.status_icon(it.cat) .. ' ', hl.CAT[it.cat]):add(it.key, 'JiraKey'):add(' ')
          local used = 5 + #it.key
          local due = it.due and dates.short(it.due) or 'no due'
          local bar_w = math.max(4, math.min(10, width - used - #due - 9))
          r.progress_bar(b, it.progress, bar_w)
          b:add((' %3d%%'):format(r.percent(it.progress)), 'JiraDim')
          b:add(' ' .. (flag and config.icons.warn or ' '), 'JiraOverdue')
          b:add(due, hl.HEALTH[h.level])
          st.rows[b:row()] = { section = si, item = it }
          b:nl():add('    ' .. r.trunc(it.summary, width - 5), mine and 'Normal' or 'JiraDim')
          st.rows[b:row()] = { section = si, item = it }
        else
          b:nl():add('  ' .. r.status_icon(it.cat) .. ' ', hl.CAT[it.cat]):add(it.key, 'JiraKey')
          b:add(' ' .. r.trunc(it.summary, width - #it.key - 7))
          st.rows[b:row()] = { section = si, item = it }
        end
      end
    end
  end
  b:nl()
  b:nl():add((' ? help  / search  %s find  N new'):format(keys.lhs('sidebar', 'find') or ''), 'JiraHint')
  b:render(buf)

  if win ~= -1 and keep then
    for row, info in pairs(st.rows) do
      local id = info.item and info.item.key or ('section:' .. info.section)
      if id == keep then
        pcall(vim.api.nvim_win_set_cursor, win, { row + 1, 0 })
        break
      end
    end
  end
end

-- Nudge about my epics with stale dates (once per session).
local function check_dates()
  if st.warned or not st.me then
    return
  end
  local seen, bad = {}, {}
  for _, sec in ipairs(sections()) do
    if sec.view.kind == 'epics' then
      for _, it in ipairs(sec.items or {}) do
        if it.assignee_id == st.me and not seen[it.key] then
          seen[it.key] = true
          if checks.needs_attention(it) then
            bad[#bad + 1] = ('%s (%s)'):format(it.key, checks.health(it).text)
          end
        end
      end
    end
  end
  if #bad > 0 then
    st.warned = true
    vim.notify(('jira: %d of your epics need attention: %s. Use ds / dd / s on them.'):format(#bad, table.concat(bad, ', ')), vim.log.levels.WARN)
  end
end

local function load_section(sec)
  sec.loading, sec.error = true, nil
  draw()
  a.run(function()
    if sec.view.kind == 'epics' then
      sec.items = store.memo('epics:' .. sec.view.jql, 30, function()
        return api.epics(sec.view.jql)
      end)
      store.remember_epics(sec.items)
    else
      sec.items = api.search(sec.view.jql, { limit = 100 })
    end
  end, function(err)
    sec.loading = false
    sec.version = store.version
    if err then
      -- keep showing the saved list (still marked with its age) when offline
      sec.error = tostring(err)
      sec.items = sec.items or {}
    else
      sec.cached_at = nil
      if cache_id(sec) then
        cache.put(cache_id(sec), sec.items)
      end
    end
    draw()
    check_dates()
  end)
end

function M.refresh(force)
  if force then
    store.changed()
  end
  a.run(function()
    st.site = api.site().host
    st.me = api.me()
    cache.set_me(st.me)
  end, function(err)
    if err then
      vim.notify('jira: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end
    for _, sec in ipairs(sections()) do
      if sec.expanded then
        load_section(sec)
      else
        sec.items = nil
      end
    end
    draw()
  end)
end

-- keymaps -------------------------------------------------------------------

local function current()
  return st.rows[vim.api.nvim_win_get_cursor(0)[1] - 1]
end

local function with_item(fn)
  return function()
    local row = current()
    if not (row and row.item) then
      return vim.notify('jira: put the cursor on an issue', vim.log.levels.WARN)
    end
    fn(row.item)
  end
end

local function ctx(it)
  return {
    key = it.key,
    item = it,
    refresh = function()
      M.refresh(true)
    end,
  }
end

local function jump(dir)
  local cur = vim.api.nvim_win_get_cursor(0)[1] - 1
  local here = st.rows[cur] and st.rows[cur].item
  local n = vim.api.nvim_buf_line_count(st.buf)
  local row = cur + dir
  while row >= 0 and row < n do
    local info = st.rows[row]
    if info and info.item and info.item ~= here then
      -- land on the first line of an entry
      while st.rows[row - 1] and st.rows[row - 1].item == info.item do
        row = row - 1
      end
      vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
      return
    end
    row = row + dir
  end
end

-- row = cursor row info (nil = every section); want = true | false | 'toggle'
local function set_expanded(row, want)
  local targets = {}
  if row then
    targets[row.section] = sections()[row.section]
  else
    for i, sec in ipairs(sections()) do
      targets[i] = sec
    end
  end
  for _, sec in pairs(targets) do
    local open = want == 'toggle' and not sec.expanded or want == true
    sec.expanded = open
    if open and (not sec.items or sec.version ~= store.version) and not sec.loading then
      load_section(sec)
    end
  end
  draw()
  -- like zc: when the section closes, land on its header
  if row and not sections()[row.section].expanded then
    for r_, info in pairs(st.rows) do
      if info.section == row.section and not info.item then
        vim.api.nvim_win_set_cursor(0, { r_ + 1, 0 })
        break
      end
    end
  end
end

function M.search(query)
  query = vim.trim(query or '')
  if query == '' then
    return
  end
  if query:match('^%u[%u%d_]*%-%d+$') then
    return require('jira').open_key(query)
  end
  local is_jql = query:match('[=~]') or query:match('%s[Oo][Rr][Dd][Ee][Rr]%s') or query:match('%s[Ii][Nn]%s*%(')
  local jql = is_jql and query or ('issuetype = Epic AND text ~ "%s" ORDER BY updated DESC'):format((query:gsub('["\\]', '\\%0')))
  local secs = sections()
  local sec = secs[1] and secs[1].search and secs[1] or nil
  if not sec then
    sec = { search = true }
    table.insert(secs, 1, sec)
  end
  sec.view = { name = 'Search: ' .. query, kind = is_jql and 'tasks' or 'epics', jql = jql }
  sec.expanded = true
  load_section(sec)
end

function M.open_in(win)
  if not (st.buf and vim.api.nvim_buf_is_valid(st.buf)) then
    st.buf = bufs.scratch('jira://sidebar')
    vim.bo[st.buf].filetype = 'jira'
    vim.bo[st.buf].bufhidden = 'hide'
    local saved_site = api.site_cached()
    st.site = st.site or (saved_site and saved_site.host)
    st.me = st.me or cache.me()
    local buf = st.buf
    keys.apply(buf, 'sidebar', {
      open = function()
        local row = current()
        if not row then
          return
        end
        local layout = require('jira.ui.layout')
        if row.item then
          if is_container(row.item.type) then
            layout.show_grid({ kind = 'epic', key = row.item.key })
          else
            layout.show_detail(row.item.key)
          end
        else
          local sec = sections()[row.section]
          if not sec.expanded then
            sec.expanded = true
            if not sec.items then
              load_section(sec)
            end
            draw()
          end
          layout.show_grid(sec.view)
        end
      end,
      toggle = function()
        set_expanded(current(), 'toggle')
      end,
      fold_toggle = function()
        set_expanded(current(), 'toggle')
      end,
      fold_open = function()
        set_expanded(current(), true)
      end,
      fold_close = function()
        set_expanded(current(), false)
      end,
      fold_open_all = function()
        set_expanded(nil, true)
      end,
      fold_close_all = function()
        set_expanded(nil, false)
      end,
      next_epic = function()
        jump(1)
      end,
      prev_epic = function()
        jump(-1)
      end,
      search = function()
        vim.ui.input({ prompt = 'Search epics (text, key or JQL): ' }, function(q)
          if q then
            M.search(q)
          end
        end)
      end,
      go_key = function()
        vim.ui.input({ prompt = 'Issue key: ' }, function(k)
          if k and vim.trim(k) ~= '' then
            require('jira').open_key(vim.trim(k):upper())
          end
        end)
      end,
      status = with_item(function(it)
        actions.status(ctx(it))
      end),
      watch = with_item(function(it)
        actions.watch(ctx(it))
      end),
      start = with_item(function(it)
        actions.date(ctx(it), 'start')
      end),
      due = with_item(function(it)
        actions.date(ctx(it), 'due')
      end),
      add = with_item(function(it)
        local key = is_container(it.type) and it.key or it.parent_key
        if not key then
          return vim.notify('jira: not an epic', vim.log.levels.WARN)
        end
        actions.quick_add(key, function()
          M.refresh(true)
        end, is_container(it.type) and it or store.epics[key])
      end),
      plan = with_item(function(it)
        local key = is_container(it.type) and it.key or it.parent_key
        if not key then
          return vim.notify('jira: not an epic', vim.log.levels.WARN)
        end
        actions.plan(key, function()
          M.refresh(true)
        end, is_container(it.type) and it or store.epics[key])
      end),
      new = function()
        local row = current()
        actions.new_menu({ parent = row and row.item and is_container(row.item.type) and row.item or nil, refresh = function()
          M.refresh(true)
        end })
      end,
      find = function()
        require('jira.ui.finder').open()
      end,
      sprint_view = function()
        local row = current()
        local key = row and row.item and row.item.key
        require('jira').sprint(key and key:match('^(%u[%u%d_]*)%-') or nil)
      end,
      digest = function()
        require('jira.ui.layout').show_digest()
      end,
      timeline = function()
        local row = current()
        if not row then
          return
        end
        local layout = require('jira.ui.layout')
        if row.item and is_container(row.item.type) then
          layout.show_timeline({ kind = 'epic', key = row.item.key })
        else
          layout.show_timeline(sections()[row.section].view)
        end
      end,
      undo = function()
        actions.undo(function()
          M.refresh(true)
        end)
      end,
      browser = with_item(function(it)
        actions.browser(ctx(it))
      end),
      yank_key = with_item(function(it)
        actions.yank_key(ctx(it))
      end),
      yank_url = with_item(function(it)
        actions.yank_url(ctx(it))
      end),
      refresh = function()
        M.refresh(true)
      end,
      help = function()
        keys.help('sidebar')
      end,
      close = function()
        require('jira.ui.layout').close()
      end,
    })
    vim.api.nvim_create_autocmd('BufEnter', {
      buffer = buf,
      callback = function()
        for _, sec in ipairs(sections()) do
          if sec.expanded and sec.version and sec.version ~= store.version and not sec.loading then
            load_section(sec)
          end
        end
      end,
    })
    M.refresh(false)
  end
  vim.api.nvim_win_set_buf(win, st.buf)
  -- Native folds off: za/zo/zc/zM/zR are mapped to the section toggles instead.
  r.win_opts(win, {
    wrap = false,
    cursorline = true,
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    winfixwidth = true,
    list = false,
    foldcolumn = '0',
    foldenable = false,
    spell = false,
    winbar = '',
  })
  draw()
  return st.buf
end

function M.first_view()
  for _, sec in ipairs(sections()) do
    if sec.view.kind == 'epics' then
      return sec.view
    end
  end
  return sections()[1] and sections()[1].view
end

return M
