local _, NS = ...

local format = string.format

local RogueRules = {
    class = "ROGUE",
    builders = {
        ["Sinister Strike"] = true,
        ["Backstab"] = true,
        ["Hemorrhage"] = true,
        ["Gouge"] = true,
    },
    damageFinishers = {
        ["Eviscerate"] = 2098,
        ["Rupture"] = 1943,
    },
}

function RogueRules:EvaluateEvent(ctx)
    local ev = ctx.ev
    local spell = ev.spellName or ""
    local pool = ctx.poolBefore or 0
    local cp = ev.secondaryBefore or 0
    local history = ctx.history
    local dur = ctx.fightDuration or 0

    -- 1. Overcapping Combo Points: using a builder at 5 CP
    if self.builders[spell] and cp >= 5 then
        local bestFin = (history["Slice and Dice"] and #history["Slice and Dice"] > 0) and "Slice and Dice / Eviscerate" or "Eviscerate"
        return NS.RuleRegistry:MakeSuggestion(
            bestFin,
            2098,
            "CAPPED_COMBO_POINTS",
            0,
            format("Cast %s while already at 5 Combo Points — spend a finisher first", spell)
        )
    end

    -- 2. Low-CP Damage Finisher when fight still has >= 5s left
    if self.damageFinishers[spell] and cp > 0 and cp <= 2 and (dur - (ev.t or 0)) >= 5.0 then
        return NS.RuleRegistry:MakeSuggestion(
            "Sinister Strike / Backstab",
            1752,
            "LOW_CP_FINISHER",
            0,
            format("Spent %s at %d CP with %.1fs remaining — pool to 4–5 CP for higher DPET", spell, cp, dur - (ev.t or 0))
        )
    end

    -- 3. Slice and Dice maintenance check (if Rogue uses SnD in the fight)
    if self.builders[spell] and cp >= 1 and history["Slice and Dice"] and #history["Slice and Dice"] > 0 then
        local sndList = history["Slice and Dice"]
        local lastSnD = nil
        for i = 1, #sndList do
            if sndList[i] < (ev.t or 0) then
                lastSnD = sndList[i]
            end
        end
        if lastSnD and ((ev.t or 0) - lastSnD) > 21.0 and (dur - (ev.t or 0)) >= 8.0 then
            return NS.RuleRegistry:MakeSuggestion(
                "Slice and Dice",
                5171,
                "DROPPED_MAINT",
                0,
                format("Slice and Dice lapsed (%.1fs since last refresh) — refresh SnD before %s", (ev.t or 0) - lastSnD, spell)
            )
        end
    end

    -- 4. Energy overcap risk on Adrenaline Rush / Blade Flurry
    if self.builders[spell] and pool >= 85 and history["Blade Flurry"] and #history["Blade Flurry"] > 0 then
        local bfReady = NS.RuleRegistry:WasSpellReadyAt(history, "Blade Flurry", ev.t or 0, 120.0, dur)
        if bfReady and (dur - (ev.t or 0)) >= 10.0 then
            return NS.RuleRegistry:MakeSuggestion(
                "Blade Flurry",
                13877,
                "CD_READY",
                0,
                "Blade Flurry was off CD with high Energy — activate Blade Flurry early"
            )
        end
    end

    return nil
end

if NS.RuleRegistry then
    NS.RuleRegistry:RegisterClass("ROGUE", RogueRules)
end
