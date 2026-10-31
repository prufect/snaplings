-- Particle effects for moves. Everything is drawn from shapes, so there are no asset files.
-- A move's look is a spec of shape, motion and two colors. The server's AI picks one for each
-- move, and types have defaults. Only draw() touches LÖVE, so tests can run the rest anywhere.
local M = {}

M.SHAPES = {spark = true, flame = true, bubble = true, leaf = true, star = true, bolt = true,
  shard = true, wisp = true, heart = true, slash = true}
M.MOTIONS = {burst = true, beam = true, spiral = true, rain = true, rise = true, wave = true, ring = true}

local TYPE_LOOKS = {
  flame = {shape = "flame", motion = "beam", color1 = "#ff7a1a", color2 = "#ffd23f"},
  aqua = {shape = "bubble", motion = "wave", color1 = "#3fa7ff", color2 = "#b8ecff"},
  leaf = {shape = "leaf", motion = "spiral", color1 = "#58c94f", color2 = "#c8f27a"},
  spark = {shape = "bolt", motion = "burst", color1 = "#ffe23f", color2 = "#ffffff"},
  stone = {shape = "shard", motion = "rain", color1 = "#a08a6e", color2 = "#e0d2b8"},
  spirit = {shape = "wisp", motion = "spiral", color1 = "#b56cff", color2 = "#f0d0ff"},
}
local KIND_STRENGTH = {strike = 1, heavy = 1.6, quick = 0.7, drain = 1}
local MAX_PARTICLES = 260
local SCALES = {0.35, 0.65, 1, 1.4, 1.8}

local particles = {}
local emitters = {}
local scale = 1
M.flash = nil  -- {r, g, b, alpha} for a brief full-screen tint.

local function validColor(color)
  return type(color) == "string" and color:match("^#%x%x%x%x%x%x$") ~= nil
end

-- Reads "shape|motion|#rrggbb|#rrggbb". Returns nil unless every part is valid.
function M.parse(text)
  local shape, motion, color1, color2 = (text or ""):match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
  if M.SHAPES[shape] and M.MOTIONS[motion] and validColor(color1) and validColor(color2) then
    return {shape = shape, motion = motion, color1 = color1, color2 = color2}
  end
  return nil
end

function M.serialize(spec)
  return table.concat({spec.shape, spec.motion, spec.color1, spec.color2}, "|")
end

-- A move's own look, or its type's default.
function M.lookFor(move)
  return move.fx or TYPE_LOOKS[move.type] or TYPE_LOOKS.stone
end

function M.setScale(rank)
  scale = SCALES[math.max(1, math.min(5, rank or 3))]
end

function M.count()
  return #particles
end

local function rgb(hex)
  return tonumber(hex:sub(2, 3), 16) / 255, tonumber(hex:sub(4, 5), 16) / 255, tonumber(hex:sub(6, 7), 16) / 255
end

local function spawn(look, x, y, vx, vy, life, size, gravity)
  if #particles >= MAX_PARTICLES then return end
  local r, g, b = rgb(math.random() < 0.5 and look.color1 or look.color2)
  particles[#particles + 1] = {shape = look.shape, x = x, y = y, vx = vx, vy = vy, life = life, maxLife = life,
    size = size, gravity = gravity or 0, angle = math.random() * 6.28, spin = (math.random() - 0.5) * 8,
    r = r, g = g, b = b, wobble = math.random() * 6.28}
end

local function jitter(amount)
  return (math.random() - 0.5) * amount
end

