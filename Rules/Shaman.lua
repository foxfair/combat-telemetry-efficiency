local _, NS = ...

local format = string.format

local ShamanRules = {
    class = "SHAMAN",
    signatures = {
        { name = "Stormstrike", id = 17364, cd = 20.0, cost = 100 },
        { name = "Earth Shock", id = 8042,  cd = 6.0,  cost = 80 },
    },
    fillers = {
        ["Lightning Bolt"] = true,
        ["Chain Lightning"] = true,
    },
}

function ShamanRules:EvaluateEvent(ctx)
    local ev = ctx.ev
    local spell = ev.spellName or ""
    local pool = ctx.poolBefore or 0
    local history = ctx.history
    local dur = ctx.fightDuration or 0

    -- 1. Flame Shock maintenance check when casting Lightning Bolt / Earth Shock
    if (self.fillers[spell] or spell == "Earth Shock") and history["Flame Shock"] and #history["Flame Shock"] > 0 then
        local fsList = history["Flame Shock"]
        local lastFS = nil
        for i = 1, #fsList do
            if fsList[i] < (ev.t or 0) then
                lastFS = fsList[i]
            end
        end
        if lastFS then
            local elapsed = (ev.t or 0) - lastFS
            if elapsed > 12.5 and (dur - (ev.t or 0)) >= 8.0 then
                return NS.RuleRegistry:MakeSuggestion(
                    "Flame Shock",
                    8050,
                    "DROPPED_MAINT",
                    0,
                    format("Flame Shock expired (%.1fs elapsed) — refresh Flame Shock before %s", elapsed, spell)
                )
            end
        end
    end

    -- 2. Stormstrike priority for Enhancement Shaman
    if (spell == "Earth Shock" or spell == "Flame Shock") and history["Stormstrike"] and #history["Stormstrike"] > 0 then
        local ssReady = NS.RuleRegistry:WasSpellReadyAt(history, "Stormstrike", ev.t or 0, 20.0, dur)
        if ssReady and pool >= 100 then
            return NS.RuleRegistry:MakeSuggestion(
                "Stormstrike",
                17364,
                "HIGHER_PRIORITY_READY",
                0,
                format("Stormstrike was off CD — weave Stormstrike before %s to amplify Nature damage", spell)
            )
        end
    end

    -- 3. Elemental Mastery cooldown check before Chain Lightning / Lightning Bolt
    if self.fillers[spell] and history["Elemental Mastery"] and #history["Elemental Mastery"] > 0 then
        local emReady = NS.RuleRegistry:WasSpellReadyAt(history, "Elemental Mastery", ev.t or 0, 180.0, dur)
        if emReady then
            return NS.RuleRegistry:MakeSuggestion(
                "Elemental Mastery",
                16166,
                "CD_READY",
                0,
                format("Elemental Mastery was off CD — activate before %s for guaranteed crit & 0 Mana cost", spell)
            )
        end
    end

    return nil
end

if NS.RuleRegistry then
    NS.RuleRegistry:RegisterClass("SHAMAN", ShamanRules)
end
