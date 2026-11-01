-- The fight-night state machine. Takes the Engine as a parameter so it can run
-- against a fake engine in tests.
--
-- idle -> card -> spawning -> betting -> fighting -> result -> idle
local Roster = require("roster")
local Odds = require("odds")

local Pit = {}
Pit.__index = Pit

local SIDE_NAME = { "Red", "Blue" }

function Pit.new(engine, rand)
  local self = setmetatable({}, Pit)
  self.E = engine
  self.rand = rand or math.random
  self.cfg = {
    bettingTime = 60,     -- seconds before the bell rings by itself
    fightTimeout = 120,   -- judges' decision after this
    arenaDistance = 8,
    arenaSpread = 3,
    cleanupDelay = 20,
    requireLookAt = true, -- sabotage only the fighter you are looking at
    spawnTimeout = 15,
    strayDistance = 25,   -- a fighter this far from the ring...
    strayTime = 10,       -- ...for this long forfeits
    bookieDelay = 8,      -- head start before the muscle spawns
    bookieDistance = 25,  -- how far from the ring they spawn
  }
  self.venueIndex = 1
  self.stake = 500
  self.stats = { fights = 0, wagered = 0, won = 0, lost = 0, biggestWin = 0, timesCaught = 0 }
  self.bookies = {}
  self.message = ""
  self:reset()
  return self
end

function Pit:reset()
  self.state = "idle"
  self.card = nil
  self.bet = nil
  self.timer = 0
  self.elapsed = 0
  self.tick = 0
  self.provokeTimer = 0
  self.lostTimer = 0
  self.strayTimer = 0
  self.heat = { acts = 0, caught = false, log = {} }
  self.lastHit = {}
  self.result = nil
end

function Pit:venue() return Roster.venues[self.venueIndex] end

function Pit:say(msg)
  self.message = msg
  self.E.notify(msg)
end

-- Always look fighters up by ID: a handle cached across frames can point at a
-- freed entity after a save load, and touching it crashes the game.
function Pit:fighterEntity(i)
  local f = self.card and self.card[i]
  if not f or not f.entityID then return nil end
  return self.E.getEntity(f.entityID)
end

function Pit:sideOf(ent)
  if not self.card or not ent then return nil end
  for i = 1, 2 do
    local fe = self:fighterEntity(i)
    if fe and self.E.sameEntity(fe, ent) then return i end
  end
  return nil
end

-- Card ----------------------------------------------------------------------

function Pit:refreshOdds()
  local a, b = self.card[1], self.card[2]
  if a and b then
    self.card.probs, self.card.mults = Odds.book(a.rating, b.rating)
  else
    self.card.probs, self.card.mults = nil, nil
  end
end

function Pit:newCard()
  if self.state ~= "idle" and self.state ~= "card" then return end
  self:cleanupCard()
  local v = self:venue()
  local a = Roster.rollFighter(v, self.rand)
  local b = Roster.rollFighter(v, self.rand, a and a.name)
  self.card = { a, b }
  self:refreshOdds()
  self.state = "card"
  if not a or not b then
    self:say("No valid fighter records for this venue. Draft fighters from the crowd instead.")
  else
    self.message = ""
  end
end