-- How each motion places one particle, t running 0..1 across the effect.
local MOTION_EMIT = {
  beam = function(look, from, to, t, power)
    local x, y = from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t
    spawn(look, x + jitter(22), y + jitter(22), jitter(50), jitter(50), 0.3 + math.random() * 0.25, (6 + math.random() * 7) * power)
  end,
  burst = function(look, from, to, t, power)
    local x, y = from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t
    spawn(look, x + jitter(12), y + jitter(12), jitter(40), jitter(40), 0.22, (9 + math.random() * 5) * power)
  end,
  spiral = function(look, from, to, t, power)
    local angle = t * 14 + math.random() * 0.6
    local radius = 70 * (1 - t) + 8
    local x, y = from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t
    spawn(look, x + math.cos(angle) * radius, y + math.sin(angle) * radius * 0.6, 0, 0, 0.4, (6 + math.random() * 6) * power)
  end,
  rain = function(look, _, to, _, power)
    spawn(look, to.x + jitter(170), to.y - 130 - math.random() * 60, jitter(30), 280 + math.random() * 120,
      0.5, (6 + math.random() * 8) * power, 260)
  end,
  rise = function(look, _, to, _, power)
    spawn(look, to.x + jitter(120), to.y + 60, jitter(30), -(110 + math.random() * 110), 0.75, (5 + math.random() * 7) * power)
  end,
  wave = function(look, from, to, t, power)
    local dx, dy = to.x - from.x, to.y - from.y
    local x = from.x + dx * t
    local y = from.y + dy * t + math.sin(t * 9) * 46 + jitter(18)
    spawn(look, x, y, dx * 0.15, dy * 0.15 + jitter(50), 0.42, (6 + math.random() * 8) * power)
  end,
  ring = function(look, _, to, _, power)
    local angle = math.random() * 6.28
    spawn(look, to.x + math.cos(angle) * 22, to.y + math.sin(angle) * 22, math.cos(angle) * 220, math.sin(angle) * 150,
      0.45, (5 + math.random() * 6) * power)
  end,
}

local function addEmitter(look, motion, from, to, duration, amount, power)
  emitters[#emitters + 1] = {look = look, motion = motion, from = from, to = to, time = 0, duration = duration,
    rate = amount * scale / duration, owed = 0, power = power}
end

-- Starts a move's animation. Status moves glow on whoever they affect.
function M.launch(move, kindInfo, from, to)
  local look = M.lookFor(move)
  if move.kind == "guard" or move.kind == "rally" then
    addEmitter(look, move.kind == "guard" and "ring" or "rise", from, from, 0.6, 40, 1)
  elseif move.kind == "hex" then
    addEmitter(look, "spiral", to, to, 0.6, 40, 1)
  else
    local power = KIND_STRENGTH[move.kind] or 1
    local duration = move.kind == "quick" and 0.25 or 0.45
    addEmitter(look, look.motion, from, to, duration, 50 * power, power)
  end
end

-- The moment a hit lands: bits fly out, and heavy moves tint the screen.
function M.impact(move, at, amountFraction)
  local look = M.lookFor(move)
  local power = KIND_STRENGTH[move.kind] or 1
  local count = math.floor((22 + 40 * math.min(1, amountFraction or 0.2)) * power * scale)
  for _ = 1, count do
    local angle = math.random() * 6.28
    local speed = (70 + math.random() * 230) * power
    spawn(look, at.x, at.y, math.cos(angle) * speed, math.sin(angle) * speed, 0.3 + math.random() * 0.4,
      (4 + math.random() * 7) * power, 240)
  end
  if move.kind == "heavy" and scale > 0.5 then
    local r, g, b = rgb(look.color1)
    M.flash = {r, g, b, 0.45}
  end
end

-- Energy flowing back to the attacker.
function M.drain(move, from, to)
  addEmitter(M.lookFor(move), "spiral", from, to, 0.5, 26, 0.8)
end

-- A move that misses fades out.
function M.fizzle(move, at)
  local look = M.lookFor(move)
  for _ = 1, math.floor(10 * scale) do
    spawn(look, at.x + jitter(50), at.y + jitter(50), jitter(60), -40 - math.random() * 50, 0.5, 3 + math.random() * 3)
  end
end

local GOLD = {shape = "star", color1 = "#ffd23f", color2 = "#fff5c2"}
local CONFETTI = {shape = "spark", color1 = "#ff5f9e", color2 = "#5fe0ff"}
local PUFF = {shape = "wisp", color1 = "#d9d9e6", color2 = "#ffffff"}

-- A creature fainting comes apart in its type's colors.
function M.faint(type, at)
  local look = TYPE_LOOKS[type] or TYPE_LOOKS.stone
  look = {shape = "wisp", color1 = look.color1, color2 = look.color2}
  for _ = 1, math.floor(60 * scale) do
    spawn(look, at.x + jitter(100), at.y + jitter(100), jitter(60), -60 - math.random() * 120, 0.7 + math.random() * 0.5, 5 + math.random() * 7)
  end
end

function M.ballThrown(from, to)
  addEmitter(GOLD, "beam", from, to, 0.4, 24, 0.8)
end

