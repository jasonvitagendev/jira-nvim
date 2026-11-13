local a = require('jira.async')
local config = require('jira.config')

local M = {}

local KEY_PATTERN = '%u[%u%d_]*%-%d+'

function M.setup(opts)
  config.setup(opts)
  require('jira.ui.hl').setup()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('jira_hl', { clear = true }),
    callback = function()
      require('jira.ui.hl').setup()
    end,
  })
end

local function key_under_cursor()
  local word = vim.fn.expand('<cWORD>')
  return word:match(KEY_PATTERN)
end

-- The issue a command is about: the key under the cursor, else the one in the git branch.
local function key_here()
  return key_under_cursor() or require('jira.git').key()
end

-- Commands that change an issue prefer the branch: in code, a word like UTF-8 under the cursor looks like a key.
local function key_to_change()
  return require('jira.git').key() or key_under_cursor()
end

-- For your statusline, e.g. lualine_c = { function() return require('jira').statusline() end }
function M.statusline()
  return require('jira.statusline').get()
end

-- Epics open in the grid, everything else in the detail view.
function M.open_key(key)
  key = key or key_here()
  if not key then
    return vim.notify('jira: no issue key given, under the cursor, or in the git branch', vim.log.levels.WARN)
  end
  key = vim.trim(key):upper()
  -- keys end up in JQL (parent = KEY), so only accept the real key shape
  if not key:match('^' .. KEY_PATTERN .. '$') then
    return vim.notify('jira: not an issue key: ' .. key, vim.log.levels.WARN)
  end
  local layout = require('jira.ui.layout')
  local known = require('jira.ui.store').epics[key]
  if known then
    return layout.show_grid({ kind = 'epic', key = key })
  end
  a.run(function()
    local api = require('jira.api')
    local res = require('jira.mcp').call('getJiraIssue', { cloudId = api.site().id, issueIdOrKey = key, fields = { 'issuetype' } })
    return res.fields and res.fields.issuetype and res.fields.issuetype.name
  end, function(err, kind)
    if err then
      return vim.notify('jira: ' .. tostring(err), vim.log.levels.ERROR)
    end
    if vim.tbl_contains(config.container_types, kind) then
      layout.show_grid({ kind = 'epic', key = key })
    elseif layout.is_open() and vim.api.nvim_get_current_tabpage() == layout.tab then
      layout.show_detail(key)
    else
      require('jira.ui.detail').open(key)
    end
  end)
end

-- Active sprint of a project in the grid. project = nil uses the branch's project, or asks.
function M.sprint(project)
  a.run(function()
    local p = project
    if not p then
      local key = require('jira.git').key()
      p = key and key:match('^(%u[%u%d_]*)%-')
    end
    if not p then
      p = a.await(function(cb)
        vim.ui.input({ prompt = 'Project key for the sprint: ' }, function(v)
          cb(nil, v)
        end)
      end)
      p = p and vim.trim(p):upper()
    end
    if not (p and p:match('^%u[%u%d_]*$')) then
      return nil
    end
    local board = require('jira.ui.actions').pick_board(p)
    if not board then
      return nil
    end
    local sprint = require('jira.api').active_sprint(board.id)
    return {
      kind = 'sprint',
      name = p .. ' · ' .. tostring(sprint.name),
      jql = ('sprint = %d ORDER BY Rank ASC'):format(assert(tonumber(sprint.id), 'bad sprint id')),
      sprint = sprint,
      board = board,
      group = 'status',
    }
  end, function(err, view)
    if err then
      return vim.notify('jira: ' .. tostring(err), vim.log.levels.ERROR)
    end
    if view then
      require('jira.ui.layout').show_grid(view)
    end
  end)
end

