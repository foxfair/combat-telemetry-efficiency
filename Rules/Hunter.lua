local _, NS = ...

local format = string.format

local HunterRules = {
    class = "HUNTER",
    signatures = {
        { name = "Aimed Shot",  id = 19434, cd = 6.0, cost = 75 },
        { name = "Multi-Shot",  id = 2643,  cd = 10.0, cost = 100 },
    },
    fillers = {
        ["Arcane Shot"] = true,
        ["Steady Shot"] = true,
    },
    stings = {
        { name = "Serpent Sting", id = 1978, dur = 15.0 },
    },
}

function HunterRules:EvaluateEvent(ctx)
    local ev = ctx.ev
    local spell = ev.spellName or ""
    local pool = ctx.poolBefore or 0
    local history = ctx.history
    local dur = ctx.fightDuration or 0

    -- 1. Prioritize Aimed Shot / Multi-Shot over Arcane Shot when off CD
    if self.fillers[spell] then
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
                        format("%s was off CD (%d Mana available) — prioritize %s over %s", sig.name, sig.cost, sig.name, spell)
                    )
                elseif (not isReady) and remCD and remCD <= 1.2 and spell == "Arcane Shot" then
                    return NS.RuleRegistry:MakeSuggestion(
                        sig.name,
                        sig.id,
                        "WAIT_FOR_THRESHOLD",
                        remCD,
                        format("Cast Arcane Shot %.1fs before %s came off CD — shares cooldown/weave window", remCD, sig.name)
                    )
                end
            end
        end
    end

    -- 2. Serpent Sting maintenance & early clipping check
    if history["Serpent Sting"] and #history["Serpent Sting"] > 0 then
        local ssList = history["Serpent Sting"]
        local lastSS = nil
        for i = 1, #ssList do
            if ssList[i] < (ev.t or 0) then
                lastSS = ssList[i]
            end
        end
        if lastSS then
            local elapsed = (ev.t or 0) - lastSS
            if spell == "Serpent Sting" and elapsed < 10.5 then
                return NS.RuleRegistry:MakeSuggestion(
                    "Multi-Shot / Aimed Shot",
                    2643,
                    "CLIPPED_UPTIME",
                    0,
                    format("Re-applied Serpent Sting early after %.1fs (%.1fs remaining) — wasted Mana & GCD", elapsed, 15.0 - elapsed)
                )
            elseif self.fillers[spell] and elapsed > 15.5 and (dur - (ev.t or 0)) >= 9.0 then
                return NS.RuleRegistry:MakeSuggestion(
                    "Serpent Sting",
                    1978,
                    "DROPPED_MAINT",
                    0,
                    format("Serpent Sting expired (%.1fs elapsed) — refresh Sting before %s", elapsed, spell)
                )
            end
        end
    end

    -- 3. Rapid Fire / Bestial Wrath cooldown weaving before Aimed Shot
    if spell == "Aimed Shot" and history["Rapid Fire"] and #history["Rapid Fire"] > 0 then
        local rfReady = NS.RuleRegistry:WasSpellReadyAt(history, "Rapid Fire", ev.t or 0, 300.0, dur)
        if rfReady then
            return NS.RuleRegistry:MakeSuggestion(
                "Rapid Fire",
                3045,
                "CD_READY",
                0,
                "Rapid Fire was available — pop Rapid Fire before casting Aimed Shot"
            )
        end
    end

    return nil
end

if NS.RuleRegistry then
    NS.RuleRegistry:RegisterClass("HUNTER", HunterRules)
end
