-- Fuzzy find any issue. Uses the Snacks picker (live Jira search as you type) when it is installed,
-- otherwise asks for text and shows the results with vim.ui.select.
local a = require('jira.async')
local api = require('jira.api')
local config = require('jira.config')
local dates = require('jira.dates')

local M = {}

local KEY = '^%u[%u%d_]*%-%d+$'

-- Text or a key -> JQL. Anything with = ~ or ORDER BY is used as JQL as-is.
function M.jql_for(query)
  local q = vim.trim(query or '')
  if q == '' then
    return nil
  end
  if q:match('[=~]') or q:upper():match('%sORDER%s+BY%s') then
    return q
  end
  if q:upper():match(KEY) then
    return ('key = %s'):format(q:upper())
  end
  -- quotes and backslashes would end the JQL string early
  local safe = q:gsub('["\\]', ' ')
  return ('text ~ "%s*" ORDER BY updated DESC'):format(vim.trim(safe))
end

local function preview_text(it)
  local lines = {
    '# ' .. it.key .. '  ' .. it.summary,
    '',
    ('- **Status:** %s'):format(it.status),
    ('- **Type:** %s'):format(it.type),
    ('- **Assignee:** %s'):format(it.assignee or 'Unassigned'),
  }
  if it.parent_key then
    lines[#lines + 1] = ('- **Parent:** %s %s'):format(it.parent_key, it.parent_summary or '')
  end
  if it.start or it.due then
    lines[#lines + 1] = ('- **Dates:** %s → %s'):format(it.start or '—', it.due or '—')
  end
  lines[#lines + 1] = ('- **Updated:** %s'):format(require('jira.ui.render').ago(it.updated))
  return table.concat(lines, '\n')
end

local function search(jql, cb)
  a.run(function()
    return api.search(jql, { limit = 40 })
  end, cb)
end

local function open(key)
  require('jira').open_key(key)
end

local function snacks_pick(initial)
  local hl = require('jira.ui.hl')
  local r = require('jira.ui.render')
  Snacks.picker.pick({
    title = 'Jira',
    search = initial,
    live = true,
    supports_live = true,
    preview = 'preview',
    finder = function(_, ctx)
      local jql = M.jql_for(ctx.filter.search)
      if not jql or #vim.trim(ctx.filter.search) < 2 then
        return {}
      end
      return function(cb)
        -- wait for a pause in typing; snacks cancels this task when the text changes
        ctx.async:sleep(250)
        local done, items = false, {}
        vim.schedule(function()
          search(jql, function(err, list)
            items = err and {} or list
            done = true
            ctx.async:resume()
          end)
        end)
        while not done do
          ctx.async:suspend()
        end
        for _, it in ipairs(items) do
          cb({
            text = it.key .. ' ' .. it.summary,
            key = it.key,
            issue = it,
            preview = { text = preview_text(it), ft = 'markdown' },
          })
        end
      end
    end,
    format = function(item)
      local it = item.issue
      return {
        { r.status_icon(it.cat) .. ' ', hl.CAT[it.cat] },
        { r.pad(it.key, 12), 'JiraKey' },
        { r.pad(it.type, 8), 'JiraDim' },
        { ' ' .. it.summary },
        { it.assignee and ('  ' .. it.assignee) or '', 'JiraDim' },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        open(item.key)
      end
    end,
  })
end

local function fallback(initial)
  vim.ui.input({ prompt = 'Find issue (text, key or JQL): ', default = initial or '' }, function(q)
    local jql = M.jql_for(q)
    if not jql then
      return
    end
    search(jql, function(err, list)
      if err then
        return vim.notify('jira: ' .. tostring(err), vim.log.levels.ERROR)
      end
      if #list == 0 then
        return vim.notify('jira: nothing found for ' .. q, vim.log.levels.INFO)
      end
      vim.ui.select(list, {
        prompt = 'Jira',
        format_item = function(it)
          return ('%s  %s  [%s]%s'):format(it.key, it.summary, it.status, it.due and ('  due ' .. dates.short(it.due)) or '')
        end,
      }, function(it)
        if it then
          open(it.key)
        end
      end)
    end)
  end)
end

function M.open(initial)
  local use_snacks = config.picker ~= 'select' and _G.Snacks and Snacks.picker and Snacks.picker.pick
  if use_snacks then
    local ok, err = pcall(snacks_pick, initial)
    if ok then
      return
    end
    vim.notify('jira: snacks picker failed, using vim.ui.select (' .. tostring(err) .. ')', vim.log.levels.WARN)
  end
  fallback(initial)
end

return M
