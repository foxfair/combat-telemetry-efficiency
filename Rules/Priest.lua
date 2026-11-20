local _, NS = ...

local format = string.format

local PriestRules = {
    class = "PRIEST",
    shadowFillers = {
        ["Mind Flay"] = true,
        ["Smite"] = true,
        ["Mind Blast"] = true,
    },
    heals = {
        ["Flash Heal"] = true,
        ["Greater Heal"] = true,
        ["Heal"] = true,
    },
}

function PriestRules:EvaluateEvent(ctx)
    local ev = ctx.ev
    local spell = ev.spellName or ""
    local pool = ctx.poolBefore or 0
    local history = ctx.history
    local dur = ctx.fightDuration or 0

    -- 1. Shadow Word: Pain maintenance check during DPS casts
    if self.shadowFillers[spell] and history["Shadow Word: Pain"] and #history["Shadow Word: Pain"] > 0 then
        local swpList = history["Shadow Word: Pain"]
        local lastSWP = nil
        for i = 1, #swpList do
            if swpList[i] < (ev.t or 0) then
                lastSWP = swpList[i]
            end
        end
        if lastSWP then
            local elapsed = (ev.t or 0) - lastSWP
            if elapsed > 18.0 and (dur - (ev.t or 0)) >= 8.0 then
                return NS.RuleRegistry:MakeSuggestion(
                    "Shadow Word: Pain",
                    589,
                    "DROPPED_MAINT",
                    0,
                    format("Shadow Word: Pain expired (%.1fs elapsed) — refresh SW:P before %s", elapsed, spell)
                )
            elseif spell == "Shadow Word: Pain" and elapsed < 12.0 then
                return NS.RuleRegistry:MakeSuggestion(
                    "Mind Flay",
                    15407,
                    "CLIPPED_UPTIME",
                    0,
                    format("Re-cast Shadow Word: Pain early after %.1fs (%.1fs remaining) — wasted Mana & GCD", elapsed, 18.0 - elapsed)
                )
            end
        end
    end

    -- 2. Mind Blast priority over Mind Flay when off 8s CD
    if spell == "Mind Flay" and history["Mind Blast"] and #history["Mind Blast"] > 0 then
        local mbReady = NS.RuleRegistry:WasSpellReadyAt(history, "Mind Blast", ev.t or 0, 8.0, dur)
        if mbReady and pool >= 260 then
            return NS.RuleRegistry:MakeSuggestion(
                "Mind Blast",
                8092,
                "HIGHER_PRIORITY_READY",
                0,
                "Mind Blast was off CD — weave Mind Blast before channeling Mind Flay"
            )
        end
    end

    -- 3. Inner Focus suggestion before expensive Greater Heal / Prayer of Healing
    if (spell == "Greater Heal" or spell == "Prayer of Healing") and history["Inner Focus"] and #history["Inner Focus"] > 0 then
        local ifReady = NS.RuleRegistry:WasSpellReadyAt(history, "Inner Focus", ev.t or 0, 180.0, dur)
        if ifReady then
            return NS.RuleRegistry:MakeSuggestion(
                "Inner Focus",
                14751,
                "CD_READY",
                0,
                format("Inner Focus was available — pair with %s for 0 Mana cost & +25%% crit", spell)
            )
        end
    end

    return nil
end

if NS.RuleRegistry then
    NS.RuleRegistry:RegisterClass("PRIEST", PriestRules)
end
