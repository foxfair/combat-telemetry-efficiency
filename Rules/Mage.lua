local _, NS = ...

local format = string.format

local MageRules = {
    class = "MAGE",
    nukes = {
        ["Frostbolt"] = true,
        ["Fireball"] = true,
        ["Scorch"] = true,
        ["Arcane Missiles"] = true,
    },
    instants = {
        { name = "Fire Blast", id = 2136, cd = 8.0, cost = 115 },
    },
}

function MageRules:EvaluateEvent(ctx)
    local ev = ctx.ev
    local spell = ev.spellName or ""
    local pool = ctx.poolBefore or 0
    local history = ctx.history
    local dur = ctx.fightDuration or 0

    -- 1. Fire Scorch maintenance check (if player uses Scorch in rotation)
    if (spell == "Fireball" or spell == "Pyroblast") and history["Scorch"] and #history["Scorch"] > 0 then
        local scList = history["Scorch"]
        local lastSC = nil
        for i = 1, #scList do
            if scList[i] < (ev.t or 0) then
                lastSC = scList[i]
            end
        end
        if lastSC and ((ev.t or 0) - lastSC) > 26.0 and (dur - (ev.t or 0)) >= 8.0 then
            return NS.RuleRegistry:MakeSuggestion(
                "Scorch",
                2948,
                "DROPPED_MAINT",
                0,
                format("Improved Scorch window nearing expiry (%.1fs since last Scorch) — weave Scorch before %s", (ev.t or 0) - lastSC, spell)
            )
        end
    end

    -- 2. Presence of Mind / Arcane Power cooldown pairing before Pyroblast or Frostbolt/Fireball
    if (spell == "Pyroblast" or spell == "Fireball" or spell == "Frostbolt") then
        if history["Presence of Mind"] and #history["Presence of Mind"] > 0 then
            local pomReady = NS.RuleRegistry:WasSpellReadyAt(history, "Presence of Mind", ev.t or 0, 180.0, dur)
            if pomReady then
                return NS.RuleRegistry:MakeSuggestion(
                    "Presence of Mind",
                    12043,
                    "CD_READY",
                    0,
                    format("Presence of Mind was ready — pair with %s for an instant cast", spell)
                )
            end
        end
    end

    -- 3. Evocation / Mana Gem reminder if casting low-efficiency filler while deeply OOM
    if self.nukes[spell] and pool > 0 and pool < 350 and history["Evocation"] and #history["Evocation"] > 0 then
        local evoReady = NS.RuleRegistry:WasSpellReadyAt(history, "Evocation", ev.t or 0, 480.0, dur)
        if evoReady and (dur - (ev.t or 0)) >= 10.0 then
            return NS.RuleRegistry:MakeSuggestion(
                "Evocation",
                12051,
                "CD_READY",
                0,
                "Low Mana (~<350) with Evocation off CD — channel Evocation to sustain DPS"
            )
        end
    end

    return nil
end

if NS.RuleRegistry then
    NS.RuleRegistry:RegisterClass("MAGE", MageRules)
end
