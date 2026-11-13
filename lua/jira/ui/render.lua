-- Builds buffer lines from highlighted chunks, plus shared widgets (bars, chips, tables).
local config = require('jira.config')
local dates = require('jira.dates')
local hl = require('jira.ui.hl')

local M = {}

local Builder = {}
Builder.__index = Builder

function M.builder()
  return setmetatable({ lines = {}, marks = {}, line_hls = {}, cur = nil }, Builder)
end

function Builder:nl()
  self.cur = { text = {}, len = 0 }
  self.lines[#self.lines + 1] = self.cur
  return self
end

function Builder:add(text, group)
  if not self.cur then
    self:nl()
  end
  text = tostring(text or ''):gsub('\n', ' ')
  if group and #text > 0 then
    self.marks[#self.marks + 1] = { #self.lines - 1, self.cur.len, self.cur.len + #text, group }
  end
  self.cur.text[#self.cur.text + 1] = text
  self.cur.len = self.cur.len + #text
  return self
end

function Builder:line_hl(group)
  self.line_hls[#self.lines - 1] = group
  return self
end

-- 0-based index of the current line
function Builder:row()
  return #self.lines - 1
end

function Builder:render(buf)
  local out = {}
  for i, l in ipairs(self.lines) do
    out[i] = table.concat(l.text)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, hl.ns, 0, -1)
  for row, group in pairs(self.line_hls) do
    vim.api.nvim_buf_set_extmark(buf, hl.ns, row, 0, { line_hl_group = group, priority = 50 })
  end
  for _, m in ipairs(self.marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, hl.ns, m[1], m[2], { end_col = m[3], hl_group = m[4], priority = 120 })
  end
end

-- text ----------------------------------------------------------------------

function M.width(s)
  return vim.fn.strdisplaywidth(s or '')
end

function M.trunc(s, w)
  s = s or ''
  if M.width(s) <= w then
    return s
  end
  if w <= 1 then
    return w == 1 and '…' or ''
  end
  local chars = vim.fn.strchars(s)
  local lo, hi = 0, chars
  while lo < hi do
    local mid = math.ceil((lo + hi) / 2)
    if M.width(vim.fn.strcharpart(s, 0, mid)) <= w - 1 then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return vim.fn.strcharpart(s, 0, lo) .. '…'
end

function M.pad(s, w, right)
  s = M.trunc(s, w)
  local gap = string.rep(' ', w - M.width(s))
  return right and (gap .. s) or (s .. gap)
end

-- "now", "3m", "2h", "5d" since an epoch time
function M.age(t)
  local diff = math.max(0, os.time() - t)
  if diff < 60 then
    return 'now'
  elseif diff < 3600 then
    return math.floor(diff / 60) .. 'm'
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. 'h'
  end
  return math.floor(diff / 86400) .. 'd'
end

-- "just now", "3m ago"
function M.age_text(t)
  local s = M.age(t)
  return s == 'now' and 'just now' or (s .. ' ago')
end

-- "3m", "2h", "5d", "Oct 27"
function M.ago(iso)
  local t = dates.epoch(iso)
  if not t then
    return '—'
  end
  local diff = os.time() - t
  if diff < 60 then
    return 'now'
  elseif diff < 3600 then
    return math.floor(diff / 60) .. 'm'
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. 'h'
  elseif diff < 86400 * 14 then
    return math.floor(diff / 86400) .. 'd'
  end
  return dates.short(iso:sub(1, 10))
end

-- "Oct 27 12:31"
function M.stamp(iso)
  local date, time = (iso or ''):match('^(%d+%-%d+%-%d+)T(%d+:%d+)')
  if not date then
    return iso or ''
  end
  return dates.short(date) .. ' ' .. time
end

-- Window-local only, so settings don't leak into the next buffer shown in that window.
function M.win_opts(win, opts)
  for opt, v in pairs(opts) do
    vim.api.nvim_set_option_value(opt, v, { scope = 'local', win = win })
  end
end

-- Re-apply opts whenever buf is shown in a window (grid and detail share the main window).
function M.own_window(buf, opts)
  vim.api.nvim_create_autocmd('BufWinEnter', {
    buffer = buf,
    callback = function()
      M.win_opts(vim.api.nvim_get_current_win(), opts)
    end,
  })
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    M.win_opts(win, opts)
  end
end

-- widgets -------------------------------------------------------------------

function M.status_icon(cat)
  local i = config.icons
  return cat == 'done' and i.done or cat == 'indeterminate' and i.progress or i.todo
end

-- Segmented bar: done | in progress | to do
function M.progress_bar(b, p, width)
  local i = config.icons
  if not p or p.total == 0 then
    b:add(string.rep(i.bar_empty, width), 'JiraBarEmpty')
    return
  end
  local done = math.floor(p.done / p.total * width + 0.5)
  local prog = math.floor((p.done + p.indeterminate) / p.total * width + 0.5) - done
  b:add(string.rep(i.bar_fill, done), 'JiraBarDone')
  b:add(string.rep(i.bar_fill, prog), 'JiraBarProgress')
  b:add(string.rep(i.bar_empty, width - done - prog), 'JiraBarEmpty')
end

function M.percent(p)
  if not p or p.total == 0 then
    return 0
  end
  return math.floor(p.done / p.total * 100 + 0.5)
end

-- Start ━━━━━●┄┄┄┄ Due
function M.timeline(b, start, due, cat, width)
  local h = dates.health(start, due, cat, config.due_soon_days)
  if not start and not due then
    b:add('no start or due date', 'JiraMissing'):add('   ds', 'JiraKey'):add(' start  ', 'JiraHint'):add('dd', 'JiraKey'):add(' due', 'JiraHint')
    return h
  end
  b:add(dates.short(start), start and 'JiraHeader' or 'JiraMissing'):add(' ')
  local frac = dates.elapsed(start, due)
  if h.level == 'overdue' then
    b:add(string.rep('━', width), 'JiraOverdue')
  elseif h.level == 'done' then
    b:add(string.rep('━', width), 'JiraDone')
  elseif frac then
    local pos = math.min(width - 1, math.floor(frac * (width - 1) + 0.5))
    b:add(string.rep('━', pos), 'JiraProgress'):add('●', 'JiraToday'):add(string.rep('┄', width - pos - 1), 'JiraBarEmpty')
  else
    b:add(string.rep('┄', width), 'JiraBarEmpty')
  end
  b:add(' '):add(dates.short(due), due and 'JiraHeader' or 'JiraMissing')
  b:add('   '):add(h.text, hl.HEALTH[h.level])
  return h
end

return M
