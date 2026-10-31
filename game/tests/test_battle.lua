-- Battle rule tests. Run with: love game/tests (or any Lua: lua game/tests/test_battle.lua from the repo root)
package.path = "game/snaplings/?.lua;../snaplings/?.lua;" .. package.path
local battle = require("battle")

local failed, passed = 0, 0
local function check(name, condition)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. name)
  end
end

local function creature(name, type, kinds)
  local moves = {}
  for i, kind in ipairs(kinds or {"strike"}) do
    moves[i] = {name = "Move" .. i, kind = kind, type = type}
  end
  return {name = name, type = type, hp = 3, attack = 3, defense = 3, speed = 3, level = 5, moves = moves}
end

local function always(value)
  return function() return value end
end

-- The second player's shaking and yelled move
check("no shaking is the weakest", battle.shakeStrength(0) == battle.WEAKEST)
check("full shaking is the strongest", battle.shakeStrength(battle.SHAKE_FOR_FULL) == battle.STRONGEST)
check("more than full stops at the strongest", battle.shakeStrength(60000) == battle.STRONGEST)
check("shaking in between is in between", battle.shakeStrength(battle.SHAKE_FOR_FULL / 2) == (battle.WEAKEST + battle.STRONGEST) / 2)
do
  local function damageTo(strength)
    local b = battle.new(creature("Me", "stone", {"strike"}), creature("Foe", "stone", {"strike"}), always(0.5))
    local start = b.me.hp
    battle.fight(b, b.me.creature.moves[1], {move = b.foe.creature.moves[1], strength = strength})
    return start - b.me.hp
  end
  check("a harder shake hits harder", damageTo(1.5) > damageTo(1) and damageTo(1) > damageTo(0.75))

  local b = battle.new(creature("Me", "stone", {"strike"}), creature("Foe", "stone", {"guard", "heavy"}), always(0.5))
  local events = battle.fight(b, b.me.creature.moves[1], {move = b.foe.creature.moves[1], strength = 1})
  local usedGuard = false
  for _, event in ipairs(events) do
    if event.move == b.foe.creature.moves[1] then usedGuard = true end
  end
  check("the yelled move replaces the game's pick", usedGuard)

  local plain = battle.new(creature("Me", "stone", {"strike"}), creature("Foe", "stone", {"strike"}), always(0.5))
  battle.fight(plain, plain.me.creature.moves[1], {strength = 1.5})
  local after = plain.me.hp
  plain.me.hp, plain.foe.hp = plain.me.maxHp, plain.foe.maxHp
  battle.fight(plain, plain.me.creature.moves[1])
  check("a turn without the paddle goes back to normal strength", plain.me.maxHp - plain.me.hp < plain.me.maxHp - after)

  local ball = battle.new(creature("Me", "stone", {"strike"}), creature("Foe", "stone", {"strike"}), always(0.99))
  ball.foe.hp = ball.foe.maxHp
  local start = ball.me.hp
  battle.throwBall(ball, {move = ball.foe.creature.moves[1], strength = 1.5})
  check("the second player hits back after a failed catch", ball.me.hp < start)
end

-- Type chart
check("flame beats leaf", battle.effectiveness("flame", "leaf") == 2)
check("leaf resists into flame", battle.effectiveness("leaf", "flame") == 0.5)
check("flame neutral to flame", battle.effectiveness("flame", "flame") == 1)
for _, a in ipairs(battle.TYPES) do
  local strong = 0
  for _, b in ipairs(battle.TYPES) do
    if battle.effectiveness(a, b) == 2 then strong = strong + 1 end
    check(a .. " and " .. b .. " aren't both strong", not (battle.effectiveness(a, b) == 2 and battle.effectiveness(b, a) == 2))
  end
  check(a .. " beats exactly two types", strong == 2)
end

-- Stats stay in bounds whatever the server sends
local wild = creature("Wild", "aqua")
wild.hp, wild.attack, wild.defense, wild.speed = 999, -4, "nonsense", nil
local s = battle.stats(wild)
check("rank above 5 is clamped", s.hp == 20 + 5 * 6 + 5 * 3)
check("rank below 1 is clamped", s.attack == 6 + 1 * 3 + 5)
check("unreadable rank becomes 3", s.defense == 6 + 3 * 3 + 5)
check("missing rank becomes 3", s.speed == 6 + 3 * 3 + 5)

