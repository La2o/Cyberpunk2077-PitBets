-- Fighter, cyberware and venue data. Pure Lua: no game calls.
--
-- Record IDs: each fighter template lists several candidate TweakDB character
-- records. At load the mod keeps only the ones that exist in your game, so a
-- wrong guess just gets skipped. Add your own (find IDs with AMM or the
-- WolvenKit Tweak Browser). If none are valid you can still draft fighters
-- from the crowd in-game.
local Roster = {}

-- hp = max-health multiplier, armor = flat armor. These are applied to the NPC
-- for real, so the cyberware changes the fight as well as the odds.
Roster.cyberware = {
  subdermal  = { name = "Subdermal Armor",          rating = 12, armor = 150 },
  gorilla    = { name = "Gorilla Arms",             rating = 14, hp = 1.10, armor = 40 },
  mantis     = { name = "Mantis Blades",            rating = 16, hp = 1.05 },
  sandy      = { name = "Sandevistan",              rating = 20, hp = 1.15 },
  kerenzikov = { name = "Kerenzikov",               rating = 12, hp = 1.10 },
  paineditor = { name = "Pain Editor",              rating = 15, hp = 1.25 },
  biomon     = { name = "Biomonitor",               rating = 10, hp = 1.15 },
  lungs      = { name = "Bionic Lungs",             rating = 7,  hp = 1.08 },
  tendons    = { name = "Reinforced Tendons",       rating = 5,  hp = 1.03 },
  plating    = { name = "Militech Chassis Plating", rating = 45, hp = 1.50, armor = 600 },
  servos     = { name = "Overclocked Servos",       rating = 25, hp = 1.20 },
}

Roster.classes = {
  boxer   = { label = "Boxer",           base = 40,  slots = { 0, 1 }, pool = { "lungs", "tendons", "biomon", "paineditor" } },
  brawler = { label = "Chromed Brawler", base = 55,  slots = { 1, 3 }, pool = { "subdermal", "gorilla", "mantis", "sandy", "kerenzikov", "paineditor", "biomon" } },
  mech    = { label = "Mech",            base = 110, slots = { 0, 1 }, pool = { "servos" }, fixed = { "plating" } },
  local_  = { label = "Local Talent",    base = 30,  slots = { 0, 2 }, pool = { "subdermal", "gorilla", "biomon", "lungs", "kerenzikov" } },
}

Roster.sabotage = {
  { id = "shortcircuit", name = "Short Circuit",         ram = 3, heat = 0.00, desc = "Fry them before the bell: -25% health." },
  { id = "malfunction",  name = "Cyberware Malfunction", ram = 4, heat = 0.05, desc = "Knock their best implant offline." },
  { id = "shred",        name = "Armor Shred",           ram = 2, heat = 0.00, desc = "Halve their armor." },
}

Roster.venues = {
  {
    id = "pacifica",
    name = "Pacifica - Grand Imperial pit",
    blurb = "Animals run this book. Get caught and they settle it with fists.",
    detect = 0.30,
    handles = { "Tin Can Tomas", "Haitian Hurricane", "Big Ollie", "Mama Brick", "Rust Saint", "Low Tide",
                "Concrete Dee", "Boardwalk Benny", "Hollow Point Hal", "Senora Steel" },
    templates = {
      { class = "boxer",   records = { "Character.animals_grunt1_melee1_fists_mb", "Character.animals_bouncer1_melee1_fists_mb",
                                       "Character.animals_bouncer2_melee2_fists_mb" } },
      { class = "brawler", records = { "Character.animals_bouncer2_hmelee2_fists_mba_rare", "Character.animals_elite2_hmelee2_fists_mba_rare",
                                       "Character.animals_bouncer3_hmelee3_fists_mba_elite", "Character.animals_elite3_hmelee3_fists_mba_elite",
                                       "Character.animals_grunt2_hmelee2_fists_wba_rare", "Character.voodooboys_grunt1_fmelee2rare_baseball_ma_rare" } },
      -- Mechs only exist as quest records; experimental.
      { class = "mech",    records = { "Character.q114_militech_drop_mech", "Character.q003_militech_mech" } },
    },
    bookies = { count = 3, records = { "Character.animals_grunt1_melee1_baseball_mb", "Character.animals_grunt2_melee2_hammer_mb",
                                       "Character.animals_bouncer1_melee1_baton_mb" } },
  },
  {
    id = "kabuki",
    name = "Kabuki - backstreet ring",
    blurb = "Tyger Claws hold the book. Quieter than Pacifica, but they bring knives.",
    detect = 0.20,
    handles = { "Neon Kenji", "Twelve-Cut Mei", "Paper Lantern", "Iron Sato", "Kabuki Kid", "Static Hana",
                "Noodle Shop Nobu", "Chrome Crane", "Midnight Rin", "Lucky Goro" },
    templates = {
      { class = "boxer",   records = { "Character.tyger_claws_gangster1_melee1_fists_ma", "Character.tyger_claws_gangster1_melee1_fists_wa",
                                       "Character.tyger_claws_biker1_melee1_fists_ma", "Character.tyger_claws_biker1_melee1_fists_wa",
                                       "Character.tyger_claws_gangster2_melee2_fists_ma" } },
      { class = "brawler", records = { "Character.tyger_claws_martial_fmelee2_fists_ma_rare", "Character.tyger_claws_kunoichi_fmelee3_fists_ma_elite",
                                       "Character.tyger_claws_martial_hmelee2_StrongArms_ma", "Character.tyger_claws_martial_hmelee3_StrongArms_mb",
                                       "Character.maelstrom_fast_fmelee3_mantis_wa_elite" } },
      { class = "mech",    records = { "Character.q114_militech_drop_mech", "Character.q003_militech_mech" } },
    },
    -- Grunt tier on purpose: getting caught should hurt, not be an instant flatline.
    bookies = { count = 3, records = { "Character.tyger_claws_gangster1_melee1_knife_ma", "Character.tyger_claws_biker1_melee1_baseball_ma",
                                       "Character.tyger_claws_biker1_melee1_tireiron_ma" } },
  },
}

