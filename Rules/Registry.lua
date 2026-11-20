local _, NS = ...

local tinsert = table.insert
local max = math.max
local floor = math.floor

local RuleRegistry = {}
NS.RuleRegistry = RuleRegistry

RuleRegistry.classes = {}

function RuleRegistry:RegisterClass(classFile, specRules)
    if classFile and type(specRules) == "table" then
        self.classes[classFile] = specRules
    end
end

function RuleRegistry:GetClassRules(classFile)
    return (classFile and self.classes[classFile]) or self.classes["GENERIC"]
end

function RuleRegistry:BuildSpellHistoryIndex(events)
    -- Index every spell cast by spellName -> list of timestamps so rules can check
    -- whether a higher-priority signature ability was off cooldown at timestamp t.
    local history = {}
    for i = 1, #events do
        local ev = events[i]
        if not ev.isSyntheticEvent and ev.outcome == "SUCCEEDED" and ev.spellName then
            local list = history[ev.spellName]
            if not list then
                list = {}
                history[ev.spellName] = list
            end
            tinsert(list, ev.t or 0)
        end
    end
    return history
end

function RuleRegistry:WasSpellReadyAt(history, spellName, t, cooldownSec, fightDuration)
    local list = history and history[spellName]
    if not list or #list == 0 then
        -- Spell was never used in the fight; only recommend if the fight lasted long enough to matter
        return (fightDuration or 0) >= 8.0, nil
    end

    local lastUseBefore = nil
    local nextUseAfter = nil
    for i = 1, #list do
        local ts = list[i]
        if ts < (t - 0.05) then
            lastUseBefore = ts
        elseif ts > (t + 0.05) and not nextUseAfter then
            nextUseAfter = ts
            break
        end
    end

    if not lastUseBefore then
        return true, nextUseAfter
    end

    local elapsed = t - lastUseBefore
    if elapsed >= cooldownSec then
        return true, nextUseAfter
    end

    local remainingCD = cooldownSec - elapsed
    return false, nextUseAfter, remainingCD
end

function RuleRegistry:MakeSuggestion(betterSpellName, betterSpellID, reasonCode, waitSec, summary)
    return {
        betterSpellName = betterSpellName,
        betterSpellID = betterSpellID or 0,
        reasonCode = reasonCode or "HIGHER_PRIORITY_READY",
        waitSeconds = max(0, floor((waitSec or 0) * 10 + 0.5) / 10),
        summary = summary or "",
    }
end
