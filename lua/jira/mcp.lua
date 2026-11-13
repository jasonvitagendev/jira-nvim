-- Minimal MCP (streamable HTTP) client: initialize once, then tools/call.
local a = require('jira.async')
local auth = require('jira.auth')
local http = require('jira.http')

local M = {}

local session = { id = nil, version = '2025-06-18', ready = false }
local next_id = 0
local init_once = a.singleflight()

local function post(token, msg)
  local headers = {
    'Content-Type: application/json',
    'Accept: application/json, text/event-stream',
    'Authorization: Bearer ' .. token,
  }
  if session.id then
    headers[#headers + 1] = 'Mcp-Session-Id: ' .. session.id
    headers[#headers + 1] = 'MCP-Protocol-Version: ' .. session.version
  end
  return http.fetch({ url = auth.RESOURCE, method = 'POST', headers = headers, body = vim.json.encode(msg), timeout = 60 })
end

local function read_reply(r, id)
  if (r.headers['content-type'] or ''):match('text/event%-stream') then
    for data in r.body:gmatch('data:%s*([^\r\n]+)') do
      local j = http.decode(data)
      if j and j.id == id then
        return j
      end
    end
    return nil
  end
  return http.decode(r.body)
end

-- Raw JSON-RPC call. Returns result, or nil + an error kind ('auth', 'session') the caller can recover from.
local function rpc(method, params, notify)
  local msg = { jsonrpc = '2.0', method = method, params = params or vim.empty_dict() }
  if not notify then
    next_id = next_id + 1
    msg.id = next_id
  end
  local r = post(auth.token(), msg)
  if r.status == 401 then
    return nil, 'auth'
  end
  if session.id and (r.status == 404 or (r.status == 400 and r.body:match('[Ss]ession'))) then
    return nil, 'session'
  end
  if r.status >= 300 then
    error(('mcp %s failed (http %s): %s'):format(method, r.status, r.body:sub(1, 300)), 0)
  end
  session.id = r.headers['mcp-session-id'] or session.id
  if notify then
    return true
  end
  local reply = read_reply(r, msg.id)
  if not reply then
    error('mcp ' .. method .. ': no reply', 0)
  end
  if reply.error then
    error(('mcp %s: %s'):format(method, reply.error.message or vim.json.encode(reply.error)), 0)
  end
  return reply.result
end

local function initialize()
  return init_once(function()
    session.id, session.ready = nil, false
    local init, kind = rpc('initialize', {
      protocolVersion = session.version,
      capabilities = vim.empty_dict(),
      clientInfo = { name = 'jira.nvim', version = '0.1.0' },
    })
    if kind == 'auth' then
      auth.refresh()
      init = rpc('initialize', {
        protocolVersion = session.version,
        capabilities = vim.empty_dict(),
        clientInfo = { name = 'jira.nvim', version = '0.1.0' },
      })
    end
    if type(init) ~= 'table' then
      error('mcp initialize failed', 0)
    end
    session.version = init.protocolVersion or session.version
    rpc('notifications/initialized', nil, true)
    session.ready = true
    return true
  end)
end

-- Call with one retry after refreshing the token or re-opening an expired session.
local function request(method, params)
  if not session.ready then
    initialize()
  end
  local res, kind = rpc(method, params)
  if kind == 'auth' then
    auth.refresh()
    res, kind = rpc(method, params)
  end
  if kind == 'session' then
    session.ready = false
    initialize()
    res, kind = rpc(method, params)
  end
  if kind then
    error(kind == 'auth' and 'not authorised, run :Jira login' or 'mcp session lost', 0)
  end
  return res
end

-- Coroutine: call a tool and return the decoded `data` payload.
function M.call(name, args)
  local res = request('tools/call', { name = name, arguments = args or vim.empty_dict() })
  local text = {}
  for _, c in ipairs(res.content or {}) do
    if c.type == 'text' then
      text[#text + 1] = c.text
    end
  end
  local joined = table.concat(text, '\n')
  local j = http.decode(joined)
  -- Errors come as isError, or as a body like { error = true, message = '...' } / { error = { message = '...' } }
  if res.isError or (type(j) == 'table' and j.error and j.data == nil) then
    local msg = joined
    if type(j) == 'table' then
      msg = type(j.error) == 'table' and (j.error.message or j.error) or j.message or j.error or joined
    end
    if type(msg) == 'table' then
      msg = vim.json.encode(msg)
    end
    local hint = j and j.repairHint and ('\n' .. j.repairHint) or ''
    error(name .. ': ' .. tostring(msg):sub(1, 500) .. hint, 0)
  end
  if j and j.data ~= nil then
    return j.data
  end
  return j or joined
end

function M.reset()
  session.id, session.ready = nil, false
end

return M
