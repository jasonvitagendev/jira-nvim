# jira.nvim

Epics and their tasks in a Neovim grid. Check progress, reorder, change status, set dates, edit descriptions and comment without leaving the editor.

```
┌ sidebar ─────────────────────────┬ grid ───────────────────────────────────────────────────────────────┐
│ ⚡ Jira  example.atlassian.net    │ ⚡ PROJ-12  Set up infrastructure in Dublin                          │
│ ──────────────────────────────── │    ◐ In Progress   Ana Diaz  ·  Must  ·  ↑ PROJ-1 Region split       │
│ ▾ Watching  3                    │                                                                     │
│  ◐ PROJ-12 ██████░░░░  36% Nov 20│   Timeline  Nov 10 ━━━━━━━━━━━●┄┄┄┄┄┄┄┄┄┄┄┄ Nov 20   7d left       │
│    Set up infrastructure in Dub… │   Progress  ██████████████░░░░░░░░░░  36%  8 done · 5 in progress  │
│  ◐ PROJ-30 █████░░░░░   9% Nov 29│                                                                     │
│    Resume handling               │ ╭─────┬─────────┬─────────────┬───────────┬───────────────┬─────╮  │
│                                  │ │ # ↓ │ Key     │ Summary     │ Assignee  │ Status        │ Due │  │
│ ▸ My open tasks                  │ ├─────┼─────────┼─────────────┼───────────┼───────────────┼─────┤  │
│                                  │ │   1 │ PROJ-21 │ Catalog …   │ Pat Ruiz  │ ● Done        │ —   │  │
│ ? help  / search  \f find  N new │ │   2 │ PROJ-49 │ Make CDK …  │ Ana Diaz  │ ◐ In Progress │ —   │  │
└──────────────────────────────────┴─────────────────────────────────────────────────────────────────────┘
```

## Install

Needs Neovim 0.10+, `curl` and macOS (tokens are kept in the Keychain).

```lua
-- lazy.nvim
{ 'jasonvitagendev/jira-nvim', cmd = 'Jira', opts = {} }
```

Then `:Jira login` once. A browser tab opens, you approve, and you're done. After that, tokens refresh on their own.

## Commands

| Command | What it does |
| --- | --- |
| `:Jira` | Open or close the Jira tab |
| `:Jira PROJ-12` | Open an issue (epics and initiatives open in the grid) |
| `:Jira issue` | Open the issue under the cursor, or the one in your git branch |
| `:Jira branch` | Open the issue in your git branch (`feature/PROJ-12-…`) |
| `:Jira find [text]` | Fuzzy find any issue (live search with Snacks, otherwise a prompt) |
| `:Jira search <text or JQL>` | Search epics by text, or run any JQL, in the sidebar |
| `:Jira mine` | Your open tasks across all projects |
| `:Jira view <name>` | Open a configured view |
| `:Jira sprint [PROJ]` | The active sprint of a project, grouped by status |
| `:Jira sidebar` | Hide or show the sidebar (`\b` in any Jira window) |
| `:Jira digest [days]` | What happened in your epics this week, ready to paste |
| `:Jira timeline [PROJ-12 or view]` | Timeline of an epic's tasks, an initiative's epics, or a view |
| `:Jira changes PROJ-12` | What changed in an epic and its tasks since yesterday |
| `:Jira start [PROJ-12]` | Start work: assign to you, In Progress, start date today, copy the branch name |
| `:Jira log [PROJ-12] 1h 30m [what you did]` | Log time. With no time, it asks |
| `:Jira new` | New task, epic or initiative (menu) |
| `:Jira epic [PROJ] [PROJ-1]` | New epic, optionally under an initiative |
| `:Jira initiative [PROJ]` | New initiative |
| `:Jira create PROJ-12` | New task in an epic (form) |
| `:Jira plan PROJ-12` | Many tasks in an epic, one per line |
| `:Jira comment PROJ-49` | Comment on an issue |
| `:Jira undo` | Undo the last change |
| `:Jira login` / `logout` / `status` | Auth |
| `:checkhealth jira` | Check setup |

## Keys

Press `?` in any Jira window for the full list.

Common edits are single keys. Everything else sits behind `\` (Vim's default `<LocalLeader>`), so it never shadows built-in `g` keys. With which-key installed, pressing `\` shows them all. Change it with `prefix`.

**Grid** (an epic's tasks, an initiative's epics, a sprint, a list of epics, or any JQL)

| Key | Action | Key | Action |
| --- | --- | --- | --- |
| `<CR>` | Open issue / epic | `p` | Peek description |
| `s` | Change status | `J` / `K` | Move down / up (rank) |
| `m` / `@` | Assign to me / someone | `E` | Move to another epic |
| `ds` / `dd` | Start / due date | `!` | Priority |
| `#` | Story points | `L` | Labels (`a, b` or `+a -b`) |
| `e` / `S` | Edit description / summary | `c` | Comment |
| `a` / `A` | Quick add / add with form | `P` | Add many, one per line |
| `N` | New task / epic / initiative | `D` | Set epic due date to the latest task due date |
| `o` / `O` | Cycle sort / reverse | `f` / `F` | Filter / clear |
| `H` | Hide done | `T` | Timeline |
| `zw` | Wide columns (full text, scroll with `zl` `zh`), remembered per grid | | |
| `\m` | Move a column (pick it, then where it goes), remembered for all task or epic grids | | |
| `za` `zM` `zR` | Fold groups | `u` | Undo last change |
| `yy` `yu` `yb` | Copy key / URL / branch name | | |

