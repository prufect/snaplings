-- Snaplings: photograph anything, battle it, catch it, and build a team.
-- A takes photos and confirms, B goes back, the D-pad or left stick moves.
-- Hold L1 to talk to the game and change it. R1/R2 change the volume. Hold Start + Select to quit.
-- The XIAO sends each photo and recording to the server on the Mac, which answers.

local battle = require("battle")
local creature = require("creature")
local fx = require("fx")
local juice = require("juice")
local rules = require("rules")

local SERIAL = os.getenv("SNAPLINGS_SERIAL") or "/dev/ttyACM0"
local GAMEDIR = os.getenv("GAMEDIR") or love.filesystem.getSource()
local CMD_PREVIEW_ON, CMD_PREVIEW_OFF, CMD_SNAP, CMD_MIC_ON, CMD_MIC_OFF = 0x01, 0x02, 0x03, 0x04, 0x05
local CMD_PING, CMD_DUEL_START, CMD_DUEL_STOP = 0x06, 0x10, 0x11
local MSG_FRAME, MSG_PHOTO, MSG_TRANSCRIPT, MSG_LEVEL, MSG_SPRITE, MSG_STATUS = 0x81, 0x82, 0x83, 0x84, 0x85, 0x86
local MSG_PADDLE, MSG_SHAKE, MSG_YELL = 0x90, 0x91, 0x92
local COUNT_SECONDS = 0.8    -- How long each of 3, 2 and 1 stays up.
local START_FLASH_SECONDS = 0.8
local DUEL_SECONDS = 5       -- How long the second player has to yell and shake.
local YELL_WAIT_SECONDS = 10 -- How long to wait for the server after the window, before the game picks.
local W, H = 640, 480
local CAMERA_TURNS, CAMERA_MIRROR = 2, true  -- Must match CAMERA_QUARTER_TURNS on the server.
local CATCH_TIMEOUT = 70     -- The XIAO gives up on the server after about 60 s.
local FRAME_TIMEOUT = 3      -- Seconds without a preview frame before saying so.
local EVENT_SECONDS = 1.1
local TOAST_SECONDS = 6
local TYPE_COLORS = {
  flame = {0.95, 0.42, 0.2}, aqua = {0.25, 0.6, 0.95}, leaf = {0.35, 0.8, 0.35},
  spark = {0.98, 0.82, 0.2}, stone = {0.65, 0.58, 0.48}, spirit = {0.72, 0.45, 0.95},
}
local KIND_HINTS = {
  strike = "Reliable hit", heavy = "Strong, can miss", quick = "Goes first", drain = "Hits and heals",
  guard = "Raises your defense", rally = "Raises your attack", hex = "Lowers foe's attack",
}

local state = "menu"         -- menu, camera, catching, reveal, battle, result, team
local team = {}
local sfx, fonts = {}, {}
local sky
local stars = {}
local notice = ""
local linkOpen = false
local held = {}
local stickDown = {}

local menuChoice = 1
local preview, lastFrameAt = nil, 0
local caught, catchStartedAt, catchPhoto = nil, 0, nil
local fight = nil            -- The battle table, plus what's being shown.
local shown = {me = 0, foe = 0}
local bars = {me = 0, foe = 0}
local events, eventTimer = {}, 0
local message = ""
local actionChoice, moveChoice, picking = 1, 1, nil
local shake, flashWho = 0, nil
local teamChoice = 1
local resultLines = {}
local gameRules = rules.defaults()
local undoHistory = {}
local music
local voice, voiceStartedAt = nil, 0  -- nil, "listening" or "thinking"
local toast = nil            -- {heard, say, untilTime}
local pendingSpawn = nil     -- A creature asked for by voice, waiting for a good moment.
local paddleOn = false
local duel = nil             -- This turn's second player: see beginTurn.
local startFlash = 0

local function send(kind, payload)
  local f = io.open(SERIAL, "wb")
  if not f then
    notice = "Camera not connected"
    return false
  end
  payload = payload or ""
  local n = #payload
  f:write("GB", string.char(kind, n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, 0), payload)
  f:close()
  return true
end

local function decodeImage(bytes, name)
  local ok, image = pcall(function()
    return love.graphics.newImage(love.filesystem.newFileData(bytes, name))
  end)
  return ok and image or nil
end

local gotCreature

local function goMenu()
  state = "menu"
  menuChoice = 1
  send(CMD_PREVIEW_OFF)
  if pendingSpawn then
    local packet = pendingSpawn
    pendingSpawn = nil
    gotCreature(packet)
  end
end

local function currentPowers()
  return {me = rules.power(gameRules.myPower), foe = rules.power(gameRules.foePower), catch = rules.catchBonus(gameRules)}
end

local function saveRules()
  local f = io.open(GAMEDIR .. "/rules.txt", "w")
  if f then
    f:write(rules.serialize(gameRules))
    f:close()
  end
end

local function loadRules()
  local f = io.open(GAMEDIR .. "/rules.txt", "r")
  if f then
    gameRules = rules.deserialize(f:read("*a"))
    f:close()
  end
end

local function applyTheme()
  local colors = rules.THEMES[gameRules.theme]
  sky = juice.gradient(W, H, colors[1], colors[2])
end

local function applyMusic()
  if music then music:stop() end
  music = nil
  local step = rules.MUSIC[gameRules.music]
  if step then music = juice.music(step) end
