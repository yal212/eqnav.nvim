local config = require("eqnav.config")

--- Client for scripts/mathjax-daemon.mjs.
---
--- MathJax costs ~100ms to load and ~1ms per equation after that, so the whole
--- point of a daemon is to pay the load once per session. Requests carry ids
--- and are answered as they finish, which lets a whole document be pipelined
--- in one batch instead of serialised.
local M = {}

local state = {
  proc = nil, ---@type vim.SystemObj|nil
  -- Bumped on every start and every stop. The async callbacks below capture the
  -- generation they belong to, so a process we have already replaced can never
  -- write over the state of the one that replaced it.
  gen = 0,
  ready = false,
  next_id = 1,
  pending = {}, ---@type table<integer, fun(res: table)>
  queue = {}, ---@type string[]
  buffer = "",
  failed = nil, ---@type string|nil
}

---@return string
function M.root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h:h:h:h")
end

---@return string
function M.script()
  return vim.fs.joinpath(M.root(), "scripts", "mathjax-daemon.mjs")
end

function M.is_running()
  return state.proc ~= nil and state.failed == nil
end

function M.error()
  return state.failed
end

local function fail(msg)
  state.failed = msg
  state.ready = false
  for _, cb in pairs(state.pending) do
    cb({ ok = false, err = msg })
  end
  state.pending = {}
  state.queue = {}
end

--- Send everything that queued up while the daemon was booting.
local function flush()
  if not state.proc then
    return
  end
  for _, payload in ipairs(state.queue) do
    state.proc:write(payload)
  end
  state.queue = {}
end

---@param line string
local function handle_line(line)
  if vim.trim(line) == "" then
    return
  end
  local ok, res = pcall(vim.json.decode, line)
  if not ok or type(res) ~= "table" then
    return
  end
  if res.ready then
    state.ready = true
    flush()
    return
  end
  local cb = res.id and state.pending[res.id]
  if cb then
    state.pending[res.id] = nil
    cb(res)
  end
end

---@param gen integer the daemon generation this pipe belongs to
local function on_stdout(gen, data)
  -- Trailing bytes from a daemon we have already replaced must not be spliced
  -- onto the current one's output.
  if not data or state.gen ~= gen then
    return
  end
  state.buffer = state.buffer .. data
  while true do
    local nl = state.buffer:find("\n", 1, true)
    if not nl then
      break
    end
    local line = state.buffer:sub(1, nl - 1)
    state.buffer = state.buffer:sub(nl + 1)
    handle_line(line)
  end
end

---@return boolean ok
function M.start()
  if state.proc then
    return true
  end
  if state.failed then
    return false
  end

  local node = config.options.render.node
  if vim.fn.executable(node) ~= 1 then
    fail("'" .. node .. "' not found on PATH")
    return false
  end
  local script = M.script()
  if vim.fn.filereadable(script) ~= 1 then
    fail("daemon script missing at " .. script)
    return false
  end

  local gen = state.gen + 1
  state.gen = gen

  local stderr_tail = {}
  local ok, proc = pcall(
    vim.system,
    { node, script, "--daemon" },
    {
      stdin = true,
      text = true,
      cwd = M.root(),
      stdout = vim.schedule_wrap(function(_, data)
        on_stdout(gen, data)
      end),
      stderr = function(_, data)
        if data and not data:match("No version information") then
          table.insert(stderr_tail, data)
          if #stderr_tail > 8 then
            table.remove(stderr_tail, 1)
          end
        end
      end,
    },
    vim.schedule_wrap(function(res)
      -- A stop() or a later start() has already superseded this process. Its
      -- exit says nothing about the daemon running now, and clearing the state
      -- here would null out a live handle.
      if state.gen ~= gen then
        return
      end
      state.proc = nil
      state.ready = false
      -- A signalled death reports code 0, so the signal has to be checked too:
      -- otherwise an OOM kill looks like a clean exit and strands every request.
      if (res.code ~= 0 or res.signal ~= 0) and state.failed == nil then
        local how = res.signal ~= 0 and ("killed by signal " .. res.signal)
          or ("exited (" .. res.code .. ")")
        local tail = vim.trim(table.concat(stderr_tail, ""))
        fail("mathjax daemon " .. how .. " " .. tail:sub(1, 300))
      end
    end)
  )

  if not ok then
    fail("could not start node: " .. tostring(proc))
    return false
  end
  state.proc = proc
  return true
end

function M.stop()
  -- Bump first: the kill below delivers its on_exit later, and by then it must
  -- not be able to touch whatever daemon is running.
  state.gen = state.gen + 1
  if state.proc then
    pcall(function()
      state.proc:kill("sigterm")
    end)
    state.proc = nil
  end
  state.ready = false
  state.queue = {}
  state.buffer = ""
  -- Callers are still waiting on these. Dropping them silently stalls
  -- render_all, whose pump only advances from a callback.
  local pending = state.pending
  state.pending = {}
  for _, cb in pairs(pending) do
    cb({ ok = false, err = "render daemon stopped" })
  end
end

--- Reset after a failure so the next render tries again.
function M.reset()
  M.stop()
  state.failed = nil
  state.next_id = 1
end

---@class eqnav.RenderRequest
---@field equation string
---@field display boolean
---@field color string|nil
---@field preamble string|nil
---@field ex number|nil
---@field width number|nil room in ex; display math wider is broken over lines

--- Ask the daemon for one equation's SVG.
---@param req eqnav.RenderRequest
---@param cb fun(res: { ok: boolean, svg?: string, err?: string, width?: number, height?: number, depth?: number }) sizes in ex
function M.request(req, cb)
  if not M.start() then
    cb({ ok = false, err = state.failed or "daemon unavailable" })
    return
  end
  local id = state.next_id
  state.next_id = id + 1
  state.pending[id] = cb

  local payload = vim.json.encode({
    id = id,
    equation = req.equation,
    display = req.display and true or false,
    color = req.color,
    preamble = req.preamble,
    ex = req.ex,
    width = req.width,
  }) .. "\n"

  if state.ready and state.proc then
    state.proc:write(payload)
  else
    table.insert(state.queue, payload)
  end
end

return M
