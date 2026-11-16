if vim.g.loaded_jira then
  return
end
vim.g.loaded_jira = true

if vim.fn.has('nvim-0.10') == 0 then
  vim.notify('jira.nvim needs Neovim 0.10+', vim.log.levels.ERROR)
  return
end

require('jira.ui.hl').setup()

vim.api.nvim_create_user_command('Jira', function(opts)
  require('jira').command(opts)
end, {
  nargs = '*',
  desc = 'Jira: open, branch, find, search, mine, view, sprint, digest, sidebar, timeline, changes, new, epic, initiative, create, plan, start, log, comment, undo, login, logout, status',
  complete = function(arglead, line)
    return require('jira').complete(arglead, line)
  end,
})
