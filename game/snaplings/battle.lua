-- Battle rules. Pure Lua with no LÖVE calls, so tests can run it anywhere.
-- Code owns every number: the server only picks names, types, 1-5 stat ranks and move kinds.
local M = {}

M.TYPES = {"flame", "aqua", "leaf", "spark", "stone", "spirit"}

local STRONG = {
  flame = {leaf = true, spirit = true},
  aqua = {flame = true, stone = true},
  leaf = {aqua = true, spark = true},
  spark = {aqua = true, spirit = true},
  stone = {spark = true, flame = true},
  spirit = {leaf = true, stone = true},
}

-- power 0 means a status move. Stages run from -3 to +3.
M.KINDS = {
  strike = {power = 50, accuracy = 1.0},
  heavy = {power = 85, accuracy = 0.75},
  quick = {power = 40, accuracy = 1.0, first = true},
  drain = {power = 40, accuracy = 1.0, drain = 0.5},
  guard = {power = 0, accuracy = 1.0, self = "defense", stage = 1},
  rally = {power = 0, accuracy = 1.0, self = "attack", stage = 1},
  hex = {power = 0, accuracy = 0.9, foe = "attack", stage = -1},
}

M.MAX_LEVEL = 50

function M.effectiveness(moveType, targetType)
  if STRONG[moveType] and STRONG[moveType][targetType] then return 2 end
  if STRONG[targetType] and STRONG[targetType][moveType] then return 0.5 end
  return 1
end

local function clampRank(rank)
  return math.max(1, math.min(5, math.floor(tonumber(rank) or 3)))
end

-- Turns a creature's ranks and level into battle numbers.
function M.stats(creature)
  local level = creature.level or 5
  return {
    hp = 20 + clampRank(creature.hp) * 6 + level * 3,
    attack = 6 + clampRank(creature.attack) * 3 + level,
    defense = 6 + clampRank(creature.defense) * 3 + level,
    speed = 6 + clampRank(creature.speed) * 3 + level,
  }
end

local function fighter(creature)
  local s = M.stats(creature)
  return {creature = creature, hp = s.hp, maxHp = s.hp, attack = s.attack, defense = s.defense,
    speed = s.speed, stages = {attack = 0, defense = 0}}
end

-- random() returns 0..1. Tests pass their own to make turns repeatable.
-- powers holds the voice settings: me and foe damage multipliers, and catch, a bonus chance.
function M.new(mine, wild, random, powers)
  return {me = fighter(mine), foe = fighter(wild), random = random or math.random, over = false,
    powers = powers or {me = 1, foe = 1, catch = 0}}
end

local function stageMultiplier(stage)
  return stage >= 0 and (2 + stage) / 2 or 2 / (2 - stage)
end

function M.damage(battle, attacker, target, move)
  local kind = M.KINDS[move.kind]
  local level = attacker.creature.level or 5
  local attack = attacker.attack * stageMultiplier(attacker.stages.attack)
  local defense = target.defense * stageMultiplier(target.stages.defense)
  local base = ((2 * level / 5 + 2) * kind.power * attack / defense) / 25 + 2
  local same = move.type == attacker.creature.type and 1.25 or 1
  local type = M.effectiveness(move.type, target.creature.type)
  local roll = 0.85 + battle.random() * 0.15
  local power = attacker == battle.me and battle.powers.me or battle.powers.foe * (battle.foeStrength or 1)
  return math.max(1, math.floor(base * same * type * roll * power)), type
end

-- How much shaking the paddle takes to reach full strength, in the bridge's tenths.
M.SHAKE_FOR_FULL = 200
M.WEAKEST, M.STRONGEST = 0.75, 1.5

-- Turns the paddle's shaking into a multiplier on the second player's damage.
function M.shakeStrength(tenths)
  local amount = math.max(0, math.min(1, (tenths or 0) / M.SHAKE_FOR_FULL))
  return M.WEAKEST + (M.STRONGEST - M.WEAKEST) * amount
end

local function changeStage(fighterTable, stat, by)
  local before = fighterTable.stages[stat]
  fighterTable.stages[stat] = math.max(-3, math.min(3, before + by))
  return fighterTable.stages[stat] ~= before
end