-- ":Jira log [KEY] 1h 30m fixed the build" -> key, '1h 30m', 'fixed the build'
function M.parse_log_args(args)
  local parse = require('jira.ui.actions').parse_duration
  local key, time, rest = nil, {}, {}
  for i, arg in ipairs(args) do
    if i == 1 and arg:upper():match('^' .. KEY_PATTERN .. '$') then
      key = arg:upper()
    elseif #rest == 0 and parse(arg) then
      time[#time + 1] = arg
    else
      rest[#rest + 1] = arg
    end
  end
  return key, #time > 0 and table.concat(time, ' ') or nil, #rest > 0 and table.concat(rest, ' ') or nil
end

local function find_view(name)
  for _, v in ipairs(config.views) do
    if v.name:lower() == name:lower() then
      return v
    end
  end
end

M.commands = {
  open = function(args)
    if args[1] then
      M.open_key(args[1])
    else
      require('jira.ui.layout').toggle()
    end
  end,
  issue = function(args)
    M.open_key(args[1])
  end,
  search = function(args)
    local q = table.concat(args, ' ')
    require('jira.ui.layout').open()
    require('jira.ui.sidebar').search(q)
  end,
  mine = function()
    local v = find_view('My open tasks')
      or { name = 'My open tasks', kind = 'tasks', jql = 'assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC' }
    require('jira.ui.layout').show_grid(v)
  end,
  view = function(args)
    local v = find_view(table.concat(args, ' '))
    if not v then
      return vim.notify('jira: no view named ' .. table.concat(args, ' '), vim.log.levels.WARN)
    end
    require('jira.ui.layout').show_grid(v)
  end,
  create = function(args)
    local epic = args[1] or key_under_cursor()
    if not epic then
      return vim.notify('jira: give an epic key, e.g. :Jira create PROJ-1', vim.log.levels.WARN)
    end
    epic = epic:upper()
    local store = require('jira.ui.store')
    require('jira.ui.actions').add_form(epic, nil, store.epics[epic])
  end,
  plan = function(args)
    local epic = (args[1] or key_under_cursor() or ''):upper()
    if not epic:match('^' .. KEY_PATTERN .. '$') then
      return vim.notify('jira: give an epic key, e.g. :Jira plan PROJ-1', vim.log.levels.WARN)
    end
    local store = require('jira.ui.store')
    require('jira.ui.actions').plan(epic, nil, store.epics[epic])
  end,
  -- :Jira epic [PROJECT] [PARENT-INITIATIVE]
  epic = function(args)
    local project, parent
    for _, arg in ipairs(args) do
      arg = arg:upper()
      if arg:match('^' .. KEY_PATTERN .. '$') then
        parent = arg
      elseif arg:match('^%u[%u%d_]*$') then
        project = arg
      end
    end
    require('jira.ui.actions').new_epic({ project = project, parent = parent })
  end,
  initiative = function(args)
    require('jira.ui.actions').new_initiative({ project = args[1] and args[1]:upper() or nil })
  end,
  new = function()
    require('jira.ui.actions').new_menu({})
  end,
  find = function(args)
    require('jira.ui.finder').open(#args > 0 and table.concat(args, ' ') or nil)
  end,
  timeline = function(args)
    local key = (args[1] or key_under_cursor() or ''):upper()
    if key:match('^' .. KEY_PATTERN .. '$') then
      return require('jira.ui.layout').show_timeline({ kind = 'epic', key = key })
    end
    local name = table.concat(args, ' ')
    local v = name ~= '' and find_view(name) or require('jira.ui.sidebar').first_view()
    if not v then
      return vim.notify('jira: give an epic key or a view name', vim.log.levels.WARN)
    end
    require('jira.ui.layout').show_timeline(v)
  end,
  changes = function(args)
    local key = (args[1] or key_under_cursor() or ''):upper()
    if not key:match('^' .. KEY_PATTERN .. '$') then
      return vim.notify('jira: give an epic key, e.g. :Jira changes PROJ-1', vim.log.levels.WARN)
    end
    require('jira.ui.layout').show_changes(key)
  end,
  undo = function()
    require('jira.ui.actions').undo()
  end,
  comment = function(args)
    local key = args[1] or key_here()
    if not key then
      return vim.notify('jira: give an issue key', vim.log.levels.WARN)
    end
    require('jira.ui.actions').comment({ key = key:upper() })
  end,
  -- the issue in the current git branch
  branch = function()
    local key = require('jira.git').key()
    if not key then
      return vim.notify('jira: no issue key in this git branch (expects something like feature/PROJ-12-…)', vim.log.levels.WARN)
    end
    M.open_key(key)
  end,
  -- assign to me, In Progress, start date today, copy the branch name
  start = function(args)
    local key = (args[1] or key_to_change() or ''):upper()
    if not key:match('^' .. KEY_PATTERN .. '$') then
      return vim.notify('jira: give an issue key, e.g. :Jira start PROJ-12', vim.log.levels.WARN)
    end
    require('jira.ui.actions').start_work({ key = key })
  end,
  log = function(args)
    local key, time, comment = M.parse_log_args(args)
    key = key or key_to_change()
    if not key then
      return vim.notify('jira: give an issue key, e.g. :Jira log PROJ-12 2h', vim.log.levels.WARN)
    end
    -- a time on the command line means no prompts: the comment is whatever followed it
    require('jira.ui.actions').log_work({ key = key }, time, time and (comment or '') or nil)
  end,
  sprint = function(args)
    M.sprint(args[1] and args[1]:upper() or nil)
  end,
  digest = function(args)
    require('jira.ui.layout').show_digest(tonumber(args[1]))
  end,
  login = function()
    a.run(function()
      require('jira.auth').login()
      require('jira.mcp').reset()
    end, function(err)
      if err then
        return vim.notify('jira: login failed: ' .. tostring(err), vim.log.levels.ERROR)
      end
      vim.notify('jira: logged in', vim.log.levels.INFO)
    end)
  end,
  logout = function()
    require('jira.auth').logout()
    require('jira.mcp').reset()
    require('jira.cache').clear()
    vim.notify('jira: logged out (tokens removed from Keychain)', vim.log.levels.INFO)
  end,
  status = function()
    local s = require('jira.auth').status()
    if not s.logged_in then
      return vim.notify('jira: not logged in, run :Jira login', vim.log.levels.WARN)
    end
    local mins = math.floor(s.expires_in / 60)
    vim.notify(('jira: logged in · access token %s · refresh token %s'):format(mins > 0 and ('valid for ' .. mins .. ' min') or 'expired (refreshes on next use)', s.has_refresh and 'stored' or 'missing'))
  end,
}

function M.command(opts)
  local args = vim.deepcopy(opts.fargs)
  local sub = table.remove(args, 1)
  if not sub then
    return M.commands.open({})
  end
  if sub:match('^' .. KEY_PATTERN .. '$') or sub:match('^' .. KEY_PATTERN:lower() .. '$') then
    return M.open_key(sub)
  end
  local fn = M.commands[sub]
  if not fn then
    return vim.notify('jira: unknown command ' .. sub, vim.log.levels.WARN)
  end
  fn(args)
end

function M.complete(arglead, line)
  local words = vim.split(line, '%s+')
  if #words <= 2 then
    return vim.tbl_filter(function(c)
      return c:find(arglead, 1, true) == 1
    end, vim.tbl_keys(M.commands))
  end
  if words[2] == 'view' or words[2] == 'timeline' then
    return vim.tbl_map(function(v)
      return v.name
    end, config.views)
  end
  return {}
end

return M
