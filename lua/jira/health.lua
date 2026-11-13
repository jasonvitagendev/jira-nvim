local M = {}

function M.check()
  local h = vim.health
  h.start('jira.nvim')
  if vim.fn.has('nvim-0.10') == 1 then
    h.ok('Neovim ' .. tostring(vim.version()))
  else
    h.error('Neovim 0.10+ is required')
  end
  if vim.fn.executable('curl') == 1 then
    h.ok('curl found')
  else
    h.error('curl not found')
  end
  if require('jira.keychain').available() then
    h.ok('macOS Keychain available for token storage')
  else
    h.error('token storage needs the macOS Keychain (`security`)')
  end
  local s = require('jira.auth').status()
  if not s.logged_in then
    h.warn('not logged in', { 'Run :Jira login' })
  elseif not s.has_refresh then
    h.warn('no refresh token stored, you will need to log in again when the access token expires')
  else
    h.ok(('logged in (access token %s)'):format(s.expires_in > 0 and ('valid for ' .. math.floor(s.expires_in / 60) .. ' min') or 'expired, refreshes on next use'))
  end
  local site = vim.fn.stdpath('data') .. '/jira-nvim/site.json'
  if vim.uv.fs_stat(site) then
    h.ok('site cached in ' .. site)
  else
    h.info('site not picked yet (happens on first use)')
  end
end

return M