-- Damage
do
  local b = battle.new(creature("A", "flame"), creature("B", "leaf"), always(0.5))
  local strong = battle.damage(b, b.me, b.foe, {name = "x", kind = "strike", type = "flame"})
  local plain = battle.damage(b, b.me, b.foe, {name = "x", kind = "strike", type = "stone"})
  check("same type and super effective hits harder", strong > plain)
  b.me.stages.attack = 2
  check("raised attack hits harder", battle.damage(b, b.me, b.foe, {name = "x", kind = "strike", type = "stone"}) > plain)
end

-- Turns: first striker wins when it knocks the other out
do
  local b = battle.new(creature("A", "flame"), creature("B", "aqua"), always(0.5))
  b.me.speed, b.foe.speed = 99, 1
  b.foe.hp = 1
  local events = battle.fight(b, b.me.creature.moves[1])
  check("faster fighter wins", b.over and b.result == "won")
  check("fainted foe doesn't hit back", b.me.hp == b.me.maxHp)
  check("events mention fainting", events[#events].text:find("fainted") ~= nil)
end
do
  local b = battle.new(creature("A", "flame"), creature("B", "aqua"), always(0.5))
  b.me.speed, b.foe.speed = 1, 99
  b.me.hp = 1
  battle.fight(b, b.me.creature.moves[1])
  check("slower fighter can lose first", b.over and b.result == "lost")
  check("fainted player doesn't hit back", b.foe.hp == b.foe.maxHp)
end
do
  local b = battle.new(creature("A", "flame", {"quick"}), creature("B", "aqua"), always(0.5))
  b.me.speed, b.foe.speed = 1, 99
  b.foe.hp = 1
  battle.fight(b, b.me.creature.moves[1])
  check("quick moves go first", b.result == "won")
end

-- Status moves
do
  local b = battle.new(creature("A", "flame", {"rally"}), creature("B", "aqua", {"guard"}), always(0.5))
  battle.fight(b, b.me.creature.moves[1])
  check("rally raises attack", b.me.stages.attack == 1)
  for _ = 1, 6 do battle.fight(b, b.me.creature.moves[1]) end
  check("stages stop at 3", b.me.stages.attack == 3)
end
do
  local b = battle.new(creature("A", "flame", {"heavy"}), creature("B", "aqua", {"guard"}), always(0.9))
  local before = b.foe.hp
  local events = battle.fight(b, b.me.creature.moves[1])
  check("a roll above accuracy misses", b.foe.hp == before)
  local missed = false
  for _, e in ipairs(events) do missed = missed or e.text == "It missed!" end
  check("misses are announced", missed)
end
do
  local b = battle.new(creature("A", "flame", {"drain"}), creature("B", "aqua", {"guard"}), always(0.5))
  b.me.hp = 5
  battle.fight(b, b.me.creature.moves[1])
  check("drain heals the attacker", b.me.hp > 5)
end

-- Catching
do
  local b = battle.new(creature("A", "flame"), creature("B", "aqua"), always(0.99))
  local healthy = battle.catchChance(b)
  b.foe.hp = 1
  check("weak creatures are easier to catch", battle.catchChance(b) > healthy)
  check("catching is never certain", battle.catchChance(b) <= 0.95)
  local events = battle.throwBall(b)
  check("a high roll breaks free", not b.over or b.result == "lost")
  check("breaking free is announced", events[2].escaped == true)
  check("the wild creature hits back", b.me.hp < b.me.maxHp)
end
do
  local b = battle.new(creature("A", "flame"), creature("B", "aqua"), always(0.01))
  battle.throwBall(b)
  check("a low roll catches it", b.over and b.result == "caught")
end

-- Levels
do
  local c = creature("A", "flame")
  c.level = 49
  check("levels up", battle.levelUp(c) and c.level == 50)
  check("stops at the cap", not battle.levelUp(c) and c.level == 50)
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
