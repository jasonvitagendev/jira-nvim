-- Async HTTPS over curl. The whole request goes to curl on stdin, so tokens never show up in the process list.
local a = require('jira.async')

local M = {}

function M.urlencode(s)
  return (tostring(s):gsub('[^%w%-%._~]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

function M.form(params)
  local parts = {}
  for k, v in pairs(params) do
    parts[#parts + 1] = M.urlencode(k) .. '=' .. M.urlencode(v)
  end
  table.sort(parts)
  return table.concat(parts, '&')
end

local function cfg_quote(s)
  return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r') .. '"'
end

local function parse(raw)
  local status, headers, body
  repeat
    local head, rest = raw:match('^(HTTP/.-)\r?\n\r?\n(.*)$')
    if not head then
      return nil, 'could not parse http response'
    end
    status = tonumber(head:match('^HTTP/%S+%s+(%d+)'))
    headers = {}
    for line in head:gmatch('[^\r\n]+') do
      local k, v = line:match('^([^:]+):%s*(.*)$')
      if k then
        headers[k:lower()] = v
      end
    end
    body, raw = rest, rest
  until not (status == 100 or raw:match('^HTTP/%S+ %d'))
  return { status = status, headers = headers, body = body }
end

-- opts: url, method, headers (list of "K: V"), body, timeout (seconds)
function M.request(opts, cb)
  local cfg = {
    'url = ' .. cfg_quote(opts.url),
    'request = ' .. cfg_quote(opts.method or 'GET'),
    'silent',
    'show-error',
    'include',
    'max-time = ' .. (opts.timeout or 30),
    'proto = "=https"',
  }
  for _, h in ipairs(opts.headers or {}) do
    cfg[#cfg + 1] = 'header = ' .. cfg_quote(h)
  end
  if opts.body then
    cfg[#cfg + 1] = 'data-raw = ' .. cfg_quote(opts.body)
  end
  local ok, err = pcall(vim.system, { 'curl', '--config', '-' }, { stdin = table.concat(cfg, '\n') .. '\n', text = false }, function(r)
    if r.code ~= 0 then
      return cb('network error: ' .. vim.trim(r.stderr or ('curl exit ' .. r.code)))
    end
    local res, perr = parse(r.stdout or '')
    cb(perr, res)
  end)
  if not ok then
    cb('could not start curl: ' .. tostring(err))
  end
end

-- Coroutine form: local res = http.fetch({...})
function M.fetch(opts)
  return a.await(function(cb)
    M.request(opts, cb)
  end)
end

function M.decode(body)
  -- luanil: JSON null becomes nil instead of the truthy vim.NIL
  local ok, v = pcall(vim.json.decode, body or '', { luanil = { object = true, array = true } })
  return ok and v or nil
end

return M
