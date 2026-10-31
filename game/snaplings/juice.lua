-- Shared sound and scenery. Everything is generated, so there are no asset files.
local M = {}
local RATE = 22050

-- A sweep from f1 to f2 Hz. noise (0..1) mixes in static for hits and blasts.
function M.sfx(f1, f2, dur, noise)
  noise = noise or 0
  local n = math.floor(RATE * dur)
  local sd = love.sound.newSoundData(n, RATE, 16, 1)
  local phase = 0
  for i = 0, n - 1 do
    local t = i / n
    phase = phase + (f1 + (f2 - f1) * t) / RATE
    local square = (phase % 1) < 0.5 and 1 or -1
    local s = square * (1 - noise) + (math.random() * 2 - 1) * noise
    sd:setSample(i, s * 0.9 * (1 - t) * math.min(1, i / 60))
  end
  return love.audio.newSource(sd, "static")
end

function M.play(source)
  local s = source:clone()
  s:play()
end

-- Original looping tune: 16 steps per bar, 4 bars, bass plus arpeggio.
local CHORDS = {{110, 220, 262, 330}, {87.3, 175, 220, 262}, {130.8, 262, 330, 392}, {98, 196, 247, 294}}

function M.music(step)
  step = step or 0.13
  local perStep = math.floor(RATE * step)
  local total = perStep * 16 * #CHORDS
  local sd = love.sound.newSoundData(total, RATE, 16, 1)
  local pattern = {2, 3, 4, 3}
  for i = 0, total - 1 do
    local s = math.floor(i / perStep)
    local chord = CHORDS[math.floor(s / 16) + 1]
    local into = (i % perStep) / perStep
    local bass = (i * chord[1] / RATE) % 1 < 0.5 and 0.28 or -0.28
    local note = chord[pattern[s % 4 + 1]] * 2
    local lead = ((i * note / RATE) % 1 < 0.25 and 0.2 or -0.2) * (1 - into)
    local kick = s % 8 == 0 and math.sin(i * 0.05) * 0.3 * (1 - into) or 0
    sd:setSample(i, bass + lead + kick)
  end
  local src = love.audio.newSource(sd, "static")
  src:setLooping(true)
  src:setVolume(0.6)
  src:play()
  return src
end

-- L1/R1: system volume in raw mixer steps (range 0-237).
function M.volume(direction)
  os.execute("amixer -q sset Playback 15" .. (direction > 0 and "+" or "-") .. " >/dev/null 2>&1 &")
end

-- Vertical gradient from {r,g,b} top to bottom.
function M.gradient(w, h, top, bottom)
  return love.graphics.newMesh({
    {0, 0, 0, 0, top[1], top[2], top[3]}, {w, 0, 0, 0, top[1], top[2], top[3]},
    {w, h, 0, 0, bottom[1], bottom[2], bottom[3]}, {0, h, 0, 0, bottom[1], bottom[2], bottom[3]},
  }, "fan", "static")
end

-- Simple particle list.
local parts = {}
function M.burst(x, y, count, color, speed)
  for _ = 1, count do
    local a, v = math.random() * 6.28, (0.3 + math.random()) * speed
    parts[#parts + 1] = {x = x, y = y, vx = math.cos(a) * v, vy = math.sin(a) * v,
      life = 0.4 + math.random() * 0.4, color = color, size = 2 + math.random() * 4}
  end
end

function M.updateParts(dt)
  for i = #parts, 1, -1 do
    local p = parts[i]
    p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
    p.vy = p.vy + 300 * dt
    p.life = p.life - dt
    if p.life <= 0 then table.remove(parts, i) end
  end
end

function M.drawParts()
  for _, p in ipairs(parts) do
    love.graphics.setColor(p.color[1], p.color[2], p.color[3], math.min(1, p.life * 3))
    love.graphics.rectangle("fill", p.x, p.y, p.size, p.size)
  end
end

return M
