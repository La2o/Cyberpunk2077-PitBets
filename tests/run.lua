-- Offline tests for Pit Bets. Run from the repo root:  luajit tests/run.lua
-- Covers the odds math, roster, the full fight state machine against a fake
-- engine, every UI screen against a fake ImGui, init.lua against fake CET
-- globals, and engine.lua against a fake game API.
package.path = "./PitBets/?.lua;./tests/?.lua;" .. package.path

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. "\n  " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end
local function truthy(v, msg) if not v then error(msg or "expected truthy", 2) end end
local function near(a, b, eps, msg) if math.abs(a - b) > (eps or 1e-6) then error((msg or "") .. " expected ~" .. b .. ", got " .. a, 2) end end

local function fresh(name) package.loaded[name] = nil; return require(name) end

-- Syntax ---------------------------------------------------------------------
for _, f in ipairs({ "init", "engine", "odds", "pit", "roster", "ui" }) do
  test("syntax " .. f, function() assert(loadfile("PitBets/" .. f .. ".lua")) end)
end

-- Odds -----------------------------------------------------------------------
local Odds = require("odds")
test("even fight is 50/50 and pays under 2x", function()
  near(Odds.winProbability(50, 50), 0.5)
  eq(Odds.payoutMultiplier(0.5), 1.84)
end)
test("probabilities sum to 1, favourite pays less", function()
  local p, m = Odds.book(120, 60)
  near(p[1] + p[2], 1)
  truthy(p[1] > 0.7, "120 vs 60 should be a strong favourite")
  truthy(m[1] < m[2])
  truthy(m[1] > 1)
end)
test("mech vs bare boxer still pays something on the favourite", function()
  local p, m = Odds.book(200, 20)
  eq(p[1], Odds.MAX_PROB)
  truthy(m[1] > 1 and m[2] < 10)
end)
test("house always has an edge", function()
  for r = 10, 200, 10 do
    local p, m = Odds.book(r, 70)
    for i = 1, 2 do truthy(p[i] * m[i] <= 1.0, "EV must be <= 1 at rating " .. r) end
  end
end)
test("detection grows per act and caps", function()
  near(Odds.detectionChance(0.2, 0), 0.2)
  near(Odds.detectionChance(0.2, 2), 0.44)
  eq(Odds.detectionChance(0.3, 20), 0.9)
  eq(Odds.detectionChance(-1, 0), 0)
end)
test("settle", function()
  local bet = { side = 1, stake = 1000, mult = 2.35 }
  eq(Odds.settle(bet, 1), 2350)
  eq(Odds.settle(bet, 2), 0)
  eq(Odds.settle(bet, 0), 1000)
  eq(Odds.settle({ side = 1, stake = 1000, mult = 2, void = true }, 1), 0)
  eq(Odds.settle(nil, 1), 0)
end)

