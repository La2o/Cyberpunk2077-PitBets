-- Every call into the game lives here, wrapped in pcall so a changed game
-- API logs a warning instead of killing the mod.
local Engine = {}

local TAG = "PitBets"

local function try(fn, ...)
  local ok, res = pcall(fn, ...)
  if ok then return res end
  return nil
end
Engine.try = try

function Engine.log(msg) print("[PitBets] " .. tostring(msg)) end

function Engine.notify(msg)
  Engine.log(msg)
  pcall(function() Game.GetPlayer():SetWarningMessage(msg) end)
end

function Engine.player() return try(function() return Game.GetPlayer() end) end

function Engine.hasCodeware()
  return try(function() return Game.GetDynamicEntitySystem() ~= nil end) == true
end

function Engine.recordExists(id)
  return try(function() return TweakDB:GetRecord(id) ~= nil end) == true
end

-- Eddies ---------------------------------------------------------------------

local function moneyID() return ItemID.FromTDBID(TweakDBID.new("Items.money")) end

function Engine.getMoney()
  return try(function() return Game.GetTransactionSystem():GetItemQuantity(Game.GetPlayer(), moneyID()) end) or 0
end

function Engine.takeMoney(n)
  if n <= 0 then return true end
  return try(function() return Game.GetTransactionSystem():RemoveItem(Game.GetPlayer(), moneyID(), n) end) == true
end

function Engine.giveMoney(n)
  if n <= 0 then return true end
  return try(function() return Game.GetTransactionSystem():GiveItem(Game.GetPlayer(), moneyID(), n) end) == true
end

-- Geometry -------------------------------------------------------------------

-- Quaternion for facing direction (dx, dy). The game is Z-up, Y-forward.
local function yawQuat(dx, dy)
  local yaw = math.atan2(-dx, dy)
  return Quaternion.new(0, 0, math.sin(yaw / 2), math.cos(yaw / 2))
end

-- Ring in front of the player: centre plus red/blue corners either side.
function Engine.arenaPoints(distance, spread)
  local p = Game.GetPlayer()
  local pos, fwd = p:GetWorldPosition(), p:GetWorldForward()
  local len = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y)
  local fx, fy = 0, 1
  if len > 0.001 then fx, fy = fwd.x / len, fwd.y / len end
  local rx, ry = fy, -fx
  local cx, cy = pos.x + fx * distance, pos.y + fy * distance
  return {
    center = Vector4.new(cx, cy, pos.z, 1),
    red = Vector4.new(cx - rx * spread, cy - ry * spread, pos.z, 1),
    blue = Vector4.new(cx + rx * spread, cy + ry * spread, pos.z, 1),
  }
end

function Engine.offset(p, dx, dy)
  return Vector4.new(p.x + dx, p.y + dy, p.z, 1)
end

function Engine.distance(a, b)
  if not a or not b then return math.huge end
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function Engine.position(ent)
  return try(function() return ent:GetWorldPosition() end)
end

-- Spawning (Codeware DynamicEntitySystem) ------------------------------------

function Engine.spawn(record, pos, face)
  local spec = try(function()
    local s = DynamicEntitySpec.new()
    s.recordID = TweakDBID.new(record)
    s.position = pos
    s.orientation = yawQuat(face.x - pos.x, face.y - pos.y)
    s.tags = { CName.new(TAG) }
    return s
  end)
  if not spec then Engine.log("could not build spawn spec for " .. record); return nil end
  -- Optional flags: set one by one so a renamed field cannot break spawning.
  pcall(function() spec.alwaysSpawned = true end)
  pcall(function() spec.spawnInView = true end)
  pcall(function() spec.persistState = false end)
  pcall(function() spec.persistSpawn = false end)
  local id = try(function() return Game.GetDynamicEntitySystem():CreateEntity(spec) end)
  if not id then Engine.log("spawn failed for " .. record) end
  return id
end

function Engine.getEntity(id)
  if not id then return nil end
  return try(function() return Game.FindEntityByID(id) end)
end

function Engine.despawn(id)
  if id then pcall(function() Game.GetDynamicEntitySystem():DeleteEntity(id) end) end
