-- Auth spike: prove a Neovim plugin can log in to Atlassian's MCP server by itself.
-- Usage: nvim -l spike/auth_spike.lua <login|refresh|tools|call <tool> [json-args]|logout>

local uv = vim.uv

local RESOURCE = 'https://mcp.atlassian.com/v2/mcp'
local PORT = 47823
local REDIRECT = ('http://127.0.0.1:%d/callback'):format(PORT)
-- read:me, read:account and offline_access are always sent back by Atlassian's consent page, so they must be requested.
local SCOPES = 'read:me read:account offline_access read:jira:agent-interface search:jira:agent-interface write:jira:agent-interface'
local KEYCHAIN_SERVICE = 'jira.nvim'
local DATA_DIR = vim.fn.stdpath('data') .. '/jira-nvim'

local function out(...)
  io.stdout:write(table.concat(vim.tbl_map(tostring, { ... }), ' '), '\n')
  io.stdout:flush()
end

local function die(msg)
  io.stderr:write('error: ' .. msg .. '\n')
  os.exit(1)
end

-- http ----------------------------------------------------------------------

local function urlencode(s)
  return (s:gsub('[^%w%-%._~]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

local function form(params)
  local parts = {}
  for k, v in pairs(params) do
    parts[#parts + 1] = urlencode(k) .. '=' .. urlencode(v)
  end
  return table.concat(parts, '&')
end

local function cfg_quote(s)
  return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r') .. '"'
end

-- Everything goes to curl on stdin, so tokens never show up in the process list.
local function http(opts)
  local cfg = {
    'url = ' .. cfg_quote(opts.url),
    'request = ' .. cfg_quote(opts.method or 'GET'),
    'silent',
    'show-error',
    'include',
    'max-time = 30',
    'proto = "=https"',
  }
  for _, h in ipairs(opts.headers or {}) do
    cfg[#cfg + 1] = 'header = ' .. cfg_quote(h)
  end
  if opts.body then
    cfg[#cfg + 1] = 'data-raw = ' .. cfg_quote(opts.body)
  end
  local r = vim.system({ 'curl', '--config', '-' }, { stdin = table.concat(cfg, '\n') .. '\n', text = false }):wait()
  if r.code ~= 0 then
    die('curl failed: ' .. (r.stderr or ''))
  end
  local raw = r.stdout or ''
  local status, headers, body
  repeat
    local head, rest = raw:match('^(HTTP/.-)\r?\n\r?\n(.*)$')
    if not head then
      die('could not parse http response')
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

local function decode(body)
  -- luanil: JSON null becomes nil instead of the truthy vim.NIL
  local ok, v = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  return ok and v or nil
end

-- keychain ------------------------------------------------------------------

-- `security -i` reads commands from stdin (keeps the secret out of argv) but caps a line near 4k, so chunk.
local CHUNK = 3000

local function keychain_delete(account)
  return vim.system({ 'security', 'delete-generic-password', '-s', KEYCHAIN_SERVICE, '-a', account }):wait().code == 0
end

local function keychain_get(name)
  local parts, i = {}, 0
  while true do
    local r = vim.system({ 'security', 'find-generic-password', '-s', KEYCHAIN_SERVICE, '-a', name .. '.' .. i, '-w' }, { text = true }):wait()
    if r.code ~= 0 then
      break
    end
    parts[#parts + 1] = vim.trim(r.stdout)
    i = i + 1
  end
  if #parts == 0 then
    return nil
  end
  return vim.base64.decode(table.concat(parts))
end

local function keychain_clear(name, from)
  local i = from or 0
  while keychain_delete(name .. '.' .. i) do
    i = i + 1
  end
end

local function keychain_set(name, value)
  local b64, i = vim.base64.encode(value), 0
  for pos = 1, #b64, CHUNK do
    local cmd = ('add-generic-password -U -s "%s" -a "%s.%d" -w "%s"\n'):format(KEYCHAIN_SERVICE, name, i, b64:sub(pos, pos + CHUNK - 1))
    if vim.system({ 'security', '-i' }, { stdin = cmd, text = true }):wait().code ~= 0 then
      die('keychain write failed')
    end
    i = i + 1
  end
  keychain_clear(name, i)
  if keychain_get(name) ~= value then
    die('keychain read-back mismatch')
  end
end

-- oauth ---------------------------------------------------------------------

local function discover()
  local probe = http({
    url = RESOURCE,
    method = 'POST',
    headers = { 'Content-Type: application/json', 'Accept: application/json, text/event-stream' },
    body = '{}',
  })
  local meta_url = (probe.headers['www-authenticate'] or ''):match('resource_metadata="([^"]+)"')
  if not meta_url then
    die('no resource_metadata in 401 response (status ' .. tostring(probe.status) .. ')')
  end
  local res = decode(http({ url = meta_url }).body)
  if not res or res.resource ~= RESOURCE then
    die('resource metadata does not match ' .. RESOURCE)
  end
  local issuer = res.authorization_servers[1]
  local origin, path = issuer:match('^(https://[^/]+)(.*)$')
  local as = decode(http({ url = origin .. '/.well-known/oauth-authorization-server' .. path }).body)
  if not as or as.issuer ~= issuer then
    die('authorization server metadata does not match issuer ' .. issuer)
  end
  for _, k in ipairs({ 'authorization_endpoint', 'token_endpoint', 'registration_endpoint' }) do
    if not (as[k] or ''):match('^https://') then
      die('auth server is missing an https ' .. k)
    end
  end
  return as
end

local function client_file()
  return DATA_DIR .. '/client.json'
end

local function load_client(issuer)
  local f = io.open(client_file(), 'r')
  if not f then
    return nil
  end
  local c = decode(f:read('*a'))
  f:close()
  if c and c.issuer == issuer and c.redirect_uri == REDIRECT then
    if c.has_secret then
      c.client_secret = keychain_get('client_secret') or die('client secret missing from Keychain, delete ' .. client_file())
    end
    return c
  end
end

local function register(as)
  local cached = load_client(as.issuer)
  if cached then
    out('client: reusing registration', cached.client_id)
    return cached
  end
  local r = http({
    url = as.registration_endpoint,
    method = 'POST',
    headers = { 'Content-Type: application/json', 'Accept: application/json' },
    body = vim.json.encode({
      client_name = 'jira.nvim',
      redirect_uris = { REDIRECT },
      grant_types = { 'authorization_code', 'refresh_token' },
      response_types = { 'code' },
      token_endpoint_auth_method = 'none',
    }),
  })
  local j = decode(r.body)
  if r.status >= 300 or not j or not j.client_id then
    die(('registration refused (http %s): %s'):format(r.status, r.body:sub(1, 400)))
  end
  out(('client: registered %s (auth method=%s, secret issued=%s)'):format(j.client_id, tostring(j.token_endpoint_auth_method), tostring(j.client_secret ~= nil)))
  local c = { issuer = as.issuer, client_id = j.client_id, redirect_uri = REDIRECT, has_secret = j.client_secret ~= nil }
  if j.client_secret then
    keychain_set('client_secret', j.client_secret)
  end
  vim.fn.mkdir(DATA_DIR, 'p', 448) -- 0700
  local f = assert(io.open(client_file(), 'w'))
  f:write(vim.json.encode(c))
  f:close()
  uv.fs_chmod(client_file(), 384) -- 0600
  c.client_secret = j.client_secret
  return c
end

local function b64url(bytes)
  return (vim.base64.encode(bytes):gsub('+', '-'):gsub('/', '_'):gsub('=', ''))
end

local function sha256_bytes(s)
  return (vim.fn.sha256(s):gsub('%x%x', function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function parse_query(target)
  local q = {}
  for k, v in (target:match('%?(.*)$') or ''):gmatch('([^&=]+)=([^&]*)') do
    q[k] = v:gsub('+', ' '):gsub('%%(%x%x)', function(h)
      return string.char(tonumber(h, 16))
    end)
  end
  return q
end

local function respond(client, status, text)
  local body = '<!doctype html><meta charset="utf-8"><title>jira.nvim</title><body style="font-family:system-ui;margin:4rem auto;max-width:28rem"><h2>'
    .. text
    .. '</h2></body>'
  client:write(
    ('HTTP/1.1 %s\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s'):format(status, #body, body),
    function()
      client:shutdown(function()
        client:close()
      end)
    end
  )
end

-- One-shot listener on loopback only. Accepts a single /callback carrying our state.
local function wait_for_callback(state, timeout_ms)
  local server = assert(uv.new_tcp())
  local ok, err = server:bind('127.0.0.1', PORT)
  if not ok then
    die('cannot bind 127.0.0.1:' .. PORT .. ': ' .. tostring(err))
  end
  local result
  assert(server:listen(8, function(lerr)
    if lerr then
      return
    end
    local client = assert(uv.new_tcp())
    server:accept(client)
    local buf = ''
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        return client:close()
      end
      buf = buf .. chunk
      local target = buf:match('^GET (%S+) HTTP/')
      if not target then
        if #buf > 8192 then
          client:close()
        end
        return
      end
      client:read_stop()
      local q = parse_query(target)
      if not target:match('^/callback%?') then
        respond(client, '404 Not Found', 'Not found')
      elseif result or q.state ~= state then
        respond(client, '400 Bad Request', 'Login rejected (state mismatch)')
      elseif q.code then
        result = q
        respond(client, '200 OK', 'Logged in. You can close this tab and go back to Neovim.')
      else
        result = q
        respond(client, '400 Bad Request', 'Login failed. See Neovim for details.')
      end
    end)
  end))
  vim.wait(timeout_ms, function()
    return result ~= nil
  end, 100)
  vim.wait(300) -- let the response flush
  server:close()
  return result
end

local function save_tokens(as, client, tok)
  if not tok.access_token then
    die('token response has no access_token')
  end
  keychain_set('tokens', vim.json.encode({
    issuer = as.issuer,
    client_id = client.client_id,
    access_token = tok.access_token,
    refresh_token = tok.refresh_token,
    expires_at = os.time() + (tok.expires_in or 0),
    scope = tok.scope,
  }))
  out(('tokens: stored in Keychain (type=%s, expires_in=%ss, access_token=%d chars, refresh_token=%s)'):format(
    tostring(tok.token_type),
    tostring(tok.expires_in),
    #tok.access_token,
    tok.refresh_token and (#tok.refresh_token .. ' chars') or 'none'
  ))
  out('tokens: granted scope =', tostring(tok.scope))
end

local function token_request(as, params, client)
  params.client_id = client.client_id
  params.client_secret = client.client_secret
  local r = http({
    url = as.token_endpoint,
    method = 'POST',
    headers = { 'Content-Type: application/x-www-form-urlencoded', 'Accept: application/json' },
    body = form(params),
  })
  local j = decode(r.body)
  if r.status >= 300 or not j then
    die(('token endpoint refused (http %s): %s'):format(r.status, r.body:sub(1, 400)))
  end
  return j
end

local function login()
  local as = discover()
  out('discovery: issuer', as.issuer)
  local client = register(as)
  local verifier = b64url(uv.random(32))
  local state = b64url(uv.random(24))
  local url = as.authorization_endpoint
    .. '?'
    .. form({
      response_type = 'code',
      client_id = client.client_id,
      redirect_uri = REDIRECT,
      scope = SCOPES,
      state = state,
      code_challenge = b64url(sha256_bytes(verifier)),
      code_challenge_method = 'S256',
      resource = RESOURCE,
    })
  out('AUTH_URL ' .. url)
  out('waiting for the browser callback on ' .. REDIRECT .. ' ...')
  local cb = wait_for_callback(state, 8 * 60 * 60 * 1000)
  if not cb then
    die('timed out waiting for the login callback')
  end
  if not cb.code then
    die(('login refused: %s (%s)'):format(tostring(cb.error), tostring(cb.error_description)))
  end
  out('callback: received authorization code')
  local tok = token_request(as, {
    grant_type = 'authorization_code',
    code = cb.code,
    redirect_uri = REDIRECT,
    code_verifier = verifier,
    resource = RESOURCE,
  }, client)
  save_tokens(as, client, tok)
end

local function load_tokens()
  local raw = keychain_get('tokens')
  local t = raw and decode(raw)
  if not t then
    die('not logged in, run: login')
  end
  return t
end

local function refresh()
  local t = load_tokens()
  if not t.refresh_token then
    die('no refresh token stored')
  end
  local as = discover()
  local client = load_client(as.issuer) or die('client registration not found, run: login')
  local tok = token_request(as, {
    grant_type = 'refresh_token',
    refresh_token = t.refresh_token,
    resource = RESOURCE,
  }, client)
  out('refresh: rotated refresh token =', tostring(tok.refresh_token ~= nil and tok.refresh_token ~= t.refresh_token))
  tok.refresh_token = tok.refresh_token or t.refresh_token
  save_tokens(as, client, tok)
end

-- mcp -----------------------------------------------------------------------

local session = { id = nil, next_id = 0, version = '2025-06-18' }

local function rpc(token, method, params, notify)
  local msg = { jsonrpc = '2.0', method = method, params = params or vim.empty_dict() }
  if not notify then
    session.next_id = session.next_id + 1
    msg.id = session.next_id
  end
  local headers = {
    'Content-Type: application/json',
    'Accept: application/json, text/event-stream',
    'Authorization: Bearer ' .. token,
  }
  if session.id then
    headers[#headers + 1] = 'Mcp-Session-Id: ' .. session.id
    headers[#headers + 1] = 'MCP-Protocol-Version: ' .. session.version
  end
  local r = http({ url = RESOURCE, method = 'POST', headers = headers, body = vim.json.encode(msg) })
  if r.status >= 300 then
    die(('mcp %s failed (http %s): %s'):format(method, r.status, r.body:sub(1, 400)))
  end
  session.id = r.headers['mcp-session-id'] or session.id
  if notify then
    return
  end
  local reply
  if (r.headers['content-type'] or ''):match('text/event%-stream') then
    for data in r.body:gmatch('data:%s*([^\r\n]+)') do
      local j = decode(data)
      if j and j.id == msg.id then
        reply = j
      end
    end
  else
    reply = decode(r.body)
  end
  if not reply then
    die('mcp ' .. method .. ': no reply')
  end
  if reply.error then
    die(('mcp %s error: %s'):format(method, vim.json.encode(reply.error)))
  end
  return reply.result
end

local function connect()
  local t = load_tokens()
  local init = rpc(t.access_token, 'initialize', {
    protocolVersion = session.version,
    capabilities = vim.empty_dict(),
    clientInfo = { name = 'jira.nvim', version = '0.0.0-spike' },
  })
  session.version = init.protocolVersion or session.version
  rpc(t.access_token, 'notifications/initialized', nil, true)
  out(('mcp: connected to %s %s (protocol %s)'):format(init.serverInfo.name, tostring(init.serverInfo.version), session.version))
  return t.access_token
end

local function tools()
  local token = connect()
  local res = rpc(token, 'tools/list')
  out(('mcp: %d tools'):format(#res.tools))
  for _, tool in ipairs(res.tools) do
    local props = vim.tbl_keys((tool.inputSchema or {}).properties or {})
    table.sort(props)
    out(('  %s(%s)'):format(tool.name, table.concat(props, ', ')))
  end
end

local function call(name, json_args)
  local args = json_args and decode(json_args) or vim.empty_dict()
  local token = connect()
  local res = rpc(token, 'tools/call', { name = name, arguments = args })
  for _, c in ipairs(res.content or {}) do
    out(c.type == 'text' and c.text or vim.json.encode(c))
  end
  if res.isError then
    os.exit(2)
  end
end

local function logout()
  keychain_clear('tokens')
  out('tokens removed from Keychain')
end

-- Does the MCP token also work on the plain Jira REST API? (read-only probe)
local function rest(url)
  local t = load_tokens()
  local r = http({ url = url, headers = { 'Accept: application/json', 'Authorization: Bearer ' .. t.access_token } })
  out(('rest: http %s %s'):format(r.status, r.body:sub(1, 300)))
end

local cmd = arg[1]
if cmd == 'rest' and arg[2] then
  rest(arg[2])
elseif cmd == 'login' then
  login()
elseif cmd == 'refresh' then
  refresh()
elseif cmd == 'tools' then
  tools()
elseif cmd == 'call' and arg[2] then
  call(arg[2], arg[3])
elseif cmd == 'logout' then
  logout()
else
  die('usage: nvim -l spike/auth_spike.lua <login|refresh|tools|call <tool> [json-args]|logout>')
end
