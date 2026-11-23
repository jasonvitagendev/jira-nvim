-- One issue: fields, description, links and comments.
local a = require('jira.async')
local actions = require('jira.ui.actions')
local api = require('jira.api')
local bufs = require('jira.ui.bufs')
local config = require('jira.config')
local hl = require('jira.ui.hl')
local keys = require('jira.ui.keys')
local r = require('jira.ui.render')
local store = require('jira.ui.store')

local M = {}

M.states = {}

-- Readable text from an HTML body (display only; editing keeps the real HTML).
function M.plain(body, fmt)
  if fmt ~= 'html' then
    return body or ''
  end
  local s = (body or ''):gsub('\r', '')
  s = s:gsub('<br%s*/?>', '\n'):gsub('</p>', '\n\n'):gsub('<li[^>]*>', '- '):gsub('</li>', '\n')
  s = s:gsub('<h(%d)[^>]*>', function(n)
    return string.rep('#', tonumber(n)) .. ' '
  end)
  s = s:gsub('</h%d>', '\n\n'):gsub('<code>', '`'):gsub('</code>', '`'):gsub('<strong>', '**'):gsub('</strong>', '**')
  s = s:gsub('<[^>]+>', '')
  local entities = { amp = '&', lt = '<', gt = '>', quot = '"', ['#39'] = "'", nbsp = ' ' }
  s = s:gsub('&(#?%w+);', function(e)
    return entities[e]
  end)
  return (s:gsub('\n\n\n+', '\n\n'):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Confluence returns generic titles ("Page", "Wiki Page"), so fall back to the page name in the URL, then its id.
function M.link_title(l)
  local t = l.title
  if t and t ~= '' and t ~= 'Page' and t ~= 'Wiki Page' then
    return t
  end
  local slug = l.url:match('/pages/%d+/([^/?#]+)')
  if slug then
    return (slug:gsub('%+', ' '):gsub('%%(%x%x)', function(h)
      return string.char(tonumber(h, 16))
    end))
  end
  local id = l.url:match('[?&]pageId=(%d+)') or l.url:match('/pages/(%d+)')
  if id then
    return 'Confluence page ' .. id
  end
  return l.url
end

-- Only web links leave the editor; anything else (file:, javascript:, …) is refused.
local function open_url(url)
  if not (type(url) == 'string' and url:match('^https?://')) then
    return vim.notify('jira: not opening a non-web link: ' .. tostring(url), vim.log.levels.WARN)
  end
  vim.ui.open(url)
end

local function section(b, st, title, hint, width)
  b:nl()
  b:nl():add(' ─ ', 'JiraBorder'):add(title, 'JiraSection'):add(' ')
  local used = 4 + r.width(title) + (hint and (#hint + 2) or 0)
  b:add(string.rep('─', math.max(3, width - used - 2)), 'JiraBorder')
  if hint then
    b:add(' ' .. hint, 'JiraHint')
  end
  st.sections[#st.sections + 1] = b:row()
  st.fold_starts[b:row()] = 1
end

local function label(b, text)
  return b:nl():add('   ' .. r.pad(text, 10) .. ' ', 'JiraLabel')
end

local function field(b, text, value, group)
  label(b, text):add(value or '—', value and group or 'JiraDim')
end

local function draw(st)
  local buf = st.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local win = vim.fn.bufwinid(buf)
  local width = math.min(win ~= -1 and vim.api.nvim_win_get_width(win) or 100, 110)
  local b = r.builder()
  st.rows, st.sections, st.fold_starts = {}, {}, {}
  local it = st.issue
  if not it then
    b:nl():add('  ' .. (st.error or ('loading ' .. st.key .. '…')), st.error and 'JiraOverdue' or 'JiraDim')
    b:render(buf)
    return
  end

  local container = vim.tbl_contains(config.container_types, it.type)
  b:nl():add(' ' .. (container and config.icons.epic or r.status_icon(it.cat)) .. ' ', container and 'JiraEpic' or hl.CAT[it.cat])
  b:add(it.key, 'JiraKey'):add('  ·  ' .. it.type, 'JiraDim')
  b:nl():add(' ' .. it.summary, 'JiraTitle')
  b:nl()
  label(b, 'Status'):add(r.status_icon(it.cat) .. ' ' .. it.status, hl.CHIP[it.cat])
  field(b, 'Assignee', it.assignee, st.me and it.assignee_id == st.me and 'JiraMe' or 'Normal')
  field(b, 'Reporter', it.reporter, 'Normal')
  field(b, 'Priority', it.priority, 'Normal')
  if it.parent_key then
    label(b, 'Parent'):add('↑ ' .. it.parent_key, 'JiraEpic'):add('  ' .. (it.parent_summary or ''), 'JiraDim')
    st.rows[b:row()] = { open = it.parent_key }
  end
  label(b, 'Dates')
  r.timeline(b, it.start, it.due, it.cat, 24)
  st.rows[b:row()] = { dates = true }
  field(b, 'Labels', #it.labels > 0 and table.concat(it.labels, ', ') or nil, 'Normal')
  if it.points then
    field(b, 'Points', tostring(it.points), 'Normal')
  end
  label(b, 'Created'):add(r.stamp(it.created)):add('  ·  updated ' .. r.ago(it.updated), 'JiraDim')
  if st.children then
    local p = api.progress_of(st.children)
    label(b, 'Progress')
    r.progress_bar(b, p, 24)
    b:add(('  %d%%  %d/%d done'):format(r.percent(p), p.done, p.total), 'JiraHeader'):add('   <CR> tasks', 'JiraHint')
    st.rows[b:row()] = { grid = it.key }
  end

  section(b, st, 'Description', 'e edit', width)
  local desc = M.plain(it.description, it.format)
  b:nl()
  if desc == '' then
    b:nl():add('_No description._', 'JiraDim')
  else
    for _, l in ipairs(vim.split(desc, '\n')) do
      b:nl():add(l)
    end
  end

  if #it.subtasks > 0 then
    section(b, st, ('Subtasks (%d)'):format(#it.subtasks), nil, width)
    for _, s in ipairs(it.subtasks) do
      b:nl():add('   ' .. r.status_icon(s.cat) .. ' ', hl.CAT[s.cat]):add(s.key, 'JiraKey'):add('  ' .. s.summary)
      st.rows[b:row()] = { open = s.key }
    end
  end

  if #it.links > 0 then
    section(b, st, ('Links (%d)'):format(#it.links), nil, width)
    for _, l in ipairs(it.links) do
      b:nl():add('   ' .. r.pad(l.kind, 16), 'JiraDim'):add(l.key, 'JiraKey'):add('  ' .. r.trunc(l.summary, width - 40)):add('  ' .. l.status, 'JiraDim')
      st.rows[b:row()] = { open = l.key }
    end
  end

  if st.web_links and #st.web_links > 0 then
    section(b, st, ('Web links (%d)'):format(#st.web_links), '<CR> opens in browser', width)
    for _, l in ipairs(st.web_links) do
      local host = l.url:match('^https?://([^/]+)') or ''
      local wiki = l.url:match('/wiki/') ~= nil
      b:nl():add('   ' .. r.pad(l.relationship or (wiki and 'Confluence' or 'link'), 16), 'JiraDim')
      b:add('↗ ' .. r.trunc(M.link_title(l), width - 50), 'JiraLink'):add('  ' .. host, 'JiraDim')
      st.rows[b:row()] = { url = l.url }
    end
  end

  local comments = st.comments or {}
  section(b, st, ('Comments (%d)'):format(#comments), 'c add · R reply · e edit', width)
  if st.comments == nil then
    b:nl():add('   loading…', 'JiraDim')
  elseif #comments == 0 then
    b:nl()
    b:nl():add('   No comments yet.', 'JiraDim')
  end
  for _, c in ipairs(comments) do
    b:nl()
    local reply = c.parent_id and '  ↳ ' or ''
    b:nl():add(' ▍ ', 'JiraAuthor'):add(reply .. c.author, 'JiraAuthor'):add('  ' .. r.stamp(c.created), 'JiraDim')
    if c.updated and c.updated ~= c.created then
      b:add(' (edited)', 'JiraDim')
    end
    st.rows[b:row()] = { comment = c }
    st.sections[#st.sections + 1] = b:row()
    st.fold_starts[b:row()] = 2
    for _, l in ipairs(vim.split(M.plain(c.body, c.format), '\n')) do
      b:nl():add(' ▍', 'JiraBorder'):add(' ' .. l)
      st.rows[b:row()] = { comment = c }
    end
  end
  b:nl()
  -- foldexpr levels (1-based lnum): header fields 0, sections 1, each comment 2
  local levels, level = {}, 0
  for row = 0, b:row() do
    local start = st.fold_starts[row]
    if start then
      level = start
      levels[row + 1] = '>' .. start
    else
      levels[row + 1] = tostring(level)
    end
  end
  st.fold_levels = levels
  b:render(buf)
  if win ~= -1 then
    vim.wo[win].winbar = ('%%#JiraTitle# %s %%#JiraDim# %s%%=%%#JiraHint#? help '):format(it.key, r.trunc(it.summary, 60):gsub('%%', '%%%%'))
  end
end

function M.load(st)
  st.error = nil
  a.run(function()
    local was_container = st.issue and vim.tbl_contains(config.container_types, st.issue.type)
    local starters = {
      a.starter(api.issue, st.key),
      a.starter(api.comments, st.key),
      -- web links are extra: never fail the view over them
      a.starter(function()
        local ok, links = pcall(api.web_links, st.key)
        return ok and links or {}
      end),
    }
    local res = a.all(starters)
    st.issue, st.comments, st.web_links = res[1], res[2], res[3]
    if vim.tbl_contains(config.container_types, st.issue.type) or was_container then
      st.children = api.children(st.key)
      store.remember_epics({ st.issue })
    end
    pcall(function()
      st.me = api.me()
    end)
  end, function(err)
    st.version = store.version
    if err then
      st.error = tostring(err)
      vim.notify('jira: ' .. st.error, vim.log.levels.ERROR)
    end
    draw(st)
  end)
end

local function row(st)
  return st.rows[vim.api.nvim_win_get_cursor(0)[1] - 1] or {}
end

function M.open(key, win)
  win = win or vim.api.nvim_get_current_win()
  local name = 'jira://issue/' .. key
  local buf = bufs.find(name)
  local prev = vim.api.nvim_win_get_buf(win)
  local st = buf ~= -1 and M.states[buf]
  if st then
    vim.api.nvim_win_set_buf(win, buf)
    st.back = prev ~= buf and prev or st.back
    M.load(st)
    return st
  end
  buf = bufs.scratch(name)
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = 'markdown'
  st = { buf = buf, key = key, rows = {}, sections = {}, back = prev }
  M.states[buf] = st
  vim.api.nvim_win_set_buf(win, buf)
  r.own_window(buf, {
    wrap = true,
    linebreak = true,
    conceallevel = 2,
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    cursorline = true,
    spell = false,
    list = false,
    -- our own folds instead of treesitter / indent ones
    foldmethod = 'expr',
    foldexpr = "v:lua.require'jira.ui.detail'.foldexpr()",
    foldenable = true,
    foldlevel = 99,
    foldcolumn = '0',
    foldtext = '',
  })

  local function ctx()
    return {
      key = key,
      item = st.issue,
      refresh = function()
        M.load(st)
      end,
    }
  end

  local function go(dir)
    local cur = vim.api.nvim_win_get_cursor(0)[1] - 1
    local best
    for _, s in ipairs(st.sections) do
      if dir > 0 and s > cur and (not best or s < best) then
        best = s
      elseif dir < 0 and s < cur and (not best or s > best) then
        best = s
      end
    end
    if best then
      vim.api.nvim_win_set_cursor(0, { best + 1, 0 })
    end
  end

  keys.apply(buf, 'detail', {
    open = function()
      local rw = row(st)
      if rw.open then
        require('jira').open_key(rw.open)
      elseif rw.url then
        open_url(rw.url)
      elseif rw.grid then
        require('jira.ui.layout').show_grid({ kind = 'epic', key = rw.grid })
      elseif rw.dates then
        actions.date(ctx(), 'due')
      end
    end,
    back = function()
      if st.back and vim.api.nvim_buf_is_valid(st.back) then
        vim.api.nvim_win_set_buf(0, st.back)
      end
    end,
    parent = function()
      if st.issue and st.issue.parent_key then
        require('jira').open_key(st.issue.parent_key)
      end
    end,
    next_section = function()
      go(1)
    end,
    prev_section = function()
      go(-1)
    end,
    status = function()
      actions.status(ctx())
    end,
    priority = function()
      actions.priority(ctx())
    end,
    labels = function()
      actions.labels(ctx())
    end,
    sprint = function()
      actions.sprint(ctx())
    end,
    link = function()
      actions.link(ctx())
    end,
    reply = function()
      local rw = row(st)
      if not rw.comment then
        return vim.notify('jira: put the cursor on a comment to reply to it', vim.log.levels.WARN)
      end
      actions.reply(ctx(), rw.comment)
    end,
    undo = function()
      actions.undo(function()
        M.load(st)
      end)
    end,
    changes = function()
      require('jira.ui.changes').open(key)
    end,
    new = function()
      actions.new_menu({ parent = st.issue, refresh = function()
        M.load(st)
      end })
    end,
    assign_me = function()
      actions.assign_me(ctx())
    end,
    assign = function()
      actions.assign(ctx())
    end,
    summary = function()
      actions.summary(ctx())
    end,
    edit = function()
      local rw = row(st)
      if rw.comment then
        actions.comment(ctx(), rw.comment)
      else
        actions.description(ctx())
      end
    end,
    comment = function()
      actions.comment(ctx())
    end,
    start = function()
      actions.date(ctx(), 'start')
    end,
    due = function()
      actions.date(ctx(), 'due')
    end,
    move_epic = function()
      actions.move_epic(ctx())
    end,
    browser = function()
      local rw = row(st)
      if rw.url then
        return open_url(rw.url)
      end
      actions.browser(ctx())
    end,
    points = function()
      actions.points(ctx())
    end,
    start_work = function()
      actions.start_work(ctx())
    end,
    watch = function()
      actions.watch(ctx())
    end,
    log_work = function()
      actions.log_work(ctx())
    end,
    yank_key = function()
      actions.yank_key(ctx())
    end,
    yank_url = function()
      actions.yank_url(ctx())
    end,
    yank_branch = function()
      actions.yank_branch(ctx())
    end,
    refresh = function()
      M.load(st)
    end,
    help = function()
      keys.help('detail')
    end,
    close = function()
      if st.back and vim.api.nvim_buf_is_valid(st.back) then
        vim.api.nvim_win_set_buf(0, st.back)
      elseif #vim.api.nvim_list_wins() > 1 then
        vim.cmd('close')
      else
        vim.cmd('enew')
      end
    end,
  })

  local group = vim.api.nvim_create_augroup('jira_detail_' .. buf, { clear = true })
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    buffer = buf,
    callback = function()
      if st.version and st.version ~= store.version then
        M.load(st)
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

function M.foldexpr()
  local st = M.states[vim.api.nvim_get_current_buf()]
  return st and st.fold_levels and st.fold_levels[vim.v.lnum] or '0'
end

M._draw = draw

return M
