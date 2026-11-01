-- Stand-in for engine.lua so pit.lua runs without the game.
local Fake = {}

-- rand() returns the values in seq in turn (for forcing detection rolls);
-- rand(a, b) is a normal random integer.
function Fake.rand(seq)
  local i = 0
  return function(a, b)
    if a then return math.random(a, b) end
    if not seq then return math.random() end
    i = i % #seq + 1
    return seq[i]
  end
end

function Fake.new()
  local E = {
    money = 10000, look = nil, noPlayer = false,
    entities = {}, despawned = {}, attitude = {}, provoked = {}, mods = {},
    spawnCount = 0, spawnDelay = nil, failSpawn = false, despawnedAll = false,
    nextId = 0, modId = 0,
  }
  local playerObj = { id = "player", isPlayer = true, pos = { x = 0, y = 0, z = 0 } }

  local function newEnt(opts)
    E.nextId = E.nextId + 1
    local ent = { id = "e" .. E.nextId, hp = 100, dead = false, npc = true, pos = { x = 0, y = 0, z = 0 } }
    for k, v in pairs(opts or {}) do ent[k] = v end
    E.entities[ent.id] = ent
    return ent
  end

  function E:addNPC(opts) return newEnt(opts) end

  E.notify = function() end
  E.log = function() end
  E.try = function(fn, ...) local ok, r = pcall(fn, ...); if ok then return r end end
  E.player = function() if E.noPlayer then return nil end return playerObj end
  E.playerDead = function() return E.dead == true end
  E.sessionActive = function() return not E.noPlayer end
  E.arenaPoints = function(d, s)
    return { center = { x = 0, y = d, z = 0 }, red = { x = -s, y = d, z = 0 }, blue = { x = s, y = d, z = 0 } }
  end
  E.offset = function(p, dx, dy) return { x = p.x + dx, y = p.y + dy, z = p.z } end
  E.distance = function(a, b)
    if not a or not b then return math.huge end
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
  end
  E.position = function(ent) return ent and ent.pos end
  E.spawn = function(record, pos)
    assert(type(record) == "string", "spawn needs a record id")
    if E.failSpawn then return nil end
    E.spawnCount = E.spawnCount + 1
    local ent = newEnt({ record = record, pos = { x = pos.x, y = pos.y, z = pos.z } })
    if E.spawnDelay then ent.hidden = true end
    return ent.id
  end
  E.getEntity = function(id)
    local ent = id and E.entities[id]
    if ent and ent.hidden then return nil end
    return ent
  end
  E.despawn = function(id) if id then E.despawned[id] = true; E.entities[id] = nil end end
  E.despawnAll = function() E.despawnedAll = true end
  E.sameEntity = function(a, b) return a ~= nil and b ~= nil and a.id == b.id end
  E.entityID = function(ent) return ent and ent.id end
  E.isNPC = function(o) return o ~= nil and o.npc == true end
  E.isPlayer = function(o) return o ~= nil and o.isPlayer == true end
  E.isDown = function(ent) return ent ~= nil and (ent.dead or ent.hp <= 0) end
  E.healthPct = function(ent) return ent and ent.hp end
  E.damagePct = function(ent, p) ent.hp = ent.hp - p end
  E.powerLevel = function(ent) return ent.level end
  E.displayName = function(ent) return ent.name end
  E.addStatMod = function(ent, stat, kind, value)
    assert(ent, "stat mod on nil entity")
    E.modId = E.modId + 1
    local mod = { ent = ent.id, stat = stat, kind = kind, value = value }
    E.mods[E.modId] = mod
    return mod
  end
  E.removeStatMod = function(ent, mod) if mod then mod.removed = true end end
  E.setAttitude = function(a, b, name)
    if not a or not b then return end
    E.attitude[a.id .. ">" .. b.id] = name
    E.attitude[b.id .. ">" .. a.id] = name
  end
  E.provoke = function(npc, target)
    if npc and target then E.provoked[npc.id] = (E.provoked[npc.id] or 0) + 1 end
  end
  E.lookAt = function() return E.look end
  E.ram = function() return E.ramValue end
  E.spendRam = function(n) E.ramValue = E.ramValue - n end
  E.getMoney = function() return E.money end
  E.takeMoney = function(n) if n > E.money then return false end E.money = E.money - n; return true end
  E.giveMoney = function(n) E.money = E.money + n; return true end

  E.ramValue = 10
  return E
end

return Fake
