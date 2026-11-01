-- Fake Cyberpunk 2077 script API: just enough of each system engine.lua
-- touches, with the call shapes the mod relies on.
local M = { money = 777, ram = 8, entities = {}, deleted = {}, removedMods = {} }
local saved = {}
local names = { "Game", "TweakDB", "ItemID", "TweakDBID", "CName", "Vector4", "Quaternion", "DynamicEntitySpec",
  "RPGManager", "gamedataStatType", "gameStatModifierType", "gamedataStatPoolType", "EAIAttitude",
  "ScriptedPuppet", "NPCPuppet", "gamedataNPCHighLevelState", "gamedataAttackType" }

M.EAIAttitude = { AIA_Friendly = 0, AIA_Neutral = 1, AIA_Hostile = 2 }

local Ent = {}
Ent.__index = Ent
function Ent:GetEntityID() return { hash = self.id } end
function Ent:IsDead() return self.dead == true end
function Ent:IsNPC() return not self.player end
function Ent:IsPlayer() return self.player == true end
function Ent:GetWorldPosition() return self.pos end
function Ent:GetWorldForward() return Vector4.new(0, 1, 0, 0) end
function Ent:GetDisplayName() return self.name or "" end
function Ent:SetWarningMessage(s) assert(type(s) == "string") end
function Ent:GetAttitudeAgent()
  local owner = self
  return { owner = owner, SetAttitudeTowards = function(agent, other, att)
    assert(att ~= nil, "attitude enum missing"); agent.owner.attitudes[other.owner] = att end }
end
function Ent:GetTargetTrackerComponent()
  local owner = self
  return { AddThreat = function(_, target, hostile, pos, acc, cd, persist)
    assert(hostile == true and type(acc) == "number" and pos, "AddThreat args"); owner.threat = target end }
end

local function newEnt(t) t.attitudes = {}; t.hp = t.hp or 100; return setmetatable(t, Ent) end

local function install()
  local player = newEnt({ id = "player", player = true, pos = { x = 0, y = 0, z = 0 } })
  local nextId = 0
  local G = {}
  G.Game = {
    GetPlayer = function() return player end,
    GetDynamicEntitySystem = function()
      return {
        CreateEntity = function(_, spec)
          assert(spec.recordID and spec.position and spec.orientation, "spec incomplete")
          M.lastSpec = spec
          nextId = nextId + 1
          local id = { hash = "dyn" .. nextId }
          M.entities[id.hash] = newEnt({ id = id.hash, pos = spec.position })
          return id
        end,
        DeleteEntity = function(_, id) M.deleted[id] = true end,
        DeleteTagged = function(_, tag) M.deletedTag = tag.name end,
      }
    end,
    FindEntityByID = function(id) return M.entities[id.hash] end,
    GetTransactionSystem = function()
      return {
        GetItemQuantity = function(_, who, item) assert(who == player and item.tdb.str == "Items.money"); return M.money end,
        RemoveItem = function(_, who, item, n) if n > M.money then return false end M.money = M.money - n; return true end,
        GiveItem = function(_, who, item, n) M.money = M.money + n; return true end,
      }
    end,
    GetStatPoolsSystem = function()
      return {
        GetStatPoolValue = function(_, id, pool, perc)
          if pool == "Memory" then assert(id.hash == "player" and perc == false); return M.ram end
          assert(pool == "Health" and perc == true); return M.entities[id.hash].hp
        end,
        RequestChangingStatPoolValue = function(_, id, pool, diff, inst, force, perc)
          assert(type(diff) == "number" and type(force) == "boolean" and type(perc) == "boolean")
          if pool == "Memory" then M.ram = M.ram + diff else M.entities[id.hash].hp = M.entities[id.hash].hp + diff end
        end,
      }
    end,
    GetStatsSystem = function()
      return {
        AddModifier = function(_, id, mod) assert(M.entities[id.hash], "mod on unknown entity") end,
        RemoveModifier = function(_, id, mod) M.removedMods[mod] = true end,
        GetStatValue = function() return 20 end,
      }
    end,
    GetTargetingSystem = function() return { GetLookAtObject = function() return nil end } end,
  }
  G.TweakDB = { GetRecord = function(_, id) if id == "Character.good" then return {} end return nil end }
  G.TweakDBID = { new = function(s) return { str = s } end }
  G.ItemID = { FromTDBID = function(t) return { tdb = t } end }
  G.CName = { new = function(s) return { name = s } end }
  G.Vector4 = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
  G.Quaternion = { new = function(i, j, k, r) return { i = i, j = j, k = k, r = r } end }
  G.DynamicEntitySpec = { new = function() return {} end }
  G.gamedataStatType = { Health = "Health", Armor = "Armor", PowerLevel = "PowerLevel" }
  G.gameStatModifierType = { Multiplier = "Multiplier", Additive = "Additive" }
  G.gamedataStatPoolType = { Health = "Health", Memory = "Memory" }
  G.RPGManager = { CreateStatModifier = function(stat, kind, v)
    assert(stat and kind and type(v) == "number", "CreateStatModifier args"); return { stat = stat, kind = kind, value = v } end }
  G.EAIAttitude = M.EAIAttitude
  G.ScriptedPuppet = { IsDefeated = function(e) return false end }
  G.NPCPuppet = { ChangeHighLevelState = function(e, s) assert(s) end }
  G.gamedataNPCHighLevelState = { Combat = "Combat" }
  G.gamedataAttackType = { Effect = "Effect", Ranged = "Ranged", Hack = "Hack", Melee = "Melee" }
  for _, n in ipairs(names) do saved[n] = rawget(_G, n); _G[n] = G[n] end
  saved.print = print
  print = function() end
end

M.install = install

function M.breakEverything()
  local boom = setmetatable({}, { __index = function() error("API changed") end })
  Game, TweakDB, DynamicEntitySpec = boom, boom, boom
end

function M.uninstall()
  for _, n in ipairs(names) do _G[n] = saved[n] end
  print = saved.print
end

return M