-- Use the NPC the player is looking at as a corner's fighter.
function Pit:draft(side)
  if self.state ~= "card" then return end
  local ent = self.E.lookAt()
  if not ent or not self.E.isNPC(ent) then
    self:say("Look at an NPC first, then draft them.")
    return
  end
  if self:sideOf(ent) then self:say("They're already on the card."); return end
  local other = self.card[3 - side]
  if other and self:fighterEntity(3 - side) and self.E.sameEntity(self:fighterEntity(3 - side), ent) then return end
  local level = self.E.powerLevel(ent) or 10
  -- Most NPCs share a generic game name ("NC Resident"), so give them a ring
  -- handle and keep the game name as a label.
  local origin = self.E.displayName(ent)
  local otherName = other and other.name
  local name = otherName
  local guard = 0
  while name == otherName and guard < 20 do
    name = self:venue().handles[self.rand(1, #self:venue().handles)]
    guard = guard + 1
  end
  local f = Roster.makeFighter("local_", nil, name, self.rand, 25 + math.floor(level))
  if origin then f.label = f.label .. " (" .. origin .. ")" end
  f.entityID = self.E.entityID(ent)
  f.drafted = true
  self.card[side] = f
  self:refreshOdds()
  self:say(name .. " drafted into the " .. SIDE_NAME[side] .. " corner.")
end

-- Spawn fighters and open the book.
function Pit:openBook()
  if self.state ~= "card" or not self.card[1] or not self.card[2] then return end
  local pts = self.E.arenaPoints(self.cfg.arenaDistance, self.cfg.arenaSpread)
  self.arena = pts
  local corners = { pts.red, pts.blue }
  for i = 1, 2 do
    local f = self.card[i]
    if not f.drafted then
      f.entityID = self.E.spawn(f.record, corners[i], corners[3 - i])
      f.owned = true
      if not f.entityID then
        -- Undo any corner already spawned, keep the card so the player can retry or draft.
        for j = 1, 2 do
          local g = self.card[j]
          if g.owned then self.E.despawn(g.entityID) end
          if not g.drafted then g.entityID, g.owned = nil, nil end
        end
        self:say("Spawn failed for " .. f.name .. ". Is Codeware installed?")
        return
      end
    end
  end
  self.state = "spawning"
  self.timer = self.cfg.spawnTimeout
  self:say("Fighters are walking out...")
end

-- Implants become real stat modifiers on the NPC.
function Pit:applyImplants(f, ent)
  f.mods = {}
  for _, key in ipairs(f.implants) do
    local cw = Roster.cyberware[key]
    local list = {}
    if cw.hp then table.insert(list, self.E.addStatMod(ent, "Health", "Multiplier", cw.hp)) end
    if cw.armor then table.insert(list, self.E.addStatMod(ent, "Armor", "Additive", cw.armor)) end
    f.mods[key] = list
  end
end

-- Neutral, not friendly: friendly NPCs can't be quickhacked, and real
-- quickhacks are part of the sabotage game.
function Pit:pacify(ent)
  self.E.setAttitude(ent, self.E.player(), "neutral")
end

-- Betting -------------------------------------------------------------------

function Pit:placeBet(side, stake)
  if self.state ~= "betting" or self.bet then return false end
  stake = math.floor(stake or 0)
  if stake <= 0 then self:say("Stake must be above zero."); return false end
  if self.E.getMoney() < stake then self:say("Not enough eddies."); return false end
  if not self.E.takeMoney(stake) then self:say("Couldn't take the stake."); return false end
  self.bet = { side = side, stake = stake, mult = self.card.mults[side], void = false }
  self.stats.wagered = self.stats.wagered + stake
  self:say(string.format("%d eddies on %s at %.2fx.", stake, self.card[side].name, self.bet.mult))
  return true
end

-- Sabotage ------------------------------------------------------------------

function Pit:caught(reason)
  if self.heat.caught then return end
  self.heat.caught = true
  self.stats.timesCaught = self.stats.timesCaught + 1
  if self.bet and not self.bet.void then
    self.bet.void = true
    self.stats.lost = self.stats.lost + self.bet.stake
  end
  -- Give the player a head start: the muscle shows up after a delay.
  self.bookiesDue = self.cfg.bookieDelay
  self.bookieCenter = (self.arena and self.arena.center) or self.E.position(self.E.player())
  self.bookieFine = (self.bet and self.bet.stake) or 1000
  self:say(string.format("The bookies saw that (%s). Bet void - their muscle arrives in %ds. Run or fight!",
    reason, math.floor(self.cfg.bookieDelay)))
end

-- Every sabotage act risks detection; each act makes the next riskier.
function Pit:registerAct(side, what, extraHeat)
  local chance = Odds.detectionChance(self:venue().detect, self.heat.acts, extraHeat)
  self.heat.acts = self.heat.acts + 1
  table.insert(self.heat.log, string.format("%s on %s (%d%% risk)", what, self.card[side].name, math.floor(chance * 100 + 0.5)))
  if self.rand() < chance then self:caught(what) end
end

function Pit:sabotageTarget(side)
  if self.state ~= "betting" and self.state ~= "fighting" then return nil, "No fight on." end
  local f = self.card[side]
  local ent = self:fighterEntity(side)
  if not f or not ent then return nil, "Fighter not in reach." end
  if self.cfg.requireLookAt then
    local look = self.E.lookAt()
    if not look or not self.E.sameEntity(look, ent) then return nil, "Look at " .. f.name .. " to hack them." end
  end
  return f, ent
end

function Pit:sabotage(side, sabId)
  local def
  for _, s in ipairs(Roster.sabotage) do if s.id == sabId then def = s end end
  local f, ent = self:sabotageTarget(side)
  if not f then self:say(ent); return false end
  if self.E.ram() < def.ram then self:say("Not enough RAM for " .. def.name .. "."); return false end
  f.sabotaged = f.sabotaged or {}
  if f.sabotaged[sabId] then self:say(f.name .. " already got " .. def.name .. "."); return false end

  if sabId == "shortcircuit" then
    self.E.damagePct(ent, 25)
  elseif sabId == "malfunction" then
    local best, bestRating
    for _, key in ipairs(f.implants) do
      local cw = Roster.cyberware[key]
      if not (f.disabled and f.disabled[key]) and (not bestRating or cw.rating > bestRating) then best, bestRating = key, cw.rating end
    end
    if not best then self:say(f.name .. " has no chrome to glitch."); return false end
    for _, mod in ipairs((f.mods or {})[best] or {}) do self.E.removeStatMod(ent, mod) end
    f.disabled = f.disabled or {}
    f.disabled[best] = true
  elseif sabId == "shred" then
    f.shredMod = self.E.addStatMod(ent, "Armor", "Multiplier", 0.5)
  end

  self.E.spendRam(def.ram)
  f.sabotaged[sabId] = true
  self:say(def.name .. " landed on " .. f.name .. ".")
  self:registerAct(side, def.name, def.heat)
  return true
end

-- The player shooting/hacking a fighter directly (from the OnHit hook).
function Pit:onPlayerHit(side, now)
  if self.state ~= "betting" and self.state ~= "fighting" then return end
  if self.lastHit[side] and now - self.lastHit[side] < 3 then return end
  self.lastHit[side] = now
  self:registerAct(side, "Direct interference", 0.15)
end

-- Bookies -------------------------------------------------------------------

function Pit:sendBookies()
  local v = self:venue()
  local records = v.bookies.valid or {}
  local center = self.bookieCenter
  if #records == 0 or not center then
    local fine = math.min(self.E.getMoney(), self.bookieFine or 1000)
    self.E.takeMoney(fine)
    self:say("No muscle nearby - they took " .. fine .. " eddies off you instead.")
    return
  end
  local r = self.cfg.bookieDistance
  for i = 1, v.bookies.count do
    local ang = (i / v.bookies.count) * 2 * math.pi
    local pos = self.E.offset(center, math.cos(ang) * r, math.sin(ang) * r)
    local id = self.E.spawn(records[self.rand(1, #records)], pos, center)
    if id then table.insert(self.bookies, { id = id, hostile = false, age = 0 }) end
  end
end

function Pit:updateBookies(dt)
  local p = self.E.player()
  for i = #self.bookies, 1, -1 do
    local b = self.bookies[i]
    b.age = b.age + dt
    local ent = self.E.getEntity(b.id)
    if ent and p and not b.hostile then
      self.E.setAttitude(ent, p, "hostile")
      self.E.provoke(ent, p)
      b.hostile = true
    end
    local far = ent and p and self.E.distance(self.E.position(ent), self.E.position(p)) > 150
    if ent and self.E.isDown(ent) then b.deadFor = (b.deadFor or 0) + dt end
    if (b.deadFor or 0) > 30 or far or b.age > 600 then
      self.E.despawn(b.id)
      table.remove(self.bookies, i)
    end
  end
end

-- Fight ---------------------------------------------------------------------

function Pit:ringBell()
  if self.state ~= "betting" then return end
  local a, b = self:fighterEntity(1), self:fighterEntity(2)
  self.E.setAttitude(a, b, "hostile")
  self.E.provoke(a, b)
  self.E.provoke(b, a)
  self.state = "fighting"
  self.elapsed = 0
  self.provokeTimer = 0
  self:say("Ding ding! " .. self.card[1].name .. " vs " .. self.card[2].name)
end

function Pit:resolve(winner, how)
  self.stats.fights = self.stats.fights + 1
  local bet = self.bet
  local paid = Odds.settle(bet, winner)
  local text
  if winner == 0 then
    text = "Draw (" .. how .. ")."
  else
    text = self.card[winner].name .. " wins by " .. how .. "."
  end
  if bet and not bet.void then
    if paid > 0 then self.E.giveMoney(paid) end
    if winner == 0 then
      text = text .. " Stake refunded."
    elseif winner == bet.side then
      local profit = paid - bet.stake
      self.stats.won = self.stats.won + profit
      if profit > self.stats.biggestWin then self.stats.biggestWin = profit end
      text = text .. " You collect " .. paid .. " eddies."
    else
      self.stats.lost = self.stats.lost + bet.stake
      text = text .. " You lose " .. bet.stake .. " eddies."
    end
  end
  self.result = { winner = winner, how = how, paid = paid, text = text }
  -- Let the survivor stop swinging.
  self.E.setAttitude(self:fighterEntity(1), self:fighterEntity(2), "neutral")
  self.state = "result"
  self.timer = self.cfg.cleanupDelay
  self:say(text)
  if self.onSettled then self.onSettled() end
end

-- Abort; refunds a live bet.
function Pit:cancel(reason)
  local refunded = self.bet and not self.bet.void
  if refunded then
    self.E.giveMoney(self.bet.stake)
    self.stats.wagered = self.stats.wagered - self.bet.stake
  end
  self:cleanupCard()
  self:reset()
  self:say("Fight called off: " .. reason .. (refunded and " Stake refunded." or ""))
end

function Pit:cleanupCard()
  if not self.card then return end
  for i = 1, 2 do
    local f = self.card[i]
    if f then
      local ent = self.E.getEntity(f.entityID)
      if ent and f.drafted then
        -- Leave the borrowed NPC as we found it.
        for _, list in pairs(f.mods or {}) do for _, m in ipairs(list) do self.E.removeStatMod(ent, m) end end
        if f.shredMod then self.E.removeStatMod(ent, f.shredMod) end
      end
      if f.owned then self.E.despawn(f.entityID) end
    end
  end
  self.card = nil
end

function Pit:update(dt)
  if not self.E.sessionActive() then
    self:dropSession()
    return
  end
  self:updateBookies(dt)

  if self.E.playerDead() then
    if self.state ~= "idle" or #self.bookies > 0 or self.bookiesDue then
      self:cancel("you flatlined.")
      for _, b in ipairs(self.bookies) do self.E.despawn(b.id) end
      self.bookies = {}
      self.bookiesDue = nil
    end
    return
  end

  if self.bookiesDue then
    self.bookiesDue = self.bookiesDue - dt
    if self.bookiesDue <= 0 then
      self.bookiesDue = nil
      self:sendBookies()
      self:say("The bookies' muscle is here!")
    end
  end

  if self.state == "spawning" then
    self.timer = self.timer - dt
    local ready = true
    for i = 1, 2 do
      if not self:fighterEntity(i) then ready = false end
    end
    if ready then
      for i = 1, 2 do
        local ent = self:fighterEntity(i)
        self:applyImplants(self.card[i], ent)
        self:pacify(ent)
      end
      self.state = "betting"
      self.timer = self.cfg.bettingTime
      self:say("Book is open. " .. math.floor(self.cfg.bettingTime) .. "s to place your bet.")
    elseif self.timer <= 0 then
      self:cancel("fighters never showed (spawn timed out).")
    end

  elseif self.state == "betting" then
    self.timer = self.timer - dt
    -- Gunfire nearby makes neutral NPCs (mechs especially) pick V as a
    -- threat; keep reasserting neutral while they wait for the bell.
    self.provokeTimer = self.provokeTimer + dt
    if self.provokeTimer >= 2 then
      self.provokeTimer = 0
      self:pacify(self:fighterEntity(1))
      self:pacify(self:fighterEntity(2))
    end
    if self.timer <= 0 then self:ringBell() end

  elseif self.state == "fighting" then
    self.elapsed = self.elapsed + dt
    self.tick = self.tick + dt
    if self.tick < 0.25 then return end
    local step = self.tick
    self.tick = 0
    local a, b = self:fighterEntity(1), self:fighterEntity(2)
    if not a and not b then
      self.lostTimer = self.lostTimer + step
      if self.lostTimer > 8 then self:cancel("fighters out of sight.") end
      return
    end
    self.lostTimer = 0
    local downA, downB = self.E.isDown(a), self.E.isDown(b)
    if downA and downB then return self:resolve(0, "double knockout") end
    if downA then return self:resolve(2, "knockout") end
    if downB then return self:resolve(1, "knockout") end
    -- Civilians flee and some NPCs wander off; leaving the ring forfeits.
    local center = self.arena and self.arena.center
    if center then
      local sa = self.E.distance(self.E.position(a), center) > self.cfg.strayDistance
      local sb = self.E.distance(self.E.position(b), center) > self.cfg.strayDistance
      if sa or sb then self.strayTimer = self.strayTimer + step else self.strayTimer = 0 end
      if self.strayTimer >= self.cfg.strayTime then
        if sa and sb then return self:resolve(0, "no contest (both left the ring)") end
        return self:resolve(sa and 2 or 1, "forfeit (opponent left the ring)")
      end
    end
    if self.elapsed >= self.cfg.fightTimeout then
      local ha, hb = self.E.healthPct(a) or 0, self.E.healthPct(b) or 0
      if math.abs(ha - hb) < 1 then return self:resolve(0, "split decision") end
      return self:resolve(ha > hb and 1 or 2, "judges' decision")
    end
    self.provokeTimer = self.provokeTimer + step
    if self.provokeTimer >= 4 then
      self.provokeTimer = 0
      self.E.provoke(a, b)
      self.E.provoke(b, a)
      self:pacify(a)
      self:pacify(b)
    end

  elseif self.state == "result" then
    self.timer = self.timer - dt
    if self.timer <= 0 then self:clearPit() end
  end
end

-- The world is gone (main menu, save loading): forget everything without
-- touching any entity.
function Pit:dropSession()
  if self.state ~= "idle" then self:reset() end
  self.bookies = {}
  self.bookiesDue = nil
end

function Pit:clearPit()
  self:cleanupCard()
  self:reset()
end

function Pit:shutdown()
  self:cleanupCard()
  for _, b in ipairs(self.bookies) do self.E.despawn(b.id) end
  self.bookies = {}
  self.E.despawnAll()
end

return Pit
