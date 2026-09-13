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
    for _, payload in ipairs(state.queue) do
      state.proc:write(payload)
    end
    state.queue = {}
    return
  end
  local cb = res.id and state.pending[res.id]
  if cb then
    state.pending[res.id] = nil
    cb(res)
  end
end

local function on_stdout(_, data)
  if not data then
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

  local stderr_tail = {}
  local ok, proc = pcall(
    vim.system,
    { node, script, "--daemon" },
    {
      stdin = true,
      text = true,
      cwd = M.root(),
      stdout = vim.schedule_wrap(on_stdout),
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
      state.proc = nil
      state.ready = false
      if res.code ~= 0 and state.failed == nil then
        local tail = vim.trim(table.concat(stderr_tail, ""))
        fail("mathjax daemon exited (" .. res.code .. ") " .. tail:sub(1, 300))
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
  if state.proc then
    pcall(function()
      state.proc:kill("sigterm")
    end)
    state.proc = nil
  end
  state.ready = false
  state.pending = {}
  state.queue = {}
  state.buffer = ""
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

--- Ask the daemon for one equation's SVG.
---@param req eqnav.RenderRequest
---@param cb fun(res: { ok: boolean, svg?: string, err?: string })
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
  }) .. "\n"

  if state.ready then
    state.proc:write(payload)
  else
    table.insert(state.queue, payload)
  end
end

return M
