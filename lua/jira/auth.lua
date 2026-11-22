-- OAuth 2.1 (PKCE + dynamic client registration) against Atlassian's MCP server.
local a = require('jira.async')
local http = require('jira.http')
local keychain = require('jira.keychain')

local uv = vim.uv
local M = {}

M.RESOURCE = 'https://mcp.atlassian.com/v2/mcp'
local PORT = 47823
local REDIRECT = ('http://127.0.0.1:%d/callback'):format(PORT)
-- read:me, read:account and offline_access are always sent back by Atlassian's consent page, so they must be requested.
local SCOPES = 'read:me read:account offline_access read:jira:agent-interface search:jira:agent-interface write:jira:agent-interface'
local DATA_DIR = vim.fn.stdpath('data') .. '/jira-nvim'
local LOGIN_TIMEOUT_MS = 5 * 60 * 1000

local state = { as = nil, tokens = nil }

local function fail(msg)
  error(msg, 0)
end

-- discovery -----------------------------------------------------------------

local function discover()
  if state.as then
    return state.as
  end
  local probe = http.fetch({
    url = M.RESOURCE,
    method = 'POST',
    headers = { 'Content-Type: application/json', 'Accept: application/json, text/event-stream' },
    body = '{}',
  })
  local meta_url = (probe.headers['www-authenticate'] or ''):match('resource_metadata="([^"]+)"')
  if not meta_url or not meta_url:match('^https://') then
    fail('no resource_metadata in 401 response (status ' .. tostring(probe.status) .. ')')
  end
  local res = http.decode(http.fetch({ url = meta_url }).body)
  if not res or res.resource ~= M.RESOURCE then
    fail('resource metadata does not match ' .. M.RESOURCE)
  end
  local issuer = (res.authorization_servers or {})[1] or ''
  local origin, path = issuer:match('^(https://[^/]+)(.*)$')
  if not origin then
    fail('authorization server is not https: ' .. issuer)
  end
  local as = http.decode(http.fetch({ url = origin .. '/.well-known/oauth-authorization-server' .. path }).body)
  if not as or as.issuer ~= issuer then
    fail('authorization server metadata does not match issuer ' .. issuer)
  end
  for _, k in ipairs({ 'authorization_endpoint', 'token_endpoint', 'registration_endpoint' }) do
    if not (as[k] or ''):match('^https://') then
      fail('auth server is missing an https ' .. k)
    end
  end
  state.as = as
  return as
end

-- client registration -------------------------------------------------------

local function client_file()
  return DATA_DIR .. '/client.json'
end

local function load_client(issuer)
  local f = io.open(client_file(), 'r')
  if not f then
    return nil
  end
  local c = http.decode(f:read('*a'))
  f:close()
  if c and c.issuer == issuer and c.redirect_uri == REDIRECT then
    if c.has_secret then
      c.client_secret = keychain.get('client_secret') or fail('client secret missing from Keychain, delete ' .. client_file())
    end
    return c
  end
end

