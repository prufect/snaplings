-- Plays the game by script for testing: real server packets go in, screenshots come out.
-- The game loads this when SNAPLINGS_DEV points here, passing a function that returns its state.
-- See run_game_test.sh.
local OUT = os.getenv("SNAPLINGS_OUT")
local PACKET = io.open(os.getenv("SNAPLINGS_PACKET"), "rb"):read("*a")
local PHOTO = io.open(os.getenv("SNAPLINGS_PHOTO"), "rb"):read("*a")
local SPAWN = io.open(os.getenv("SNAPLINGS_SPAWN"), "rb"):read("*a")
local REDRAW = os.getenv("SNAPLINGS_REDRAW") and io.open(os.getenv("SNAPLINGS_REDRAW"), "rb"):read("*a")
local channel = love.thread.getChannel("serial")
local gameUpdate = love.update
local gameRandom = love.math.random

-- Fixes every random roll, so a chosen outcome always happens.
local function rigRandom(roll)
  love.math.random = function(low)
    if low then return 0 end
    return roll
  end
end

return function(getState)
  local function wait(seconds)
    local finish = love.timer.getTime() + seconds
    while love.timer.getTime() < finish do coroutine.yield() end
  end

  local function press(button)
    love.gamepadpressed(nil, button)
    love.gamepadreleased(nil, button)
    wait(0.15)
  end

  local function shot(name)
    love.graphics.captureScreenshot(function(data)
      local f = io.open(OUT .. "/" .. name .. ".png", "wb")
      f:write(data:encode("png"):getString())
      f:close()
    end)
    wait(0.2)
    print("screenshot " .. name .. " in state " .. getState())
  end

  local function expect(wanted)
    assert(getState() == wanted, "expected state " .. wanted .. " but was " .. getState())
  end

  -- Presses A until the game reaches a state, failing the test if it never does.
  local function pressUntil(wanted, seconds)
    local finish = love.timer.getTime() + (seconds or 60)
    while getState() ~= wanted do
      assert(love.timer.getTime() < finish, "never reached " .. wanted .. ", still in " .. getState())
      press("a")
      wait(0.1)
    end
  end

  local function deliver(kind, payload)
    channel:push({kind, payload})
    wait(0.3)
  end

  -- Opens the camera from the menu and catches or meets a creature.
  local function snap()
    expect("menu")
    press("a")
    expect("camera")
    deliver(0x81, PHOTO)
    press("a")
    expect("catching")
    deliver(0x82, PHOTO)
    deliver(0x85, PACKET)
    expect("reveal")
  end

  local function firstRun()
    shot("01-menu-empty")
    press("dpdown")
    press("a")
    expect("team")
    shot("02-team-empty")
    press("b")
    press("dpup")

    press("a")
    expect("camera")
    deliver(0x81, PHOTO)
    shot("03-camera")
    press("a")
    deliver(0x82, PHOTO)
    wait(0.8)
    shot("04-catching")
    deliver(0x86, "error: /photo returned -1")
    expect("camera")
    shot("05-catch-failed")
    press("a")
    deliver(0x85, "not a creature")
    expect("camera")
    shot("06-garbled")
    press("a")
    deliver(0x86, "server_busy")
    expect("camera")
    press("a")
    channel:push({0, "closed"})
    wait(0.3)
    expect("camera")
    shot("07-link-lost")
    channel:push({0, "opened"})
    wait(0.2)
    press("a")
    deliver(0x85, PACKET)
    expect("reveal")
    shot("08-reveal-starter")
    press("a")
    expect("menu")
    shot("09-menu-team")

    -- Talking: a recording, then the real replies the server gave to real speech.
    love.gamepadpressed(nil, "leftshoulder")
    wait(0.3)
    shot("40-listening")
    love.gamepadreleased(nil, "leftshoulder")
    wait(0.2)
    shot("41-thinking")
    deliver(0x83, "Make the world look spooky and play faster music.")
    deliver(0x84, "say=Spooky world, faster music!\ntheme=spooky\nmusic=fast\n")
    shot("42-spooky")
    press("leftshoulder")
    deliver(0x83, "Rename my creature to Sparky and teach it a move called Thunder Hug.")
    deliver(0x84, "say=Done! Sparky learned Thunder Hug.\nleadname=Sparky\nleadmove=Thunder Hug|strike|spark\n")
    shot("43-renamed")
    press("leftshoulder")
    deliver(0x83, "Undo that.")
    deliver(0x84, "say=Undid that change.\nundo=1\n")
    shot("44-undone")
    press("leftshoulder")
    deliver(0x83, "Make it lava.")
    deliver(0x84, "say=Hot!\ntheme=lava\n")
    press("leftshoulder")
    deliver(0x86, "error: recording too short")
    shot("45-too-short")
    press("leftshoulder")
    deliver(0x83, "I want to fight a giant angry pizza.")
    channel:push({0x84, SPAWN:sub(SPAWN:find("\n", 1, true) + 1)})
    wait(0.5)
    expect("reveal")
    shot("46-pizza")
    press("b")
    press("a")
    expect("battle")
    press("a")
    press("leftshoulder")
    deliver(0x83, "Make enemies weaker while we fight.")
    deliver(0x84, "say=Weakened enemies!\nfoepower=-2\n")
    shot("47-voice-in-battle")
    rigRandom(0.99)
    press("b")
    press("dpdown")
    press("dpdown")
    press("a")
    pressUntil("menu", 15)

    -- Redrawing the lead by voice, then undoing it.
    if REDRAW then
      press("leftshoulder")
      deliver(0x83, "Give it a wizard hat.")
      channel:push({0x84, REDRAW:sub(REDRAW:find("\n", 1, true) + 1)})
      wait(0.4)
      shot("60-redrawn")
      press("leftshoulder")
      deliver(0x83, "Undo that.")
      deliver(0x84, "say=Undone.\nundo=1\n")
      shot("61-redraw-undone")
      press("leftshoulder")
      deliver(0x83, "Draw Nobody as a hat.")
      channel:push({0x84, "say=Sure\nredraw=Nobody\n\ncreature\nnot art"})
      wait(0.3)
      shot("62-not-on-team")
      press("leftshoulder")
      deliver(0x83, "Make it a robot.")
      channel:push({0x84, "say=Sure\nredraw=*\n\ncreature\nnot art"})
      wait(0.3)
      shot("63-garbled-art")
    end

    -- A tour of each move's effect, as it launches and as it lands.
    rigRandom(0.5)
    for i = 1, 4 do
      if getState() ~= "menu" and getState() ~= "battle" then pressUntil("menu", 20) end
      if getState() == "menu" then
        snap()
        press("a")
        expect("battle")
      end
      press("a")
      if i == 2 or i == 4 then press("dpright") end
      if i >= 3 then press("dpdown") end
      press("a")
      wait(0.3)
      shot("50-move" .. i .. "-launch")
      wait(0.35)
      shot("51-move" .. i .. "-hit")
      wait(4.5)
    end
    if getState() == "battle" then
      press("a")
      wait(0.2)
      press("b")
      press("dpdown")
      press("dpdown")
      press("a")
    end
    pressUntil("menu", 20)

    -- A battle won: rolls of 0.5 never miss, and every hit lands.
    rigRandom(0.5)
    snap()
    shot("10-reveal-wild")
    press("a")
    expect("battle")
    shot("11-battle-start")
    press("a")
    shot("12-moves")
    press("dpright")
    press("dpleft")
    press("b")
    press("a")
    press("a")
    wait(0.3)
    shot("13-attack-text")
    wait(1.0)
    shot("14-after-hit")
    pressUntil("result")
    shot("15-result")
    press("a")
    expect("menu")

    -- A catch: rolls of 0.01 always succeed.
    rigRandom(0.01)
    snap()
    press("a")
    press("dpdown")
    wait(0.1)
    shot("16-ball-menu")
    press("a")
    wait(0.2)
    shot("17-ball-thrown")
    wait(1.3)
    shot("18-gotcha")
    pressUntil("result")
    shot("19-caught-result")
    press("a")
    expect("menu")

    -- A duel with the paddle: a yell and a hard shake, with the first player picking during the window.
    rigRandom(0.5)
    deliver(0x90, "1")
    snap()
    press("a")
    expect("battle")
    wait(0.3)
    shot("70-countdown-3")
    press("a")  -- Pressing A during the countdown does nothing.
    wait(0.9)
    shot("71-countdown-2")
    wait(1.5)
    shot("72-start")
    deliver(0x91, string.char(100, 0))
    wait(0.5)
    shot("73-window-half-power")
    press("a")
    press("a")
    shot("74-locked-in")
    expect("battle")
    deliver(0x91, string.char(200, 0))
    wait(4.2)
    shot("75-hearing-the-yell")
    deliver(0x92, "2\nhe yelled move two")
    wait(0.3)
    shot("76-yell-heard")
    wait(5)

    -- The next turn: nothing yelled, and the first player runs during the window.
    wait(2.7)
    shot("77-next-window")
    press("dpdown")
    press("dpdown")
    press("a")
    pressUntil("menu", 15)

    -- A failed server still finishes the turn, and the first player can pick after the window.
    snap()
    press("a")
    wait(3.2 + 5.2)
    shot("78-window-over-no-pick")
    deliver(0x92, "0\n")
    press("a")
    press("a")
    wait(0.2)
    shot("79-picked-after-window")
    wait(1)
    deliver(0x90, "0")  -- The paddle drops: later turns have no countdown.
    local finish = love.timer.getTime() + 30
    while getState() == "battle" and love.timer.getTime() < finish do
      press("a")
      wait(0.2)
      press("dpdown")
      press("dpdown")
    end
    if getState() ~= "menu" then pressUntil("menu", 20) end

    -- Breaking free, then running away.
    rigRandom(0.99)
    snap()
    press("a")
    press("dpdown")
    press("a")
    wait(1.4)
    shot("20-broke-free")
    local finish = love.timer.getTime() + 20
    while getState() == "battle" and love.timer.getTime() < finish do
      press("a")
      wait(0.2)
      press("dpdown")
      press("dpdown")
    end
    love.math.random = gameRandom
    shot("21-after-running")
  end

  local function secondRun()
    shot("30-menu-reloaded")
    press("dpdown")
    press("a")
    expect("team")
    press("dpdown")
    shot("31-team-second")
    press("a")
    shot("32-team-new-lead")
    press("b")
    expect("menu")
    shot("33-menu-new-lead")
    print("rules kept: " .. io.open(os.getenv("GAMEDIR") .. "/rules.txt"):read("*a"):gsub("\n", " "))
  end

  local script = coroutine.create(function()
    wait(0.5)
    if os.getenv("SNAPLINGS_STAGE") == "1" then firstRun() else secondRun() end
    print("script finished")
    love.event.quit()
  end)

  function love.update(dt)
    gameUpdate(dt)
    local ok, err = coroutine.resume(script)
    if not ok then
      print("TEST FAILED: " .. tostring(err))
      os.exit(1)
    end
  end
end
