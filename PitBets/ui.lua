-- ImGui window (overlay open) and a small fight HUD (overlay closed).
local Engine = require("engine")
local Roster = require("roster")

local UI = {}

local RED = { 1.0, 0.35, 0.35, 1 }
local BLUE = { 0.35, 0.65, 1.0, 1 }
local GOLD = { 1.0, 0.85, 0.3, 1 }
local DIM = { 0.65, 0.65, 0.65, 1 }
local CORNER = { RED, BLUE }
local CORNER_NAME = { "RED", "BLUE" }

local function colored(c, text) ImGui.TextColored(c[1], c[2], c[3], c[4], text) end

local function eddies(n)
  local s = tostring(math.floor(n or 0))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", "")) .. " ed"
end

local function tooltip(text)
  if ImGui.IsItemHovered() then ImGui.SetTooltip(text) end
end

local function fighterBlock(pit, i)
  local f = pit.card[i]
  colored(CORNER[i], CORNER_NAME[i] .. " CORNER")
  if not f then
    colored(DIM, "  (empty)")
    return
  end
  ImGui.Text("  " .. f.name .. "  -  " .. f.label)
  colored(DIM, "  Chrome: " .. Roster.implantNames(f))
  local line = "  Rating " .. f.rating
  if pit.card.probs then
    line = line .. string.format("   |   %d%% to win   |   pays %.2fx", math.floor(pit.card.probs[i] * 100 + 0.5), pit.card.mults[i])
  end
  ImGui.Text(line)
  if f.entity then
    local hp = Engine.healthPct(f.entity)
    if hp then ImGui.ProgressBar(math.max(0, math.min(1, hp / 100)), 320, 0, string.format("%d%% HP", math.floor(hp))) end
  end
end

local function venueCombo(pit)
  local v = pit:venue()
  if ImGui.BeginCombo("Venue", v.name) then
    for i, venue in ipairs(Roster.venues) do
      if ImGui.Selectable(venue.name, i == pit.venueIndex) then pit.venueIndex = i end
    end
    ImGui.EndCombo()
  end
  colored(DIM, v.blurb)
  colored(DIM, string.format("Base chance bookies spot a hack: %d%%", math.floor(v.detect * 100)))
end

local function drawIdle(mod, pit)
  venueCombo(pit)
  ImGui.Spacing()
  if ImGui.Button("Get tonight's card", 220, 0) then pit:newCard() end
  tooltip("Stand somewhere open: fighters spawn about 8 m in front of you.")
end

local function drawCard(mod, pit)
  venueCombo(pit)
  ImGui.Separator()
  for i = 1, 2 do
    fighterBlock(pit, i)
    if ImGui.Button("Draft looked-at NPC##" .. i) then pit:draft(i) end
    tooltip("Aim at any NPC before opening the overlay, then press this to put them in the " .. CORNER_NAME[i] .. " corner.")
    ImGui.Spacing()
  end
  ImGui.Separator()
  if ImGui.Button("Reroll card", 140, 0) then pit:newCard() end
  ImGui.SameLine()
  if pit.card and pit.card[1] and pit.card[2] then
    if ImGui.Button("Open the book", 140, 0) then pit:openBook() end
    tooltip("Spawn the fighters. Odds are locked from here on.")
  end
  ImGui.SameLine()
  if ImGui.Button("Cancel", 100, 0) then pit:clearPit() end
end

