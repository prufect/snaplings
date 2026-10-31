-- Voice change tests. Run with: luajit game/tests/test_rules.lua from the project folder.
package.path = "game/snaplings/?.lua;" .. package.path
local battle = require("battle")
local rules = require("rules")

local failed, passed = 0, 0
local function check(name, condition)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. name)
  end
end

local function lead()
  return {name = "Mug", type = "flame", level = 5, hp = 3, attack = 3, defense = 3, speed = 3,
    moves = {{name = "Scald", kind = "strike", type = "flame"}}}
end

-- Parsing
do
  local parsed = rules.parse("say=Done\ntheme=lava\nfoepower=1\n")
  check("reads changes", parsed.say == "Done" and parsed.theme == "lava" and parsed.foepower == "1")
  check("no creature by default", parsed.packet == nil)
  local withCreature = rules.parse("say=Here\n\ncreature\n\137PNG\nbinary=stuff")
  check("splits off a creature", withCreature.packet == "\137PNG\nbinary=stuff")
  check("creature bytes aren't read as changes", withCreature.binary == nil)
  check("keeps the text with a creature", withCreature.say == "Here")
end

-- Applying and limits
do
  local r, history = rules.defaults(), {}
  rules.apply(r, {theme = "lava", music = "fast", foepower = "1"}, nil, history)
  check("changes the theme", r.theme == "lava")
  check("changes the music", r.music == "fast")
  check("adjusts foe power", r.foePower == 4)
  rules.apply(r, {theme = "nonsense", music = "wild", foepower = "99", catch = "-99", foelevel = "99"}, nil, history)
  check("ignores unknown themes", r.theme == "lava")
  check("ignores unknown music", r.music == "fast")
  check("foe power stays in range", r.foePower == 5)
  check("catch stays in range", r.catchEase == 1)
  check("foe level stays in range", r.foeLevel == 5)
  local before = #history
  rules.apply(r, {say = "Nothing to do"}, nil, history)
  check("no change adds no undo step", #history == before)
end

-- Changing the lead
do
  local r, history, c = rules.defaults(), {}, lead()
  local changed = rules.apply(r, {leadname = "Blaze", leadtype = "aqua", leadmove = "Soak|drain|aqua"}, c, history)
  check("renames", c.name == "Blaze")
  check("changes type", c.type == "aqua")
  check("adds a move", #c.moves == 2 and c.moves[2].name == "Soak")
  check("reports the lead changed", changed.lead)
  rules.apply(r, {leadtype = "cosmic", leadmove = "Bad|teleport|aqua"}, c, history)
  check("rejects an unknown type", c.type == "aqua")
  check("rejects an unknown move kind", #c.moves == 2)
  for i = 1, 5 do rules.apply(r, {leadmove = "M" .. i .. "|strike|aqua"}, c, history) end
  check("never more than four moves", #c.moves == 4)
  check("the newest move is kept", c.moves[4].name == "M5")
end

-- Undo
do
  local r, history, c = rules.defaults(), {}, lead()
  rules.apply(r, {theme = "lava", foepower = "2", leadname = "Blaze", leadmove = "Soak|drain|aqua"}, c, history)
  local _, undone = rules.apply(r, {undo = "1"}, c, history)
  check("undo reports success", undone)
  check("undo restores rules", r.theme == "night" and r.foePower == 3)
  check("undo restores the lead", c.name == "Mug" and #c.moves == 1)
  local _, again = rules.apply(r, {undo = "1"}, c, history)
  check("undo with no history reports it", again == false)
  for _ = 1, 15 do rules.apply(r, {foepower = "1"}, nil, history) end
  check("undo history is capped", #history == 10)
end

-- Saving
do
  local r = rules.defaults()
  rules.apply(r, {theme = "snow", music = "off", mypower = "2"}, nil, {})
  local loaded = rules.deserialize(rules.serialize(r))
  check("saved rules reload", loaded.theme == "snow" and loaded.music == "off" and loaded.myPower == 5)
  local bad = rules.deserialize("theme=hacked\nmusic=nope\nunknown=1\n")
  check("bad saved values fall back", bad.theme == "night" and bad.music == "normal" and bad.unknown == nil)
  check("missing save gives defaults", rules.deserialize(nil).theme == "night")
end

-- Effects in battle
do
  local foe = lead()
  local base = battle.new(lead(), foe, function() return 0.5 end)
  local move = {name = "x", kind = "strike", type = "stone"}
  local normal = battle.damage(base, base.me, base.foe, move)
  local strong = battle.new(lead(), foe, function() return 0.5 end, {me = rules.power(5), foe = 1, catch = 0})
  check("my power raises damage", battle.damage(strong, strong.me, strong.foe, move) > normal)
  local weak = battle.new(lead(), foe, function() return 0.5 end, {me = 1, foe = rules.power(1), catch = 0})
  check("foe power lowers its damage", battle.damage(weak, weak.foe, weak.me, move) < normal)
  check("foe power leaves mine alone", battle.damage(weak, weak.me, weak.foe, move) == normal)
  local easy = battle.new(lead(), foe, nil, {me = 1, foe = 1, catch = rules.catchBonus({catchEase = 5})})
  check("catch ease helps", battle.catchChance(easy) > battle.catchChance(base))
  local hard = battle.new(lead(), foe, nil, {me = 1, foe = 1, catch = rules.catchBonus({catchEase = 1})})
  check("catching is never impossible", battle.catchChance(hard) >= 0.05)
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
