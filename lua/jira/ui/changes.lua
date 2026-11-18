-- "What changed": field changes and comments on a parent and its children since N days ago. Good for standup.
local a = require('jira.async')
local api = require('jira.api')
local bufs = require('jira.ui.bufs')
local config = require('jira.config')
local keys = require('jira.ui.keys')
local r = require('jira.ui.render')
local store = require('jira.ui.store')

local M = {}

M.states = {}

local WEEKDAY = { 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat' }

-- Start of the window: midnight `days` days ago. On Monday, 1 day reaches back to Friday.
local function since_for(days)
  local now = os.date('*t')
  local back = days
  if days == 1 and now.wday == 2 then
    back = 3
  end
  return os.time({ year = now.year, month = now.month, day = now.day - back, hour = 0 })
end

local function short_value(v)
  if not v or v == '' then
    return '—'
  end
  return r.trunc(v:gsub('\n', ' '), 40)
end

local function draw(st)
  local buf = st.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local win = vim.fn.bufwinid(buf)
  local width = win ~= -1 and vim.api.nvim_win_get_width(win) or vim.o.columns
  local b = r.builder()
  st.rows = {}
  local since = os.date('*t', since_for(st.days))
  b:nl():add(' What changed', 'JiraTitle'):add('  ' .. st.key, 'JiraKey')
  b:add(('  since %s %s'):format(WEEKDAY[since.wday], r.stamp(os.date('%Y-%m-%dT00:00', since_for(st.days)))), 'JiraDim')
  b:add('   - / + to change', 'JiraHint')
  if st.loading then
    b:nl()
    b:nl():add('   loading… (one request per issue)', 'JiraDim')
  elseif st.error then
    b:nl()
    b:nl():add('   ' .. st.error, 'JiraOverdue')
  elseif #st.groups == 0 then
    b:nl()
    b:nl():add('   Nothing changed in ' .. st.key .. ' or its children.', 'JiraDim')
  end
  for _, g in ipairs(st.groups or {}) do
    b:nl()
    b:nl():add(' ' .. r.status_icon(g.issue.cat) .. ' ', require('jira.ui.hl').CAT[g.issue.cat]):add(g.issue.key, 'JiraKey')
    b:add('  ' .. r.trunc(g.issue.summary, width - #g.issue.key - 8), 'JiraHeader')
    st.rows[b:row()] = g.issue
    for _, e in ipairs(g.events) do
      b:nl():add('   ' .. r.pad(r.ago(e.created), 6, true), 'JiraDim'):add('  ' .. r.pad(e.author, 18), 'JiraAuthor')
      if e.comment then
        b:add('  commented  ', 'JiraLabel'):add(r.trunc(require('jira.ui.detail').plain(e.body, e.format):gsub('\n', ' '), width - 50))
      else
        b:add('  ' .. e.field .. '  ', 'JiraLabel')
        if e.field == 'description' then
          b:add('edited', 'JiraDim')
        else
          b:add(short_value(e.from), 'JiraDim'):add(' → ', 'JiraDim'):add(short_value(e.to), e.field == 'status' and 'JiraProgress' or nil)
        end
      end
      st.rows[b:row()] = g.issue
    end
  end
  b:nl()
  b:render(buf)
  if win ~= -1 then
    vim.wo[win].winbar = ('%%#JiraTitle# Changes %%#JiraDim# %s · %d issue%s%%=%%#JiraHint#? help '):format(st.key, #(st.groups or {}), #(st.groups or {}) == 1 and '' or 's')
  end
end

function M.load(st)
  st.loading, st.error = true, nil
  draw(st)
  local since = since_for(st.days)
  a.run(function()
    local parent = api.issue(st.key)
    local children = api.children(st.key)
    -- only issues touched in the window need their history read
    local touched = { parent }
    local cutoff = require('jira.dates')
    for _, c in ipairs(children) do
      local at = cutoff.epoch(c.updated)
      if at and at >= since then
        touched[#touched + 1] = c
      end
    end
    local wanted = {}
    for _, f in ipairs(config.changes_fields) do
      wanted[f] = true
    end
    local groups = {}
    for i = 1, #touched, 4 do
      local starters = {}
      for j = i, math.min(i + 3, #touched) do
        local it = touched[j]
        starters[#starters + 1] = a.starter(function()
          local events = {}
          for _, e in ipairs(api.changelog(it.key, since)) do
            if wanted[(e.field or ''):lower()] then
              events[#events + 1] = e
            end
          end
          for _, c in ipairs(api.recent_comments(it.key, since)) do
            c.comment = true
            events[#events + 1] = c
          end
          table.sort(events, function(x, y)
            return x.at > y.at
          end)
          return { issue = it, events = events }
        end)
      end
      for _, g in ipairs(a.all(starters)) do
        if #g.events > 0 then
          groups[#groups + 1] = g
        end
      end
    end
    -- most recent activity first, parent always on top
    table.sort(groups, function(x, y)
      if (x.issue == parent) ~= (y.issue == parent) then
        return x.issue == parent
      end
      return x.events[1].at > y.events[1].at
    end)
    st.groups = groups
  end, function(err)
    st.loading = false
    st.version = store.version
    if err then
      st.error = tostring(err)
    end
    draw(st)
  end)
end

function M.open(key, win)
  win = win or vim.api.nvim_get_current_win()
  local name = 'jira://changes/' .. key
  local buf = bufs.find(name)
  local prev = vim.api.nvim_win_get_buf(win)
  local st = buf ~= -1 and M.states[buf] or nil
  if st then
    vim.api.nvim_win_set_buf(win, buf)
    st.back = prev ~= buf and prev or st.back
    M.load(st)
    return st
  end
  buf = bufs.scratch(name)
  vim.bo[buf].filetype = 'jira'
  vim.bo[buf].bufhidden = 'hide'
  st = { buf = buf, key = key, days = 1, rows = {}, groups = {}, back = prev }
  M.states[buf] = st
  vim.api.nvim_win_set_buf(win, buf)
  r.own_window(buf, { wrap = false, cursorline = true, number = false, relativenumber = false, signcolumn = 'no', foldenable = false, spell = false, list = false })
  keys.apply(buf, 'changes', {
    open = function()
      local it = st.rows[vim.api.nvim_win_get_cursor(0)[1] - 1]
      if it then
        require('jira').open_key(it.key)
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
    refresh = function()
      M.load(st)
    end,
    help = function()
      keys.help('changes')
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
