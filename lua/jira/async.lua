-- Tiny coroutine runner so API code reads top to bottom instead of nesting callbacks.
local M = {}

local function report(err)
  vim.schedule(function()
    vim.notify('jira: ' .. tostring(err), vim.log.levels.ERROR)
  end)
end

-- Run fn in a coroutine. done(err, result) is optional; without it errors are notified.
function M.run(fn, done)
  local co = coroutine.create(fn)
  local function step(...)
    local ok, res = coroutine.resume(co, ...)
    if not ok then
      if done then
        done(res)
      else
        report(res)
      end
      return
    end
    if coroutine.status(co) == 'dead' then
      if done then
        done(nil, res)
      end
      return
    end
    -- Yielded value is a starter: start(cb) where cb(err, value).
    res(function(...)
      local args = vim.F.pack_len(...)
      vim.schedule(function()
        step(vim.F.unpack_len(args))
      end)
    end)
  end
  step()
end

-- Inside M.run: wait for start(cb) to call cb(err, value). Raises on err.
function M.await(start)
  assert(coroutine.running(), 'jira.async.await called outside a coroutine')
  local err, value = coroutine.yield(start)
  if err then
    error(err, 0)
  end
  return value
end

-- Run several starters at once and wait for all of them.
function M.all(starters)
  return M.await(function(cb)
    local n, results, failed = #starters, {}, false
    if n == 0 then
      return cb(nil, results)
    end
    for i, start in ipairs(starters) do
      start(function(err, value)
        if failed then
          return
        end
        if err then
          failed = true
          return cb(err)
        end
        results[i] = value
        n = n - 1
        if n == 0 then
          cb(nil, results)
        end
      end)
    end
  end)
end

-- Turn a coroutine function into a starter so it can be awaited or run in parallel.
function M.starter(fn, ...)
  local args = vim.F.pack_len(...)
  return function(cb)
    M.run(function()
      return fn(vim.F.unpack_len(args))
    end, cb)
  end
end

-- Share one in-flight run between many callers (token refresh, MCP init).
function M.singleflight()
  local waiters
  return function(fn)
    return M.await(function(cb)
      if waiters then
        waiters[#waiters + 1] = cb
        return
      end
      waiters = { cb }
      M.run(fn, function(err, value)
        local list = waiters
        waiters = nil
        for _, w in ipairs(list) do
          w(err, value)
        end
      end)
    end)
  end
end

return M