function M.caught(at)
  for _ = 1, math.floor(90 * scale) do
    local angle = math.random() * 6.28
    local speed = 60 + math.random() * 260
    spawn(GOLD, at.x, at.y, math.cos(angle) * speed, math.sin(angle) * speed, 0.6 + math.random() * 0.7, 5 + math.random() * 8, 120)
  end
end

function M.brokeFree(at)
  for _ = 1, math.floor(40 * scale) do
    local angle = math.random() * 6.28
    spawn(PUFF, at.x, at.y, math.cos(angle) * 120, math.sin(angle) * 90, 0.45, 8 + math.random() * 8)
  end
end

function M.confetti(width)
  for _ = 1, math.floor(100 * scale) do
    spawn(CONFETTI, math.random() * width, -10 - math.random() * 200, jitter(60), 100 + math.random() * 120, 2.2, 4 + math.random() * 5, 30)
  end
end

function M.update(dt)
  for i = #emitters, 1, -1 do
    local e = emitters[i]
    local before = e.time
    e.time = math.min(e.duration, e.time + dt)
    e.owed = e.owed + e.rate * (e.time - before)
    while e.owed >= 1 do
      e.owed = e.owed - 1
      local t = e.time / e.duration
      MOTION_EMIT[e.motion](e.look, e.from, e.to, t, e.power)
    end
    if e.time >= e.duration then table.remove(emitters, i) end
  end
  for i = #particles, 1, -1 do
    local p = particles[i]
    p.life = p.life - dt
    if p.life <= 0 then
      particles[i] = particles[#particles]
      particles[#particles] = nil
    else
      p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
      p.vy = p.vy + p.gravity * dt
      p.angle = p.angle + p.spin * dt
    end
  end
  if M.flash then
    M.flash[4] = M.flash[4] - dt * 1.6
    if M.flash[4] <= 0 then M.flash = nil end
  end
end

function M.clear()
  particles, emitters = {}, {}
  M.flash = nil
end

local DRAW = {
  spark = function(g, s) g.rectangle("fill", -s / 2, -s / 2, s, s) end,
  flame = function(g, s, p)
    local lick = math.sin(p.life * 22 + p.wobble) * s * 0.3
    g.polygon("fill", lick, -s, s * 0.6, s * 0.4, 0, s * 0.8, -s * 0.6, s * 0.4)
  end,
  bubble = function(g, s)
    g.setLineWidth(2)
    g.circle("line", 0, 0, s * 0.7)
    g.circle("fill", -s * 0.25, -s * 0.25, s * 0.14)
  end,
  leaf = function(g, s) g.ellipse("fill", 0, 0, s * 0.8, s * 0.35) end,
  star = function(g, s)
    g.polygon("fill", 0, -s, s * 0.28, -s * 0.28, s, 0, s * 0.28, s * 0.28, 0, s, -s * 0.28, s * 0.28, -s, 0, -s * 0.28, -s * 0.28)
  end,
  bolt = function(g, s)
    g.setLineWidth(3)
    g.line(-s * 0.3, -s, s * 0.3, -s * 0.25, -s * 0.25, s * 0.2, s * 0.3, s)
  end,
  shard = function(g, s) g.polygon("fill", 0, -s, s * 0.7, s * 0.6, -s * 0.6, s * 0.4) end,
  wisp = function(g, s)
    g.circle("fill", 0, 0, s * 0.55)
    g.circle("fill", s * 0.3, -s * 0.55, s * 0.28)
  end,
  heart = function(g, s)
    g.circle("fill", -s * 0.3, -s * 0.2, s * 0.36)
    g.circle("fill", s * 0.3, -s * 0.2, s * 0.36)
    g.polygon("fill", -s * 0.64, 0, s * 0.64, 0, 0, s * 0.8)
  end,
  slash = function(g, s)
    g.setLineWidth(3)
    g.line(-s * 1.2, -s * 0.5, s * 1.2, s * 0.5)
  end,
}

function M.draw(width, height)
  local g = love.graphics
  for _, p in ipairs(particles) do
    g.setColor(p.r, p.g, p.b, math.min(1, p.life / p.maxLife * 2))
    g.push()
    g.translate(p.x, p.y)
    g.rotate(p.angle)
    DRAW[p.shape](g, p.size, p)
    g.pop()
  end
  if M.flash then
    g.setColor(M.flash[1], M.flash[2], M.flash[3], M.flash[4])
    g.rectangle("fill", 0, 0, width, height)
  end
  g.setColor(1, 1, 1)
end

return M