local function register(as)
  local cached = load_client(as.issuer)
  if cached then
    return cached
  end
  local r = http.fetch({
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
  local j = http.decode(r.body)
  if r.status >= 300 or not j or not j.client_id then
    fail(('registration refused (http %s): %s'):format(r.status, r.body:sub(1, 400)))
  end
  local c = { issuer = as.issuer, client_id = j.client_id, redirect_uri = REDIRECT, has_secret = j.client_secret ~= nil }
  if j.client_secret then
    keychain.set('client_secret', j.client_secret)
  end
  vim.fn.mkdir(DATA_DIR, 'p', 448) -- 0700
  local f = assert(io.open(client_file(), 'w'))
  f:write(vim.json.encode(c))
  f:close()
  uv.fs_chmod(client_file(), 384) -- 0600
  c.client_secret = j.client_secret
  return c
end

-- tokens --------------------------------------------------------------------

local function save_tokens(as, client, tok)
  if not tok.access_token then
    fail('token response has no access_token')
  end
  local t = {
    issuer = as.issuer,
    client_id = client.client_id,
    access_token = tok.access_token,
    refresh_token = tok.refresh_token,
    expires_at = os.time() + (tok.expires_in or 0),
    scope = tok.scope,
  }
  keychain.set('tokens', vim.json.encode(t))
  state.tokens = t
  return t
end

local function load_tokens()
  if not state.tokens then
    local raw = keychain.get('tokens')
    state.tokens = raw and http.decode(raw) or nil
  end
  return state.tokens
end

local function token_request(as, params, client)
  params.client_id = client.client_id
  params.client_secret = client.client_secret
  local r = http.fetch({
    url = as.token_endpoint,
    method = 'POST',
    headers = { 'Content-Type: application/x-www-form-urlencoded', 'Accept: application/json' },
    body = http.form(params),
  })
  local j = http.decode(r.body)
  if r.status >= 300 or not j then
    local why = j and (j.error_description or j.error) or r.body:sub(1, 200)
    fail(('token endpoint refused (http %s): %s'):format(r.status, why))
  end
  return j
end

local refresh_once = a.singleflight()

-- Coroutine: rotate tokens. Concurrent callers share one refresh, so a rotated refresh token is never reused.
function M.refresh()
  return refresh_once(function()
    local t = load_tokens()
    if not t or not t.refresh_token then
      fail('not logged in, run :Jira login')
    end
    local as = discover()
    local client = load_client(as.issuer) or fail('client registration not found, run :Jira login')
    local tok = token_request(as, { grant_type = 'refresh_token', refresh_token = t.refresh_token, resource = M.RESOURCE }, client)
    tok.refresh_token = tok.refresh_token or t.refresh_token
    return save_tokens(as, client, tok)
  end)
end

-- Coroutine: a valid access token, refreshing if it expires within a minute.
function M.token()
  local t = load_tokens()
  if not t then
    fail('not logged in, run :Jira login')
  end
  if (t.expires_at or 0) - 60 <= os.time() then
    t = M.refresh()
  end
  return t.access_token
end

function M.status()
  local t = load_tokens()
  if not t then
    return { logged_in = false }
  end
  return { logged_in = true, expires_in = (t.expires_at or 0) - os.time(), scope = t.scope, has_refresh = t.refresh_token ~= nil }
end

-- login ---------------------------------------------------------------------

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
local function wait_for_callback(expected_state, cb)
  local server = assert(uv.new_tcp())
  local ok, err = server:bind('127.0.0.1', PORT)
  if not ok then
    server:close()
    return cb('cannot bind 127.0.0.1:' .. PORT .. ': ' .. tostring(err))
  end
  local done = false
  local timer = assert(uv.new_timer())
  local function finish(e, result)
    if done then
      return
    end
    done = true
    timer:stop()
    timer:close()
    -- small delay so the browser gets its response before the socket closes
    vim.defer_fn(function()
      if not server:is_closing() then
        server:close()
      end
    end, 300)
    cb(e, result)
  end
  timer:start(LOGIN_TIMEOUT_MS, 0, function()
    finish('timed out waiting for the login callback')
  end)
  server:listen(8, function(lerr)
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
      elseif done or q.state ~= expected_state then
        respond(client, '400 Bad Request', 'Login rejected (state mismatch)')
      elseif q.code then
        respond(client, '200 OK', 'Logged in. You can close this tab and go back to Neovim.')
        finish(nil, q)
      else
        respond(client, '400 Bad Request', 'Login failed. See Neovim for details.')
        finish(nil, q)
      end
    end)
  end)
end

-- Coroutine: full browser login.
function M.login()
  if not keychain.available() then
    fail('token storage needs the macOS Keychain (`security`)')
  end
  local as = discover()
  local client = register(as)
  local verifier = b64url(uv.random(32))
  local st = b64url(uv.random(24))
  local url = as.authorization_endpoint
    .. '?'
    .. http.form({
      response_type = 'code',
      client_id = client.client_id,
      redirect_uri = REDIRECT,
      scope = SCOPES,
      state = st,
      code_challenge = b64url(sha256_bytes(verifier)),
      code_challenge_method = 'S256',
      resource = M.RESOURCE,
    })
  local cb_result = a.await(function(cb)
    wait_for_callback(st, cb)
    vim.schedule(function()
      vim.notify('jira: finish login in your browser (waiting 5 min)', vim.log.levels.INFO)
      local _, oerr = vim.ui.open(url)
      if oerr then
        vim.notify('jira: open this URL to log in:\n' .. url, vim.log.levels.WARN)
      end
    end)
  end)
  if not cb_result.code then
    fail(('login refused: %s (%s)'):format(tostring(cb_result.error), tostring(cb_result.error_description)))
  end
  local tok = token_request(as, {
    grant_type = 'authorization_code',
    code = cb_result.code,
    redirect_uri = REDIRECT,
    code_verifier = verifier,
    resource = M.RESOURCE,
  }, client)
  save_tokens(as, client, tok)
end

function M.logout()
  keychain.clear('tokens')
  state.tokens = nil
end

return M
