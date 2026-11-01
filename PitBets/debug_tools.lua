-- Developer helper: writes every character record ID the game knows to
-- records_dump.txt in the mod folder. Triggered by the "Dump character
-- records" hotkey; used to pick valid fighter records for roster.lua.
local Debug = {}

local function idName(id)
  local ok, v = pcall(function() return id.value end)
  if ok and type(v) == "string" and v ~= "" then return v end
  local s = tostring(id)
  return s:match("%-%-%[%[%s*(.-)%s*%]%]") or s
end

function Debug.dumpRecords(path)
  path = path or "records_dump.txt"
  local ok, records = pcall(function() return TweakDB:GetRecords("gamedataCharacter_Record") end)
  if not ok or not records then print("[PitBets] dump: GetRecords failed: " .. tostring(records)); return 0 end
  local names = {}
  for _, r in ipairs(records) do
    local n = idName(r:GetID())
    if n then table.insert(names, n) end
  end
  table.sort(names)
  local f = io.open(path, "w")
  if not f then print("[PitBets] dump: cannot write " .. path); return 0 end
  f:write(table.concat(names, "\n"))
  f:close()
  print("[PitBets] dumped " .. #names .. " character records to " .. path)
  return #names
end

-- Logs every hit V takes: attacker record, whether it's one of ours, V's HP.
function Debug.watchPlayerHits(mod)
  Observe("PlayerPuppet", "OnHit", function(self, evt)
    pcall(function()
      local inst = evt.attackData:GetInstigator()
      local rec = inst and idName(inst:GetRecordID()) or "?"
      local role = "other"
      local pit = mod.pit
      if pit and inst then
        if pit:sideOf(inst) then role = "fighter " .. pit:sideOf(inst) end
        for _, b in ipairs(pit.bookies) do
          local e = Game.FindEntityByID(b.id)
          if e and e:GetEntityID().hash == inst:GetEntityID().hash then role = "bookie" end
        end
      end
      local hp = Game.GetStatPoolsSystem():GetStatPoolValue(self:GetEntityID(), gamedataStatPoolType.Health, false)
      print(string.format("[PitBets] V hit by %s (%s), V hp=%.0f", rec, role, hp or -1))
    end)
  end)
end

return Debug
