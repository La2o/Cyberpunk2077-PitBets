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
  self.heat = { acts = 0, caught = false, log = {} }
  self.lastHit = {}
  self.result = nil
end

function Pit:venue() return Roster.venues[self.venueIndex] end

function Pit:say(msg)
  self.message = msg
  self.E.notify(msg)
end

function Pit:sideOf(ent)
  if not self.card or not ent then return nil end
  for i = 1, 2 do
    local f = self.card[i]
    if f and f.entity and self.E.sameEntity(f.entity, ent) then return i end
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
  if other and other.entity and self.E.sameEntity(other.entity, ent) then return end
  local level = self.E.powerLevel(ent) or 10
  local name = self.E.displayName(ent) or ("Local talent #" .. self.rand(10, 99))
  local f = Roster.makeFighter("local_", nil, name, self.rand, 25 + math.floor(level))
  f.entity = ent
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
function Pit:applyImplants(f)
  f.mods = {}
  for _, key in ipairs(f.implants) do
    local cw = Roster.cyberware[key]
    local list = {}
    if cw.hp then table.insert(list, self.E.addStatMod(f.entity, "Health", "Multiplier", cw.hp)) end
    if cw.armor then table.insert(list, self.E.addStatMod(f.entity, "Armor", "Additive", cw.armor)) end
    f.mods[key] = list
  end
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
  self:say("The bookies saw that (" .. reason .. "). Your bet is void and they're coming for you!")
  self:sendBookies()
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
  if not f or not f.entity then return nil, "Fighter not in reach." end
  if self.cfg.requireLookAt then
    local look = self.E.lookAt()
    if not look or not self.E.sameEntity(look, f.entity) then return nil, "Look at " .. f.name .. " to hack them." end
  end
  return f
end

function Pit:sabotage(side, sabId)
  local def
  for _, s in ipairs(Roster.sabotage) do if s.id == sabId then def = s end end
  local f, err = self:sabotageTarget(side)
  if not f then self:say(err); return false end
  if self.E.ram() < def.ram then self:say("Not enough RAM for " .. def.name .. "."); return false end
  f.sabotaged = f.sabotaged or {}
  if f.sabotaged[sabId] then self:say(f.name .. " already got " .. def.name .. "."); return false end

  if sabId == "shortcircuit" then
    self.E.damagePct(f.entity, 25)
  elseif sabId == "malfunction" then
    local best, bestRating
    for _, key in ipairs(f.implants) do
      local cw = Roster.cyberware[key]
      if not (f.disabled and f.disabled[key]) and (not bestRating or cw.rating > bestRating) then best, bestRating = key, cw.rating end
    end
    if not best then self:say(f.name .. " has no chrome to glitch."); return false end
    for _, mod in ipairs((f.mods or {})[best] or {}) do self.E.removeStatMod(f.entity, mod) end
    f.disabled = f.disabled or {}
    f.disabled[best] = true
  elseif sabId == "shred" then
    f.shredMod = self.E.addStatMod(f.entity, "Armor", "Multiplier", 0.5)
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
  local p = self.E.player()
  local center = (self.arena and self.arena.center) or (p and self.E.position(p))
  if #records == 0 or not center then
    local fine = math.min(self.E.getMoney(), (self.bet and self.bet.stake) or 1000)
    self.E.takeMoney(fine)
    self:say("No muscle nearby - they took " .. fine .. " eddies off you instead.")
    return
  end
  for i = 1, v.bookies.count do
    local ang = (i / v.bookies.count) * 2 * math.pi
    local pos = self.E.offset(center, math.cos(ang) * 12, math.sin(ang) * 12)
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
  local a, b = self.card[1].entity, self.card[2].entity
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
  self.E.setAttitude(self.card[1].entity, self.card[2].entity, "neutral")
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
      local ent = f.entity or self.E.getEntity(f.entityID)
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
  self:updateBookies(dt)
  if not self.E.player() then
    -- Back at the main menu / loading: everything we spawned is gone.
    if self.state ~= "idle" then self:reset() end
    self.bookies = {}
    return
  end

  if self.state == "spawning" then
    self.timer = self.timer - dt
    local ready = true
    for i = 1, 2 do
      local f = self.card[i]
      f.entity = self.E.getEntity(f.entityID)
      if not f.entity then ready = false end
    end
    if ready then
      local p = self.E.player()
      for i = 1, 2 do
        local f = self.card[i]
        self:applyImplants(f)
        self.E.setAttitude(f.entity, p, "neutral")
      end
      self.state = "betting"
      self.timer = self.cfg.bettingTime
      self:say("Book is open. " .. math.floor(self.cfg.bettingTime) .. "s to place your bet.")
    elseif self.timer <= 0 then
      self:cancel("fighters never showed (spawn timed out).")
    end

  elseif self.state == "betting" then
    self.timer = self.timer - dt
    for i = 1, 2 do self.card[i].entity = self.E.getEntity(self.card[i].entityID) or self.card[i].entity end
    if self.timer <= 0 then self:ringBell() end

  elseif self.state == "fighting" then
    self.elapsed = self.elapsed + dt
    self.tick = self.tick + dt
    if self.tick < 0.25 then return end
    local step = self.tick
    self.tick = 0
    local a = self.E.getEntity(self.card[1].entityID)
    local b = self.E.getEntity(self.card[2].entityID)
    self.card[1].entity, self.card[2].entity = a or self.card[1].entity, b or self.card[2].entity
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
    end

  elseif self.state == "result" then
    self.timer = self.timer - dt
    if self.timer <= 0 then self:clearPit() end
  end
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
