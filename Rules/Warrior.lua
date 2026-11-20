local _, NS = ...

local format = string.format

local WarriorRules = {
    class = "WARRIOR",
    signatures = {
        { name = "Mortal Strike", id = 12294, cd = 6.0, cost = 30 },
        { name = "Bloodthirst",   id = 23881, cd = 6.0, cost = 30 },
        { name = "Shield Slam",   id = 23922, cd = 6.0, cost = 20 },
        { name = "Whirlwind",     id = 1680,  cd = 10.0, cost = 25 },
        { name = "Overpower",     id = 7384,  cd = 5.0, cost = 5 },
    },
    fillers = {
        ["Heroic Strike"] = true,
        ["Cleave"] = true,
        ["Sunder Armor"] = true,
        ["Hamstring"] = true,
    },
}

function WarriorRules:EvaluateEvent(ctx)
    local ev = ctx.ev
    local spell = ev.spellName or ""
    local pool = ctx.poolBefore or 0
    local history = ctx.history
    local dur = ctx.fightDuration or 0

    -- Only evaluate rotational fillers/dumps
    if not self.fillers[spell] then
        return nil
    end

    -- Check if player actually used a signature ability during this fight (identifies spec/stance)
    for i = 1, #self.signatures do
        local sig = self.signatures[i]
        if history[sig.name] and #history[sig.name] > 0 then
            local isReady, _, remCD = NS.RuleRegistry:WasSpellReadyAt(history, sig.name, ev.t or 0, sig.cd, dur)
            if isReady and pool >= sig.cost then
                return NS.RuleRegistry:MakeSuggestion(
                    sig.name,
                    sig.id,
                    "HIGHER_PRIORITY_READY",
                    0,
                    format("%s was off CD (%d Rage available) — prioritize %s over %s", sig.name, sig.cost, sig.name, spell)
                )
            elseif isReady and pool < sig.cost and (sig.cost - pool) <= 12 then
                return NS.RuleRegistry:MakeSuggestion(
                    sig.name,
                    sig.id,
                    "WAIT_FOR_THRESHOLD",
                    1.2,
                    format("Dumped Rage on %s (~%d Rage) right before %s (%d Rage) — hold 1 GCD", spell, pool, sig.name, sig.cost)
                )
            elseif (not isReady) and remCD and remCD <= 1.3 and pool < (sig.cost + (ev.spellCost or 15)) then
                return NS.RuleRegistry:MakeSuggestion(
                    sig.name,
                    sig.id,
                    "WAIT_FOR_THRESHOLD",
                    remCD,
                    format("Spent %s %.1fs before %s came off CD — starving next signature window", spell, remCD, sig.name)
                )
            end
        end
    end

    return nil
end

if NS.RuleRegistry then
    NS.RuleRegistry:RegisterClass("WARRIOR", WarriorRules)
end
