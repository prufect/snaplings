-- Particle effect tests. Run with: luajit game/tests/test_fx.lua from the project folder.
package.path = "game/snaplings/?.lua;" .. package.path
local fx = require("fx")
local rules = require("rules")
local creature = require("creature")

local failed, passed = 0, 0
local function check(name, condition)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. name)
  end
end

local A, B = {x = 150, y = 265}, {x = 490, y = 125}

-- Parsing
local spec = fx.parse("star|spiral|#ff0000|#00ff00")
check("reads a valid look", spec and spec.shape == "star" and spec.motion == "spiral" and spec.color2 == "#00ff00")
check("round trips", fx.serialize(spec) == "star|spiral|#ff0000|#00ff00")
check("rejects unknown shapes", fx.parse("laser|spiral|#ff0000|#00ff00") == nil)
check("rejects unknown motions", fx.parse("star|teleport|#ff0000|#00ff00") == nil)
check("rejects bad colors", fx.parse("star|spiral|red|#00ff00") == nil)
check("rejects missing parts", fx.parse("star|spiral") == nil)
check("handles nothing", fx.parse(nil) == nil)

-- Defaults
check("a move's own look wins", fx.lookFor({type = "flame", fx = spec}) == spec)
check("types have defaults", fx.lookFor({type = "aqua"}).shape == "bubble")
check("unknown types still work", fx.lookFor({type = "nope"}).shape ~= nil)

-- Every motion and kind runs, stays capped and cleans up
local moved = {kind = "heavy", type = "flame", name = "x"}
for motion in pairs(fx.MOTIONS) do
  fx.clear()
  moved.fx = {shape = "spark", motion = motion, color1 = "#ff0000", color2 = "#00ff00"}
  fx.launch(moved, nil, A, B)
  for _ = 1, 10 do fx.update(0.05) end
  check(motion .. " makes particles", fx.count() > 0)
  check(motion .. " stays capped", fx.count() <= 260)
  for _ = 1, 100 do fx.update(0.05) end
  check(motion .. " cleans up", fx.count() == 0)
end
for _, kind in ipairs({"strike", "heavy", "quick", "drain", "guard", "rally", "hex"}) do
  fx.clear()
  fx.launch({kind = kind, type = "spirit", name = "x"}, nil, A, B)
  for _ = 1, 5 do fx.update(0.05) end
  check(kind .. " has an animation", fx.count() > 0)
end

-- Impacts and heavy flashes
fx.clear()
fx.impact({kind = "strike", type = "aqua"}, B, 0.2)
check("a hit makes particles", fx.count() > 0)
check("normal hits don't flash", fx.flash == nil)
fx.impact({kind = "heavy", type = "aqua"}, B, 0.9)
check("heavy hits flash", fx.flash ~= nil)
for _ = 1, 100 do fx.update(0.05) end
check("flash fades", fx.flash == nil)

-- The amount setting
fx.clear()
fx.setScale(1)
fx.impact({kind = "strike", type = "aqua"}, B, 0.5)
local few = fx.count()
fx.clear()
fx.setScale(5)
fx.impact({kind = "strike", type = "aqua"}, B, 0.5)
check("the effects setting changes the amount", fx.count() > few * 2)
fx.confetti(640)
fx.caught(B)
fx.caught(B)
fx.caught(B)
fx.caught(B)
check("the cap holds at the highest setting", fx.count() <= 260)
fx.setScale(3)
fx.clear()

-- Creature packets carry looks, and older packets still load
local packet = "\137PNG....IEND\174B`\130name=Mug\ntype=flame\nmove=Scald|strike|flame\nmove=Steam|hex|aqua\n" ..
  "fx=1|flame|beam|#ff0000|#ffff00\nfx=2|nonsense|beam|#ff0000|#ffff00\nfx=9|flame|beam|#ff0000|#ffff00\n"
local parsed = creature.parse(packet)
check("a move gets its look", parsed.moves[1].fx and parsed.moves[1].fx.shape == "flame")
check("a bad look falls back", parsed.moves[2].fx == nil)
local older = creature.parse("\137PNG....IEND\174B`\130name=Mug\ntype=flame\nmove=Scald|strike|flame\n")
check("older creatures still load", older and older.moves[1].fx == nil)

-- Voice can change looks and the amount
do
  local r, history = rules.defaults(), {}
  local lead = {name = "Mug", type = "flame", moves = {{name = "Scald", kind = "strike", type = "flame"}, {name = "Bonk", kind = "heavy", type = "flame"}}}
  rules.apply(r, {leadfx = "Bonk|heart|ring|#ff0000|#ffffff"}, lead, history)
  check("changes the named move", lead.moves[2].fx and lead.moves[2].fx.shape == "heart")
  check("leaves other moves alone", lead.moves[1].fx == nil)
  rules.apply(r, {leadfx = "scald|bolt|ring|#ff0000|#ffffff"}, lead, history)
  check("move names ignore capitals", lead.moves[1].fx and lead.moves[1].fx.shape == "bolt")
  rules.apply(r, {undo = "1"}, lead, history)
  rules.apply(r, {leadfx = "*|star|rain|#ff0000|#ffffff"}, lead, history)
  check("star changes every move", lead.moves[1].fx.shape == "star" and lead.moves[2].fx.shape == "star")
  rules.apply(r, {undo = "1"}, lead, history)
  check("undo restores looks", lead.moves[1].fx == nil and lead.moves[2].fx.shape == "heart")
  local before = lead.moves[2].fx.shape
  rules.apply(r, {leadfx = "Bonk|laser|ring|#ff0000|#ffffff"}, lead, history)
  check("rejects a bad look", lead.moves[2].fx.shape == before)
  rules.apply(r, {leadfx = "Nothing|star|rain|#ff0000|#ffffff"}, lead, history)
  check("an unknown move changes nothing", lead.moves[1].fx == nil)
  rules.apply(r, {effects = "2"}, nil, history)
  check("raises the amount", r.effects == 5)
  rules.apply(r, {effects = "-9"}, nil, history)
  check("the amount stays in range", r.effects == 1)
  check("the amount is saved", rules.deserialize(rules.serialize(r)).effects == 1)
end

-- Undoing a redraw hands back the old art
do
  local r, history = rules.defaults(), {}
  local who = {name = "Mug"}
  rules.rememberArt(r, history, who, "old png")
  r.theme = "lava"
  local _, undone, snapshot = rules.apply(r, {undo = "1"}, nil, history)
  check("undo finds the art", undone and snapshot.art.creature == who and snapshot.art.png == "old png")
  check("undo restores rules too", r.theme == "night")
  for _ = 1, 15 do rules.rememberArt(r, history, who, "x") end
  check("art undo history is capped", #history == 10)
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
