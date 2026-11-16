-- Run: nvim -l tests/logic_test.lua
vim.opt.rtp:prepend('.')
local fails = 0
local function eq(name, got, want)
  if not vim.deep_equal(got, want) then
    fails = fails + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

-- plan parsing ----------------------------------------------------------------
local parse = require('jira.ui.actions').parse_plan
local tasks = parse({
  '# One task per line.',
  '',
  'Set up Datadog monitors for Dublin',
  'Cut over DNS @me due:fri !High #infra #dublin',
  '  Do it after the freeze.',
  '  - check TTLs first',
  '',
  '- [ ] Pasted checklist item @Jamie Rivera',
  '2. Numbered item type:Bug',
  'Email alerts to ops@example.com',
  '#✓ WIDGET-1  already created',
})
eq('plan count', #tasks, 5)
eq('plan plain', tasks[1].summary, 'Set up Datadog monitors for Dublin')
eq('plan tags', { tasks[2].summary, tasks[2].assignee, tasks[2].due, tasks[2].priority, tasks[2].labels }, { 'Cut over DNS', 'me', 'fri', 'High', { 'infra', 'dublin' } })
eq('plan description', tasks[2].desc, { 'Do it after the freeze.', '- check TTLs first' })
-- only the last word is a tag, so "@Jamie Rivera" leaves "Rivera" as summary text: names with spaces need @first
eq('plan checklist', tasks[3].summary, 'Pasted checklist item @Jamie Rivera')
eq('plan numbered + type', { tasks[4].summary, tasks[4].type }, { 'Numbered item', 'Bug' })
eq('plan email is not a tag', tasks[5].summary, 'Email alerts to ops@example.com')
eq('plan line numbers', { tasks[1].line, tasks[2].line, tasks[2].last }, { 3, 4, 6 })

-- markdown -> html for mentions ----------------------------------------------------
local md = require('jira.md')
local m = { { name = 'Ann Lee', id = 'acc-1' }, { name = 'Ann', id = 'acc-2' } }
eq('md mention longest name wins', md.to_html('Thanks @Ann Lee and @Ann', m),
  '<p>Thanks <span data-type="mention" data-user-id="acc-1">@Ann Lee</span> and <span data-type="mention" data-user-id="acc-2">@Ann</span></p>')
eq('md escapes html', md.to_html('a < b & <script>', {}), '<p>a &lt; b &amp; &lt;script&gt;</p>')
eq('md blocks', md.to_html('## Title\n\n- one **bold**\n- two `x<y`\n\n> quoted', {}),
  '<h2>Title</h2><ul><li>one <strong>bold</strong></li><li>two <code>x&lt;y</code></li></ul><blockquote><p>quoted</p></blockquote>')
eq('md code fence', md.to_html('```lua\nlocal a = "<b>"\n```', {}), '<pre><code class="language-lua">local a = "&lt;b&gt;"</code></pre>')
eq('md link', md.to_html('[docs](https://example.com/a)', {}), '<p><a href="https://example.com/a">docs</a></p>')
eq('md lines in a paragraph', md.to_html('one\ntwo', {}), '<p>one<br>two</p>')
local html, why = md.to_html('| a | b |\n| - | - |', m)
eq('md table refused', { html, why ~= nil }, { nil, true })

-- checks --------------------------------------------------------------------------
local checks = require('jira.checks')
local now = os.time({ year = 2026, month = 11, day = 13, hour = 12 })
local parent = { key = 'P-1', type = 'Epic', status = 'In Progress', cat = 'indeterminate', start = nil, due = '2026-11-20' }
local kids = {
  { key = 'P-2', cat = 'indeterminate', due = '2026-11-25', updated = '2026-11-01T10:00:00.000+1100' },
  { key = 'P-3', cat = 'new', due = '2026-11-18', blocked_by = { 'X-9' }, updated = '2026-11-12T10:00:00.000+1100' },
  { key = 'P-4', cat = 'done', due = '2026-12-30', updated = '2026-11-01T10:00:00.000+1100' },
}
eq('row late + stale', checks.row(parent, kids[1], now), { late = true, stale = 12 })
eq('row blocked', checks.row(parent, kids[2], now), { blocked = { 'X-9' } })
eq('row done is quiet', checks.row(parent, kids[3], now), {})
local findings, suggest = checks.parent(parent, kids, now)
eq('suggest latest open child due', suggest, '2026-11-25')
local texts = vim.tbl_map(function(f)
  return f.text
end, findings)
eq('parent findings', #texts, 4)
eq('no start but started', vim.tbl_contains(texts, 'Work has started but there is no start date. Set it with ds.'), true)
local all_done = { { key = 'P-5', cat = 'done' } }
eq('all done still open', checks.parent(parent, all_done, now)[1].text, 'All 1 are done but this is still In Progress. Close it with s.')
eq('epic health all done', checks.health({ cat = 'indeterminate', due = '2026-12-01', progress = { total = 2, done = 2, new = 0, indeterminate = 0 } }, now).text, 'all tasks done, still open')

-- finder JQL ------------------------------------------------------------------------
local jql = require('jira.ui.finder').jql_for
eq('jql key', jql('widget-12'), 'key = WIDGET-12')
eq('jql text', jql('dublin dns'), 'text ~ "dublin dns*" ORDER BY updated DESC')
eq('jql quotes stripped', jql('a" OR 1=1'), 'a" OR 1=1') -- has "=", so it is treated as the user's own JQL
eq('jql quote in text', jql('say "hi'), 'text ~ "say  hi*" ORDER BY updated DESC')
eq('jql passthrough', jql('project = X ORDER BY updated'), 'project = X ORDER BY updated')

-- branch -> key ------------------------------------------------------------------
local branch = require('jira.git').key_from_branch
eq('branch plain', branch('WIDGET-12-fix-login'), 'WIDGET-12')
eq('branch with folder', branch('feature/OP-1677-dublin'), 'OP-1677')
eq('branch lower case ignored', branch('release-2024'), nil)
eq('branch key glued to a word ignored', branch('fooWIDGET-1'), nil)
eq('branch main', branch('main'), nil)
eq('branch nil', branch(nil), nil)

-- durations and :Jira log args --------------------------------------------------------
local dur = require('jira.ui.actions').parse_duration
eq('dur hours', dur('2h'), '2h')
eq('dur compact', dur('1h30m'), '1h 30m')
eq('dur spaced', dur('1h 30m'), '1h 30m')
eq('dur bare number is hours', dur('3'), '3h')
eq('dur decimal hours', dur('1.5h'), '1h 30m')
eq('dur decimal minutes refused', dur('1.5m'), nil)
eq('dur junk', dur('fixed'), nil)
eq('dur zero', dur('0h'), nil)
local log_args = require('jira').parse_log_args
eq('log key time comment', { log_args({ 'proj-1', '1h', '30m', 'fixed', 'the', 'build' }) }, { 'PROJ-1', '1h 30m', 'fixed the build' })
eq('log time only', { log_args({ '45m' }) }, { nil, '45m', nil })
eq('log number in comment stays', { log_args({ '2h', 'reviewed', '3', 'PRs' }) }, { nil, '2h', 'reviewed 3 PRs' })

-- web link titles -----------------------------------------------------------------
local title = require('jira.ui.detail').link_title
eq('link real title', title({ title = 'Runbook', url = 'https://x.atlassian.net/wiki/x' }), 'Runbook')
eq('link slug', title({ title = 'Page', url = 'https://x.atlassian.net/wiki/spaces/ENG/pages/123/Dublin+Cut%2Dover' }), 'Dublin Cut-over')
eq('link page id', title({ title = 'Wiki Page', url = 'https://x.atlassian.net/wiki/pages/viewpage.action?pageId=123456789' }), 'Confluence page 123456789')

-- dates in UTC (sprints) -------------------------------------------------------------
local dates = require('jira.dates')
eq('epoch Z equals +0000', dates.epoch('2026-03-30T13:00:00.000Z'), dates.epoch('2026-03-30T13:00:00.000+0000'))
eq('epoch no zone', dates.epoch('2026-03-30T13:00:00'), nil)

-- cache keeps list fields only --------------------------------------------------------
local stripped = require('jira.cache').strip({ { key = 'P-1', summary = 's', description = 'secret', raw = { x = 1 }, progress = { total = 1 } } })
eq('cache strip', stripped, { { key = 'P-1', summary = 's', progress = { total = 1 } } })

-- grid column order -------------------------------------------------------------------
local place = require('jira.ui.grid')._place
eq('column after another', place({ 'key', 'summary', 'assignee', 'status' }, 'status', 'summary'), { 'key', 'summary', 'status', 'assignee' })
eq('column to the right', place({ 'key', 'summary', 'status' }, 'key', 'status'), { 'summary', 'status', 'key' })
eq('column first', place({ 'key', 'summary', 'status' }, 'status', nil), { 'status', 'key', 'summary' })

-- done rows sink -------------------------------------------------------------------------
local visible = require('jira.ui.grid')._visible
local function keys_of(st)
  return vim.tbl_map(function(it)
    return it.key
  end, visible(st))
end
local rows = {
  { key = 'A', cat = 'done', status = 'Done', priority = 'High' },
  { key = 'B', cat = 'new', status = 'To Do', priority = 'Low' },
  { key = 'C', cat = 'indeterminate', status = 'In Progress', priority = 'High' },
  { key = 'D', cat = 'new', status = 'To Do', priority = 'Medium' },
}
local view = { kind = 'tasks' }
eq('done last keeps rank', keys_of({ items = rows, view = view, sort = 'rank' }), { 'B', 'C', 'D', 'A' })
eq('done last by priority', keys_of({ items = rows, view = view, sort = 'priority' }), { 'C', 'D', 'B', 'A' })
eq('done last reversed', keys_of({ items = rows, view = view, sort = 'rank', reverse = true }), { 'D', 'C', 'B', 'A' })
require('jira.config').options.done_last = false
eq('rank only', keys_of({ items = rows, view = view, sort = 'rank' }), { 'A', 'B', 'C', 'D' })
eq('rank only reversed', keys_of({ items = rows, view = view, sort = 'rank', reverse = true }), { 'D', 'C', 'B', 'A' })
require('jira.config').options.done_last = true

-- digest ----------------------------------------------------------------------------
local digest = require('jira.ui.digest')
local epic = { key = 'P-1', summary = 'Dublin', status = 'In Progress', cat = 'indeterminate', due = '2026-11-20', progress = { total = 4, done = 2, new = 1, indeterminate = 1 } }
local quiet = { key = 'P-9', summary = 'Quiet one', status = 'To Do', cat = 'new', progress = { total = 0, done = 0, new = 0, indeterminate = 0 } }
local out = digest.render({
  days = 7,
  epics = {
    { epic = quiet, done = {}, started = {}, added = {}, overdue = {}, changes = {} },
    {
      epic = epic,
      done = { { key = 'P-2', summary = 'DNS' } },
      started = {},
      added = {},
      overdue = { { key = 'P-3', summary = 'Monitors', due = '2026-11-10' } },
      changes = { { field = 'Due date', from = '2026-11-13', to = '2026-11-20' } },
    },
  },
}, now)
eq('digest', out, {
  '# Weekly digest · Nov 06 – Nov 13',
  '',
  '_2 epics · 1 done · 0 started · 0 added_',
  '',
  '## P-1 Dublin',
  'In Progress · 50% (2/4) · due Nov 20 · 7d left',
  '- Due date: Nov 13 → Nov 20',
  '- Done (1)',
  '  - P-2 DNS',
  '- Overdue (1)',
  '  - P-3 Monitors (due Nov 10)',
  '',
  '## No changes',
  '- P-9 Quiet one',
})

print(fails == 0 and 'logic: all passed' or ('logic: ' .. fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
