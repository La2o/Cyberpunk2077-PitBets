-- Cyber Engine Tweaks globals: events, hotkeys, Observe, json and a
-- sandboxed in-memory io.open.
local M = { events = {}, hotkeys = {}, observed = {}, files = {} }
local saved = {}

local function encode(v)
  local t = type(v)
  if t == "table" then
    local parts = {}
    for k, x in pairs(v) do table.insert(parts, string.format("%q:%s", tostring(k), encode(x))) end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then return string.format("%q", v)
  else return tostring(v) end
end

-- Good enough for the flat objects the mod writes.
local function decode(s)
  local lua = s:gsub('"([^"]-)":', '["%1"]=')
  return assert(loadstring("return " .. lua))()
end

local function memFile(name, mode)
  if mode == "r" then
    if not M.files[name] then return nil end
    local data = M.files[name]
    return { read = function() return data end, close = function() end }
  end
  local buf = {}
  return { write = function(_, s) table.insert(buf, s) end, close = function() M.files[name] = table.concat(buf) end }
end

local GLOBALS = {
  registerForEvent = function(name, fn) M.events[name] = fn end,
  registerHotkey = function(id, label, fn) M.hotkeys[id] = fn end,
  Observe = function(cls, method, fn) M.observed[cls .. "." .. method] = fn end,
  json = { encode = encode, decode = decode },
}

function M.install()
  for k, v in pairs(GLOBALS) do saved[k] = rawget(_G, k); _G[k] = v end
  saved.ioopen = io.open
  saved.print = print
  io.open = memFile
  print = function() end
end

function M.uninstall()
  for k in pairs(GLOBALS) do _G[k] = saved[k] end
  io.open = saved.ioopen
  print = saved.print
end

return M
