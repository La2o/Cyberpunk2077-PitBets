-- Pure math: no game calls, so this file can be unit-tested outside the game.
local Odds = {}

Odds.EDGE = 0.08        -- house cut
Odds.SHARPNESS = 1.6    -- how strongly rating gaps turn into favourites
Odds.MAX_PROB = 0.9     -- no fight is a lock; also keeps favourites paying > 1x

-- Chance that a fighter rated rA beats one rated rB.
function Odds.winProbability(rA, rB, k)
  k = k or Odds.SHARPNESS
  local a = math.max(rA or 1, 1) ^ k
  local b = math.max(rB or 1, 1) ^ k
  local p = a / (a + b)
  return math.max(1 - Odds.MAX_PROB, math.min(Odds.MAX_PROB, p))
end

-- Decimal payout multiplier (stake included) after the house edge.
-- Rounded down so the house edge never rounds away.
function Odds.payoutMultiplier(p, edge)
  edge = edge or Odds.EDGE
  local m = (1 - edge) / math.max(p, 0.01)
  return math.floor(m * 100 + 1e-9) / 100
end

-- Both corners' probabilities and multipliers for a matchup.
function Odds.book(rA, rB)
  local pA = Odds.winProbability(rA, rB)
  local pB = 1 - pA
  return { pA, pB }, { Odds.payoutMultiplier(pA), Odds.payoutMultiplier(pB) }
end

-- Chance a bookie notices a sabotage act. acts = acts already committed this fight.
function Odds.detectionChance(base, acts, extra)
  local c = (base or 0) + 0.12 * (acts or 0) + (extra or 0)
  if c < 0 then c = 0 end
  if c > 0.9 then c = 0.9 end
  return c
end

-- What a settled bet pays back (0 for a loss). winner: 1, 2, or 0 for a draw.
function Odds.settle(bet, winner)
  if not bet or bet.void then return 0 end
  if winner == 0 then return bet.stake end
  if winner == bet.side then return math.floor(bet.stake * bet.mult) end
  return 0
end

return Odds
