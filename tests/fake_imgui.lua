-- Minimal ImGui stand-in: checks argument types and Begin/End balance, and
-- can "press" one button by label.
local M = { calls = 0, press = nil, openHeaders = true }

local depth, comboDepth = 0, 0
local saved = {}

local function str(v, name) assert(type(v) == "string", name .. " needs a string, got " .. type(v)) end
local function num(v, name) assert(type(v) == "number", name .. " needs a number, got " .. type(v)) end
local function count() M.calls = M.calls + 1 end

local ImGui = {
  Begin = function(name, flags) count(); str(name, "Begin"); depth = depth + 1; return true end,
  End = function() count(); depth = depth - 1 end,
  Text = function(s) count(); str(s, "Text") end,
  TextWrapped = function(s) count(); str(s, "TextWrapped") end,
  TextColored = function(r, g, b, a, s) count(); num(r, "TextColored"); num(a, "TextColored"); str(s, "TextColored") end,
  Separator = count, Spacing = count, SameLine = count, EndCombo = function() count(); comboDepth = comboDepth - 1 end,
  Button = function(label, w, h) count(); str(label, "Button"); return label == M.press end,
  Selectable = function(label, sel) count(); str(label, "Selectable"); assert(type(sel) == "boolean"); return false end,
  BeginCombo = function(label, preview) count(); str(label, "BeginCombo"); str(preview, "BeginCombo"); comboDepth = comboDepth + 1; return true end,
  CollapsingHeader = function(label) count(); str(label, "CollapsingHeader"); return M.openHeaders end,
  ProgressBar = function(f, w, h, overlay)
    count(); num(f, "ProgressBar"); assert(f >= 0 and f <= 1, "ProgressBar fraction out of range"); str(overlay, "ProgressBar")
  end,
  InputInt = function(label, v, a, b) count(); str(label, "InputInt"); num(v, "InputInt"); return v, false end,
  SliderInt = function(label, v, lo, hi) count(); str(label, "SliderInt"); num(v, "SliderInt"); return v, false end,
  Checkbox = function(label, v) count(); str(label, "Checkbox"); assert(type(v) == "boolean"); return v, false end,
  IsItemHovered = function() return true end,
  SetTooltip = function(s) str(s, "SetTooltip") end,
  SetNextWindowPos = function(x, y, c) num(x, "SetNextWindowPos"); num(y, "SetNextWindowPos") end,
  SetNextWindowSize = function(w, h, c) num(w, "SetNextWindowSize") end,
  SetNextWindowBgAlpha = function(a) num(a, "SetNextWindowBgAlpha") end,
}

function M.reset() depth, comboDepth = 0, 0 end
function M.check()
  assert(depth == 0, "Begin/End unbalanced: " .. depth)
  assert(comboDepth == 0, "BeginCombo/EndCombo unbalanced")
end

local GLOBALS = {
  ImGui = ImGui,
  ImGuiCond = { Always = 1, FirstUseEver = 4 },
  ImGuiWindowFlags = { NoTitleBar = 1, NoInputs = 512, AlwaysAutoResize = 64, NoMove = 4, NoSavedSettings = 256 },
  GetDisplayResolution = function() return 1920, 1080 end,
}

function M.install()
  for k, v in pairs(GLOBALS) do saved[k] = rawget(_G, k); _G[k] = v end
end
function M.uninstall()
  for k in pairs(GLOBALS) do _G[k] = saved[k] end
end

return M