-- Keep only records the game knows. exists(id) -> bool. Returns a report table.
function Roster.validate(exists)
  local report = {}
  for _, venue in ipairs(Roster.venues) do
    for _, t in ipairs(venue.templates) do
      t.valid = {}
      for _, id in ipairs(t.records) do
        local ok = exists(id)
        if ok then table.insert(t.valid, id) end
        table.insert(report, { venue = venue.id, class = t.class, id = id, ok = ok })
      end
    end
    venue.bookies.valid = {}
    for _, id in ipairs(venue.bookies.records) do
      local ok = exists(id)
      if ok then table.insert(venue.bookies.valid, id) end
      table.insert(report, { venue = venue.id, class = "bookie", id = id, ok = ok })
    end
  end
  return report
end

local function pick(list, rand)
  if not list or #list == 0 then return nil end
  return list[rand(1, #list)]
end

-- Choose n distinct implants from a pool.
local function rollImplants(class, rand)
  local out, used = {}, {}
  for _, key in ipairs(class.fixed or {}) do
    table.insert(out, key); used[key] = true
  end
  local n = rand(class.slots[1], class.slots[2])
  local guard = 0
  while n > 0 and guard < 50 do
    guard = guard + 1
    local key = pick(class.pool, rand)
    if key and not used[key] then
      table.insert(out, key); used[key] = true; n = n - 1
    end
  end
  return out
end

function Roster.rating(f)
  local r = f.base
  for _, key in ipairs(f.implants) do r = r + Roster.cyberware[key].rating end
  return math.floor(r * f.form + 0.5)
end

-- Build a fighter from a class. record may be nil (drafted from the crowd).
function Roster.makeFighter(classKey, record, name, rand, baseOverride)
  local class = Roster.classes[classKey]
  local f = {
    name = name or "Unknown",
    class = classKey,
    label = class.label,
    record = record,
    base = baseOverride or class.base,
    implants = rollImplants(class, rand),
    form = 0.9 + rand(0, 20) / 100, -- 0.90..1.10, "form on the night"
  }
  f.rating = Roster.rating(f)
  return f
end

-- Roll a fighter for a venue from templates with at least one valid record.
-- avoidName stops both corners getting the same handle.
function Roster.rollFighter(venue, rand, avoidName)
  local usable = {}
  for _, t in ipairs(venue.templates) do
    if t.valid and #t.valid > 0 then table.insert(usable, t) end
  end
  if #usable == 0 then return nil end
  local t = pick(usable, rand)
  local name = pick(venue.handles, rand)
  local guard = 0
  while name == avoidName and guard < 20 do name = pick(venue.handles, rand); guard = guard + 1 end
  return Roster.makeFighter(t.class, pick(t.valid, rand), name, rand)
end

function Roster.implantNames(f)
  local names = {}
  for _, key in ipairs(f.implants) do
    local cw = Roster.cyberware[key]
    table.insert(names, f.disabled and f.disabled[key] and (cw.name .. " (offline)") or cw.name)
  end
  if #names == 0 then return "no chrome" end
  return table.concat(names, ", ")
end

return Roster