| Key | Action | Key | Action |
| --- | --- | --- | --- |
| `\w` | Start work | `\t` | Log time |
| `\S` | Move to the active sprint | `\l` | Link (blocks, relates, …) |
| `\g` | Group by status / assignee | `\c` | What changed |
| `\s` | Sprint view | `\d` | Weekly digest |
| `\f` | Find any issue | `\x` | Open in browser |
| `\b` | Hide / show sidebar | `<C-h>` | Focus sidebar (shows it if hidden) |

- **Several rows at once:** select rows with `V`, then press `s`, `m`, `@`, `!`, `#`, `L`, `E`, `ds`, `dd`, `\S`, `\l` or `\w`. You're asked once and the change goes to every row. With dates, `++1w` pushes each row out from its own date.
- **Epic header:** on the lines at the top of the grid, `ds`, `dd`, `s`, `e` and `c` apply to the epic itself.

**Detail**: same edit keys. `e` on a comment edits it, `R` replies to it (as a quoted comment), and `@` in a comment opens a people picker. `]]` / `[[` jump between sections and comments, `\p` goes to the parent, `<BS>` goes back. Sections and comments fold with `za` `zo` `zc` `zM` `zR`. On a web link, `<CR>` or `\x` opens it.

**Sidebar**: `<CR>` opens, `<Tab>` or `za` folds a section (`zo` `zc` `zM` `zR` too, and opening loads it), `]]` / `[[` jump between epics, `/` searches, `\f` finds, `\i` opens a key, `T` opens a timeline, `\s` / `\d` open the sprint / digest, `a` / `P` / `N` create, `ds` / `dd` / `s` work on the epic under the cursor.

