-- Gantt-style view of a grid's rows: one bar per issue from start to due, with a today marker.
--
--   KEY-1  36% ◐   ┣━━━━━━━●━━━━━┫            7d left    Summary
--                  └ green = share done      ● = today
local a = require('jira.async')
local actions = require('jira.ui.actions')
local checks = require('jira.checks')
local config = require('jira.config')
local dates = require('jira.dates')
local hl = require('jira.ui.hl')
local keys = require('jira.ui.keys')
local r = require('jira.ui.render')
local store = require('jira.ui.store')

local M = {}

M.states = {}

local DAY = 24 * 60 * 60

local function sorted(items)
  local out = vim.list_extend({}, items)
  table.sort(out, function(x, y)
    local kx, ky = x.start or x.due or '9999', y.start or y.due or '9999'
    if kx ~= ky then
      return kx < ky
    end
    return (x.due or '9999') < (y.due or '9999')
  end)
  return out
end

local function draw(st)
  local buf = st.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local win = vim.fn.bufwinid(buf)
  local width = win ~= -1 and vim.api.nvim_win_get_width(win) or vim.o.columns
  local keep
  if win ~= -1 and st.rows then
    local it = st.rows[vim.api.nvim_win_get_cursor(win)[1] - 1]
    keep = it and it.key
  end
  local b = r.builder()
  st.rows = {}
  local title = st.view.kind == 'epic' and st.view.key or st.view.name

  local dated, undated = {}, {}
  if st.parent then
    dated[#dated + 1] = st.parent
  end
  for _, it in ipairs(sorted(st.items or {})) do
    if it.start or it.due then
      dated[#dated + 1] = it
    else
      undated[#undated + 1] = it
    end
  end

  b:nl():add(' ' .. config.icons.epic .. ' Timeline', 'JiraTitle'):add('  ' .. title, 'JiraKey')
  if st.loading then
    b:add('  loading…', 'JiraHint')
  end
  if #dated == 0 then
    b:nl()
    b:nl():add('   ' .. (st.error or (st.loading and '' or 'Nothing here has a start or due date yet. Set them with ds / dd in the grid.')), st.error and 'JiraOverdue' or 'JiraDim')
    b:render(buf)
    return
  end

  -- time range: every date plus today, padded a little
  local today = dates.today()
  local lo, hi = today, today
  for _, it in ipairs(dated) do
    for _, d in ipairs({ it.start, it.due }) do
      local t = dates.to_time(d)
      if t then
        lo, hi = math.min(lo, t), math.max(hi, t)
      end
    end
  end
  lo, hi = lo - 2 * DAY, hi + 2 * DAY
  local days = math.floor((hi - lo) / DAY + 0.5) + 1

  local key_w = 0
  for _, it in ipairs(dated) do
    key_w = math.max(key_w, #it.key)
  end
  local left = key_w + 9 -- " KEY  36% ◐ "
  local health_w = 22
  local summary_w = math.max(0, math.min(40, width - left - health_w - 50))
  local chart = math.max(20, width - left - health_w - summary_w - 4)
  local function col(t)
    return math.max(0, math.min(chart - 1, math.floor((t - lo) / DAY / (days - 1) * (chart - 1) + 0.5)))
  end
  local today_col = col(today)

  -- axis: a label on each Monday that has room
  local axis, ticks, next_free = {}, {}, 0
  for i = 1, chart do
    axis[i], ticks[i] = ' ', ' '
  end
  for d = 0, days - 1 do
    local t = lo + d * DAY
    if os.date('*t', t).wday == 2 then
      local c = col(t)
      local label = dates.short(dates.fmt(t))
      if c >= next_free and c + #label <= chart then
        for i = 1, #label do
          axis[c + i] = label:sub(i, i)
        end
        ticks[c + 1] = '┬'
        next_free = c + #label + 2
      end
    end
  end
  b:nl()
  b:nl():add(string.rep(' ', left + 1)):add(table.concat(axis), 'JiraDim')
  b:nl():add(string.rep(' ', left + 1)):add(table.concat(ticks), 'JiraBorder')

  for _, it in ipairs(dated) do
    local h = checks.health(it)
    local is_parent = it == st.parent
    local pct = it.progress and it.progress.total > 0 and r.percent(it.progress) or nil
    b:nl():add(' ' .. r.pad(it.key, key_w), is_parent and 'JiraEpic' or 'JiraKey')
    b:add(' ' .. (pct and ('%3d%%'):format(pct) or '    '), 'JiraDim')
    b:add(' ' .. r.status_icon(it.cat) .. ' ', hl.CAT[it.cat])

    -- one cell per chart column: { char, highlight }
    local cells = {}
    for i = 1, chart do
      cells[i] = { ' ', nil }
    end
    local s, e = dates.to_time(it.start), dates.to_time(it.due)
    local base = it.cat == 'done' and 'JiraDim' or h.level == 'overdue' and 'JiraOverdue' or it.cat == 'new' and 'JiraTodo' or 'JiraProgress'
    if s and e and e >= s then
      local cs, ce = col(s), col(e)
      -- green up to the share that is done, so "today past the green" reads as behind
      local done_to = pct and (cs + math.floor((ce - cs + 1) * pct / 100 + 0.5) - 1) or (it.cat == 'done' and ce or cs - 1)
      for c = cs, ce do
        local ch = it.cat == 'new' and '─' or '━'
        if c == cs then
          ch = '┣'
        end
        if c == ce then
          ch = '┫'
        end
        cells[c + 1] = { ch, (c <= done_to and it.cat ~= 'done') and 'JiraBarDone' or base }
      end
    elseif e then
      cells[col(e) + 1] = { '◆', base }
    elseif s then
      local cs = col(s)
      cells[cs + 1] = { '┣', base }
      for c = cs + 1, chart - 1 do
        cells[c + 1] = { '┄', 'JiraBarEmpty' }
      end
    end
    local t = cells[today_col + 1]
    cells[today_col + 1] = t[1] == ' ' and { '│', 'JiraBarEmpty' } or { '●', 'JiraToday' }
    -- emit runs of the same highlight
    local run, run_hl = {}, cells[1][2]
    for i = 1, chart do
      if cells[i][2] ~= run_hl then
        b:add(table.concat(run), run_hl)
        run, run_hl = {}, cells[i][2]
      end
      run[#run + 1] = cells[i][1]
    end
    b:add(table.concat(run), run_hl)

    b:add('  ' .. r.pad(h.text, health_w - 2), hl.HEALTH[h.level])
    if summary_w > 0 then
      b:add(' ' .. r.trunc(it.summary, summary_w), is_parent and 'JiraTitle' or nil)
    end
    st.rows[b:row()] = it
  end
  b:nl():add(string.rep(' ', left + 1 + today_col)):add('▲ today ' .. dates.short(dates.fmt(today)), 'JiraToday')

  if #undated > 0 then
    b:nl()
    b:nl():add((' %d without dates'):format(#undated), 'JiraSection'):add('   ds / dd on a row sets them', 'JiraHint')
    for i, it in ipairs(undated) do
      if i > 12 then
        b:nl():add(('   … and %d more'):format(#undated - 12), 'JiraDim')
        break
      end
      b:nl():add(' ' .. r.pad(it.key, key_w), 'JiraKey'):add('      ' .. r.status_icon(it.cat) .. ' ', hl.CAT[it.cat])
      b:add(r.trunc(it.summary, width - key_w - 12), 'JiraDim')
      st.rows[b:row()] = it
    end
  end
  b:render(buf)
  if win ~= -1 then
    for row, it in pairs(st.rows) do
      if it.key == keep then
        pcall(vim.api.nvim_win_set_cursor, win, { row + 1, 1 })
      end
    end
    vim.wo[win].winbar = ('%%#JiraTitle# Timeline %%#JiraDim# %s · %d with dates%%=%%#JiraHint#green = done · ● today · ? help '):format(title:gsub('%%', '%%%%'), #dated)
  end
end

function M.load(st)
  st.loading, st.error = true, nil
  draw(st)
  a.run(function()
    local data = require('jira.ui.grid').fetch(st.view)
    st.parent, st.items = data.parent, data.items
  end, function(err)
    st.loading = false
    st.version = store.version
    if err then
      st.error = tostring(err)
      vim.notify('jira: ' .. st.error, vim.log.levels.ERROR)
    end
    draw(st)
  end)
end

function M.open(view, win)
  win = win or vim.api.nvim_get_current_win()
  local name = 'jira://timeline/' .. (view.kind == 'epic' and view.key or view.name)
  local buf = vim.fn.bufnr(name)
  local prev = vim.api.nvim_win_get_buf(win)
  local st = buf ~= -1 and M.states[buf] or nil
  if st then
    vim.api.nvim_win_set_buf(win, buf)
    st.back = prev ~= buf and prev or st.back
    M.load(st)
    return st
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].filetype = 'jira'
  vim.bo[buf].bufhidden = 'hide'
  st = { buf = buf, view = view, rows = {}, back = prev }
  M.states[buf] = st
  vim.api.nvim_win_set_buf(win, buf)
  r.own_window(buf, {
    wrap = false,
    cursorline = true,
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    list = false,
    foldenable = false,
    foldcolumn = '0',
    spell = false,
    conceallevel = 0,
  })

  local function with_item(fn)
    return function()
      local it = st.rows[vim.api.nvim_win_get_cursor(0)[1] - 1]
      if not it then
        return vim.notify('jira: put the cursor on a row', vim.log.levels.WARN)
      end
      fn({
        key = it.key,
        item = it,
        refresh = function()
          M.load(st)
        end,
      })
    end
  end

  keys.apply(buf, 'timeline', {
    open = with_item(function(ctx)
      require('jira').open_key(ctx.key)
    end),
    back = function()
      if st.back and vim.api.nvim_buf_is_valid(st.back) then
        vim.api.nvim_win_set_buf(0, st.back)
      end
    end,
    status = with_item(actions.status),
    start = with_item(function(ctx)
      actions.date(ctx, 'start')
    end),
    due = with_item(function(ctx)
      actions.date(ctx, 'due')
    end),
    undo = function()
      actions.undo(function()
        M.load(st)
      end)
    end,
    browser = with_item(actions.browser),
    refresh = function()
      store.changed()
      M.load(st)
    end,
    help = function()
      keys.help('timeline')
    end,
    close = function()
      require('jira.ui.layout').close()
    end,
  })
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    callback = function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return true
      end
      if vim.fn.bufwinid(buf) ~= -1 then
        draw(st)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufEnter', {
    buffer = buf,
    callback = function()
      if st.version and st.version ~= store.version and not st.loading then
        M.load(st)
      end
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

M._draw = draw

return M