-- Roster ---------------------------------------------------------------------
local Roster = require("roster")
local function allValid() return true end
test("every implant key exists", function()
  for k, c in pairs(Roster.classes) do
    for _, key in ipairs(c.pool) do truthy(Roster.cyberware[key], k .. " pool has unknown " .. key) end
    for _, key in ipairs(c.fixed or {}) do truthy(Roster.cyberware[key], k .. " fixed has unknown " .. key) end
  end
  for _, v in ipairs(Roster.venues) do
    for _, t in ipairs(v.templates) do truthy(Roster.classes[t.class], "unknown class " .. t.class) end
    truthy(#v.handles >= 2, "need 2+ handles")
  end
end)
test("validate filters bad records", function()
  local report = Roster.validate(function(id) return id:find("mech") == nil end)
  for _, v in ipairs(Roster.venues) do
    for _, t in ipairs(v.templates) do
      if t.class == "mech" then eq(#t.valid, 0) else truthy(#t.valid > 0) end
    end
  end
  truthy(#report > 10)
end)
test("rolled fighters are sane", function()
  Roster.validate(allValid)
  math.randomseed(42)
  for _ = 1, 500 do
    for _, v in ipairs(Roster.venues) do
      local a = Roster.rollFighter(v, math.random)
      local b = Roster.rollFighter(v, math.random, a.name)
      truthy(a.name ~= b.name, "duplicate handles")
      local seen = {}
      for _, k in ipairs(a.implants) do truthy(not seen[k], "duplicate implant"); seen[k] = true end
      local c = Roster.classes[a.class]
      truthy(#a.implants >= c.slots[1] + #(c.fixed or {}) and #a.implants <= c.slots[2] + #(c.fixed or {}))
      truthy(a.rating > 0 and a.form >= 0.9 and a.form <= 1.1)
      if a.class == "mech" then eq(a.implants[1], "plating") end
    end
  end
end)
test("no valid records -> nil fighter", function()
  Roster.validate(function() return false end)
  eq(Roster.rollFighter(Roster.venues[1], math.random), nil)
  Roster.validate(allValid)
end)
test("implantNames marks offline", function()
  local f = { implants = { "sandy", "biomon" }, disabled = { sandy = true } }
  eq(Roster.implantNames(f), "Sandevistan (offline), Biomonitor")
  eq(Roster.implantNames({ implants = {} }), "no chrome")
end)

-- Pit state machine against a fake engine ------------------------------------
local Fake = require("fake_engine")
local Pit = require("pit")

local function newPit(seq)
  Roster.validate(allValid)
  local E = Fake.new()
  local rand = Fake.rand(seq)
  local pit = Pit.new(E, rand)
  return pit, E
end

local function toBetting(pit, E)
  pit:newCard()
  eq(pit.state, "card")
  pit:openBook()
  eq(pit.state, "spawning")
  pit:update(0.1)
  eq(pit.state, "betting")
  return E.entities[pit.card[1].entityID], E.entities[pit.card[2].entityID]
end

test("full fight: bet on winner gets paid", function()
  local pit, E = newPit()
  E.money = 5000
  local a, b = toBetting(pit, E)
  truthy(a and b, "entities resolved")
  eq(E.attitude[a.id .. ">player"], "friendly")
  eq(a.group, "player", "fighter moved into V's attitude group")
  eq(pit.card[1].origGroup, "gang")
  -- implants were applied as stat mods
  local modCount = 0
  for _ in pairs(E.mods) do modCount = modCount + 1 end
  truthy(modCount > 0 or (#pit.card[1].implants + #pit.card[2].implants == 0))
  truthy(pit:placeBet(1, 1000))
  eq(E.money, 4000)
  truthy(not pit:placeBet(2, 100), "second bet refused")
  local mult = pit.bet.mult
  pit:ringBell()
  eq(pit.state, "fighting")
  eq(E.attitude[a.id .. ">" .. b.id], "hostile")
  truthy(E.provoked[a.id] and E.provoked[b.id])
  pit:update(0.3)
  eq(pit.state, "fighting")
  b.dead = true
  pit:update(0.3)
  eq(pit.state, "result")
  eq(pit.result.winner, 1)
  eq(E.money, 4000 + math.floor(1000 * mult))
  eq(pit.stats.fights, 1)
  eq(pit.stats.won, math.floor(1000 * mult) - 1000)
  pit:update(pit.cfg.cleanupDelay + 1)
  eq(pit.state, "idle")
  truthy(E.despawned[a.id] and E.despawned[b.id], "owned fighters despawned")
end)

test("losing bet", function()
  local pit, E = newPit()
  E.money = 2000
  local a = toBetting(pit, E)
  pit:placeBet(2, 500)
  pit:ringBell()
  E.entities[pit.card[2].entityID].dead = true
  pit:update(0.3)
  eq(pit.result.winner, 1)
  eq(E.money, 1500)
  eq(pit.stats.lost, 500)
end)

test("double KO refunds", function()
  local pit, E = newPit()
  E.money = 1000
  local a, b = toBetting(pit, E)
  pit:placeBet(1, 1000)
  pit:ringBell()
  a.dead, b.dead = true, true
  pit:update(0.3)
  eq(pit.result.winner, 0)
  eq(E.money, 1000)
end)

test("defeated (not dead) counts as down", function()
  local pit, E = newPit()
  local a, b = toBetting(pit, E)
  pit:ringBell()
  a.hp = 0
  pit:update(0.3)
  eq(pit.result.winner, 2)
end)

test("bell rings itself after betting time", function()
  local pit, E = newPit()
  toBetting(pit, E)
  pit:update(pit.cfg.bettingTime - 1)
  eq(pit.state, "betting")
  pit:update(2)
  eq(pit.state, "fighting")
end)

test("timeout goes to the judges", function()
  local pit, E = newPit()
  local a, b = toBetting(pit, E)
  pit:ringBell()
  a.hp, b.hp = 40, 70
  for _ = 1, math.ceil(pit.cfg.fightTimeout / 0.5) + 2 do pit:update(0.5) if pit.state ~= "fighting" then break end end
  eq(pit.state, "result")
  eq(pit.result.winner, 2)
  eq(pit.result.how, "judges' decision")
end)

test("timeout with equal health is a draw", function()
  local pit, E = newPit()
  local a, b = toBetting(pit, E)
  pit:ringBell()
  a.hp, b.hp = 50, 50.5
  for _ = 1, 400 do pit:update(0.5) if pit.state ~= "fighting" then break end end
  eq(pit.result.winner, 0)
end)

test("fighters re-provoked every few seconds", function()
  local pit, E = newPit()
  local a = toBetting(pit, E)
  pit:ringBell()
  local before = E.provoked[a.id]
  for _ = 1, 20 do pit:update(0.3) end
  truthy(E.provoked[a.id] > before)
end)

test("fighters lost from the world -> cancel with refund", function()
  local pit, E = newPit()
  E.money = 1000
  local a, b = toBetting(pit, E)
  pit:placeBet(1, 400)
  pit:ringBell()
  E.entities[a.id], E.entities[b.id] = nil, nil
  for _ = 1, 40 do pit:update(0.3) end
  eq(pit.state, "idle")
  eq(E.money, 1000)
  eq(pit.stats.wagered, 0)
end)

test("spawn timeout cancels", function()
  local pit, E = newPit()
  pit:newCard()
  E.spawnDelay = 999
  pit:openBook()
  for _ = 1, 20 do pit:update(1) end
  eq(pit.state, "idle")
  truthy(pit.message:find("timed out"))
end)

test("spawn failure stays on card", function()
  local pit, E = newPit()
  pit:newCard()
  E.failSpawn = true
  pit:openBook()
  eq(pit.state, "card")
  truthy(pit.card[1] and pit.card[2], "card kept for retry")
  eq(pit.card[1].entityID, nil)
  E.failSpawn = false
  pit:openBook()
  eq(pit.state, "spawning")
end)

test("spawn failure on second corner despawns the first", function()
  local pit, E = newPit()
  pit:newCard()
  local realSpawn = E.spawn
  local n = 0
  E.spawn = function(...) n = n + 1; if n == 2 then return nil end return realSpawn(...) end
  pit:openBook()
  eq(pit.state, "card")
  truthy(E.despawned["e1"], "first corner cleaned up")
end)

test("can't bet more than you have", function()
  local pit, E = newPit()
  E.money = 100
  toBetting(pit, E)
  truthy(not pit:placeBet(1, 500))
  truthy(not pit:placeBet(1, 0))
  eq(E.money, 100)
  eq(pit.bet, nil)
end)

test("call off during betting refunds", function()
  local pit, E = newPit()
  E.money = 1000
  local a = toBetting(pit, E)
  pit:placeBet(2, 300)
  pit:cancel("test")
  eq(E.money, 1000)
  eq(pit.state, "idle")
  truthy(E.despawned[a.id])
  truthy(pit.message:find("refunded"))
end)

test("no records -> empty card, drafting fills it", function()
  local pit, E = newPit()
  Roster.validate(function() return false end)
  pit:newCard()
  eq(pit.state, "card")
  eq(pit.card[1], nil)
  local npc1 = E:addNPC({ level = 20, name = "Street Vendor" })
  local npc2 = E:addNPC({ level = 35 })
  E.look = npc1
  pit:draft(1)
  eq(pit.card[1].name, "Street Vendor")
  eq(pit.card[1].base, 45)
  pit:draft(2) -- same NPC refused
  eq(pit.card[2], nil)
  E.look = npc2
  pit:draft(2)
  truthy(pit.card[2] and pit.card.mults, "odds after both drafted")
  pit:openBook()
  pit:update(0.1)
  eq(pit.state, "betting")
  eq(E.spawnCount, 0, "drafted fighters are not spawned")
  pit:ringBell()
  npc2.dead = true
  pit:update(0.3)
  pit:clearPit()
  truthy(not E.despawned[npc1.id], "drafted NPCs are never deleted")
  for key, mod in pairs(E.mods) do truthy(mod.removed, "drafted mods removed: " .. key) end
  eq(npc1.group, "gang", "drafted NPC attitude group restored")
  Roster.validate(allValid)
end)

test("draft needs an NPC in sight", function()
  local pit, E = newPit()
  pit:newCard()
  E.look = nil
  pit:draft(1)
  truthy(pit.message:find("Look at"))
end)

test("sabotage: needs look-at, RAM, applies effect once", function()
  local pit, E = newPit({ 0.99 }) -- rand() high: never caught
  local a, b = toBetting(pit, E)
  E.ramValue = 10
  E.look = nil
  truthy(not pit:sabotage(2, "shortcircuit"))
  E.look = b
  truthy(pit:sabotage(2, "shortcircuit"))
  eq(b.hp, 75)
  eq(E.ramValue, 7)
  truthy(not pit:sabotage(2, "shortcircuit"), "no repeat")
  E.ramValue = 1
  truthy(not pit:sabotage(2, "shred"), "not enough RAM")
  E.ramValue = 10
  truthy(pit:sabotage(2, "shred"))
  truthy(pit.card[2].shredMod)
  eq(pit.heat.acts, 2)
  eq(#pit.heat.log, 2)
end)

test("sabotage: malfunction disables best implant", function()
  local pit, E = newPit({ 0.99 })
  local a, b = toBetting(pit, E)
  local f = pit.card[2]
  f.implants = { "biomon", "sandy" }
  pit:applyImplants(f, b)
  E.ramValue, E.look = 10, b
  truthy(pit:sabotage(2, "malfunction"))
  truthy(f.disabled.sandy and not f.disabled.biomon)
  for _, m in ipairs(f.mods.sandy) do truthy(m.removed) end
  truthy(pit:sabotage(2, "malfunction") == false, "once per fighter")
end)

test("lookAt can be turned off", function()
  local pit, E = newPit({ 0.99 })
  toBetting(pit, E)
  pit.cfg.requireLookAt = false
  E.look, E.ramValue = nil, 10
  truthy(pit:sabotage(1, "shred"))
end)

test("caught: bet void, bookies spawn hostile, no payout", function()
  local pit, E = newPit({ 0.0 }) -- rand() always 0: always caught
  E.money = 2000
  local a, b = toBetting(pit, E)
  pit:placeBet(1, 1000)
  E.ramValue, E.look = 10, b
  pit:sabotage(2, "shortcircuit")
  truthy(pit.heat.caught)
  truthy(pit.bet.void)
  eq(pit.stats.timesCaught, 1)
  eq(pit.stats.lost, 1000)
  eq(#pit.bookies, 0, "muscle is delayed")
  truthy(pit.bookiesDue)
  pit:update(pit.cfg.bookieDelay - 1)
  eq(#pit.bookies, 0)
  pit:update(1.5)
  eq(#pit.bookies, Roster.venues[1].bookies.count)
  local bk1 = E.entities[pit.bookies[1].id]
  near(E.distance(bk1.pos, pit.arena.center), pit.cfg.bookieDistance, 0.01, "spawn distance")
  pit:update(0.1)
  for _, bk in ipairs(pit.bookies) do
    truthy(bk.hostile)
    eq(E.attitude[bk.id .. ">player"], "hostile")
  end
  pit:ringBell()
  b.dead = true
  pit:update(0.3)
  eq(pit.result.winner, 1)
  eq(E.money, 1000, "void bet pays nothing")
  eq(pit.stats.lost, 1000, "loss counted once")
  -- bookies are cleaned up after dying
  for _, bk in ipairs(pit.bookies) do E.entities[bk.id].dead = true end
  for _ = 1, 40 do pit:update(1) end
  eq(#pit.bookies, 0)
end)

test("caught with no bookie records -> fine instead", function()
  local pit, E = newPit({ 0.0 })
  E.money = 3000
  Roster.venues[1].bookies.valid = {}
  local a, b = toBetting(pit, E)
  pit:placeBet(1, 1000)
  E.ramValue, E.look = 10, b
  pit:sabotage(2, "shred")
  pit:update(pit.cfg.bookieDelay + 1)
  eq(#pit.bookies, 0)
  eq(E.money, 1000) -- 3000 - 1000 stake - 1000 fine
  Roster.validate(allValid)
end)

test("muscle still comes after the fight is cleared", function()
  local pit, E = newPit({ 0.0 })
  local a, b = toBetting(pit, E)
  E.ramValue, E.look = 10, b
  pit:sabotage(2, "shred")
  pit:cancel("walked off")
  eq(pit.state, "idle")
  pit:update(pit.cfg.bookieDelay + 1)
  eq(#pit.bookies, Roster.venues[1].bookies.count)
end)

test("player death ends the night and clears bookies", function()
  local pit, E = newPit({ 0.0 })
  E.money = 1000
  local a, b = toBetting(pit, E)
  pit:placeBet(1, 400)
  E.ramValue, E.look = 10, b
  pit:sabotage(2, "shred")
  pit:update(pit.cfg.bookieDelay + 1)
  local ids = {}
  for _, bk in ipairs(pit.bookies) do table.insert(ids, bk.id) end
  truthy(#ids > 0)
  E.dead = true
  pit:update(0.1)
  eq(pit.state, "idle")
  eq(#pit.bookies, 0)
  for _, id in ipairs(ids) do truthy(E.despawned[id], "bookie despawned") end
  truthy(E.despawned[a.id], "fighters despawned")
  eq(E.money, 600, "void bet not refunded")
end)

test("player death mid-fight refunds a live bet", function()
  local pit, E = newPit({ 0.99 })
  E.money = 1000
  toBetting(pit, E)
  pit:placeBet(2, 300)
  pit:ringBell()
  E.dead = true
  pit:update(0.3)
  eq(pit.state, "idle")
  eq(E.money, 1000)
end)

test("player hits register as interference, throttled", function()
  local pit, E = newPit({ 0.99 })
  local a, b = toBetting(pit, E)
  eq(pit:sideOf(b), 2)
  pit:onPlayerHit(2, 10)
  pit:onPlayerHit(2, 11)
  eq(pit.heat.acts, 1)
  pit:onPlayerHit(2, 14)
  eq(pit.heat.acts, 2)
  pit.state = "idle"
  pit:onPlayerHit(2, 30)
  eq(pit.heat.acts, 2)
end)

test("player gone (main menu) resets", function()
  local pit, E = newPit()
  toBetting(pit, E)
  E.noPlayer = true
  pit:update(0.1)
  eq(pit.state, "idle")
  eq(next(E.despawned), nil, "no entity touched after the world is gone")
end)

test("shutdown despawns everything", function()
  local pit, E = newPit({ 0.0 })
  local a, b = toBetting(pit, E)
  E.ramValue, E.look = 10, b
  pit:sabotage(2, "shred")
  pit:shutdown()
  truthy(E.despawnedAll)
  truthy(E.despawned[a.id])
  eq(#pit.bookies, 0)
end)

test("1000 random fight nights keep the books balanced", function()
  math.randomseed(7)
  for _ = 1, 1000 do
    local pit, E = newPit(nil)
    pit.rand = math.random
    pit.venueIndex = math.random(1, #Roster.venues)
    E.money = 10000
    local start = E.money
    local a, b = toBetting(pit, E)
    local stake = math.random(1, 3000)
    local side = math.random(1, 2)
    pit:placeBet(side, stake)
    E.ramValue = 20
    if math.random() < 0.5 then E.look = (math.random() < 0.5) and a or b; pit:sabotage(E.look == a and 1 or 2, Roster.sabotage[math.random(1, 3)].id) end
    pit:ringBell()
    local r = math.random()
    if r < 0.4 then a.dead = true elseif r < 0.8 then b.dead = true elseif r < 0.85 then a.dead, b.dead = true, true end
    for _ = 1, 600 do pit:update(0.5) if pit.state ~= "fighting" then break end end
    truthy(pit.state == "result", "fight must end")
    -- money change must match stats
    local net = E.money - start
    local fine = E.fined or 0
    eq(net + fine, pit.stats.won - pit.stats.lost, "ledger mismatch")
  end
end)

-- UI against a fake ImGui -----------------------------------------------------
local FakeImGui = require("fake_imgui")
test("every UI screen renders", function()
  FakeImGui.install()
  local UI = fresh("ui")
  local pit, E = newPit({ 0.99 })
  local mod = { pit = pit, report = Roster.validate(allValid), codeware = false, save = function() end }
  local Engine = require("engine")
  local function both() FakeImGui.reset(); UI.window(mod); FakeImGui.check(); UI.hud(mod); FakeImGui.check() end
  FakeImGui.openHeaders = true
  both()
  pit:newCard(); both()
  pit:openBook(); both()
  pit:update(0.1); both()
  pit:placeBet(1, 100); both()
  pit.heat.caught = true; pit.bet.void = true; both()
  pit:ringBell(); both()
  E.entities[pit.card[2].entityID].dead = true; pit:update(0.3); both()
  pit.message = ""; both()
  -- empty card
  pit:clearPit(); Roster.validate(function() return false end); pit:newCard(); both()
  Roster.validate(allValid)
  eq(UI.eddies(1234567), "1,234,567 ed")
  eq(UI.eddies(100), "100 ed")
  eq(UI.eddies(0), "0 ed")
  truthy(FakeImGui.calls > 50, "UI drew things")
  FakeImGui.uninstall()
end)

test("UI buttons drive the pit", function()
  FakeImGui.install()
  local UI = fresh("ui")
  local pit, E = newPit()
  E.money = 5000
  local mod = { pit = pit, report = {}, codeware = true, save = function() end }
  local function click(label) FakeImGui.reset(); FakeImGui.press = label; UI.window(mod); FakeImGui.check() end
  click("Get tonight's card"); eq(pit.state, "card")
  click("Open the book"); eq(pit.state, "spawning")
  pit:update(0.1)
  click("Bet RED: " .. pit.card[1].name .. "##bet1"); truthy(pit.bet and pit.bet.side == 1)
  click("Ring the bell now"); eq(pit.state, "fighting")
  click("Abandon fight"); eq(pit.state, "idle")
  eq(E.money, 5000)
  FakeImGui.uninstall()
end)

-- init.lua against fake CET globals -------------------------------------------
test("init.lua wires events and saves stats", function()
  local cet = require("fake_cet")
  cet.install()
  FakeImGui.install()
  fresh("engine"); fresh("ui"); fresh("pit"); fresh("roster")
  local mod = assert(loadfile("PitBets/init.lua"))()
  truthy(cet.events.onInit and cet.events.onUpdate and cet.events.onDraw and cet.events.onShutdown)
  truthy(cet.hotkeys.pitbets_toggle and cet.hotkeys.pitbets_bell)
  cet.events.onInit()
  truthy(mod.pit, "pit created")
  truthy(cet.observed["ScriptedPuppet.OnHit"], "OnHit observed")
  cet.events.onUpdate(0.016)
  cet.events.onOverlayOpen()
  FakeImGui.reset(); cet.events.onDraw(); FakeImGui.check()
  cet.events.onOverlayClose()
  FakeImGui.reset(); cet.events.onDraw(); FakeImGui.check()
  -- the OnHit hook with a non-fighter does nothing
  cet.observed["ScriptedPuppet.OnHit"]({}, {})
  mod.pit.stats.fights = 9
  mod.save()
  local saved = cet.files["stats.json"]
  truthy(saved and saved:find("fights"), "stats written")
  -- reload picks them up
  local mod2 = assert(loadfile("PitBets/init.lua"))()
  cet.events.onInit()
  eq(mod2.pit.stats.fights, 9)
  cet.events.onShutdown()
  cet.uninstall()
  FakeImGui.uninstall()
end)

-- engine.lua against a fake game API -----------------------------------------
test("engine calls the game API it means to", function()
  local G = require("fake_game")
  G.install()
  local Engine = fresh("engine")
  truthy(Engine.hasCodeware())
  truthy(Engine.recordExists("Character.good"))
  truthy(not Engine.recordExists("Character.bad"))
  eq(Engine.getMoney(), 777)
  truthy(Engine.takeMoney(7)); eq(G.money, 770)
  truthy(Engine.giveMoney(30)); eq(G.money, 800)
  local pts = Engine.arenaPoints(8, 3)
  near(pts.center.y, 8); near(pts.red.x, -3); near(pts.blue.x, 3)
  local id = Engine.spawn("Character.good", pts.red, pts.blue)
  truthy(id, "spawned")
  local spec = G.lastSpec
  eq(spec.recordID.str, "Character.good")
  eq(spec.alwaysSpawned, true)
  -- facing +x from red corner: yaw -90deg
  near(spec.orientation.k, math.sin(-math.pi / 4), 1e-6)
  near(spec.orientation.r, math.cos(-math.pi / 4), 1e-6)
  local ent = Engine.getEntity(id)
  truthy(ent)
  near(Engine.healthPct(ent), 100)
  Engine.damagePct(ent, 25); near(Engine.healthPct(ent), 75)
  truthy(not Engine.isDown(ent))
  ent.dead = true; truthy(Engine.isDown(ent))
  local mod = Engine.addStatMod(ent, "Health", "Multiplier", 1.2)
  truthy(mod and mod.stat == "Health" and mod.kind == "Multiplier")
  Engine.removeStatMod(ent, mod); truthy(G.removedMods[mod])
  local other = Engine.getEntity(Engine.spawn("Character.good", pts.blue, pts.red))
  Engine.setAttitude(ent, other, "hostile")
  eq(ent.attitudes[other], G.EAIAttitude.AIA_Hostile)
  Engine.provoke(ent, other); eq(ent.threat, other)
  truthy(Engine.sameEntity(ent, Engine.getEntity(id)))
  truthy(not Engine.sameEntity(ent, other))
  eq(Engine.ram(), 8); Engine.spendRam(3); eq(Engine.ram(), 5)
  Engine.despawn(id); truthy(G.deleted[id])
  Engine.despawnAll(); eq(G.deletedTag, "PitBets")
  -- a broken API must not throw
  G.breakEverything()
  eq(Engine.getMoney(), 0)
  eq(Engine.spawn("Character.good", pts.red, pts.blue), nil)
  truthy(not Engine.isDown(ent) or true)
  G.uninstall()
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
