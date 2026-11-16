local M = {}

M.defaults = {
  -- Atlassian site, e.g. 'example.atlassian.net'. nil picks it up from your account (asks when you have several).
  site = nil,
  -- Sidebar sections. kind = 'epics' lists epics with progress; kind = 'tasks' lists any issues.
  views = {
    { name = 'My epics', kind = 'epics', jql = 'issuetype = Epic AND assignee = currentUser() AND statusCategory != Done ORDER BY duedate ASC' },
    { name = 'Watching', kind = 'epics', jql = 'issuetype = Epic AND watcher = currentUser() AND statusCategory != Done ORDER BY duedate ASC' },
    {
      name = 'Recent epics',
      kind = 'epics',
      jql = 'issuetype = Epic AND (assignee = currentUser() OR reporter = currentUser() OR watcher = currentUser()) AND updated >= -30d ORDER BY updated DESC',
    },
    { name = 'My open tasks', kind = 'tasks', jql = 'assignee = currentUser() AND issuetype != Epic AND statusCategory != Done ORDER BY updated DESC' },
  },
  -- Field names (as shown in Jira). Their ids are looked up per project.
  fields = { start_date = 'Start date', story_points = 'Story point estimate' },
  default_issue_type = 'Task',
  -- Issue types that hold other issues. They open in the grid instead of the detail view.
  container_types = { 'Epic', 'Initiative' },
  -- Where new initiatives go. nil = taken from the parents of the epics you have loaded, or asked.
  initiative_project = nil,
  -- The link type that means "blocked", as named on your site.
  blocks_link = { name = 'Blocks', inward = 'is blocked by' },
  -- Fields shown by "what changed" (lower case).
  changes_fields = { 'status', 'assignee', 'duedate', 'start date', 'priority', 'summary', 'labels', 'parent', 'sprint', 'resolution', 'description' },
  due_soon_days = 3,
  -- An in-progress task with no update for this many days is flagged as stale.
  stale_days = 5,
  hide_done = false,
  -- Done rows go to the bottom of the grid, below the open ones, whatever the sort.
  done_last = true,
  -- Grid columns show their full text (the window scrolls sideways) instead of fitting the window. Toggle with zw.
  wide_columns = false,
  max_results = 300,
  sidebar_width = 44,
  -- Issue finder (gf, :Jira find): 'auto' uses Snacks when installed, 'select' always uses vim.ui.select.
  picker = 'auto',
  -- Grid columns in order. Remove any you don't want.
  columns = {
    tasks = { 'rank', 'flags', 'key', 'summary', 'assignee', 'type', 'status', 'priority', 'points', 'start', 'due', 'updated' },
    epics = { 'flags', 'key', 'summary', 'assignee', 'status', 'progress', 'start', 'due', 'left' },
  },
  icons = {
    todo = '○',
    progress = '◐',
    done = '●',
    expanded = '▾',
    collapsed = '▸',
    warn = '⚠',
    epic = '⚡',
    bar_fill = '█',
    bar_empty = '░',
    late = '⚠',
    stale = '◷',
    blocked = '⊘',
    selected = '▌',
  },
  -- Prefix for the less common keys (find, open in browser, link, sprint, …). `\` is Vim's default <LocalLeader>.
  prefix = '\\',
  -- Override any key by action name, or set it to false to disable. See `?` in any jira window.
  keymaps = {},
  -- Keep the last sidebar lists on disk so Jira opens instantly, then refresh in the background.
  offline_cache = true,
  -- :Jira digest. Epics in this JQL, and what happened to their tasks in the last `days`.
  digest = {
    jql = 'issuetype = Epic AND assignee = currentUser() AND (statusCategory != Done OR updated >= -14d) ORDER BY duedate ASC',
    days = 7,
  },
  -- require('jira').statusline(): seconds before the branch issue's status is read again.
  statusline_ttl = 120,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  -- Lists replace rather than merge
  if opts and opts.views then
    M.options.views = opts.views
  end
  return M.options
end

return setmetatable(M, {
  __index = function(_, k)
    return M.options[k]
  end,
})
