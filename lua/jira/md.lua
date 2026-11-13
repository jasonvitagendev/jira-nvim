-- Small markdown -> HTML converter, used only when a comment has @mentions (Jira takes mentions as HTML only).
-- Covers what comments normally hold: paragraphs, headings, lists, quotes, code, bold, italic, links.
local M = {}

local function esc(s)
  return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'))
end

-- mentions: list of { name = 'Display Name', id = 'accountId' }
local function inline(text, mentions)
  local out, pos = {}, 1
  local function styled(s)
    s = esc(s)
    s = s:gsub('%[([^%]]+)%]%((https?://[^%s%)]+)%)', function(label, url)
      return ('<a href="%s">%s</a>'):format(url:gsub('"', '%%22'), label)
    end)
    s = s:gsub('%*%*(.-)%*%*', '<strong>%1</strong>')
    s = s:gsub('%*([^*%s][^*]-)%*', '<em>%1</em>')
    -- one left-to-right pass, longest name first at each @, so "@Ann" never lands inside "@Ann Lee"
    local res, i = {}, 1
    while i <= #s do
      local hit
      if s:sub(i, i) == '@' then
        for _, m in ipairs(mentions) do
          local name = esc(m.name)
          if s:sub(i + 1, i + #name) == name then
            hit = ('<span data-type="mention" data-user-id="%s">@%s</span>'):format((esc(m.id):gsub('"', '')), name)
            i = i + 1 + #name
            break
          end
        end
      end
      if hit then
        res[#res + 1] = hit
      else
        res[#res + 1] = s:sub(i, i)
        i = i + 1
      end
    end
    return table.concat(res)
  end
  -- code spans stay literal
  while true do
    local i, j, code = text:find('`([^`]+)`', pos)
    if not i then
      break
    end
    out[#out + 1] = styled(text:sub(pos, i - 1))
    out[#out + 1] = '<code>' .. esc(code) .. '</code>'
    pos = j + 1
  end
  out[#out + 1] = styled(text:sub(pos))
  return table.concat(out)
end

-- Returns html, or nil + reason when the text uses something this converter does not handle.
function M.to_html(text, mentions)
  mentions = vim.deepcopy(mentions or {})
  -- longest names first so "@Ann Lee" wins over "@Ann"
  table.sort(mentions, function(x, y)
    return #x.name > #y.name
  end)
  local lines = vim.split(text, '\n')
  local out, para, i = {}, {}, 1
  local function flush()
    if #para > 0 then
      out[#out + 1] = '<p>' .. table.concat(para, '<br>') .. '</p>'
      para = {}
    end
  end
  local function take(pattern, wrap_open, wrap_close, item)
    flush()
    out[#out + 1] = wrap_open
    while lines[i] and lines[i]:match(pattern) do
      out[#out + 1] = item(lines[i]:match(pattern))
      i = i + 1
    end
    out[#out + 1] = wrap_close
  end
  while i <= #lines do
    local l = lines[i]
    local fence, lang = l:match('^%s*(```+)%s*([%w_+-]*)')
    if fence then
      flush()
      local code = {}
      i = i + 1
      while lines[i] and not lines[i]:match('^%s*```') do
        code[#code + 1] = lines[i]
        i = i + 1
      end
      i = i + 1
      out[#out + 1] = ('<pre><code%s>%s</code></pre>'):format(lang ~= '' and (' class="language-' .. lang .. '"') or '', esc(table.concat(code, '\n')))
    elseif l:match('^%s*|') then
      return nil, 'tables cannot be combined with @mentions yet'
    elseif l:match('^#+%s') then
      flush()
      local hashes, title = l:match('^(#+)%s+(.*)$')
      local n = math.min(#hashes, 6)
      out[#out + 1] = ('<h%d>%s</h%d>'):format(n, inline(title, mentions), n)
      i = i + 1
    elseif l:match('^%s*%-%-%-+%s*$') then
      flush()
      out[#out + 1] = '<hr>'
      i = i + 1
    elseif l:match('^%s*>%s?') then
      take('^%s*>%s?(.*)$', '<blockquote>', '</blockquote>', function(body)
        return '<p>' .. inline(body, mentions) .. '</p>'
      end)
    elseif l:match('^%s*[-*+]%s+') then
      take('^%s*[-*+]%s+(.*)$', '<ul>', '</ul>', function(body)
        return '<li>' .. inline(body, mentions) .. '</li>'
      end)
    elseif l:match('^%s*%d+[.)]%s+') then
      take('^%s*%d+[.)]%s+(.*)$', '<ol start="1">', '</ol>', function(body)
        return '<li>' .. inline(body, mentions) .. '</li>'
      end)
    elseif l:match('^%s*$') then
      flush()
      i = i + 1
    else
      para[#para + 1] = inline(l, mentions)
      i = i + 1
    end
  end
  flush()
  return table.concat(out)
end

return M
