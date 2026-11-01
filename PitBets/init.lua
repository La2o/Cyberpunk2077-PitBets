-- Pit Bets: bet eddies on underground NPC fights in Pacifica and Kabuki.
-- Cyber Engine Tweaks mod. Needs Codeware for spawning.
local Engine = require("engine")
local Roster = require("roster")
local Pit = require("pit")
local UI = require("ui")

local STATS_FILE = "stats.json"

local mod = {
  pit = nil,
  overlay = false,
  windowOpen = true,
  report = {},
  codeware = false,
  debug = false, -- true logs every hit V takes to the CET console
}

local function loadStats()
  local f = io.open(STATS_FILE, "r")
  if not f then return end
  local ok, data = pcall(json.decode, f:read("*a"))
  f:close()
  if ok and type(data) == "table" then
    for k, v in pairs(data.stats or {}) do mod.pit.stats[k] = v end
    if type(data.stake) == "number" then mod.pit.stake = data.stake end
    if type(data.venue) == "number" and Roster.venues[data.venue] then mod.pit.venueIndex = data.venue end
    for k, v in pairs(data.cfg or {}) do
      if mod.pit.cfg[k] ~= nil and type(v) == type(mod.pit.cfg[k]) then mod.pit.cfg[k] = v end
    end
  end
end

local function saveStats()
  local f = io.open(STATS_FILE, "w")
  if not f then return end
  f:write(json.encode({ stats = mod.pit.stats, stake = mod.pit.stake, venue = mod.pit.venueIndex, cfg = mod.pit.cfg }))
  f:close()
end
mod.save = saveStats

registerForEvent("onInit", function()
  math.randomseed(os.time())
  mod.pit = Pit.new(Engine)
  mod.pit.onSettled = saveStats
  mod.codeware = Engine.hasCodeware()
  mod.report = Roster.validate(Engine.recordExists)
  loadStats()

  -- Clear fighters left over from a previous CET reload.
  if mod.codeware then Engine.despawnAll() end

  local valid = 0
  for _, r in ipairs(mod.report) do if r.ok then valid = valid + 1 end end
  Engine.log(string.format("loaded. Codeware: %s. Valid records: %d/%d", tostring(mod.codeware), valid, #mod.report))

  -- Any hit the player lands on a fighter (bullets, blades, damaging
  -- quickhacks) counts as sabotage the bookies might notice.
  Observe("ScriptedPuppet", "OnHit", function(self, evt)
    local pit = mod.pit
    if not pit or (pit.state ~= "betting" and pit.state ~= "fighting") then return end
    local side = pit:sideOf(self)
    if not side then return end
    local inst = Engine.try(function() return evt.attackData:GetInstigator() end)
    if inst and Engine.isPlayer(inst) then pit:onPlayerHit(side, os.clock()) end
  end)

  if mod.debug then require("debug_tools").watchPlayerHits(mod) end

  -- V leaving the world (load, quit to menu) ends the night before any
  -- entity we know about is freed.
  Observe("PlayerPuppet", "OnDetach", function()
    if mod.pit then mod.pit:dropSession() end
  end)
end)

registerForEvent("onUpdate", function(dt)
  if mod.pit then mod.pit:update(dt) end
end)

registerForEvent("onOverlayOpen", function() mod.overlay = true end)
registerForEvent("onOverlayClose", function() mod.overlay = false; if mod.pit then saveStats() end end)

registerForEvent("onDraw", function()
  if not mod.pit then return end
  if not Engine.sessionActive() then return end
  if mod.overlay and mod.windowOpen then UI.window(mod) end
  if not mod.overlay then UI.hud(mod) end
end)

registerHotkey("pitbets_toggle", "Toggle Pit Bets window", function()
  mod.windowOpen = not mod.windowOpen
end)

registerHotkey("pitbets_bell", "Ring the bell (start the fight)", function()
  if mod.pit then mod.pit:ringBell() end
end)

registerHotkey("pitbets_dump", "Dump character records (modders)", function()
  require("debug_tools").dumpRecords()
end)

registerForEvent("onShutdown", function()
  if mod.pit then
    saveStats()
    mod.pit:shutdown()
  end
end)

return mod
