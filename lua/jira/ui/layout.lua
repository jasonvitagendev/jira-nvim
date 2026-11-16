-- Dedicated tab: sidebar on the left, grid / detail on the right.
--
--   ┌ sidebar ─────┬ main ──────────────────────────┐
--   │ ▾ My epics   │ epic header + task grid        │
--   │   ◐ PROJ-1   │   or issue detail              │
--   └──────────────┴────────────────────────────────┘
local config = require('jira.config')

-- collapsed: the sidebar was hidden on purpose, so views opening in main don't bring it back
local M = { tab = nil, side = nil, main = nil, collapsed = false }

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == M.tab
end

function M.is_open()
  return M.tab and vim.api.nvim_tabpage_is_valid(M.tab)
end

local function ensure()
  if not M.is_open() then
    vim.cmd('tabnew')
    local scratch = vim.api.nvim_get_current_buf()
    M.tab = vim.api.nvim_get_current_tabpage()
    M.main = vim.api.nvim_get_current_win()
    vim.cmd('topleft vsplit')
    M.side = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(M.side, config.sidebar_width)
    require('jira.ui.sidebar').open_in(M.side)
    vim.api.nvim_set_current_win(M.main)
    -- drop the empty buffer tabnew made
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(scratch) and vim.api.nvim_buf_get_name(scratch) == '' and vim.fn.bufwinid(scratch) == -1 then
        pcall(vim.api.nvim_buf_delete, scratch, {})
      end
    end)
    return true
  end
  vim.api.nvim_set_current_tabpage(M.tab)
  if not valid(M.side) and not M.collapsed then
    vim.cmd('topleft vsplit')
    M.side = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(M.side, config.sidebar_width)
    require('jira.ui.sidebar').open_in(M.side)
  end
  if not valid(M.main) then
    if valid(M.side) then
      vim.api.nvim_set_current_win(M.side)
      vim.cmd('rightbelow vsplit')
      M.main = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_width(M.side, config.sidebar_width)
    else
      M.main = vim.api.nvim_get_current_win()
    end
  end
  return false
end

-- :Jira  → open (first epics view in the grid) or jump back to the tab.
function M.open()
  local fresh = ensure()
  if not fresh then
    return
  end
  vim.api.nvim_set_current_win(M.side)
  local views = vim.tbl_filter(function(v)
    return v.kind == 'epics'
  end, require('jira.config').views)
  -- A list saved last time opens straight away; the grid refreshes it in the background.
  for _, v in ipairs(views) do
    local saved = require('jira.cache').get('epics:' .. v.jql)
    if saved and #saved.items > 0 then
      require('jira.ui.grid').open(v, M.main)
      return
    end
  end
  -- Start on the first epics view that has something in it (shares the sidebar's requests).
  local a = require('jira.async')
  local api = require('jira.api')
  local store = require('jira.ui.store')
  a.run(function()
    for _, v in ipairs(views) do
      local items = store.memo('epics:' .. v.jql, 30, function()
        return api.epics(v.jql)
      end)
      if #items > 0 then
        return v
      end
    end
    return views[1]
  end, function(err, view)
    if err then
      return vim.notify('jira: ' .. tostring(err), vim.log.levels.ERROR)
    end
    if view and valid(M.main) then
      require('jira.ui.grid').open(view, M.main)
    end
  end)
end

function M.toggle()
  if M.is_open() and vim.api.nvim_get_current_tabpage() == M.tab then
    return M.close()
  end
  M.open()
end

function M.show_grid(view)
  ensure()
  vim.api.nvim_set_current_win(M.main)
  require('jira.ui.grid').open(view, M.main)
end

function M.show_detail(key)
  ensure()
  vim.api.nvim_set_current_win(M.main)
  require('jira.ui.detail').open(key, M.main)
end

function M.show_timeline(view)
  ensure()
  vim.api.nvim_set_current_win(M.main)
  require('jira.ui.timeline').open(view, M.main)
end

function M.show_changes(key)
  ensure()
  vim.api.nvim_set_current_win(M.main)
  require('jira.ui.changes').open(key, M.main)
end

function M.show_digest(days)
  ensure()
  vim.api.nvim_set_current_win(M.main)
  require('jira.ui.digest').open(days, M.main)
end

function M.focus_sidebar()
  if M.collapsed then
    M.collapsed = false
    ensure()
  end
  if valid(M.side) then
    vim.api.nvim_set_current_win(M.side)
  end
end

-- Hide the sidebar so the grid gets the full width, or bring it back. Focus stays in main.
function M.toggle_sidebar()
  if not (M.is_open() and vim.api.nvim_get_current_tabpage() == M.tab) then
    return M.open()
  end
  if valid(M.side) and valid(M.main) then
    M.collapsed = true
    vim.api.nvim_win_close(M.side, false)
  else
    M.collapsed = false
    ensure()
  end
  if valid(M.main) then
    vim.api.nvim_set_current_win(M.main)
  end
end

function M.close()
  if not M.is_open() then
    return
  end
  if #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd('tabclose ' .. vim.api.nvim_tabpage_get_number(M.tab))
  else
    vim.api.nvim_set_current_tabpage(M.tab)
    vim.cmd('enew')
    vim.cmd('only')
  end
  M.tab, M.side, M.main, M.collapsed = nil, nil, nil, false
end

return M