local function drawSabotage(pit)
  if not ImGui.CollapsingHeader("Sabotage (quickhacks)") then return end
  colored(DIM, string.format("RAM: %d   |   Acts so far: %d   |   Next base risk: %d%%",
    math.floor(Engine.ram()), pit.heat.acts,
    math.floor(math.min(0.9, pit:venue().detect + 0.12 * pit.heat.acts) * 100)))
  if pit.cfg.requireLookAt then colored(DIM, "Look at the fighter you want to hack before opening the overlay.") end
  if pit.heat.caught then colored(RED, "You've been made. The bookies want a word.") end
  for i = 1, 2 do
    local f = pit.card[i]
    colored(CORNER[i], f.name .. ":")
    for _, s in ipairs(Roster.sabotage) do
      ImGui.SameLine()
      local done = f.sabotaged and f.sabotaged[s.id]
      if ImGui.Button((done and "[x] " or "") .. s.name .. " (" .. s.ram .. ")##" .. i .. s.id) then pit:sabotage(i, s.id) end
      tooltip(s.desc .. "  Costs " .. s.ram .. " RAM.")
    end
  end
  for _, line in ipairs(pit.heat.log) do colored(DIM, "  - " .. line) end
end

local function drawBetting(mod, pit)
  colored(GOLD, string.format("Book open - bell in %ds", math.max(0, math.ceil(pit.timer))))
  ImGui.Separator()
  for i = 1, 2 do fighterBlock(pit, i); ImGui.Spacing() end
  ImGui.Separator()
  ImGui.Text("Your eddies: " .. eddies(Engine.getMoney()))
  if pit.bet then
    local f = pit.card[pit.bet.side]
    if pit.bet.void then
      colored(RED, "Bet void - confiscated by the bookies.")
    else
      colored(GOLD, string.format("Bet: %s on %s at %.2fx (pays %s)", eddies(pit.bet.stake), f.name, pit.bet.mult,
        eddies(math.floor(pit.bet.stake * pit.bet.mult))))
    end
  else
    local v, changed = ImGui.InputInt("Stake", pit.stake, 100, 1000)
    if changed then pit.stake = math.max(0, v) end
    for i = 1, 2 do
      if i == 2 then ImGui.SameLine() end
      if ImGui.Button("Bet " .. CORNER_NAME[i] .. ": " .. pit.card[i].name .. "##bet" .. i, 220, 0) then
        pit:placeBet(i, pit.stake)
        mod.save()
      end
    end
  end
  ImGui.Spacing()
  if ImGui.Button("Ring the bell now", 180, 0) then pit:ringBell() end
  ImGui.SameLine()
  if ImGui.Button("Call it off (refund)", 180, 0) then pit:cancel("you walked away."); return end
  ImGui.Spacing()
  drawSabotage(pit)
end

local function drawFighting(mod, pit)
  colored(GOLD, string.format("FIGHT!  %ds  (decision at %ds)", math.floor(pit.elapsed), pit.cfg.fightTimeout))
  ImGui.Separator()
  for i = 1, 2 do fighterBlock(pit, i); ImGui.Spacing() end
  if pit.bet and not pit.bet.void then
    colored(GOLD, string.format("Riding %s on %s", eddies(pit.bet.stake), pit.card[pit.bet.side].name))
  elseif pit.bet then
    colored(RED, "Bet void.")
  end
  if ImGui.Button("Abandon fight", 160, 0) then pit:cancel("abandoned mid-fight."); return end
  tooltip("Refunds a live bet and despawns the fighters.")
  drawSabotage(pit)
end

local function drawResult(mod, pit)
  colored(GOLD, pit.result and pit.result.text or "")
  ImGui.Separator()
  for i = 1, 2 do fighterBlock(pit, i) end
  colored(DIM, string.format("Clearing the pit in %ds", math.max(0, math.ceil(pit.timer))))
  if ImGui.Button("Clear now / next fight", 200, 0) then pit:clearPit() end
end

local function drawStats(mod, pit)
  if not ImGui.CollapsingHeader("Stats") then return end
  local s = pit.stats
  ImGui.Text("Fights: " .. s.fights .. "   Wagered: " .. eddies(s.wagered))
  ImGui.Text("Won: " .. eddies(s.won) .. "   Lost: " .. eddies(s.lost) .. "   Net: " .. eddies(s.won - s.lost))
  ImGui.Text("Biggest win: " .. eddies(s.biggestWin) .. "   Times caught: " .. s.timesCaught)
end

