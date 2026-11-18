-- Scratch buffers you edit and `:w` to send to Jira (descriptions, comments, new issues).
local a = require('jira.async')
local bufs = require('jira.ui.bufs')

local M = {}

-- opts: name, lines, filetype, title, save (coroutine fn(lines, buf)), after (fn()), on_open (fn(buf, win))
function M.open(opts)
  local name = 'jira://' .. opts.name
  local existing = bufs.find(name)
  if existing ~= -1 then
    local win = vim.fn.bufwinid(existing)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
      return
    end
    vim.api.nvim_buf_delete(existing, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines or { '' })
  vim.bo[buf].filetype = opts.filetype or 'markdown'
  vim.bo[buf].modified = false

  local height = math.max(12, math.floor(vim.o.lines * 0.45))
  vim.cmd('botright ' .. height .. 'split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].spell = true
  vim.wo[win].winbar = ('%%#JiraTitle# %s %%#JiraHint# · :w send · :q cancel'):format(opts.title:gsub('%%', '%%%%'))

  local saving = false
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function()
      if saving then
        return
      end
      saving = true
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      vim.notify('jira: sending…', vim.log.levels.INFO)
      a.run(function()
        return opts.save(lines, buf)
      end, function(err, msg)
        saving = false
        if err then
          vim.notify('jira: ' .. tostring(err), vim.log.levels.ERROR)
          return
        end
        if msg == false then
          return -- save() cancelled itself (e.g. conflict prompt said no)
        end
        if vim.api.nvim_buf_is_valid(buf) then
          vim.bo[buf].modified = false
          local w = vim.fn.bufwinid(buf)
          if w ~= -1 and #vim.api.nvim_list_wins() > 1 then
            vim.api.nvim_win_close(w, true)
          end
        end
        vim.notify('jira: ' .. (type(msg) == 'string' and msg or 'saved'), vim.log.levels.INFO)
        if opts.after then
          opts.after()
        end
      end)
    end,
  })
  if opts.on_open then
    opts.on_open(buf, win)
  end
  if opts.cursor then
    pcall(vim.api.nvim_win_set_cursor, win, opts.cursor)
  end
  if opts.insert then
    vim.cmd('startinsert!')
  end
  return buf
end

-- Lines of a body, trimming the blank lines around it.
function M.body(lines)
  local s = table.concat(lines, '\n')
  return (s:gsub('^%s*\n', ''):gsub('%s+$', ''))
end

return M
