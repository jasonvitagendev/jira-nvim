-- Keymap registry: one list per window type, so `?` help and user overrides come from the same place.
-- "<prefix>" in a key stands for config.prefix (`\` by default).
local config = require('jira.config')

local M = {}

-- { action, default key(s), description, group, also works on a visual selection }
M.defs = {
  sidebar = {
    { 'open', '<CR>', 'Open epic / section in the grid', 'Navigate' },
    { 'toggle', '<Tab>', 'Expand or collapse section', 'Navigate' },
    { 'next_epic', ']]', 'Next epic', 'Navigate' },
    { 'prev_epic', '[[', 'Previous epic', 'Navigate' },
    { 'search', '/', 'Search epics (text or JQL)', 'Navigate' },
    { 'find', '<prefix>f', 'Fuzzy find any issue', 'Navigate' },
    { 'go_key', '<prefix>i', 'Open issue by key', 'Navigate' },
    { 'sidebar_toggle', '<prefix>b', 'Hide sidebar', 'Navigate' },
    { 'timeline', 'T', 'Timeline of this section', 'Navigate' },
    { 'sprint_view', '<prefix>s', 'Active sprint of a project', 'Navigate' },
    { 'digest', '<prefix>d', 'Weekly digest of your epics', 'Navigate' },
    { 'fold_toggle', { 'za', 'zA' }, 'Toggle section', 'Folds' },
    { 'fold_open', { 'zo', 'zO' }, 'Open section', 'Folds' },
    { 'fold_close', { 'zc', 'zC' }, 'Close section', 'Folds' },
    { 'fold_open_all', 'zR', 'Open all sections', 'Folds' },
    { 'fold_close_all', 'zM', 'Close all sections', 'Folds' },
    { 'status', 's', 'Change status', 'Edit' },
    { 'start', 'ds', 'Set start date', 'Dates' },
    { 'due', 'dd', 'Set due date', 'Dates' },
    { 'add', 'a', 'Add task to epic', 'Create' },
    { 'plan', 'P', 'Add many tasks to epic (one per line)', 'Create' },
    { 'new', 'N', 'New… (task, epic, initiative)', 'Create' },
    { 'watch', '<prefix>W', 'Watch / unwatch', 'Edit' },
    { 'undo', 'u', 'Undo last change', 'Edit' },
    { 'browser', '<prefix>x', 'Open in browser', 'Other' },
    { 'yank_key', 'yy', 'Copy key', 'Other' },
    { 'yank_url', 'yu', 'Copy URL', 'Other' },
    { 'refresh', 'r', 'Refresh', 'Other' },
    { 'help', '?', 'Help', 'Other' },
    { 'close', 'q', 'Close Jira', 'Other' },
  },
  grid = {
    { 'open', '<CR>', 'Open issue (epic rows open the epic)', 'Navigate' },
    { 'peek', 'p', 'Peek description in a float', 'Navigate' },
    { 'back', '<BS>', 'Back', 'Navigate' },
    { 'sidebar', '<C-h>', 'Focus sidebar', 'Navigate' },
    { 'sidebar_toggle', '<prefix>b', 'Hide / show sidebar', 'Navigate' },
    { 'find', '<prefix>f', 'Fuzzy find any issue', 'Navigate' },
    { 'timeline', 'T', 'Timeline of these rows', 'Navigate' },
    { 'changes', '<prefix>c', 'What changed since yesterday', 'Navigate' },
    { 'sprint_view', '<prefix>s', 'Active sprint of this project', 'Navigate' },
    { 'digest', '<prefix>d', 'Weekly digest of your epics', 'Navigate' },
    { 'status', 's', 'Change status', 'Edit (V selects rows)', true },
    { 'assign_me', 'm', 'Assign to me', 'Edit (V selects rows)', true },
    { 'assign', '@', 'Assign to someone', 'Edit (V selects rows)', true },
    { 'priority', '!', 'Set priority', 'Edit (V selects rows)', true },
    { 'points', '#', 'Set story points', 'Edit (V selects rows)', true },
    { 'labels', 'L', 'Edit labels', 'Edit (V selects rows)', true },
    { 'sprint', '<prefix>S', 'Move to the active sprint', 'Edit (V selects rows)', true },
    { 'link', '<prefix>l', 'Link to another issue (blocks, relates, …)', 'Edit (V selects rows)', true },
    { 'move_epic', 'E', 'Move to another epic', 'Edit (V selects rows)', true },
    { 'start', 'ds', 'Set start date (header line = epic)', 'Edit (V selects rows)', true },
    { 'due', 'dd', 'Set due date (header line = epic)', 'Edit (V selects rows)', true },
    { 'start_work', '<prefix>w', 'Start work: assign to me, In Progress, start today, copy branch', 'Edit (V selects rows)', true },
    { 'watch', '<prefix>W', 'Watch / unwatch', 'Edit (V selects rows)', true },
    { 'log_work', '<prefix>t', 'Log time spent', 'Edit' },
    { 'summary', 'S', 'Edit summary', 'Edit' },
    { 'description', 'e', 'Edit description', 'Edit' },
    { 'comment', 'c', 'Add comment', 'Edit' },
    { 'apply_due', 'D', 'Set the epic due date to the latest task due date', 'Edit' },
    { 'undo', 'u', 'Undo last change', 'Edit' },
    { 'add', 'a', 'Quick add', 'Create' },
    { 'add_form', 'A', 'Add with all fields', 'Create' },
    { 'plan', 'P', 'Add many (one per line)', 'Create' },
    { 'new', 'N', 'New… (task, epic, initiative)', 'Create' },
    { 'move_down', 'J', 'Move down (rank)', 'Organise' },
    { 'move_up', 'K', 'Move up (rank)', 'Organise' },
    { 'group', '<prefix>g', 'Group by: none / status / assignee', 'View' },
    { 'fold_toggle', { 'za', '<Tab>' }, 'Fold / unfold group (zo zc zM zR too)', 'View' },
    { 'fold_open', 'zo', nil, 'View' },
    { 'fold_close', 'zc', nil, 'View' },
    { 'fold_open_all', 'zR', nil, 'View' },
    { 'fold_close_all', 'zM', nil, 'View' },
    { 'sort', 'o', 'Cycle sort column', 'View' },
    { 'reverse', 'O', 'Reverse sort', 'View' },
    { 'filter', 'f', 'Filter rows', 'View' },
    { 'clear_filter', 'F', 'Clear filter', 'View' },
    { 'hide_done', 'H', 'Hide / show done', 'View' },
    { 'wide', 'zw', 'Wide columns: show full text, scroll sideways (remembered per grid)', 'View' },
    { 'move_column', '<prefix>m', 'Move a column (remembered)', 'View' },
    { 'browser', '<prefix>x', 'Open in browser', 'Other' },
    { 'yank_key', 'yy', 'Copy key', 'Other' },
    { 'yank_url', 'yu', 'Copy URL', 'Other' },
    { 'yank_branch', 'yb', 'Copy git branch name', 'Other' },
    { 'refresh', 'r', 'Refresh', 'Other' },
    { 'help', '?', 'Help', 'Other' },
    { 'close', 'q', 'Close Jira', 'Other' },
  },
  detail = {
    { 'open', '<CR>', 'Open linked issue, web link or parent under cursor', 'Navigate' },
    { 'back', '<BS>', 'Back', 'Navigate' },
    { 'parent', '<prefix>p', 'Go to parent', 'Navigate' },
    { 'sidebar_toggle', '<prefix>b', 'Hide / show sidebar', 'Navigate' },
    { 'next_section', ']]', 'Next section / comment', 'Navigate' },
    { 'prev_section', '[[', 'Previous section / comment', 'Navigate' },
    -- native folds, listed for help only (no handler, so no mapping)
    { 'fold', 'za', 'Fold section / comment (zo zc zM zR work too)', 'Navigate' },
    { 'changes', '<prefix>c', 'What changed since yesterday', 'Navigate' },
    { 'status', 's', 'Change status', 'Edit' },
    { 'assign_me', 'm', 'Assign to me', 'Edit' },
    { 'assign', '@', 'Assign to someone', 'Edit' },
    { 'priority', '!', 'Set priority', 'Edit' },
    { 'points', '#', 'Set story points', 'Edit' },
    { 'labels', 'L', 'Edit labels', 'Edit' },
    { 'sprint', '<prefix>S', 'Move to the active sprint', 'Edit' },
    { 'link', '<prefix>l', 'Link to another issue (blocks, relates, …)', 'Edit' },
    { 'start_work', '<prefix>w', 'Start work: assign to me, In Progress, start today, copy branch', 'Edit' },
    { 'watch', '<prefix>W', 'Watch / unwatch', 'Edit' },
    { 'log_work', '<prefix>t', 'Log time spent', 'Edit' },
    { 'summary', 'S', 'Edit summary', 'Edit' },
    { 'edit', 'e', 'Edit description, or the comment under cursor', 'Edit' },
    { 'comment', 'c', 'Add comment (@ mentions someone)', 'Edit' },
    { 'reply', 'R', 'Reply to the comment under cursor (quoted)', 'Edit' },
    { 'start', 'ds', 'Set start date', 'Dates' },
    { 'due', 'dd', 'Set due date', 'Dates' },
    { 'move_epic', 'E', 'Move to another epic', 'Edit' },
    { 'undo', 'u', 'Undo last change', 'Edit' },
    { 'new', 'N', 'New… (task, epic, initiative)', 'Create' },
    { 'browser', '<prefix>x', 'Open in browser (the web link under cursor, else the issue)', 'Other' },
    { 'yank_key', 'yy', 'Copy key', 'Other' },
    { 'yank_url', 'yu', 'Copy URL', 'Other' },
    { 'yank_branch', 'yb', 'Copy git branch name', 'Other' },
    { 'refresh', 'r', 'Refresh', 'Other' },
    { 'help', '?', 'Help', 'Other' },
    { 'close', 'q', 'Close', 'Other' },
  },
  timeline = {
    { 'open', '<CR>', 'Open', 'Navigate' },
    { 'back', { '<BS>', 'T' }, 'Back to the grid', 'Navigate' },
    { 'sidebar_toggle', '<prefix>b', 'Hide / show sidebar', 'Navigate' },
    { 'status', 's', 'Change status', 'Edit' },
    { 'start', 'ds', 'Set start date', 'Edit' },
    { 'due', 'dd', 'Set due date', 'Edit' },
    { 'undo', 'u', 'Undo last change', 'Edit' },
    { 'browser', '<prefix>x', 'Open in browser', 'Other' },
    { 'refresh', 'r', 'Refresh', 'Other' },
    { 'help', '?', 'Help', 'Other' },
    { 'close', 'q', 'Close Jira', 'Other' },
  },
  changes = {
    { 'open', '<CR>', 'Open issue', 'Navigate' },
    { 'back', '<BS>', 'Back', 'Navigate' },
    { 'earlier', '-', 'One day further back', 'View' },
    { 'later', '+', 'One day less', 'View' },
    { 'sidebar_toggle', '<prefix>b', 'Hide / show sidebar', 'View' },
    { 'refresh', 'r', 'Refresh', 'Other' },
    { 'help', '?', 'Help', 'Other' },
    { 'close', 'q', 'Close Jira', 'Other' },
  },
  digest = {
    { 'open', '<CR>', 'Open the issue under the cursor', 'Navigate' },
    { 'back', '<BS>', 'Back', 'Navigate' },
    { 'earlier', '-', 'One day further back', 'View' },
    { 'later', '+', 'One day less', 'View' },
    { 'sidebar_toggle', '<prefix>b', 'Hide / show sidebar', 'View' },
    { 'copy', 'Y', 'Copy the digest (markdown)', 'Other' },
    { 'browser', '<prefix>x', 'Open the issue under the cursor in browser', 'Other' },
    { 'refresh', 'r', 'Refresh', 'Other' },
    { 'help', '?', 'Help', 'Other' },
    { 'close', 'q', 'Close Jira', 'Other' },
  },
}

-- A def's key can be one lhs or a list of them; returns a list (empty when disabled).
local function keys_for(scope, def)
  local o = (config.keymaps or {})[scope]
  local lhs = def[2]
  if o and o[def[1]] ~= nil then
    lhs = o[def[1]]
  end
  if not lhs then
    return {}
  end
  local prefix = config.prefix or '\\'
  return vim.tbl_map(function(k)
    return (k:gsub('<prefix>', function()
      return prefix
    end))
  end, type(lhs) == 'table' and lhs or { lhs })
end

local function key_for(scope, def)
  local list = keys_for(scope, def)
  return #list > 0 and table.concat(list, ' ') or nil
end

-- Actions that behave the same in every window.
local shared = {
  sidebar_toggle = function()
    require('jira.ui.layout').toggle_sidebar()
  end,
}

function M.apply(buf, scope, handlers)
  for _, def in ipairs(M.defs[scope]) do
    local fn = handlers[def[1]] or shared[def[1]]
    for _, lhs in ipairs(fn and keys_for(scope, def) or {}) do
      -- defs flagged for selections are mapped in visual mode too; the handler reads the range itself
      vim.keymap.set(def[5] and { 'n', 'x' } or 'n', lhs, fn, { buffer = buf, nowait = #lhs == 1, silent = true, desc = 'jira: ' .. (def[3] or def[1]) })
    end
  end
  -- name the prefix group in which-key's popup, when it is installed
  if package.loaded['which-key'] then
    pcall(function()
      require('which-key').add({ { config.prefix or '\\', group = 'jira', buffer = buf, mode = { 'n', 'x' } } })
    end)
  end
end

function M.hint(scope, actions)
  local parts = {}
  for _, def in ipairs(M.defs[scope]) do
    if vim.tbl_contains(actions, def[1]) then
      local lhs = key_for(scope, def)
      if lhs then
        parts[#parts + 1] = lhs .. ' ' .. def[1]:gsub('_', ' ')
      end
    end
  end
  return table.concat(parts, '  ')
end

-- The key bound to an action, for hints drawn in buffers (nil when disabled).
function M.lhs(scope, action)
  for _, def in ipairs(M.defs[scope]) do
    if def[1] == action then
      return key_for(scope, def)
    end
  end
end

function M.help(scope)
  local b = require('jira.ui.render').builder()
  local order, groups = {}, {}
  for _, def in ipairs(M.defs[scope]) do
    local lhs = def[3] and key_for(scope, def)
    if lhs then
      if not groups[def[4]] then
        groups[def[4]] = {}
        order[#order + 1] = def[4]
      end
      table.insert(groups[def[4]], { lhs, def[3] })
    end
  end
  for gi, g in ipairs(order) do
    if gi > 1 then
      b:nl()
    end
    b:nl():add(' ' .. g, 'JiraSection')
    for _, item in ipairs(groups[g]) do
      b:nl():add('  ' .. require('jira.ui.render').pad(item[1], 9), 'JiraKey'):add(item[2])
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  b:render(buf)
  local width = 0
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local height = math.min(#b.lines, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width + 2,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' jira · ' .. scope .. ' keys ',
    title_pos = 'center',
  })
  vim.bo[buf].bufhidden = 'wipe'
  for _, lhs in ipairs({ 'q', '<Esc>', '?' }) do
    vim.keymap.set('n', lhs, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_win_close, win, true)
    end,
  })
end

return M