local function drawSettings(mod, pit)
  if not ImGui.CollapsingHeader("Settings") then return end
  local c = pit.cfg
  local v, ch
  v, ch = ImGui.SliderInt("Betting time (s)", c.bettingTime, 10, 180); if ch then c.bettingTime = v end
  v, ch = ImGui.SliderInt("Fight timeout (s)", c.fightTimeout, 30, 300); if ch then c.fightTimeout = v end
  v, ch = ImGui.SliderInt("Ring distance (m)", c.arenaDistance, 4, 20); if ch then c.arenaDistance = v end
  v, ch = ImGui.SliderInt("Corner spread (m)", c.arenaSpread, 2, 8); if ch then c.arenaSpread = v end
  v, ch = ImGui.Checkbox("Must look at target to hack", c.requireLookAt); if ch then c.requireLookAt = v end
end

local function drawRecords(mod)
  if not ImGui.CollapsingHeader("Record check") then return end
  if not mod.codeware then colored(RED, "Codeware not found: spawning is disabled. Drafting still works.") end
  colored(DIM, "Records that don't exist in your game are skipped. Edit roster.lua to add your own.")
  for _, r in ipairs(mod.report) do
    colored(r.ok and { 0.4, 1, 0.4, 1 } or RED, string.format("%s %-8s %-8s %s", r.ok and "OK " or "BAD", r.venue, r.class, r.id))
  end
end

function UI.window(mod)
  local pit = mod.pit
  ImGui.SetNextWindowSize(560, 0, ImGuiCond.FirstUseEver)
  if ImGui.Begin("Pit Bets", ImGuiWindowFlags.AlwaysAutoResize) then
    if pit.state == "idle" then drawIdle(mod, pit)
    elseif pit.state == "card" then drawCard(mod, pit)
    elseif pit.state == "spawning" then colored(GOLD, "Fighters are walking out...")
    elseif pit.state == "betting" then drawBetting(mod, pit)
    elseif pit.state == "fighting" then drawFighting(mod, pit)
    elseif pit.state == "result" then drawResult(mod, pit)
    end
    if pit.message ~= "" then
      ImGui.Separator()
      ImGui.TextWrapped(pit.message)
    end
    ImGui.Separator()
    drawStats(mod, pit)
    drawSettings(mod, pit)
    drawRecords(mod)
  end
  ImGui.End()
end

-- Always-on HUD during a fight night (no input, no title bar).
function UI.hud(mod)
  local pit = mod.pit
  if pit.state ~= "betting" and pit.state ~= "fighting" and pit.state ~= "result" then return end
  local w = GetDisplayResolution()
  ImGui.SetNextWindowPos(w / 2 - 180, 40, ImGuiCond.Always)
  ImGui.SetNextWindowBgAlpha(0.55)
  local flags = ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoInputs + ImGuiWindowFlags.AlwaysAutoResize
    + ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoSavedSettings
  if ImGui.Begin("PitBetsHUD", flags) then
    if pit.state == "betting" then
      colored(GOLD, string.format("PIT BETS - bell in %ds", math.max(0, math.ceil(pit.timer))))
    elseif pit.state == "fighting" then
      colored(GOLD, string.format("PIT BETS - round time %ds", math.floor(pit.elapsed)))
    else
      colored(GOLD, pit.result and pit.result.text or "")
    end
    for i = 1, 2 do
      local f = pit.card[i]
      local hp = f.entity and Engine.healthPct(f.entity)
      colored(CORNER[i], f.name)
      if hp then ImGui.ProgressBar(math.max(0, math.min(1, hp / 100)), 360, 0, string.format("%d%%", math.floor(hp))) end
    end
    if pit.bet then
      if pit.bet.void then colored(RED, "Bet void - run!")
      else colored(DIM, string.format("Your bet: %s on %s (%.2fx)", eddies(pit.bet.stake), pit.card[pit.bet.side].name, pit.bet.mult)) end
    end
  end
  ImGui.End()
end

UI.eddies = eddies
return UI
