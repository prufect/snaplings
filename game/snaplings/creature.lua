-- Reads the creature packets the server sends, and keeps the team on the SD card.
-- A packet is a PNG holding the front and back sprites side by side, followed by "key=value" lines.
-- Image decoders ignore bytes after the PNG, so older test games can still show the sprite.
local battle = require("battle")
local fx = require("fx")
local M = {}

local function validType(name)
  for _, type in ipairs(battle.TYPES) do
    if type == name then return true end
  end
  return false
end

-- Returns a plain table without images, or nil if the packet isn't usable.
function M.parse(packet)
  if packet:sub(1, 4) ~= "\137PNG" then return nil end
  local _, pngEnd = packet:find("IEND\174B`\130", 1, true)
  if not pngEnd then return nil end
  local creature = {moves = {}, png = packet:sub(1, pngEnd), packet = packet}
  local looks = {}
  for line in packet:sub(pngEnd + 1):gmatch("[^\n]+") do
    local key, value = line:match("^(%w+)=(.*)$")
    if key == "move" then
      local name, kind, type = value:match("^([^|]+)|([^|]+)|([^|]+)$")
      if name and battle.KINDS[kind] and validType(type) then
        creature.moves[#creature.moves + 1] = {name = name, kind = kind, type = type}
      end
    elseif key == "fx" then
      looks[#looks + 1] = value
    elseif key then
      creature[key] = value
    end
  end
  if not creature.name or not validType(creature.type) or #creature.moves == 0 then return nil end
  for _, look in ipairs(looks) do
    local index, spec = look:match("^(%d+)|(.+)$")
    local move = index and creature.moves[tonumber(index)]
    if move then move.fx = fx.parse(spec) end
  end
  creature.level = tonumber(creature.level) or 5
  return creature
end

-- Cuts the sprite sheet into its two halves.
function M.loadSprites(creature)
  local fileData = love.filesystem.newFileData(creature.png, "creature.png")
  local sheet = love.image.newImageData(fileData)
  local size = sheet:getHeight()
  local function half(x)
    local data = love.image.newImageData(size, size)
    data:paste(sheet, 0, 0, x, 0, size, size)
    local image = love.graphics.newImage(data)
    image:setFilter("nearest", "nearest")
    return image
  end
  creature.front, creature.back = half(0), half(size)
end

local dir, team = ".", {}

local function teamFile()
  return dir .. "/team.txt"
end

function M.save()
  local f = io.open(teamFile(), "w")
  if not f then return end
  for _, creature in ipairs(team) do
    f:write(creature.id, " ", creature.level, "\n")
  end
  f:close()
end

-- Loads every saved creature. A damaged file only loses that one creature.
function M.load(gameDir)
  dir, team = gameDir, {}
  local list = io.open(teamFile(), "r")
  if not list then return team end
  for line in list:lines() do
    local id, level = line:match("^(%S+) (%d+)$")
    local f = id and io.open(dir .. "/creatures/" .. id .. ".mon", "rb")
    if f then
      local creature = M.parse(f:read("*a"))
      f:close()
      if creature then
        local ok = pcall(M.loadSprites, creature)
        if ok then
          creature.id, creature.level = id, tonumber(level)
          team[#team + 1] = creature
        end
      end
    end
  end
  list:close()
  return team
end

function M.add(creature)
  os.execute('mkdir -p "' .. dir .. '/creatures"')
  creature.id = string.format("%d-%04d", os.time(), math.random(0, 9999))
  local f = io.open(dir .. "/creatures/" .. creature.id .. ".mon", "wb")
  if not f then return false end
  f:write(creature.packet)
  f:close()
  team[#team + 1] = creature
  M.save()
  return true
end

-- Saves a voice edit to a creature's name, type or moves.
function M.rewrite(creature)
  local lines = {}
  for _, key in ipairs({"name", "type", "blurb", "hp", "attack", "defense", "speed", "source"}) do
    if creature[key] then lines[#lines + 1] = key .. "=" .. tostring(creature[key]) end
  end
  for _, move in ipairs(creature.moves) do
    lines[#lines + 1] = "move=" .. move.name .. "|" .. move.kind .. "|" .. move.type
  end
  for i, move in ipairs(creature.moves) do
    if move.fx then lines[#lines + 1] = "fx=" .. i .. "|" .. fx.serialize(move.fx) end
  end
  creature.packet = creature.png .. table.concat(lines, "\n") .. "\n"
  if not creature.id then return end
  local f = io.open(dir .. "/creatures/" .. creature.id .. ".mon", "wb")
  if f then
    f:write(creature.packet)
    f:close()
  end
end

-- A team member by spoken name, ignoring capitals and spaces.
function M.findByName(name)
  local function key(text) return text:lower():gsub("[^%w]", "") end
  for _, member in ipairs(team) do
    if key(member.name) == key(name) then return member end
  end
  return nil
end

-- Gives a creature new art and saves it. Keeps the old art if the new art can't be read.
function M.setArt(creature, png)
  local old = {png = creature.png, front = creature.front, back = creature.back}
  creature.png = png
  if not pcall(M.loadSprites, creature) then
    creature.png, creature.front, creature.back = old.png, old.front, old.back
    return false
  end
  M.rewrite(creature)
  return true
end

function M.makeLead(index)
  table.insert(team, 1, table.remove(team, index))
  M.save()
end

return M