end

function Engine.despawnAll()
  pcall(function() Game.GetDynamicEntitySystem():DeleteTagged(CName.new(TAG)) end)
end

function Engine.sameEntity(a, b)
  if not a or not b then return false end
  return try(function()
    local ha, hb = a:GetEntityID().hash, b:GetEntityID().hash
    return ha == hb or tostring(ha) == tostring(hb)
  end) == true
end

function Engine.entityID(ent) return try(function() return ent:GetEntityID() end) end

-- NPC state ------------------------------------------------------------------

function Engine.isNPC(obj)
  return try(function() return obj:IsNPC() end) == true
end

function Engine.isPlayer(obj)
  return try(function() return obj:IsPlayer() end) == true
end

function Engine.isDown(ent)
  if not ent then return false end
  if try(function() return ent:IsDead() end) == true then return true end
  if try(function() return ScriptedPuppet.IsDefeated(ent) end) == true then return true end
  local hp = Engine.healthPct(ent)
  return hp ~= nil and hp <= 0
end

function Engine.healthPct(ent)
  return try(function()
    return Game.GetStatPoolsSystem():GetStatPoolValue(ent:GetEntityID(), gamedataStatPoolType.Health, true)
  end)
end

function Engine.damagePct(ent, pct)
  pcall(function()
    Game.GetStatPoolsSystem():RequestChangingStatPoolValue(ent:GetEntityID(), gamedataStatPoolType.Health, -pct, nil, false, true)
  end)
end

function Engine.powerLevel(ent)
  return try(function() return Game.GetStatsSystem():GetStatValue(ent:GetEntityID(), gamedataStatType.PowerLevel) end)
end

function Engine.displayName(ent)
  local n = try(function() return ent:GetDisplayName() end)
  if type(n) == "string" and n ~= "" then return n end
  return nil
end

-- statName: gamedataStatType key, modType: gameStatModifierType key.
function Engine.addStatMod(ent, statName, modType, value)
  return try(function()
    local mod = RPGManager.CreateStatModifier(gamedataStatType[statName], gameStatModifierType[modType], value)
    Game.GetStatsSystem():AddModifier(ent:GetEntityID(), mod)
    return mod
  end)
end

function Engine.removeStatMod(ent, mod)
  if ent and mod then pcall(function() Game.GetStatsSystem():RemoveModifier(ent:GetEntityID(), mod) end) end
end

-- Attitude & combat ----------------------------------------------------------

local function attitudeEnum(name)
  return ({ hostile = EAIAttitude.AIA_Hostile, neutral = EAIAttitude.AIA_Neutral, friendly = EAIAttitude.AIA_Friendly })[name]
end

-- Sets a's attitude towards b and b's towards a.
function Engine.setAttitude(a, b, name)
  if not a or not b then return end
  pcall(function()
    local att = attitudeEnum(name)
    a:GetAttitudeAgent():SetAttitudeTowards(b:GetAttitudeAgent(), att)
    b:GetAttitudeAgent():SetAttitudeTowards(a:GetAttitudeAgent(), att)
  end)
end

-- Push npc into combat against target.
function Engine.provoke(npc, target)
  if not npc or not target then return end
  pcall(function()
    npc:GetTargetTrackerComponent():AddThreat(target, true, target:GetWorldPosition(), 1.0, -1.0, false)
  end)
  pcall(function() NPCPuppet.ChangeHighLevelState(npc, gamedataNPCHighLevelState.Combat) end)
end

-- Player ---------------------------------------------------------------------

function Engine.lookAt()
  return try(function() return Game.GetTargetingSystem():GetLookAtObject(Game.GetPlayer(), false, false) end)
end

function Engine.ram()
  return try(function()
    return Game.GetStatPoolsSystem():GetStatPoolValue(Game.GetPlayer():GetEntityID(), gamedataStatPoolType.Memory, false)
  end) or 0
end

function Engine.spendRam(n)
  pcall(function()
    Game.GetStatPoolsSystem():RequestChangingStatPoolValue(Game.GetPlayer():GetEntityID(), gamedataStatPoolType.Memory, -n, nil, false, false)
  end)
end

return Engine
