-- Highlight groups. Colours come from the active colorscheme, so the UI follows light and dark themes.
local M = {}

M.ns = vim.api.nvim_create_namespace('jira')

local function color(group, attr)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  return ok and hl[attr] or nil
end

local function blend(fg, bg, alpha)
  if not fg or not bg then
    return nil
  end
  local function ch(c, shift)
    return math.floor(c / 2 ^ shift) % 256
  end
  local out = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local v = math.floor(ch(fg, shift) * alpha + ch(bg, shift) * (1 - alpha) + 0.5)
    out = out + v * 2 ^ shift
  end
  return out
end

local LINKS = {
  JiraTitle = 'Title',
  JiraKey = 'Identifier',
  JiraDim = 'Comment',
  JiraBorder = 'FloatBorder',
  JiraHeader = 'Bold',
  JiraSection = 'Title',
  JiraLabel = 'Comment',
  JiraMe = 'Special',
  JiraTodo = 'Comment',
  JiraProgress = 'DiagnosticInfo',
  JiraDone = 'DiagnosticOk',
  JiraOverdue = 'DiagnosticError',
  JiraSoon = 'DiagnosticWarn',
  JiraMissing = 'DiagnosticWarn',
  JiraOk = 'DiagnosticOk',
  JiraBarEmpty = 'NonText',
  JiraToday = 'DiagnosticWarn',
  JiraAuthor = 'Function',
  JiraHint = 'Comment',
  JiraEpic = 'Constant',
  JiraLink = 'Underlined',
}

function M.setup()
  for name, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  local bg = color('Normal', 'bg')
  local fg = color('Normal', 'fg')
  -- Subtle zebra rows and tinted status chips when the theme has real colours.
  if bg and fg then
    vim.api.nvim_set_hl(0, 'JiraZebra', { bg = blend(fg, bg, 0.035), default = true })
    vim.api.nvim_set_hl(0, 'JiraHeaderRow', { bg = blend(fg, bg, 0.08), bold = true, default = true })
    for _, pair in ipairs({ { 'JiraChipTodo', 'JiraTodo' }, { 'JiraChipProgress', 'JiraProgress' }, { 'JiraChipDone', 'JiraDone' } }) do
      local c = color(pair[2], 'fg') or fg
      vim.api.nvim_set_hl(0, pair[1], { fg = c, bg = blend(c, bg, 0.16), default = true })
    end
    for _, pair in ipairs({ { 'JiraBarDone', 'JiraDone' }, { 'JiraBarProgress', 'JiraProgress' } }) do
      vim.api.nvim_set_hl(0, pair[1], { fg = color(pair[2], 'fg') or fg, default = true })
    end
  else
    vim.api.nvim_set_hl(0, 'JiraZebra', { default = true })
    vim.api.nvim_set_hl(0, 'JiraHeaderRow', { link = 'Bold', default = true })
    vim.api.nvim_set_hl(0, 'JiraChipTodo', { link = 'JiraTodo', default = true })
    vim.api.nvim_set_hl(0, 'JiraChipProgress', { link = 'JiraProgress', default = true })
    vim.api.nvim_set_hl(0, 'JiraChipDone', { link = 'JiraDone', default = true })
    vim.api.nvim_set_hl(0, 'JiraBarDone', { link = 'JiraDone', default = true })
    vim.api.nvim_set_hl(0, 'JiraBarProgress', { link = 'JiraProgress', default = true })
  end
end

M.CHIP = { new = 'JiraChipTodo', indeterminate = 'JiraChipProgress', done = 'JiraChipDone' }
M.CAT = { new = 'JiraTodo', indeterminate = 'JiraProgress', done = 'JiraDone' }
M.HEALTH = {
  ok = 'JiraOk',
  soon = 'JiraSoon',
  overdue = 'JiraOverdue',
  missing = 'JiraMissing',
  late_start = 'JiraSoon',
  done = 'JiraDim',
}

return M
