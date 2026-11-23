-- Jira operations on top of the MCP tools. All functions are coroutines (call inside async.run).
local a = require('jira.async')
local config = require('jira.config')
local http = require('jira.http')
local mcp = require('jira.mcp')

local M = {}

local DATA_DIR = vim.fn.stdpath('data') .. '/jira-nvim'
local cache = { site = nil, me = nil, fields = nil, types = {} }

local function read_json(path)
  local f = io.open(path, 'r')
  if not f then
    return nil
  end
  local v = http.decode(f:read('*a'))
  f:close()
  return v
end

local function write_json(path, v)
  vim.fn.mkdir(DATA_DIR, 'p', 448)
  local f = assert(io.open(path, 'w'))
  f:write(vim.json.encode(v))
  f:close()
end

local function select(items, opts)
  return a.await(function(cb)
    vim.ui.select(items, opts, function(choice)
      cb(nil, choice)
    end)
  end)
end

-- site ----------------------------------------------------------------------

-- { id = cloudId, url = 'https://x.atlassian.net', host = 'x.atlassian.net' }
function M.site()
  if cache.site then
    return cache.site
  end
  local saved = read_json(DATA_DIR .. '/site.json')
  local wanted = config.site and config.site:gsub('^https?://', ''):gsub('/.*$', '')
  if saved and saved.id and (not wanted or saved.host == wanted) then
    cache.site = saved
    return saved
  end
  local res = mcp.call('getAccessibleAtlassianResources').resources or {}
  local sites = {}
  for _, r in ipairs(res) do
    local host = r.url:gsub('^https?://', ''):gsub('/.*$', '')
    if not wanted or host == wanted then
      sites[#sites + 1] = { id = r.cloudId, url = 'https://' .. host, host = host }
    end
  end
  if #sites == 0 then
    error(wanted and ('no access to ' .. wanted) or 'no Atlassian sites on this account', 0)
  end
  local site = sites[1]
  if #sites > 1 then
    site = select(sites, {
      prompt = 'Jira site',
      format_item = function(s)
        return s.host
      end,
    }) or error('no site picked', 0)
  end
  write_json(DATA_DIR .. '/site.json', site)
  cache.site = site
  return site
end

local function call(tool, args)
  args = args or {}
  args.cloudId = args.cloudId or M.site().id
  return mcp.call(tool, args)
end

local function op(kind, name, inputs)
  local cloud = M.site().id
  inputs = inputs or {}
  inputs.cloudId = cloud
  return mcp.call(kind, { cloudId = cloud, name = name, inputs = inputs })
end

function M.browse_url(key)
  return M.site().url .. '/browse/' .. key
end

function M.me()
  if not cache.me then
    cache.me = mcp.call('atlassianUserInfo').accountId
  end
  return cache.me
end

-- fields --------------------------------------------------------------------

-- Custom field ids are site-wide, so look them up once from the Epic create screen of any project.
function M.field_ids(project)
  if cache.fields then
    return cache.fields
  end
  local path = DATA_DIR .. '/fields-' .. M.site().id .. '.json'
  local saved = read_json(path)
  if saved and saved.start_date then
    cache.fields = saved
    return saved
  end
  if not project then
    return {}
  end
  local ids = {}
  local ok, err = pcall(function()
    local types = M.issue_types(project)
    local epic
    for _, t in ipairs(types) do
      if t.name == 'Epic' then
        epic = t
      end
    end
    epic = epic or types[1]
    local meta = op('executeRead', 'getJiraIssueTypeMetaWithFields', {
      projectIdOrKey = project,
      issueTypeId = epic.id,
      requiredFieldsOnly = false,
      maxResults = 200,
    })
    for _, f in ipairs(meta.fields or {}) do
      for key, label in pairs(config.fields) do
        if f.name == label then
          ids[key] = f.fieldId or f.key
        end
      end
    end
  end)
  if not ok then
    vim.schedule(function()
      vim.notify('jira: could not look up field ids (' .. tostring(err) .. ')', vim.log.levels.WARN)
    end)
  end
  if ids.start_date then
    write_json(path, ids)
  end
  cache.fields = ids
  return ids
end

function M.issue_types(project)
  if not cache.types[project] then
    local res = op('executeRead', 'listJiraProjectIssueTypesMetadata', { projectIdOrKey = project })
    cache.types[project] = res.issueTypes or {}
  end
  return cache.types[project]
end

-- issues --------------------------------------------------------------------

local CATEGORY = { ['To Do'] = 'new', ['In Progress'] = 'indeterminate', Done = 'done', new = 'new', indeterminate = 'indeterminate', done = 'done' }

local function cat_of(status)
  local sc = status and status.statusCategory or {}
  return CATEGORY[sc.key] or CATEGORY[sc.name] or 'new'
end

local function custom(f, label)
  local c = (f.customFields or {})[label]
  if c == nil then
    return nil
  end
  local v = c.value
  if type(v) == 'table' then
    return v.value or v.name or v
  end
  return v
end

-- Flatten an MCP issue into the shape the UI uses.
function M.normalize(raw)
  local f = raw.fields or {}
  local parent = f.parent or {}
  return {
    id = raw.id,
    key = raw.key,
    project = raw.key and raw.key:match('^(%u[%u%d_]*)%-'),
    summary = f.summary or '',
    status = f.status and f.status.name or '?',
    cat = cat_of(f.status),
    assignee = f.assignee and f.assignee.displayName or nil,
    assignee_id = f.assignee and f.assignee.accountId or nil,
    reporter = f.reporter and f.reporter.displayName or nil,
    priority = f.priority and f.priority.name or nil,
    type = f.issuetype and f.issuetype.name or '?',
    due = f.duedate,
    start = custom(f, config.fields.start_date),
    points = tonumber(custom(f, config.fields.story_points)),
    updated = f.updated,
    created = f.created,
    labels = f.labels or {},
    parent_key = parent.key,
    parent_summary = parent.fields and parent.fields.summary or nil,
    description = f.description,
    raw = raw,
  }
end

local function base_fields(project)
  local ids = M.field_ids(project)
  local fields = { 'summary', 'status', 'assignee', 'priority', 'issuetype', 'duedate', 'updated', 'created', 'labels', 'parent' }
  for _, key in ipairs({ 'start_date', 'story_points' }) do
    if ids[key] then
      fields[#fields + 1] = ids[key]
    end
  end
  return fields
end

local function project_from_jql(jql)
  return jql:match('[Pp][Rr][Oo][Jj][Ee][Cc][Tt]%s*=%s*"?(%u[%u%d_]*)') or jql:match('(%u[%u%d_]*)%-%d+')
end

-- Search with paging. opts: fields, limit, project (for field lookup)
function M.search(jql, opts)
  opts = opts or {}
  local limit = opts.limit or config.max_results
  local fields = opts.fields
  if not fields then
    -- Field ids need a project; fall back to a cheap search to find one.
    local project = opts.project or project_from_jql(jql)
    if not project and not cache.fields then
      local probe = call('searchJiraIssuesUsingJql', { jql = jql, maxResults = 1, fields = { 'summary' } })
      local first = (probe.issues or {})[1]
      project = first and first.key:match('^(%u[%u%d_]*)%-')
    end
    fields = project and base_fields(project) or base_fields(nil)
  end
  local out, token = {}, nil
  repeat
    -- compact view drops `parent`; evidence keeps it and still honours the field list
    local res = call('searchJiraIssuesUsingJql', {
      jql = jql,
      fields = fields,
      view = 'evidence',
      maxResults = math.min(100, limit - #out),
      nextPageToken = token,
    })
    for _, raw in ipairs(res.issues or {}) do
      out[#out + 1] = opts.raw and raw or M.normalize(raw)
    end
    token = res.nextPageToken
  until res.isLast or not token or #out >= limit
  return out
end

local function progress_of(children)
  local p = { total = 0, new = 0, indeterminate = 0, done = 0, points = 0, points_done = 0 }
  for _, c in ipairs(children) do
    p.total = p.total + 1
    p[c.cat] = p[c.cat] + 1
    if c.points then
      p.points = p.points + c.points
      if c.cat == 'done' then
        p.points_done = p.points_done + c.points
      end
    end
  end
  return p
end
M.progress_of = progress_of

-- Attach child progress to a list of parents, using one batched child query per 40 parents.
function M.attach_progress(parents)
  if #parents == 0 then
    return parents
  end
  local by_key, keys = {}, {}
  for _, e in ipairs(parents) do
    by_key[e.key] = { e = e, children = {} }
    keys[#keys + 1] = e.key
  end
  local ids = M.field_ids(parents[1].project)
  local fields = { 'parent', 'status' }
  if ids.story_points then
    fields[#fields + 1] = ids.story_points
  end
  local starters = {}
  for i = 1, #keys, 40 do
    local chunk = vim.list_slice(keys, i, i + 39)
    starters[#starters + 1] = a.starter(M.search, ('parent in (%s)'):format(table.concat(chunk, ',')), { fields = fields, limit = 2000 })
  end
  for _, list in ipairs(a.all(starters)) do
    for _, c in ipairs(list) do
      local slot = by_key[c.parent_key]
      if slot then
        table.insert(slot.children, c)
      end
    end
  end
  for _, slot in pairs(by_key) do
    slot.e.progress = progress_of(slot.children)
  end
  return parents
end

-- Epics (or initiatives) with child progress.
function M.epics(jql)
  return M.attach_progress(M.search(jql))
end

function M.children(epic_key)
  assert(epic_key:match('^%u[%u%d_]*%-%d+$'), 'invalid issue key')
  return M.search(('parent = %s ORDER BY Rank ASC'):format(epic_key), { project = epic_key:match('^(%u[%u%d_]*)%-') })
end

-- Full issue for the detail view (description as markdown, or html when markdown would lose content).
function M.issue(key)
  local project = key:match('^(%u[%u%d_]*)%-')
  local ids = M.field_ids(project)
  local res = call('getJiraIssue', { issueIdOrKey = key, view = 'evidence' })
  local issue = M.normalize(res)
  issue.format = res.appliedContentFormat or 'markdown'
  local f = res.fields or {}
  -- evidence drops empty custom fields, so read by id as a fallback
  if not issue.start and ids.start_date and f[ids.start_date] then
    issue.start = f[ids.start_date]
  end
  issue.links = {}
  for _, l in ipairs(f.issuelinks or {}) do
    local other = l.outwardIssue or l.inwardIssue
    if other then
      issue.links[#issue.links + 1] = {
        kind = l.outwardIssue and (l.type and l.type.outward) or (l.type and l.type.inward) or 'relates to',
        key = other.key,
        summary = other.fields and other.fields.summary or '',
        status = other.fields and other.fields.status and other.fields.status.name or '',
      }
    end
  end
  issue.subtasks = {}
  for _, s in ipairs(f.subtasks or {}) do
    issue.subtasks[#issue.subtasks + 1] = M.normalize(s)
  end
  return issue
end

-- Lightweight read for conflict checks.
function M.updated_at(key)
  local res = call('getJiraIssue', { issueIdOrKey = key, fields = { 'updated' } })
  return res.fields and res.fields.updated
end

function M.comments(key)
  local out, start = {}, 0
  local fmt = 'markdown'
  repeat
    local res = call('listJiraIssueComments', { issueIdOrKey = key, startAt = start, maxResults = 100, orderBy = 'created' })
    if res.appliedContentFormat == 'html' then
      fmt = 'html'
    end
    for _, c in ipairs(res.comments or {}) do
      out[#out + 1] = {
        id = c.id,
        author = c.author and c.author.displayName or '?',
        body = c.body or '',
        created = c.created,
        updated = c.updated,
        parent_id = c.parentId,
        format = res.appliedContentFormat or 'markdown',
      }
    end
    start = start + #(res.comments or {})
  until res.isLast ~= false or #(res.comments or {}) == 0
  return out, fmt
end

function M.transitions(key)
  return op('executeRead', 'listJiraIssueTransitions', { issueIdOrKey = key }).transitions or {}
end

function M.transition(key, id)
  return call('transitionJiraIssue', { issueIdOrKey = key, transitionId = id })
end

function M.edit(key, fields, extra)
  local args = vim.tbl_extend('force', { issueIdOrKey = key, fields = fields or vim.empty_dict() }, extra or {})
  return call('editJiraIssue', args)
end

-- which = 'start' | 'due'; value = 'YYYY-MM-DD' or vim.NIL to clear
function M.set_date(key, which, value)
  local field = 'duedate'
  if which == 'start' then
    field = M.field_ids(key:match('^(%u[%u%d_]*)%-')).start_date
    if not field then
      error('could not find the "' .. config.fields.start_date .. '" field on this site', 0)
    end
  end
  return M.edit(key, { [field] = value })
end

function M.set_description(key, body, fmt)
  return M.edit(key, { description = body }, { contentFormat = fmt or 'markdown' })
end

function M.assign(key, account_id)
  return M.edit(key, { assignee = account_id and { accountId = account_id } or vim.NIL })
end

function M.set_parent(key, parent_key)
  return M.edit(key, { parent = { key = parent_key } })
end

function M.rank(key, where, anchor)
  local extra = where == 'before' and { rankBeforeIssue = anchor } or { rankAfterIssue = anchor }
  local res = M.edit(key, nil, extra)
  if res and res.ranking and res.ranking.ranked == false then
    error('Jira did not apply the new order' .. (res.ranking.reason and (': ' .. res.ranking.reason) or ''), 0)
  end
  return res
end

function M.comment(key, body, fmt, comment_id)
  return call('addOrEditJiraIssueComment', {
    issueIdOrKey = key,
    commentBody = body,
    contentFormat = fmt or 'markdown',
    commentId = comment_id,
  })
end

-- People who can be assigned. Pass an issue key, or a project when the issue does not exist yet.
function M.assignable(key, query, project)
  local res = op('executeRead', 'listJiraIssueAssignableUsers', { issueKey = key, project = not key and project or nil, query = query })
  return res.users or res.values or (vim.islist(res) and res) or {}
end

-- opts: project, summary, type, parent, description, assignee, priority, labels, due, start
function M.create(opts)
  local extra = {}
  if opts.due then
    extra.duedate = opts.due
  end
  if opts.start then
    local id = M.field_ids(opts.project).start_date
    if id then
      extra[id] = opts.start
    end
  end
  local res = call('createJiraIssue', {
    projectKey = opts.project,
    summary = opts.summary,
    issueType = opts.type or config.default_issue_type,
    parent = opts.parent,
    description = opts.description,
    contentFormat = 'markdown',
    assignee = opts.assignee,
    priority = opts.priority,
    labels = opts.labels,
    additional_fields = next(extra) and extra or nil,
  })
  return res.key or (res.issue and res.issue.key), res
end

-- Unresolved blockers for the children of a parent: { [child key] = { 'KEY-1', ... } }
function M.blocked(parent_key)
  assert(parent_key:match('^%u[%u%d_]*%-%d+$'), 'invalid issue key')
  local link = config.blocks_link
  local out = {}
  local res = call('searchJiraIssuesUsingJql', {
    jql = ('parent = %s AND issueLinkType = "%s" AND statusCategory != Done'):format(parent_key, link.inward),
    fields = { 'issuelinks' },
    view = 'full',
    maxResults = 100,
  })
  for _, raw in ipairs(res.issues or {}) do
    for _, l in ipairs((raw.fields or {}).issuelinks or {}) do
      local blocker = l.inwardIssue
      if blocker and l.type and l.type.name == link.name then
        local sc = blocker.fields and blocker.fields.status and blocker.fields.status.statusCategory or {}
        if sc.key ~= 'done' then
          out[raw.key] = out[raw.key] or {}
          table.insert(out[raw.key], blocker.key)
        end
      end
    end
  end
  return out
end

function M.link_types()
  if not cache.link_types then
    cache.link_types = op('executeRead', 'listJiraIssueLinkTypes').issueLinkTypes or {}
  end
  return cache.link_types
end

-- "from <outward wording> to", e.g. link('Blocks', 'A-1', 'A-2') means A-1 blocks A-2.
function M.link(type_name, from, to)
  return op('executeWrite', 'createJiraIssueLink', { linkType = type_name, inwardIssue = from, outwardIssue = to })
end

-- Field changes on an issue at or after `since` (epoch seconds), oldest first.
function M.changelog(key, since)
  local dates = require('jira.dates')
  local function page(start)
    return op('executeRead', 'listJiraIssueChangelogs', { issueIdOrKey = key, startAt = start, maxResults = 50 })
  end
  local res = page(0)
  -- history is oldest-first, so the recent part is the last page (50 is the server's cap)
  if (res.total or 0) > 50 then
    res = page(res.total - 50)
  end
  local out = {}
  for _, entry in ipairs(res.values or {}) do
    local at = dates.epoch(entry.created)
    if at and at >= since then
      for _, item in ipairs(entry.items or {}) do
        out[#out + 1] = {
          at = at,
          created = entry.created,
          author = entry.author and entry.author.displayName or '?',
          field = item.field,
          from = item.fromString,
          to = item.toString,
        }
      end
    end
  end
  return out
end

-- Comments made at or after `since` (epoch seconds), newest first. Looks at the latest 10 only.
function M.recent_comments(key, since)
  local dates = require('jira.dates')
  local res = call('listJiraIssueComments', { issueIdOrKey = key, maxResults = 10, orderBy = '-created' })
  local out = {}
  for _, c in ipairs(res.comments or {}) do
    local at = dates.epoch(c.created)
    if at and at >= since then
      out[#out + 1] = { at = at, created = c.created, author = c.author and c.author.displayName or '?', body = c.body or '', format = res.appliedContentFormat }
    end
  end
  return out
end

function M.priorities(project)
  cache.priorities = cache.priorities or {}
  if not cache.priorities[project] then
    local types = M.issue_types(project)
    local pick = types[1]
    for _, t in ipairs(types) do
      if t.name == config.default_issue_type then
        pick = t
      end
    end
    local meta = op('executeRead', 'getJiraIssueTypeMetaWithFields', { projectIdOrKey = project, issueTypeId = pick.id, requiredFieldsOnly = false, maxResults = 200 })
    local names = {}
    for _, f in ipairs(meta.fields or {}) do
      if f.fieldId == 'priority' then
        for _, v in ipairs(f.allowedValues or {}) do
          names[#names + 1] = v.name
        end
      end
    end
    cache.priorities[project] = names
  end
  return cache.priorities[project]
end

function M.set_priority(key, name)
  return M.edit(key, { priority = { name = name } })
end

-- Replaces the whole label list.
function M.set_labels(key, labels)
  return M.edit(key, { labels = labels })
end

-- action = 'watch' | 'unwatch'. Always acts on you.
function M.watch(key, action)
  return op('executeWrite', 'watchJiraIssue', { issueIdOrKey = key, action = action })
end

-- The keys you watch, as a set. The MCP drops fields.watches, so JQL answers instead.
function M.watched(keys)
  keys = vim.tbl_filter(function(k)
    return k:match('^%u[%u%d_]*%-%d+$') ~= nil
  end, keys)
  local set = {}
  if #keys == 0 then
    return set
  end
  local jql = ('key in (%s) AND watcher = currentUser()'):format(table.concat(keys, ','))
  for _, raw in ipairs(M.search(jql, { fields = { 'summary' }, raw = true, limit = #keys })) do
    set[raw.key] = true
  end
  return set
end

-- Any user on the site (for @mentions), not only people assignable to an issue.
function M.find_users(query)
  local res = op('executeRead', 'lookupJiraAccountId', { query = query, maxResults = 20 })
  return vim.islist(res) and res or res.users or {}
end

-- Boards that can have sprints (kanban boards cannot).
function M.sprint_boards(project)
  local res = op('executeRead', 'listJiraBoards', { projectKeyOrId = project })
  local all = res.values or res.boards or (vim.islist(res) and res) or {}
  return vim.tbl_filter(function(b)
    return b.type ~= 'kanban'
  end, all)
end

-- { id, name, goal, startDate, endDate, state }
function M.active_sprint(board_id)
  local res = op('executeRead', 'getJiraBoardSprintData', { boardId = tostring(board_id), includeIssues = false })
  local sprint = res.resolvedSprint or res.sprint or res.activeSprint
  if not sprint or not sprint.id or (sprint.state and sprint.state ~= 'active') then
    error('no active sprint on that board', 0)
  end
  return sprint
end

function M.to_sprint(key, sprint_id)
  return call('transitionJiraIssue', { issueIdOrKey = key, sprintId = tonumber(sprint_id) })
end

-- n = number, or vim.NIL to clear
function M.set_points(key, n)
  local id = M.field_ids(key:match('^(%u[%u%d_]*)%-')).story_points
  if not id then
    error('could not find the "' .. config.fields.story_points .. '" field on this site', 0)
  end
  return M.edit(key, { [id] = n })
end

-- Cheap read for the statusline: { status, cat, summary }
function M.status_of(key)
  local res = call('getJiraIssue', { issueIdOrKey = key, fields = { 'status', 'summary' } })
  local f = res.fields or {}
  return { status = f.status and f.status.name or '?', cat = cat_of(f.status), summary = f.summary }
end

-- time = '2h 30m' style; started = now unless given
function M.log_work(key, time, comment)
  return op('executeWrite', 'addOrEditJiraIssueWorklog', {
    issueIdOrKey = key,
    timeSpent = time,
    comment = comment,
    started = os.date('!%Y-%m-%dT%H:%M:%S.000+0000'),
  })
end

-- Confluence pages and other URLs in the issue's Web links: { { relationship, title, url } }
function M.web_links(key)
  local res = op('executeRead', 'listJiraIssueRemoteIssueLinks', { issueIdOrKey = key })
  local out = {}
  local list = type(res) == 'table' and (vim.islist(res) and res or res.values or res.links) or {}
  for _, l in ipairs(list) do
    local o = l.object or {}
    if type(o.url) == 'string' then
      out[#out + 1] = { relationship = l.relationship, title = o.title, url = o.url }
    end
  end
  return out
end

-- The saved site without a network call (nil before the first login), for code that must not wait.
function M.site_cached()
  return cache.site or read_json(DATA_DIR .. '/site.json')
end

function M.clear_cache()
  cache.me, cache.types, cache.priorities, cache.link_types = nil, {}, nil, nil
end

return M
