local _, NS = ...

local format = string.format

local WarlockRules = {
    class = "WARLOCK",
    fillers = {
        ["Shadow Bolt"] = true,
        ["Drain Life"] = true,
        ["Searing Pain"] = true,
    },
    dots = {
        { name = "Corruption",     id = 172,   dur = 18.0, clipLimit = 12.0 },
        { name = "Curse of Agony", id = 980,   dur = 24.0, clipLimit = 16.0 },
        { name = "Immolate",       id = 348,   dur = 15.0, clipLimit = 10.0 },
    },
}

function WarlockRules:EvaluateEvent(ctx)
    local ev = ctx.ev
    local spell = ev.spellName or ""
    local pool = ctx.poolBefore or 0
    local maxPool = ctx.poolMax or 100
    local history = ctx.history
    local dur = ctx.fightDuration or 0

    -- 1. Check DoT early clipping & dropped maintenance
    for i = 1, #self.dots do
        local dot = self.dots[i]
        local dList = history[dot.name]
        if dList and #dList > 0 then
            local lastCast = nil
            for j = 1, #dList do
                if dList[j] < (ev.t or 0) then
                    lastCast = dList[j]
                end
            end
            if lastCast then
                local elapsed = (ev.t or 0) - lastCast
                if spell == dot.name and elapsed < dot.clipLimit then
                    return NS.RuleRegistry:MakeSuggestion(
                        "Shadow Bolt",
                        686,
                        "CLIPPED_UPTIME",
                        0,
                        format("Re-cast %s early after %.1fs (%.1fs remaining) — let final ticks finish", dot.name, elapsed, dot.dur - elapsed)
                    )
                elseif self.fillers[spell] and elapsed > (dot.dur + 1.0) and (dur - (ev.t or 0)) >= 10.0 then
                    return NS.RuleRegistry:MakeSuggestion(
                        dot.name,
                        dot.id,
                        "DROPPED_MAINT",
                        0,
                        format("%s expired (%.1fs elapsed) — refresh DoT before %s", dot.name, elapsed, spell)
                    )
                end
            end
        end
    end

    -- 2. Life Tap overcap check (casting Life Tap when Mana is already >= 85%)
    if spell == "Life Tap" and maxPool > 0 and (pool / maxPool) >= 0.85 then
        return NS.RuleRegistry:MakeSuggestion(
            "Shadow Bolt",
            686,
            "OVERCAP_RISK",
            0,
            format("Used Life Tap at %d%% Mana — risks overcapping Mana pool", math.floor((pool / maxPool) * 100))
        )
    end

    return nil
end

if NS.RuleRegistry then
    NS.RuleRegistry:RegisterClass("WARLOCK", WarlockRules)
end