local function useMove(battle, attacker, target, move, events)
  local kind = M.KINDS[move.kind]
  local who = attacker.creature.name
  events[#events + 1] = {text = who .. " used " .. move.name .. "!", move = move, from = attacker, to = target}
  if battle.random() > kind.accuracy then
    events[#events + 1] = {text = "It missed!", missed = move, to = target}
    return
  end
  if kind.power > 0 then
    local amount, type = M.damage(battle, attacker, target, move)
    target.hp = math.max(0, target.hp - amount)
    events[#events + 1] = {hit = target, amount = amount, type = move.type, move = move}
    if type > 1 then events[#events + 1] = {text = "Super effective!"} end
    if type < 1 then events[#events + 1] = {text = "Not very effective..."} end
    if kind.drain then
      attacker.hp = math.min(attacker.maxHp, attacker.hp + math.ceil(amount * kind.drain))
      events[#events + 1] = {text = who .. " drained some energy.", drained = move, from = target, to = attacker}
    end
  elseif kind.self then
    local raised = changeStage(attacker, kind.self, kind.stage)
    events[#events + 1] = {text = raised and (who .. "'s " .. kind.self .. " rose!") or "Nothing happened."}
  else
    local lowered = changeStage(target, kind.foe, kind.stage)
    events[#events + 1] = {text = lowered and (target.creature.name .. "'s " .. kind.foe .. " fell!") or "Nothing happened."}
  end
end

local function checkFaint(battle, events)
  if battle.foe.hp <= 0 then
    battle.over, battle.result = true, "won"
    events[#events + 1] = {text = battle.foe.creature.name .. " fainted!", fainted = battle.foe}
  elseif battle.me.hp <= 0 then
    battle.over, battle.result = true, "lost"
    events[#events + 1] = {text = battle.me.creature.name .. " fainted!", fainted = battle.me}
  end
  return battle.over
end

-- Wild creatures favor moves that would hurt most, with some randomness.
function M.chooseFoeMove(battle)
  local moves = battle.foe.creature.moves
  local best, bestScore = moves[1], -1
  for _, move in ipairs(moves) do
    local kind = M.KINDS[move.kind]
    local score = kind.power * M.effectiveness(move.type, battle.me.creature.type) * kind.accuracy
    if kind.power == 0 then score = 25 end
    score = score * (0.5 + battle.random())
    if score > bestScore then best, bestScore = move, score end
  end
  return best
end

local function goesFirst(battle, move, foeMove)
  local mine = M.KINDS[move.kind].first and 1 or 0
  local theirs = M.KINDS[foeMove.kind].first and 1 or 0
  if mine ~= theirs then return mine > theirs end
  return battle.me.speed >= battle.foe.speed
end

-- Plays one turn with the player's chosen move and returns the events to show.
-- second is what a second player did with the paddle: {move = a foe move or nil, strength = a multiplier}.
function M.fight(battle, move, second)
  local events = {}
  local foeMove = second and second.move or M.chooseFoeMove(battle)
  battle.foeStrength = second and second.strength or 1
  local first, firstMove, second, secondMove = battle.me, move, battle.foe, foeMove
  if not goesFirst(battle, move, foeMove) then
    first, firstMove, second, secondMove = battle.foe, foeMove, battle.me, move
  end
  useMove(battle, first, second, firstMove, events)
  if not checkFaint(battle, events) then
    useMove(battle, second, first, secondMove, events)
    checkFaint(battle, events)
  end
  return events
end

-- A healthy creature is hard to catch; a nearly fainted one is easy.
function M.catchChance(battle)
  local missing = 1 - battle.foe.hp / battle.foe.maxHp
  return math.max(0.05, math.min(0.95, 0.15 + missing * 0.8 + battle.powers.catch))
end

-- Throwing costs a turn: the wild creature hits back if it breaks free.
function M.throwBall(battle, second)
  local events = {{text = "You threw a ball!", ball = true}}
  battle.foeStrength = second and second.strength or 1
  if battle.random() < M.catchChance(battle) then
    battle.over, battle.result = true, "caught"
    events[#events + 1] = {text = "Gotcha! " .. battle.foe.creature.name .. " was caught!", caught = true}
    return events
  end
  events[#events + 1] = {text = battle.foe.creature.name .. " broke free!", escaped = true}
  useMove(battle, battle.foe, battle.me, second and second.move or M.chooseFoeMove(battle), events)
  checkFaint(battle, events)
  return events
end

function M.run(battle)
  battle.over, battle.result = true, "ran"
  return {{text = "You got away safely."}}
end

function M.levelUp(creature)
  if (creature.level or 5) >= M.MAX_LEVEL then return false end
  creature.level = (creature.level or 5) + 1
  return true
end

return M
