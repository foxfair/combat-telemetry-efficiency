local _, NS = ...

local format = string.format

local GenericRules = {
    class = "GENERIC",
}

function GenericRules:EvaluateEvent(ctx)
    local ev = ctx.ev
    local spell = ev.spellName or ""
    local pool = ctx.poolBefore or 0
    local maxPool = ctx.poolMax or 100
    local nextEv = ctx.nextEv

    -- Generic Wait-vs-Spend check: if the player cast a low-cost filler (< 15% pool)
    -- and then immediately ran out of resource (FAILED_RESOURCE) on a stronger spell within 1.5s
    if nextEv and nextEv.outcome == "FAILED_RESOURCE" and (nextEv.t - (ev.t or 0)) <= 1.5 then
        local costA = ev.spellCost or 0
        local costB = nextEv.spellCost or 0
        if costA > 0 and costB > costA and pool < (costA + costB) then
            return NS.RuleRegistry:MakeSuggestion(
                nextEv.spellName or "Higher-Cost Ability",
                nextEv.spellID or 0,
                "WAIT_FOR_THRESHOLD",
                max(0.5, (nextEv.t - (ev.t or 0))),
                format(
                    "Spent %d on %s right before %s (%d cost) — waiting briefly would afford %s",
                    costA,
                    spell,
                    nextEv.spellName or "next skill",
                    costB,
                    nextEv.spellName or "it"
                )
            )
        end
    end

    return nil
end

if NS.RuleRegistry then
    NS.RuleRegistry:RegisterClass("GENERIC", GenericRules)
end