end

local function goCamera()
  state = "camera"
  preview, lastFrameAt = nil, love.timer.getTime()
  notice = ""
  send(CMD_PREVIEW_ON)
end

local function catchFailed(why)
  notice = why
  caught = nil
  juice.play(sfx.miss)
  goCamera()
end

local queue

local function playCount(step)
  if sfx.count and sfx.count[step] then juice.play(sfx.count[step]) end
end

-- With the paddle connected, every turn opens with a spoken 3-2-1. At "start", the second
-- player yells a move and shakes while the first picks an action, and the turn plays out
-- once both are in. Without the paddle, the turn starts straight away, as it always has.
local function beginTurn()
  if paddleOn then
    duel = {phase = "count", step = 3, timer = COUNT_SECONDS, shake = 0, yelled = false, action = nil, foeMove = nil}
    picking = nil
    playCount(3)
  else
    duel = nil
    picking = "action"
  end
end

local function openDuel()
  local names = {tostring(math.floor(DUEL_SECONDS * 1000))}
  for _, move in ipairs(fight.foe.creature.moves) do names[#names + 1] = (move.name:gsub("[|\r\n]", " ")) end
  send(CMD_DUEL_START, table.concat(names, "\n"))
  duel.phase, duel.timer = "open", DUEL_SECONDS
  startFlash = START_FLASH_SECONDS
  playCount("start")
  picking, actionChoice = "action", 1
end

-- Plays the turn once the first player has picked and the second player's answer is in.
local function resolveDuel()
  local second = {move = duel.foeMove, strength = battle.shakeStrength(duel.shake)}
  local action = duel.action
  duel = nil
  queue(action.ball and battle.throwBall(fight, second) or battle.fight(fight, action.move, second))
end

local function updateDuel(dt)
  duel.timer = duel.timer - dt
  if duel.phase == "count" then
    if duel.timer <= 0 then
      duel.step = duel.step - 1
      if duel.step == 0 then
        openDuel()
      else
        duel.timer = COUNT_SECONDS
        playCount(duel.step)
      end
    end
  elseif duel.phase == "open" then
    if duel.timer <= 0 then duel.phase, duel.timer = "waiting", YELL_WAIT_SECONDS end
  elseif duel.phase == "waiting" then
    if duel.timer <= 0 then duel.yelled = true end  -- The server took too long, so the game picks.
    if duel.yelled and duel.action then resolveDuel() end
  end
end

-- The first player's choice waits here for the second player's answer.
local function lockIn(action)
  duel.action = action
  picking = nil
  message = fight.me.creature.name .. " is ready! Waiting for the yell..."
end

local function startBattle(wild)
  local lead = team[1]
  wild.level = math.max(1, lead.level + love.math.random(-1, 1) + gameRules.foeLevel)
  fight = battle.new(lead, wild, function() return love.math.random() end, currentPowers())
  shown.me, shown.foe = fight.me.hp, fight.foe.hp
  bars.me, bars.foe = fight.me.hp, fight.foe.hp
  events, eventTimer = {}, 0
  message = "A wild " .. wild.name .. " appeared!"
  actionChoice = 1
  state = "battle"
  beginTurn()
end

local function finishBattle()
  resultLines = {}
  local wild, lead = fight.foe.creature, fight.me.creature
  if fight.result ~= "lost" then fx.confetti(W) end
  if fight.result == "caught" then
    creature.add(wild)
    resultLines = {wild.name .. " joined your team!", "You have " .. #team .. " Snaplings."}
    juice.play(sfx.win)
  elseif fight.result == "won" then
    local rose = battle.levelUp(lead)
    creature.save()
    resultLines = {"You beat " .. wild.name .. "!",
      rose and (lead.name .. " grew to level " .. lead.level .. "!") or (lead.name .. " is at its peak.")}
    juice.play(sfx.win)
  elseif fight.result == "lost" then
    resultLines = {lead.name .. " needs a rest.", "It'll be ready for the next battle."}
    juice.play(sfx.over)
  else
    goMenu()
    return
  end
  state = "result"
end

local FOE_SPOT, MY_SPOT = {x = 490, y = 125}, {x = 150, y = 265}

local function spotOf(fighter)
  return fighter == fight.me and MY_SPOT or FOE_SPOT
end

function queue(newEvents)
  for _, event in ipairs(newEvents) do events[#events + 1] = event end
  eventTimer = 0
  picking = nil
end

local function playNextEvent()
  local event = table.remove(events, 1)
  if not event then
    shown.me, shown.foe = fight.me.hp, fight.foe.hp
    if fight.over then
      finishBattle()
    else
      message = "What will " .. fight.me.creature.name .. " do?"
      beginTurn()
    end
    return
  end
  eventTimer = EVENT_SECONDS
  if event.text then message = event.text end
  if event.hit then
    local side = event.hit == fight.me and "me" or "foe"
    shown[side] = math.max(0, shown[side] - event.amount)
    shake, flashWho = event.move.kind == "heavy" and 0.5 or 0.3, side
    fx.impact(event.move, spotOf(event.hit), event.amount / event.hit.maxHp)
    juice.play(sfx.hit)
    eventTimer = 0.5
  elseif event.move then
    fx.launch(event.move, nil, spotOf(event.from), spotOf(event.to))
    juice.play(sfx.move)
    eventTimer = 0.7
  elseif event.missed then
    fx.fizzle(event.missed, spotOf(event.to))
  elseif event.drained then
    fx.drain(event.drained, spotOf(event.from), spotOf(event.to))
  elseif event.fainted then
    fx.faint(event.fainted.creature.type, spotOf(event.fainted))
    juice.play(sfx.miss)
  elseif event.ball then
    fx.ballThrown(MY_SPOT, FOE_SPOT)
    juice.play(sfx.snap)
  elseif event.caught then
    fx.caught(FOE_SPOT)
    juice.play(sfx.win)
  elseif event.escaped then
    fx.brokeFree(FOE_SPOT)
    juice.play(sfx.miss)
  end
end

function gotCreature(packet)
  local made = creature.parse(packet)
  if not made or not pcall(creature.loadSprites, made) then
    catchFailed("That photo came back garbled. Try again!")
    return
  end
  caught = made
  caught.starter = #team == 0
  juice.play(sfx.win)
  send(CMD_PREVIEW_OFF)
  state = "reveal"
end

local function say(heard, words)
  toast = {heard = heard, say = words, untilTime = love.timer.getTime() + TOAST_SECONDS}
end

local function canShowCreatureNow()
  return state == "menu" or state == "camera" or state == "team"
end

-- Applies what the server made of the player's words.
local function applyVoice(level)
  local changes = rules.parse(level)
  local lead = team[1]
  local changed, undone, snapshot = rules.apply(gameRules, changes, lead, undoHistory)
  if undone and snapshot.art then creature.setArt(snapshot.art.creature, snapshot.art.png) end
  saveRules()
  if changed.theme then applyTheme() end
  if changed.music then applyMusic() end
  fx.setScale(gameRules.effects)
  if changed.lead and lead then
    creature.rewrite(lead)
    moveChoice = 1
  end
  if fight then fight.powers = currentPowers() end
  local words = changes.say or (undone and "Undone!") or "Okay!"
  if changes.leadfx and not changed.lead then words = "None of your moves are called that." end
  if changes.redraw then
    local target = changes.redraw == "*" and lead or creature.findByName(changes.redraw)
    if not target then
      words = "You don't have that one on your team."
    else
      local oldArt = target.png
      if creature.setArt(target, changes.packet or "") then
        rules.rememberArt(gameRules, undoHistory, target, oldArt)
        fx.caught(target == (fight and fight.me.creature) and MY_SPOT or {x = W / 2, y = 200})
        juice.play(sfx.win)
      else
        words = "That drawing came back garbled. Try again?"
      end
    end
    changes.packet = nil
  end
  say(toast and toast.heard or "", words)
  if changes.packet then
    if canShowCreatureNow() then
      gotCreature(changes.packet)
    else
      pendingSpawn = changes.packet
    end
  end
end

local function voiceFailed(words)
  voice = nil
  say("", words)
  if state == "camera" then send(CMD_PREVIEW_ON) end
end

local function startTalking()
  if voice or state == "catching" or duel then return end
  if send(CMD_MIC_ON) then
    voice, voiceStartedAt = "listening", love.timer.getTime()
    toast = nil
    juice.play(sfx.move)
  else
    say("", "Camera not connected")
  end
end

local function stopTalking()
  if voice ~= "listening" then return end
  send(CMD_MIC_OFF)
  voice, voiceStartedAt = "thinking", love.timer.getTime()
  juice.play(sfx.pick)
  if state == "camera" then send(CMD_PREVIEW_ON) end
end

local function updateSerial()
  local channel = love.thread.getChannel("serial")
  local msg = channel:pop()
  local frame
  while msg do
    local kind, payload = msg[1], msg[2]
    if kind == 0 then
      linkOpen = payload == "opened"
      if linkOpen then send(CMD_PING) else paddleOn = false end
      if linkOpen and state == "camera" then send(CMD_PREVIEW_ON) end
      if not linkOpen and state == "catching" then catchFailed("Lost the camera. Check its cable!") end
      if not linkOpen and voice then voiceFailed("Lost the microphone. Check its cable!") end
    elseif kind == MSG_PADDLE then
      local now = payload == "1"
      if now ~= paddleOn then say("", now and "Paddle connected!" or "Paddle disconnected.") end
      paddleOn = now
    elseif kind == MSG_SHAKE then
      if duel and #payload >= 2 then duel.shake = payload:byte(1) + payload:byte(2) * 256 end
    elseif kind == MSG_YELL then
      if duel and duel.phase ~= "count" then
        local number, heard = payload:match("^(%d+)\n(.*)$")
        local move = fight.foe.creature.moves[tonumber(number)]
        duel.foeMove, duel.yelled = move, true
        if heard and heard ~= "" then say(heard, move and (move.name .. "!") or "That isn't one of its moves!") end
      end
    elseif kind == MSG_TRANSCRIPT then
      if voice then toast = {heard = payload, say = "", untilTime = love.timer.getTime() + TOAST_SECONDS} end
    elseif kind == MSG_LEVEL then
      if voice then
        voice = nil
        applyVoice(payload)
        if state == "camera" then send(CMD_PREVIEW_ON) end
      end
    elseif kind == MSG_STATUS and voice then
      if payload == "server_busy" then
        voiceFailed("Still busy. Try again in a moment!")
      elseif payload == "error: no wifi" then
        voiceFailed("No Wi-Fi. Is the hotspot on?")
      elseif payload == "error: recording too short" then
        voiceFailed("Hold L1 while you talk!")
      elseif payload:find("^error") then
        voiceFailed("I couldn't reach the server.")
      end
    elseif kind == MSG_FRAME then
      frame = payload
    elseif kind == MSG_PHOTO and state == "catching" then
      catchPhoto = decodeImage(payload, "photo.jpg") or catchPhoto
    elseif kind == MSG_SPRITE and state == "catching" then
      gotCreature(payload)
    elseif kind == MSG_STATUS and state == "catching" then
      if payload == "server_busy" then
        catchFailed("The server's still busy. Try again!")
      elseif payload == "error: no wifi" then
        catchFailed("No Wi-Fi. Is the hotspot on?")
      elseif payload:find("^error") then
        catchFailed("It got away! Is the server running?")
      end
    end
    msg = channel:pop()
  end
  if frame and state == "camera" then
    preview = decodeImage(frame, "frame.jpg") or preview
    lastFrameAt = love.timer.getTime()
  end
end

function love.load()
  love.graphics.setDefaultFilter("nearest", "nearest")
  love.math.setRandomSeed(os.time())
  fonts.small = love.graphics.newFont(14)
  fonts.medium = love.graphics.newFont(20)
  fonts.large = love.graphics.newFont(34)
  fonts.huge = love.graphics.newFont(110)
  sfx.move = juice.sfx(700, 760, 0.04)
  sfx.pick = juice.sfx(900, 1200, 0.08)
  sfx.snap = juice.sfx(1800, 1800, 0.08, 0.3)
  sfx.hit = juice.sfx(500, 120, 0.2, 0.5)
  sfx.miss = juice.sfx(300, 120, 0.25)
  sfx.win = juice.sfx(500, 1100, 0.45)
  sfx.over = juice.sfx(500, 90, 0.8)
  sfx.count = {}
  for key, name in pairs({[3] = "three", [2] = "two", [1] = "one", start = "start"}) do
    local ok, source = pcall(love.audio.newSource, "sounds/" .. name .. ".wav", "static")
    sfx.count[key] = ok and source or juice.sfx(key == "start" and 1200 or 800, key == "start" and 1200 or 800, 0.15)
  end
  loadRules()
  applyTheme()
  applyMusic()
  fx.setScale(gameRules.effects)
  for i = 1, 50 do
    stars[i] = {x = love.math.random() * W, y = love.math.random() * H, s = love.math.random() * 2 + 1, p = love.math.random() * 6}
  end
  team = creature.load(GAMEDIR)
  love.thread.newThread("serial_thread.lua"):start(SERIAL)
  send(CMD_PREVIEW_OFF)
  send(CMD_PING)
  local dev = os.getenv("SNAPLINGS_DEV")
  if dev then dofile(dev)(function() return state end) end
end

function love.update(dt)
  updateSerial()
  fx.update(dt)
  shake = math.max(0, shake - dt)
  if shake == 0 then flashWho = nil end
  for _, side in ipairs({"me", "foe"}) do
    local d = shown[side] - bars[side]
    bars[side] = bars[side] + math.max(-40 * dt, math.min(40 * dt, d))
  end
  if voice == "thinking" and love.timer.getTime() - voiceStartedAt > CATCH_TIMEOUT then
    voiceFailed("The server didn't answer. Try again?")
  end
  if toast and love.timer.getTime() > toast.untilTime then toast = nil end
  startFlash = math.max(0, startFlash - dt)
  if duel then updateDuel(dt) end
  if state == "catching" and love.timer.getTime() - catchStartedAt > CATCH_TIMEOUT then
    catchFailed("It got away! The server didn't answer.")
  elseif state == "battle" and not picking and not duel then
    eventTimer = eventTimer - dt
    if eventTimer <= 0 then playNextEvent() end
  end
end

local function moveCursor(dx, dy)
  if state == "menu" then
    menuChoice = menuChoice + dy
    menuChoice = math.max(1, math.min(2, menuChoice))
  elseif state == "team" and #team > 0 then
    teamChoice = math.max(1, math.min(#team, teamChoice + dy))
  elseif state == "battle" and picking == "action" then
    actionChoice = math.max(1, math.min(3, actionChoice + dy))
  elseif state == "battle" and picking == "move" then
    local count = #fight.me.creature.moves
    local next = moveChoice + dx + dy * 2
    if next >= 1 and next <= count then moveChoice = next end
  else
    return
  end
  juice.play(sfx.move)
end

local function confirm()
  if state == "menu" then
    juice.play(sfx.pick)
    if menuChoice == 1 then
      goCamera()
    else
      state, teamChoice = "team", 1
    end
  elseif state == "camera" then
    if voice then
      notice = "Still thinking about what you said..."
    elseif send(CMD_SNAP) then
      juice.play(sfx.snap)
      state, catchStartedAt, catchPhoto, notice = "catching", love.timer.getTime(), preview, ""
    end
  elseif state == "reveal" then
    juice.play(sfx.pick)
    if caught.starter then
      creature.add(caught)
      goMenu()
    else
      startBattle(caught)
    end
  elseif state == "battle" then
    if picking == "action" then
      juice.play(sfx.pick)
      if actionChoice == 1 then
        picking, moveChoice = "move", 1
      elseif actionChoice == 2 then
        if duel then lockIn({ball = true}) else queue(battle.throwBall(fight)) end
      else
        if duel then
          send(CMD_DUEL_STOP)
          duel = nil
        end
        queue(battle.run(fight))
      end
    elseif picking == "move" then
      local move = fight.me.creature.moves[moveChoice]
      if duel then lockIn({move = move}) else queue(battle.fight(fight, move)) end
    else
      eventTimer = 0  -- A skips ahead through the battle text.
    end
  elseif state == "result" then
    juice.play(sfx.pick)
    goMenu()
  elseif state == "team" and team[teamChoice] then
    creature.makeLead(teamChoice)
    teamChoice = 1
    juice.play(sfx.win)
  end
end

local function back()
  if state == "camera" then
    goMenu()
  elseif state == "team" then
    state = "menu"
  elseif state == "battle" and picking == "move" then
    picking = "action"
  end
end

local function pressed(button)
  held[button] = true
  if held.start and held.back then love.event.quit() end
  if button == "rightshoulder" then juice.volume(1) end
  if button == "leftshoulder" then startTalking() end
  if button == "a" then confirm() end
  if button == "b" then back() end
  if button == "dpup" then moveCursor(0, -1) end
  if button == "dpdown" then moveCursor(0, 1) end
  if button == "dpleft" then moveCursor(-1, 0) end
  if button == "dpright" then moveCursor(1, 0) end
end

function love.gamepadpressed(_, button) pressed(button) end
function love.gamepadreleased(_, button)
  held[button] = nil
  if button == "leftshoulder" then stopTalking() end
end

-- The left stick acts like the D-pad, one step per push.
function love.gamepadaxis(_, axis, value)
  if axis == "triggerright" then
    if value > 0.6 and not stickDown.volume then juice.volume(-1) end
    if value > 0.6 then stickDown.volume = true elseif value < 0.3 then stickDown.volume = nil end
    return
  end
  local names = {leftx = {"dpleft", "dpright"}, lefty = {"dpup", "dpdown"}}
  local pair = names[axis]
  if not pair then return end
  local direction = value < -0.6 and pair[1] or value > 0.6 and pair[2] or nil
  if direction and stickDown[axis] ~= direction then
    pressed(direction)
    held[direction] = nil
  end
  if direction or math.abs(value) < 0.3 then stickDown[axis] = direction end
end

function love.keypressed(key)
  local keys = {space = "a", ["return"] = "a", backspace = "b", up = "dpup", down = "dpdown", left = "dpleft", right = "dpright"}
  if keys[key] then pressed(keys[key]) end
  if key == "t" then startTalking() end
  if key == "escape" then love.event.quit() end
end

function love.keyreleased(key)
  if key == "t" then stopTalking() end
end

function love.quit()
  if duel then send(CMD_DUEL_STOP) end
  if voice == "listening" then send(CMD_MIC_OFF) end
  send(CMD_PREVIEW_OFF)
end

local function centered(text, y, font)
  love.graphics.setFont(font or fonts.medium)
  love.graphics.printf(text, 0, y, W, "center")
end

local function panel(x, y, w, h)
  love.graphics.setColor(0.08, 0.07, 0.14, 0.92)
  love.graphics.rectangle("fill", x, y, w, h, 8)
  love.graphics.setColor(0.95, 0.92, 0.8)
  love.graphics.setLineWidth(3)
  love.graphics.rectangle("line", x, y, w, h, 8)
  love.graphics.setColor(1, 1, 1)
end

local function drawBall(x, y, radius, tilt)
  love.graphics.push()
  love.graphics.translate(x, y)
  love.graphics.rotate(tilt or 0)
  -- A little camera-lens capsule: teal shell, gold band, glass eye.
  love.graphics.setColor(0.13, 0.62, 0.62)
  love.graphics.circle("fill", 0, 0, radius)
  love.graphics.setColor(0.95, 0.75, 0.25)
  love.graphics.setLineWidth(radius * 0.22)
  love.graphics.circle("line", 0, 0, radius * 0.9)
  love.graphics.setColor(0.06, 0.09, 0.2)
  love.graphics.circle("fill", 0, 0, radius * 0.5)
  love.graphics.setColor(0.45, 0.8, 0.95)
  love.graphics.circle("fill", -radius * 0.13, -radius * 0.13, radius * 0.17)
  love.graphics.pop()
  love.graphics.setColor(1, 1, 1)
end

local function drawSprite(image, x, y, size)
  local scale = size / image:getWidth()
  love.graphics.draw(image, x - size / 2, y - size / 2, 0, scale, scale)
end

local function typeTag(name, x, y)
  love.graphics.setFont(fonts.small)
  local width = fonts.small:getWidth(name) + 14
  love.graphics.setColor(TYPE_COLORS[name] or {1, 1, 1})
  love.graphics.rectangle("fill", x, y, width, 20, 6)
  love.graphics.setColor(0.05, 0.05, 0.08)
  love.graphics.print(name, x + 7, y + 2)
  love.graphics.setColor(1, 1, 1)
  return width
end

local function statsBlock(c, x, y)
  local s = battle.stats(c)
  love.graphics.setFont(fonts.small)
  love.graphics.print(string.format("HP %d    ATK %d", s.hp, s.attack), x, y)
  love.graphics.print(string.format("DEF %d   SPD %d", s.defense, s.speed), x, y + 20)
end

local function hpBar(x, y, w, hp, maxHp)
  local fraction = math.max(0, hp / maxHp)
  love.graphics.setColor(0.2, 0.18, 0.25)
  love.graphics.rectangle("fill", x, y, w, 12, 4)
  love.graphics.setColor(fraction > 0.5 and {0.35, 0.85, 0.4} or fraction > 0.2 and {0.95, 0.8, 0.25} or {0.95, 0.3, 0.25})
  love.graphics.rectangle("fill", x, y, w * fraction, 12, 4)
  love.graphics.setColor(1, 1, 1)
end

local function drawBackdrop()
  love.graphics.setColor(1, 1, 1)
  love.graphics.draw(sky)
  local now = love.timer.getTime()
  for _, star in ipairs(stars) do
    love.graphics.setColor(1, 1, 1, 0.35 + 0.35 * math.sin(now * 2 + star.p))
    love.graphics.rectangle("fill", star.x, star.y, star.s, star.s)
  end
  love.graphics.setColor(1, 1, 1)
end

local function drawMenu()
  love.graphics.setColor(1, 0.85, 0.3)
  centered("SNAPLINGS", 44, fonts.large)
  love.graphics.setColor(0.85, 0.85, 0.95)
  centered("Catch the world around you", 92, fonts.small)
  love.graphics.setColor(1, 1, 1)
  if team[1] then
    drawSprite(team[1].front, W / 2, 200, 128)
    centered(team[1].name .. "  Lv " .. team[1].level, 268, fonts.small)
  else
    local t = love.timer.getTime()
    drawBall(W / 2, 200, 44, math.sin(t * 2) * 0.25)
    centered("Photograph anything to catch your first Snapling", 268, fonts.small)
  end
  local labels = {team[1] and "Hunt something new" or "Catch your first", "My team (" .. #team .. ")"}
  for i, label in ipairs(labels) do
    local y = 310 + (i - 1) * 46
    if i == menuChoice then
      love.graphics.setColor(1, 0.85, 0.3)
      drawBall(W / 2 - 150, y + 14, 10)
      love.graphics.setColor(1, 0.85, 0.3)
    else
      love.graphics.setColor(1, 1, 1)
    end
    centered(label, y)
    love.graphics.setColor(1, 1, 1)
  end
  love.graphics.setColor(0.7, 0.7, 0.8)
  centered(linkOpen and "A: choose    Hold L1: talk    Start + Select: quit" or "Camera not connected    Start + Select: quit", H - 30, fonts.small)
end

local function drawCamera()
  love.graphics.clear(0.03, 0.03, 0.05)
  love.graphics.setColor(1, 1, 1)
  if preview then
    local view = math.min(W / preview:getWidth(), H / preview:getHeight())
    love.graphics.draw(preview, W / 2, H / 2, CAMERA_TURNS * math.pi / 2, CAMERA_MIRROR and -view or view, view,
      preview:getWidth() / 2, preview:getHeight() / 2)
  end
  love.graphics.setColor(1, 1, 1, 0.75)
  love.graphics.setLineWidth(3)
  love.graphics.circle("line", W / 2, H / 2, 170)
  love.graphics.setColor(0, 0, 0, 0.6)
  love.graphics.rectangle("fill", 0, 0, W, 40)
  love.graphics.rectangle("fill", 0, H - 40, W, 40)
  love.graphics.setColor(1, 1, 1)
  centered(#team == 0 and "Point at your first Snapling" or "Point at something to hunt", 8)
  local status = "A: snap    B: back    Hold L1: talk"
  if love.timer.getTime() - lastFrameAt > FRAME_TIMEOUT then status = "Waiting for the camera...    B: back" end
  if notice ~= "" then status = notice end
  love.graphics.setColor(notice ~= "" and {1, 0.75, 0.4} or {1, 1, 1})
  centered(status, H - 32, fonts.small)
  love.graphics.setColor(1, 1, 1)
end

local function drawCatching()
  local t = love.timer.getTime() - catchStartedAt
  if catchPhoto then
    love.graphics.setColor(1, 1, 1, 0.35)
    local view = math.min(W / catchPhoto:getWidth(), H / catchPhoto:getHeight())
    love.graphics.draw(catchPhoto, W / 2, H / 2, CAMERA_TURNS * math.pi / 2, CAMERA_MIRROR and -view or view, view,
      catchPhoto:getWidth() / 2, catchPhoto:getHeight() / 2)
    love.graphics.setColor(1, 1, 1)
  end
  local drop = math.min(1, t / 0.5)
  local wobble = math.sin(t * 6) * 0.4 * (0.5 + 0.5 * math.sin(t * 1.3))
  drawBall(W / 2, -60 + (H / 2 + 60) * drop, 56, drop == 1 and wobble or t * 8)
  local phrases = {"The ball is wobbling...", "Something's forming inside...", "Almost got it...", "It's putting up a fight..."}
  centered(phrases[math.floor(t / 5) % #phrases + 1], H / 2 + 90)
end

local function drawReveal()
  panel(60, 40, W - 120, H - 80)
  love.graphics.setColor(1, 0.85, 0.3)
  centered(caught.starter and "You caught your first Snapling!" or "A wild Snapling appeared!", 56, fonts.medium)
  love.graphics.setColor(1, 1, 1)
  drawSprite(caught.front, 200, 220, 192)
  love.graphics.setFont(fonts.large)
  love.graphics.print(caught.name, 320, 110)
  typeTag(caught.type, 322, 158)
  statsBlock(caught, 322, 192)
  love.graphics.setFont(fonts.small)
  local moves = {}
  for i, move in ipairs(caught.moves) do moves[i] = move.name end
  love.graphics.printf(table.concat(moves, ", "), 322, 240, 240)
  love.graphics.setColor(0.85, 0.85, 0.95)
  love.graphics.printf(caught.blurb or "", 90, 346, W - 180, "center")
  love.graphics.setColor(1, 0.85, 0.3)
  centered(caught.starter and "A: add to your team" or "A: battle it!", H - 74, fonts.small)
  love.graphics.setColor(1, 1, 1)
end

local function fighterPanel(side, f, x, y)
  panel(x, y, 250, 62)
  love.graphics.setFont(fonts.medium)
  love.graphics.print(f.creature.name, x + 12, y + 6)
  love.graphics.setFont(fonts.small)
  love.graphics.printf("Lv " .. f.creature.level, x, y + 10, 238, "right")
  hpBar(x + 12, y + 36, 170, bars[side], f.maxHp)
  love.graphics.printf(math.ceil(bars[side]) .. "/" .. f.maxHp, x, y + 33, 238, "right")
end

local function drawBattle()
  love.graphics.setColor(0.2, 0.45, 0.3)
  love.graphics.ellipse("fill", 490, 190, 130, 30)
  love.graphics.ellipse("fill", 150, 340, 150, 34)
  love.graphics.push()
  if shake > 0 then
    love.graphics.translate((love.math.random() - 0.5) * 24 * shake, (love.math.random() - 0.5) * 24 * shake)
  end
  local blink = flashWho and math.floor(love.timer.getTime() * 20) % 2 == 0
  love.graphics.setColor(1, 1, 1)
  if not (blink and flashWho == "foe") and not (fight.result == "caught") then
    drawSprite(fight.foe.creature.front, 490, 125, 160)
  end
  if not (blink and flashWho == "me") then
    drawSprite(fight.me.creature.back, 150, 265, 180)
  end
  love.graphics.pop()
  love.graphics.setColor(1, 1, 1)
  fighterPanel("foe", fight.foe, 20, 24)
  fighterPanel("me", fight.me, 370, 276)

  panel(16, H - 118, W - 32, 102)
  if picking == "move" then
    local moves = fight.me.creature.moves
    for i, move in ipairs(moves) do
      local x, y = 36 + (i - 1) % 2 * 290, H - 106 + math.floor((i - 1) / 2) * 44
      love.graphics.setFont(fonts.medium)
      love.graphics.setColor(i == moveChoice and {1, 0.85, 0.3} or {1, 1, 1})
      love.graphics.print(move.name, x, y)
      love.graphics.setFont(fonts.small)
      love.graphics.setColor(TYPE_COLORS[move.type])
      love.graphics.print(move.type .. " - " .. KIND_HINTS[move.kind], x, y + 24)
    end
    love.graphics.setColor(1, 1, 1)
  elseif picking == "action" then
    love.graphics.setFont(fonts.medium)
    love.graphics.printf(message, 34, H - 102, 380)
    local labels = {"Fight", string.format("Ball (%d%%)", battle.catchChance(fight) * 100), "Run"}
    for i, label in ipairs(labels) do
      love.graphics.setColor(i == actionChoice and {1, 0.85, 0.3} or {1, 1, 1})
      love.graphics.print(label, 450, H - 110 + (i - 1) * 30)
    end
    love.graphics.setColor(1, 1, 1)
  else
    love.graphics.setFont(fonts.medium)
    love.graphics.printf(message, 34, H - 94, W - 68)
  end
end

-- The countdown, then the second player's moves and how hard they've shaken.
local function drawDuel()
  if duel and duel.phase == "count" then
    love.graphics.setFont(fonts.huge)
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.printf(tostring(duel.step), 4, 134, W, "center")
    love.graphics.setColor(1, 0.85, 0.3)
    love.graphics.printf(tostring(duel.step), 0, 130, W, "center")
    love.graphics.setColor(1, 1, 1)
    return
  end
  if startFlash > 0 then
    love.graphics.setFont(fonts.huge)
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.printf("START!", 4, 134, W, "center")
    love.graphics.setColor(0.4, 1, 0.5)
    love.graphics.printf("START!", 0, 130, W, "center")
    love.graphics.setColor(1, 1, 1)
  end
  if not duel then return end
  panel(20, 92, 250, 150)
  love.graphics.setFont(fonts.small)
  love.graphics.setColor(1, 0.85, 0.3)
  local title = duel.phase == "open" and string.format("YELL AND SHAKE! %d", math.ceil(duel.timer)) or "Hearing the yell..."
  love.graphics.print(title, 34, 100)
  for i, move in ipairs(fight.foe.creature.moves) do
    love.graphics.setColor(move == duel.foeMove and {1, 0.85, 0.3} or TYPE_COLORS[move.type])
    love.graphics.print(move.name, 34, 118 + (i - 1) * 20)
  end
  local strength = battle.shakeStrength(duel.shake)
  local amount = (strength - battle.WEAKEST) / (battle.STRONGEST - battle.WEAKEST)
  love.graphics.setColor(0.2, 0.2, 0.28)
  love.graphics.rectangle("fill", 34, 206, 222, 22, 4)
  love.graphics.setColor(0.95, 0.35 + 0.5 * (1 - amount), 0.2)
  love.graphics.rectangle("fill", 34, 206, 222 * amount, 22, 4)
  love.graphics.setColor(1, 1, 1)
  love.graphics.printf(string.format("Power %d%%", strength * 100), 34, 209, 222, "center")
end

local function drawResult()
  panel(90, 130, W - 180, 220)
  love.graphics.setColor(1, 0.85, 0.3)
  centered(fight.result == "lost" and "Defeated..." or "Victory!", 150, fonts.large)
  love.graphics.setColor(1, 1, 1)
  for i, line in ipairs(resultLines) do centered(line, 200 + (i - 1) * 34) end
  love.graphics.setColor(0.85, 0.85, 0.95)
  centered("A: continue", 310, fonts.small)
  love.graphics.setColor(1, 1, 1)
end

local function drawTeam()
  if #team == 0 then
    panel(90, 170, W - 180, 120)
    centered("Nothing caught yet", 196)
    love.graphics.setColor(0.85, 0.85, 0.95)
    centered("B: back", 240, fonts.small)
    love.graphics.setColor(1, 1, 1)
    return
  end
  panel(16, 16, 250, H - 32)
  local first = math.max(1, math.min(teamChoice - 4, #team - 8))
  for i = first, math.min(#team, first + 8) do
    local y = 28 + (i - first) * 48
    if i == teamChoice then
      love.graphics.setColor(1, 0.85, 0.3, 0.25)
      love.graphics.rectangle("fill", 24, y - 2, 234, 46, 6)
      love.graphics.setColor(1, 1, 1)
    end
    drawSprite(team[i].front, 50, y + 21, 40)
    love.graphics.setFont(fonts.small)
    love.graphics.print(team[i].name, 80, y + 4)
    love.graphics.print("Lv " .. team[i].level .. (i == 1 and "  (lead)" or ""), 80, y + 22)
  end
  local c = team[teamChoice]
  panel(280, 16, W - 296, H - 32)
  drawSprite(c.front, 460, 120, 160)
  love.graphics.setFont(fonts.medium)
  love.graphics.printf(c.name, 280, 204, W - 296, "center")
  typeTag(c.type, 296, 240)
  statsBlock(c, 296, 268)
  love.graphics.setFont(fonts.small)
  for i, move in ipairs(c.moves) do
    love.graphics.setColor(TYPE_COLORS[move.type])
    love.graphics.print(move.name, 470, 244 + (i - 1) * 20)
  end
  love.graphics.setColor(0.85, 0.85, 0.95)
  love.graphics.printf(c.blurb or "", 296, 340, W - 328)
  love.graphics.setColor(1, 0.85, 0.3)
  love.graphics.printf("A: make lead    B: back", 280, H - 50, W - 296, "center")
  love.graphics.setColor(1, 1, 1)
end

-- Shows that the game is listening, then what it heard and how it answered.
local function drawVoice()
  if not voice and not toast then return end
  local x, y, w = 40, 8, W - 80
  local height = (not voice and toast and toast.heard ~= "") and 62 or 36
  love.graphics.setColor(0.06, 0.05, 0.12, 0.94)
  love.graphics.rectangle("fill", x, y, w, height, 8)
  love.graphics.setColor(0.45, 0.85, 0.95)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", x, y, w, height, 8)
  if voice == "listening" then
    local pulse = 7 + 2 * math.sin(love.timer.getTime() * 8)
    love.graphics.setColor(0.95, 0.25, 0.25)
    love.graphics.circle("fill", x + 22, y + 18, pulse)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(fonts.medium)
    love.graphics.print("Listening... let go to send", x + 42, y + 5)
  elseif voice == "thinking" then
    local dots = string.rep(".", math.floor(love.timer.getTime() * 3) % 4)
    love.graphics.setColor(1, 0.85, 0.3)
    love.graphics.setFont(fonts.medium)
    love.graphics.print("Thinking" .. dots, x + 16, y + 5)
  elseif toast.heard ~= "" then
    love.graphics.setFont(fonts.small)
    love.graphics.setColor(0.75, 0.8, 0.9)
    local heard = toast.heard
    if #heard > 66 then heard = heard:sub(1, 63) .. "..." end
    love.graphics.print('"' .. heard .. '"', x + 14, y + 8)
    love.graphics.setColor(1, 0.85, 0.3)
    love.graphics.print(toast.say, x + 14, y + 34)
  else
    love.graphics.setFont(fonts.small)
    love.graphics.setColor(1, 0.85, 0.3)
    love.graphics.print(toast.say, x + 14, y + 10)
  end
  love.graphics.setColor(1, 1, 1)
end

function love.draw()
  drawBackdrop()
  if state == "menu" then drawMenu()
  elseif state == "camera" then drawCamera()
  elseif state == "catching" then drawCatching()
  elseif state == "reveal" then drawReveal()
  elseif state == "battle" then
    drawBattle()
    drawDuel()
  elseif state == "result" then drawResult()
  elseif state == "team" then drawTeam()
  end
  fx.draw(W, H)
  drawVoice()
end
