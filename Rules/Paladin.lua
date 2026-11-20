local _, NS = ...

local format = string.format

local PaladinRules = {
    class = "PALADIN",
    seals = {
        ["Seal of Command"] = true,
        ["Seal of Righteousness"] = true,
        ["Seal of the Crusader"] = true,
        ["Seal of Wisdom"] = true,
        ["Seal of Light"] = true,
    },
    heals = {
        ["Flash of Light"] = true,
        ["Holy Light"] = true,
    },
}

function PaladinRules:EvaluateEvent(ctx)
    local ev = ctx.ev
    local spell = ev.spellName or ""
    local pool = ctx.poolBefore or 0
    local history = ctx.history
    local dur = ctx.fightDuration or 0

    -- 1. Consecration priority when Judgement is used and Consecration is off 8s CD
    if spell == "Judgement" and history["Consecration"] and #history["Consecration"] > 0 then
        local conReady = NS.RuleRegistry:WasSpellReadyAt(history, "Consecration", ev.t or 0, 8.0, dur)
        if conReady and pool >= 250 and (dur - (ev.t or 0)) >= 6.0 then
            return NS.RuleRegistry:MakeSuggestion(
                "Consecration",
                26573,
                "HIGHER_PRIORITY_READY",
                0,
                "Consecration was off CD with Mana to spare — drop Consecration ticks early"
            )
        end
    end

    -- 2. Divine Favor cooldown check before Holy Light / Flash of Light
    if self.heals[spell] and history["Divine Favor"] and #history["Divine Favor"] > 0 then
        local dfReady = NS.RuleRegistry:WasSpellReadyAt(history, "Divine Favor", ev.t or 0, 120.0, dur)
        if dfReady then
            return NS.RuleRegistry:MakeSuggestion(
                "Divine Favor",
                20216,
                "CD_READY",
                0,
                format("Divine Favor was available — pair with %s for a guaranteed crit heal", spell)
            )
        end
    end

    -- 3. Early Seal refresh check (re-casting same Seal within 12s without Judgement)
    if self.seals[spell] and history[spell] and #history[spell] > 0 then
        local sList = history[spell]
        local lastS = nil
        for i = 1, #sList do
            if sList[i] < (ev.t or 0) then
                lastS = sList[i]
            end
        end
        if lastS and ((ev.t or 0) - lastS) < 12.0 then
            local judgedBetween = false
            local jList = history["Judgement"] or {}
            for i = 1, #jList do
                if jList[i] > lastS and jList[i] < (ev.t or 0) then
                    judgedBetween = true
                    break
                end
            end
            if not judgedBetween then
                return NS.RuleRegistry:MakeSuggestion(
                    "Judgement",
                    20271,
                    "CLIPPED_UPTIME",
                    0,
                    format("Re-cast %s after %.1fs without unleashing Judgement first", spell, (ev.t or 0) - lastS)
                )
            end
        end
    end

    return nil
end

if NS.RuleRegistry then
    NS.RuleRegistry:RegisterClass("PALADIN", PaladinRules)
end
