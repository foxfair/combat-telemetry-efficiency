local _, NS = ...

local format = string.format

local DruidRules = {
    class = "DRUID",
    catFinishers = {
        ["Ferocious Bite"] = 22568,
        ["Rip"] = 1079,
    },
    catBuilders = {
        ["Claw"] = true,
        ["Shred"] = true,
        ["Rake"] = true,
    },
    bearFillers = {
        ["Maul"] = true,
        ["Swipe"] = true,
    },
    balanceFillers = {
        ["Wrath"] = true,
        ["Starfire"] = true,
    },
}

function DruidRules:EvaluateEvent(ctx)
    local ev = ctx.ev
    local spell = ev.spellName or ""
    local form = ev.druidForm or ""
    local pool = ctx.poolBefore or 0
    local cp = ev.secondaryBefore or 0
    local history = ctx.history
    local dur = ctx.fightDuration or 0

    -- 1. Cat Form checks
    if form == "CAT" or self.catFinishers[spell] or self.catBuilders[spell] then
        if self.catFinishers[spell] and cp > 0 and cp <= 2 and (dur - (ev.t or 0)) >= 4.0 then
            return NS.RuleRegistry:MakeSuggestion(
                "Shred / Claw",
                5221,
                "LOW_CP_FINISHER",
                0,
                format("Spent %s at %d CP with %.1fs left — build to 4–5 CP first", spell, cp, dur - (ev.t or 0))
            )
        end

        if self.catBuilders[spell] and cp >= 5 then
            return NS.RuleRegistry:MakeSuggestion(
                "Ferocious Bite",
                22568,
                "CAPPED_COMBO_POINTS",
                0,
                format("Cast %s while already at 5 Combo Points — spend finisher first", spell)
            )
        end

        if spell == "Claw" and history["Tiger's Fury"] and #history["Tiger's Fury"] > 0 then
            local tfReady = NS.RuleRegistry:WasSpellReadyAt(history, "Tiger's Fury", ev.t or 0, 6.0, dur)
            if tfReady and pool >= 85 then
                return NS.RuleRegistry:MakeSuggestion(
                    "Tiger's Fury",
                    5217,
                    "OVERCAP_RISK",
                    0,
                    "Energy near cap (~85+) — weave Tiger's Fury before dumping Claw"
                )
            end
        end
    end

    -- 2. Bear Form checks
    if form == "BEAR" or self.bearFillers[spell] then
        if self.bearFillers[spell] and history["Mangle (Bear)"] and #history["Mangle (Bear)"] > 0 then
            local mReady = NS.RuleRegistry:WasSpellReadyAt(history, "Mangle (Bear)", ev.t or 0, 6.0, dur)
            if mReady and pool >= 20 then
                return NS.RuleRegistry:MakeSuggestion(
                    "Mangle (Bear)",
                    33878,
                    "HIGHER_PRIORITY_READY",
                    0,
                    format("Mangle (Bear) was ready — prioritize over %s", spell)
                )
            end
        end
    end

    -- 3. Balance / Caster Form checks
    if self.balanceFillers[spell] and history["Moonfire"] and #history["Moonfire"] > 0 then
        local mfList = history["Moonfire"]
        local lastMF = nil
        for i = 1, #mfList do
            if mfList[i] < (ev.t or 0) then
                lastMF = mfList[i]
            end
        end
        if lastMF and ((ev.t or 0) - lastMF) > 12.5 and (dur - (ev.t or 0)) >= 6.0 then
            return NS.RuleRegistry:MakeSuggestion(
                "Moonfire",
                8921,
                "DROPPED_MAINT",
                0,
                format("Moonfire DoT lapsed (%.1fs since last cast) — refresh DoT before %s", (ev.t or 0) - lastMF, spell)
            )
        end
    end

    return nil
end

if NS.RuleRegistry then
    NS.RuleRegistry:RegisterClass("DRUID", DruidRules)
end
