-- What the player has changed by voice. Pure Lua, so tests can run it anywhere.
-- The server only suggests changes from a closed list, and this file applies its limits.
local battle = require("battle")
local fx = require("fx")
local M = {}

M.THEMES = {
  night = {{0.12, 0.1, 0.3}, {0.35, 0.2, 0.4}}, lava = {{0.25, 0.04, 0.03}, {0.85, 0.3, 0.05}},
  ocean = {{0.02, 0.15, 0.35}, {0.05, 0.5, 0.6}}, forest = {{0.03, 0.2, 0.1}, {0.25, 0.45, 0.15}},
  candy = {{0.7, 0.25, 0.5}, {0.3, 0.45, 0.7}}, space = {{0.01, 0.01, 0.05}, {0.1, 0.05, 0.2}},
  spooky = {{0.04, 0.02, 0.08}, {0.2, 0.3, 0.15}}, desert = {{0.55, 0.28, 0.12}, {0.7, 0.5, 0.25}},
  snow = {{0.25, 0.4, 0.6}, {0.5, 0.6, 0.72}},
}
M.MUSIC = {slow = 0.2, normal = 0.14, fast = 0.09, off = false}
local POWER = {0.6, 0.8, 1, 1.3, 1.7}
local MAX_UNDO = 10

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

function M.defaults()
  return {theme = "night", music = "normal", foePower = 3, myPower = 3, catchEase = 3, foeLevel = 0, effects = 3}
end

function M.power(rank)
  return POWER[clamp(rank or 3, 1, 5)]
end

-- How much easier (or harder) catching is at this setting.
function M.catchBonus(rules)
  return ((rules and rules.catchEase or 3) - 3) * 0.1
end

-- Splits the server's level message into changes and an optional creature packet.
function M.parse(level)
  local text, packet = level, nil
  local at = level:find("\ncreature\n", 1, true)
  if at then text, packet = level:sub(1, at), level:sub(at + 10) end
  local changes = {packet = packet}
  for line in text:gmatch("[^\n]+") do
    local key, value = line:match("^(%w+)=(.*)$")
    if key then changes[key] = value end
  end
  return changes
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end

local function snapshot(rules, lead)
  return {rules = copy(rules), lead = lead and {name = lead.name, type = lead.type, moves = copy(lead.moves)}, leadRef = lead}
end

local function validType(name)
  for _, type in ipairs(battle.TYPES) do
    if type == name then return true end
  end
  return false
end

-- Records a creature's old art so "undo that" can bring it back.
function M.rememberArt(rules, history, creature, png)
  history[#history + 1] = {rules = copy(rules), art = {creature = creature, png = png}}
  if #history > MAX_UNDO then table.remove(history, 1) end
end

-- Applies changes and returns "theme", "music" or "lead" entries for whatever changed.
-- history collects snapshots so "undo that" can put everything back. After an undo the
-- third result is the snapshot, in case it holds art for the game to restore.
function M.apply(rules, changes, lead, history)
  local changed = {}
  if changes.undo == "1" then
    local last = table.remove(history)
    if not last then return changed, false end
    for key in pairs(rules) do rules[key] = nil end
    for key, value in pairs(last.rules) do rules[key] = value end
    if last.leadRef and last.lead then
      last.leadRef.name, last.leadRef.type = last.lead.name, last.lead.type
      last.leadRef.moves = last.lead.moves
    end
    return {theme = true, music = true, lead = true}, true, last
  end

  local before = snapshot(rules, lead)
  if changes.theme and M.THEMES[changes.theme] then
    rules.theme, changed.theme = changes.theme, true
  end
  if changes.music and M.MUSIC[changes.music] ~= nil then
    rules.music, changed.music = changes.music, true
  end
  local function adjust(key, setting, low, high)
    local by = tonumber(changes[key])
    if by and by ~= 0 then
      rules[setting] = clamp(rules[setting] + math.floor(by), low, high)
      changed[setting] = true
    end
  end
  adjust("foepower", "foePower", 1, 5)
  adjust("mypower", "myPower", 1, 5)
  adjust("catch", "catchEase", 1, 5)
  adjust("foelevel", "foeLevel", -5, 5)
  adjust("effects", "effects", 1, 5)

  if lead then
    if changes.leadname and changes.leadname ~= "" then
      lead.name, changed.lead = changes.leadname, true
    end
    if changes.leadtype and validType(changes.leadtype) then
      lead.type, changed.lead = changes.leadtype, true
    end
    if changes.leadmove then
      local name, kind, type = changes.leadmove:match("^([^|]+)|([^|]+)|([^|]+)$")
      if name and battle.KINDS[kind] and validType(type) then
        local moves = lead.moves
        moves[math.min(#moves + 1, 4)] = {name = name, kind = kind, type = type}
        changed.lead = true
      end
    end
    if changes.leadfx then
      local target, look = changes.leadfx:match("^([^|]+)|(.+)$")
      local spec = look and fx.parse(look)
      for _, move in ipairs(spec and lead.moves or {}) do
        if target == "*" or target:lower() == move.name:lower() then
          move.fx, changed.lead = spec, true
        end
      end
    end
  end
  if next(changed) then
    history[#history + 1] = before
    if #history > MAX_UNDO then table.remove(history, 1) end
  end
  return changed, false
end

function M.serialize(rules)
  local lines = {}
  for _, key in ipairs({"theme", "music", "foePower", "myPower", "catchEase", "foeLevel", "effects"}) do
    lines[#lines + 1] = key .. "=" .. tostring(rules[key])
  end
  return table.concat(lines, "\n") .. "\n"
end

function M.deserialize(text)
  local rules = M.defaults()
  for key, value in (text or ""):gmatch("(%w+)=([^\n]*)") do
    if rules[key] ~= nil then rules[key] = tonumber(value) or value end
  end
  if not M.THEMES[rules.theme] then rules.theme = "night" end
  if M.MUSIC[rules.music] == nil then rules.music = "normal" end
  return rules
end

return M