The grid turns folding off, so a global `foldmethod=indent` (LazyVim's default) can't fold the table.

## Creating

```
N  ─▶  Task in WIDGET-5502          (form)
       Many tasks in WIDGET-5502    (one per line)
       Epic under IN-877            (form, parent is the initiative)
       Initiative                   (form, project guessed from your epics' parents)
```

**Many at once** (`P` or `:Jira plan PROJ-12`): one line per task, tags at the end of a line, indented lines become the description.

```
Set up Datadog monitors for Dublin
Cut over DNS @me due:fri !High #infra
  Do it after the freeze.
- [ ] Pasted checklists work too
```

- **Checked first:** names, dates and priorities are all checked before anything is created. A typo on line 9 creates nothing.
- **Partial runs are safe:** if Jira refuses one partway through, the ones already created are marked `#✓ KEY` in the buffer. Writing again won't duplicate them.
- **Order:** tasks are created in the order you wrote them.

## Checks

Shown under the epic header (and for initiatives, against their epics):

- **Tasks due after the epic.** `D` sets the epic due date to the latest task due date.
- **Started without a start date.**
- **All tasks done, epic still open.**
- **Stale tasks:** in progress with no update for 5+ days (`stale_days`).
- **Blocked tasks:** the `blocks` link points at something unfinished.

In the grid, `⚠` marks a task due after its epic, `◷` a stale one, and `⊘` a blocked one.

## Timeline

```
                Nov 10      Nov 17      Nov 24      Dec 01
WIDGET-5502 36% ┣━━━●━━━━━┫                          7d left
WIDGET-5504  0%      │     ┣─────┫                   14d left
WIDGET-5505  0%      │              ┣───────────┫    35d left
                     ▲ today
```

The green part of each bar shows how much is done. If today's marker is past the green, that item is behind.

## Working on an issue

```
git branch feature/PROJ-49-fix-login
        │
        ├─ :Jira branch        open PROJ-49
        ├─ :Jira start         assign to me · In Progress · start today · copy branch name
        ├─ :Jira log 1h 30m    log time (anything after the time is the work note)
        └─ statusline          ◐ PROJ-49 In Progress
```

- **Branch names:** the key has to be in capitals (`PROJ-49`), so `release-2024` is never read as a key. `yb` copies a name in this shape.
- **Start work** only changes what needs changing, and `u` reverses all of it in one step.
- **Which issue:** `:Jira start` and `:Jira log` use the branch first, then the key under the cursor. `:Jira issue` and `:Jira comment` use the cursor first.

**Statusline** (never blocks, reads the status at most every `statusline_ttl` seconds):

```lua
-- lualine
sections = { lualine_c = { function() return require('jira').statusline() end } }
-- plain statusline
vim.o.statusline = "%f %{v:lua.require'jira'.statusline()}"
```

## Sprint

`:Jira sprint PROJ` (or `\s`) opens the active sprint, grouped by status:

```
 ◷ Sprint 42  Team board
   Sprint    Nov 10 ━━━━━━━━━━━━●┄┄┄┄┄┄ Nov 21   8d left
   Progress  ██████████░░░░░░░░  55%  6 done · 3 in progress · 2 to do   13/24 pts
   Checks    ⚠ 2 not started, 2d left in the sprint
```

Kanban-only projects have no sprints, and it says so.

## Weekly digest

`:Jira digest` (or `\d`) lists your epics (`digest.jql`) and what happened to their tasks in the last 7 days: done, started, new and overdue, plus changes to the epic's own dates and status. `Y` copies it as markdown for Slack or a status update, and `-` / `+` change the number of days.

## Undo

`u` undoes the last status, assignee, date, priority, points, label, summary, epic or start-work change, including a change made to several rows at once. It keeps the last 30. Comments, links, sprint moves, logged time and new issues can't be undone.

## Dates

Date prompts take any of these:

```
2026-11-20   11-20   20        exact date (next one if it has passed)
today  tomorrow  fri  next mon  eow  eom
+3d  +2w  +1m  -1w             from today
++1w  --2d                     from the current value (push a due date out a week)
none                           clear it
```

Health shows in the sidebar, the epic list and the timeline:

- red = overdue
- yellow = due within 3 days, not started yet, or no due date

When you open Jira, it reminds you about any of **your** epics that need attention: overdue, no due date, not started yet, or all tasks done but still open.

## Editing

Descriptions and comments open in a split. `:w` sends, `:q` cancels.

- **HTML bodies:** some bodies come back from Jira as HTML because they hold mentions, images or panels. Those open as HTML so saving doesn't strip anything.
- **Conflict check:** if someone changes the issue while you're editing, you're asked before your version overwrites theirs.

## Config

```lua
require('jira').setup({
  site = 'example.atlassian.net', -- optional, picked up from your account
  views = {
    { name = 'My epics', kind = 'epics', jql = 'issuetype = Epic AND assignee = currentUser() AND statusCategory != Done' },
    { name = 'Team', kind = 'epics', jql = 'project = PROJ AND issuetype = Epic AND statusCategory != Done ORDER BY duedate' },
    { name = 'My open tasks', kind = 'tasks', jql = 'assignee = currentUser() AND statusCategory != Done' },
  },
  fields = { start_date = 'Start date', story_points = 'Story point estimate' },
  container_types = { 'Epic', 'Initiative' }, -- open in the grid, can be created
  initiative_project = nil,                  -- default project for new initiatives
  blocks_link = { name = 'Blocks', inward = 'is blocked by' },
  picker = 'auto',                           -- 'select' to skip Snacks
  stale_days = 5,
  due_soon_days = 3,
  hide_done = false,
  done_last = true,                          -- done rows at the bottom, open rows keep the sort (false = Jira rank only)
  columns = { tasks = { 'key', 'summary', 'status', 'assignee', 'due' } }, -- grid columns in order (`\m` moves one and remembers it)
  prefix = '\\',                             -- for \f, \x, \w, … ('<prefix>' in keymaps below)
  keymaps = { grid = { move_down = '<C-j>', move_up = '<C-k>' } }, -- false disables a key
  offline_cache = true,                      -- show the last lists at once, refresh in the background
  digest = { jql = 'issuetype = Epic AND assignee = currentUser() AND (statusCategory != Done OR updated >= -14d)', days = 7 },
  statusline_ttl = 120,
})
```

## Offline first

Opening Jira shows the lists from last time straight away, marked `3m ago ↻`, and swaps in fresh ones when they arrive. If the network is down, the saved lists stay up with the error underneath.

## How it talks to Jira

```
Neovim ── curl (config on stdin) ──▶ mcp.atlassian.com/v2/mcp ──▶ Jira
   │
   └─ OAuth tokens ─▶ macOS Keychain (service "jira.nvim")
```

- **Server:** Atlassian's MCP server, with OAuth 2.1 (PKCE and dynamic client registration). This came from `spike/auth_spike.lua`.
- **Tokens:** never on a command line (curl and `security` read them from stdin), never written to disk in plain text, and only sent over HTTPS.
- **Login callback:** listens on `127.0.0.1` only and accepts a single request carrying the expected `state`.
- **Local files:** `stdpath('data')/jira-nvim` (mode 0700) holds the client id, the chosen site and field ids. No secrets.
- **Grid settings:** `prefs.json` (mode 0600) remembers which grids you made wide with `zw` (by epic key or view name) and the column order from `\m`.
- **Saved lists:** `views-<site>.json` (mode 0600) holds the sidebar lists: keys, summaries, statuses, assignees and dates. No descriptions or comments. `:Jira logout` deletes it, and `offline_cache = false` stops writing it.
- **Web links:** only `http(s)` links open from the detail view.

## Tests

```sh
nvim -l tests/dates_test.lua && nvim -l tests/logic_test.lua && nvim -l tests/actions_test.lua
```
