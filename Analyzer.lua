local _, NS = ...

local tinsert = table.insert
local tremove = table.remove
local sort = table.sort
local max = math.max
local min = math.min
local floor = math.floor
local abs = math.abs
local format = string.format

local Analyzer = {}
NS.Analyzer = Analyzer

Analyzer.VERDICTS = {
    EFFICIENT = "EFFICIENT",
    EARLY_STARVED = "EARLY_STARVED",
    LATE_HOARD = "LATE_HOARD",
    OVERCAP_WASTE = "OVERCAP_WASTE",
    IDLE_GAP = "IDLE_GAP",
}

local VERDICTS = Analyzer.VERDICTS

local SECONDARY = {
    COMBO_POINTS = 4,
    MANA_BACKUP = 100,
    PET_FOCUS = 102,
    TOTEM_SLOTS = 104,
}

local DEFAULT_THRESHOLDS = {
    hoardMultiplier = 2.0,
    hoardHoldSeconds = 1.0,
    idleGapSeconds = 0.6,
    spamDebounceSeconds = 0.40,
}

local POWER_PROFILES = {
    [0] = {
        name = "Mana",
        allowHoardCheck = false,
        minCapRatio = 1.0,
        discreteCapped = false,
        hoardHoldBonus = 0.0,
    },
    [1] = {
        name = "Rage",
        allowHoardCheck = true,
        minCapRatio = 0.60,
        discreteCapped = false,
        hoardHoldBonus = 0.0,
    },
    [3] = {
        name = "Energy",
        allowHoardCheck = true,
        minCapRatio = 0.90,
        discreteCapped = false,
        hoardHoldBonus = 0.25,
    },
    [4] = {
        name = "Combo Points",
        allowHoardCheck = true,
        minCapRatio = 1.0,
        discreteCapped = true,
        hoardHoldBonus = 0.20,
    },
    [102] = {
        name = "Pet Focus",
        allowHoardCheck = true,
        minCapRatio = 0.95,
        discreteCapped = false,
        hoardHoldBonus = 0.50,
    },
    [104] = {
        name = "Totems",
        allowHoardCheck = false,
        minCapRatio = 1.0,
        discreteCapped = false,
        hoardHoldBonus = 0.0,
    },
}

local DRUID_SHIFT_SPELL_IDS = {
    [5487]  = "Bear Form",
    [9634]  = "Dire Bear Form",
    [768]   = "Cat Form",
    [24858] = "Moonkin Form",
    [783]   = "Travel Form",
    [1066]  = "Aquatic Form",
}

local TOTEM_ELEMENT_NAMES = {
    [1] = "Fire",
    [2] = "Earth",
    [3] = "Water",
    [4] = "Air",
}

local TACTICAL_TOTEM_KEYWORDS = {
    "Grounding",
    "Tremor",
    "Earthbind",
    "Stoneclaw",
    "Fire Nova",
    "Mana Tide",
    "Cleansing",
    "Poison Cleansing",
    "Disease Cleansing",
}

local FINISHER_KEYWORDS = {
    "Eviscerate",
    "Slice and Dice",
    "Rupture",
    "Kidney Shot",
    "Expose Armor",
    "Envenom",
    "Deadly Throw",
    "Ferocious Bite",
    "Rip",
    "Maim",
    "Savage Roar",
}

local PET_REQUIRED_KEYWORDS = {
    "Kill Command",
    "Bestial Wrath",
    "Intimidation",
    "Mend Pet",
    "Feed Pet",
}

local function GetPowerProfile(powerType)
    return POWER_PROFILES[powerType] or POWER_PROFILES[0]
end

local function SortByTimestamp(a, b)
    return (a.t or 0) < (b.t or 0)
end

local function MatchesAnyKeyword(spellName, list)
    if not spellName then
        return false
    end
    for i = 1, #list do
        if spellName:find(list[i], 1, true) then
            return true
        end
    end
    return false
end

local function DeterminePrimaryPowerType(fight)
    local counts = {}
    for i = 1, #fight.events do
        local ev = fight.events[i]
        if not ev.isSyntheticEvent and ev.powerType ~= nil then
            counts[ev.powerType] = (counts[ev.powerType] or 0) + 1
        end
    end

    local bestType = nil
    local bestCount = -1
    for pType, cnt in pairs(counts) do
        local weight = (pType == 0) and (cnt * 0.65) or cnt
        if weight > bestCount then
            bestCount = weight
            bestType = pType
        end
    end

    if bestType ~= nil then
        return bestType
    end
    if fight.samples and #fight.samples > 0 then
        return fight.samples[1].powerType or 0
    end
    return 0
end

local function DetermineSecondaryType(fight, primaryPowerType)
    local cls = fight.playerClass
    if cls == "ROGUE" then
        return SECONDARY.COMBO_POINTS, "Combo Points"
    elseif cls == "DRUID" then
        if fight.formSegments and #fight.formSegments > 1 then
            return nil, "Multi-Form Stances"
        elseif primaryPowerType == 3 then
            return SECONDARY.COMBO_POINTS, "Combo Points"
        elseif primaryPowerType == 1 then
            return SECONDARY.MANA_BACKUP, "Mana"
        end
    elseif cls == "HUNTER" then
        return SECONDARY.PET_FOCUS, "Pet Focus"
    elseif cls == "SHAMAN" then
        return SECONDARY.TOTEM_SLOTS, "Totem Slots"
    end
    return nil, nil
end

local function ComputeReferenceSpenderCosts(events)
    local costsByPower = {}
    for i = 1, #events do
        local ev = events[i]
        if not ev.isSyntheticEvent and ev.outcome == "SUCCEEDED" and (ev.spellCost or 0) > 0 then
            local list = costsByPower[ev.powerType]
            if not list then
                list = {}
                costsByPower[ev.powerType] = list
            end
            tinsert(list, ev.spellCost)
        end
    end

    local reference = {}
    for pType, list in pairs(costsByPower) do
        sort(list)
        local mid = floor((#list + 1) / 2)
        reference[pType] = list[mid] or 0
    end
    return reference
end

local function ComputeHoardThresholdsByPower(fight, refSpenderCosts, thresholds)
    local maxByPower = {}
    if fight.samples then
        for i = 1, #fight.samples do
            local s = fight.samples[i]
            if s.powerType ~= nil and (s.powerMax or 0) > 0 then
                maxByPower[s.powerType] = s.powerMax
            end
        end
    end

    local out = {}
    for pType, pMax in pairs(maxByPower) do
        local profile = GetPowerProfile(pType)
        if profile.allowHoardCheck and pMax > 0 then
            local refCost = refSpenderCosts[pType] or 0
            local multThresh = refCost * thresholds.hoardMultiplier
            local ratioThresh = pMax * profile.minCapRatio
            out[pType] = min(pMax, max(multThresh, ratioThresh))
        end
    end
    return out
end

local function ComputeDruidFormBreakdown(fight, summary)
    if fight.playerClass ~= "DRUID" or not fight.formSegments or #fight.formSegments == 0 then
        return
    end

    local totals = { BEAR = 0, CAT = 0, MOONKIN = 0, CASTER = 0, TRAVEL = 0 }
    local totalDur = max(0.1, fight.duration or 0.1)

    for i = 1, #fight.formSegments do
        local seg = fight.formSegments[i]
        local segEnd = seg.endTime or totalDur
        local dt = max(0, segEnd - (seg.startTime or 0))
        local key = seg.form or "CASTER"
        totals[key] = (totals[key] or 0) + dt
    end

    summary.formBreakdown = {
        BEAR = floor((totals.BEAR / totalDur) * 100 + 0.5),
        CAT = floor((totals.CAT / totalDur) * 100 + 0.5),
        MOONKIN = floor((totals.MOONKIN / totalDur) * 100 + 0.5),
        CASTER = floor((totals.CASTER / totalDur) * 100 + 0.5),
        TRAVEL = floor((totals.TRAVEL / totalDur) * 100 + 0.5),
    }
end

local function ComputeHeldDurationAbove(samples, powerType, windowStart, eventTime, threshold)
    if not samples or #samples == 0 or eventTime <= windowStart then
        return 0
    end

    local windowSamples = {}
    local priorSample = nil

    for i = 1, #samples do
        local s = samples[i]
        if s.powerType == powerType then
            if s.t < windowStart then
                priorSample = s
            elseif s.t <= eventTime then
                tinsert(windowSamples, s)
            else
                break
            end
        end
    end

    if priorSample then
        tinsert(windowSamples, 1, {
            t = windowStart,
            powerType = powerType,
            power = priorSample.power,
            powerMax = priorSample.powerMax,
        })
    end

    if #windowSamples == 0 then
        return 0
    end

    local cursorTime = eventTime
    local held = 0
    for i = #windowSamples, 1, -1 do
        local s = windowSamples[i]
        if s.power < threshold then
            break
        end
        local segStart = max(windowStart, s.t)
        if cursorTime > segStart then
            held = held + (cursorTime - segStart)
            cursorTime = segStart
        end
    end
    return held
end

local function ClusterOvercaps(overcaps)
    if not overcaps or #overcaps == 0 then
        return {}
    end

    local sorted = {}
    for i = 1, #overcaps do
        tinsert(sorted, overcaps[i])
    end
    sort(sorted, SortByTimestamp)

    local clusters = {}
    for i = 1, #sorted do
        local oc = sorted[i]
        local prev = clusters[#clusters]
        if prev and prev.powerType == oc.powerType and (oc.t - prev.endTime) <= 0.50 then
            prev.endTime = oc.t
            prev.wasted = prev.wasted + (oc.wasted or 0)
            prev.tickCount = prev.tickCount + 1
        else
            tinsert(clusters, {
                t = oc.t,
                endTime = oc.t,
                spellID = oc.spellID,
                spellName = oc.spellName or "Resource Gain",
                powerType = oc.powerType,
                wasted = oc.wasted or 0,
                powerMax = oc.powerMax or 100,
                tickCount = 1,
                isPet = oc.isPet,
                attributed = false,
            })
        end
    end
    return clusters
end

local function MergeOvercapsIntoEvents(events, clusters)
    if #clusters == 0 then
        return
    end

    local ATTRIBUTION_WINDOW = 0.35
    for c = 1, #clusters do
        local cluster = clusters[c]
        if not cluster.isPet then
            local bestEvent = nil
            local bestDist = ATTRIBUTION_WINDOW + 1

            for e = 1, #events do
                local ev = events[e]
                if not ev.isSyntheticEvent and ev.powerType == cluster.powerType then
                    local dist = abs((ev.t or 0) - cluster.t)
                    if dist <= ATTRIBUTION_WINDOW and dist < bestDist then
                        bestDist = dist
                        bestEvent = ev
                    end
                end
            end

            if bestEvent then
                cluster.attributed = true
                bestEvent.wastedAmount = (bestEvent.wastedAmount or 0) + cluster.wasted
                bestEvent.overcapSource = cluster.spellName
            end
        end
    end

    for c = 1, #clusters do
        local cluster = clusters[c]
        if not cluster.attributed and cluster.wasted > 0 then
            local profile = GetPowerProfile(cluster.powerType)
            local tickSuffix = (cluster.tickCount > 1) and format(" (%dx ticks)", cluster.tickCount) or ""
            tinsert(events, {
                t = cluster.t,
                spellID = cluster.spellID or 0,
                spellName = cluster.spellName,
                spellIcon = nil,
                outcome = "OVERCAP",
                isSyntheticEvent = true,
                isSyntheticOvercap = true,
                powerType = cluster.powerType,
                powerBefore = cluster.powerMax,
                powerAfter = cluster.powerMax,
                powerMax = cluster.powerMax,
                spellCost = 0,
                burstSize = 1,
                pressCount = cluster.tickCount,
                wastedAmount = cluster.wasted,
                verdict = VERDICTS.OVERCAP_WASTE,
                note = format(
                    "Overcapped: +%d %s wasted at %d/%d%s",
                    cluster.wasted,
                    profile.name,
                    cluster.powerMax,
                    cluster.powerMax,
                    tickSuffix
                ),
            })
        end
    end
end

local function AnalyzeHunterPetTelemetry(fight, summary)
    if fight.playerClass ~= "HUNTER" then
        return
    end

    local secSamples = fight.secondarySamples or {}
    local aliveSamples = 0
    local totalSecSamples = 0
    local cappedDuration = 0

    for i = 1, #secSamples do
        local s = secSamples[i]
        if s.secondaryType == SECONDARY.PET_FOCUS then
            totalSecSamples = totalSecSamples + 1
            local isAlive = s.extra and s.extra.petAlive
            if isAlive then
                aliveSamples = aliveSamples + 1
            end
            local nextSample = secSamples[i + 1]
            local dt = nextSample and max(0, nextSample.t - s.t) or 0
            if isAlive and (s.value or 0) >= 95 and dt > 0 then
                cappedDuration = cappedDuration + dt
            end
        end
    end

    local petUptimePct = (totalSecSamples > 0) and floor((aliveSamples / totalSecSamples) * 100 + 0.5) or 0
    summary.petUptimePct = petUptimePct
    summary.petFocusCappedSeconds = cappedDuration

    if petUptimePct >= 50 and cappedDuration >= 3.5 then
        summary.lateHoardCount = summary.lateHoardCount + 1
        summary.weightedLateMistakes = summary.weightedLateMistakes + min(2.0, cappedDuration / 3.5)
    end
end

local function AnalyzeShamanTotemTelemetry(fight, summary)
    if fight.playerClass ~= "SHAMAN" then
        return
    end

    local totemEvents = fight.totemEvents or {}
    local clipCount = 0

    for i = 1, #totemEvents do
        local te = totemEvents[i]
        if te.action == "DROPPED" then
            local elemName = TOTEM_ELEMENT_NAMES[te.slot] or ("Slot " .. tostring(te.slot))
            local clipped = te.clippedRemaining or 0
            local isTactical = MatchesAnyKeyword(te.clippedTotemName, TACTICAL_TOTEM_KEYWORDS)

            local matchedEv = nil
            for e = 1, #fight.events do
                local ev = fight.events[e]
                if not ev.isSyntheticEvent and abs((ev.t or 0) - te.t) <= 0.30 then
                    matchedEv = ev
                    break
                end
            end

            if clipped > 8.0 and not isTactical then
                clipCount = clipCount + 1
                summary.overcapWasteCount = summary.overcapWasteCount + 1
                summary.weightedOvercapMistakes = summary.weightedOvercapMistakes + 0.85

                if matchedEv then
                    matchedEv.verdict = VERDICTS.OVERCAP_WASTE
                    matchedEv.note = format(
                        "Clipped %s totem (%s had %.1fs left)",
                        elemName,
                        te.clippedTotemName or "previous totem",
                        clipped
                    )
                end
            elseif matchedEv and matchedEv.verdict == VERDICTS.EFFICIENT then
                if clipped > 0 and clipped <= 8.0 then
                    matchedEv.note = format(
                        "Clean %s totem refresh (%.1fs left)",
                        elemName,
                        clipped
                    )
                elseif (te.emptyGap or 0) > 4.0 then
                    matchedEv.note = format(
                        "Re-dropped %s totem after %.1fs gap",
                        elemName,
                        te.emptyGap
                    )
                else
                    matchedEv.note = format(
                        "Deployed %s totem (%d -> %d Mana)",
                        elemName,
                        matchedEv.powerBefore or 0,
                        matchedEv.powerAfter or 0
                    )
                end
            end
        end
    end

    local secSamples = fight.secondarySamples or {}
    local weightedSlots = 0
    local totalTime = 0
    for i = 1, #secSamples do
        local s = secSamples[i]
        if s.secondaryType == SECONDARY.TOTEM_SLOTS then
            local nextS = secSamples[i + 1]
            local endT = nextS and nextS.t or (fight.duration or s.t)
            local dt = max(0, endT - s.t)
            weightedSlots = weightedSlots + ((s.value or 0) * dt)
            totalTime = totalTime + dt
        end
    end

    summary.avgActiveTotems = (totalTime > 0) and (weightedSlots / totalTime) or 0
    summary.totemClipCount = clipCount
end

local function AnalyzeCastTempoAndIdleGaps(fight, summary, thresholds)
    local dur = max(0.5, fight.duration or 0.5)
    local idleGrace = thresholds.idleGapSeconds or DEFAULT_THRESHOLDS.idleGapSeconds
    local casts = {}

    for i = 1, #fight.events do
        local ev = fight.events[i]
        if not ev.isSyntheticEvent and ev.outcome == "SUCCEEDED" then
            tinsert(casts, ev)
        end
    end

    local castCount = #casts
    summary.succeededCastCount = castCount
    summary.cpm = castCount / max(0.05, dur / 60.0)
    summary.idleGapCount = 0
    summary.totalIdleSeconds = 0
    summary.weightedIdleMistakes = 0
    summary.idleSegments = {}

    if castCount == 0 then
        summary.activeUptimePct = 0
        return
    end

    -- Merge active GCD/cast intervals to compute true active uptime without double-counting off-GCD macros
    local mergedActive = 0
    local curStart = casts[1].t or 0
    local curEnd = min(dur, curStart + max(1.5, casts[1].castTime or 0))

    for i = 2, castCount do
        local ev = casts[i]
        local evStart = ev.t or 0
        local evEnd = min(dur, evStart + max(1.5, ev.castTime or 0))
        if evStart <= curEnd then
            if evEnd > curEnd then
                curEnd = evEnd
            end
        else
            mergedActive = mergedActive + max(0, curEnd - curStart)
            curStart = evStart
            curEnd = evEnd
        end
    end
    mergedActive = mergedActive + max(0, curEnd - curStart)
    summary.activeUptimePct = floor(max(0, min(100, (mergedActive / dur) * 100.0)) + 0.5)

    -- Flag dead-time idle gaps between consecutive player casts
    local syntheticIdles = {}
    for i = 1, castCount - 1 do
        local prevEv = casts[i]
        local nextEv = casts[i + 1]
        local expectedBusy = max(1.5, prevEv.castTime or 0)
        local busyEnd = (prevEv.t or 0) + expectedBusy
        local rawGap = max(0, (nextEv.t or 0) - (prevEv.t or 0))
        local idleTime = (nextEv.t or 0) - busyEnd

        if idleTime >= idleGrace then
            summary.idleGapCount = summary.idleGapCount + 1
            summary.totalIdleSeconds = summary.totalIdleSeconds + idleTime
            local weight = max(0.6, min(2.5, idleTime / max(0.5, idleGrace)))
            summary.weightedIdleMistakes = summary.weightedIdleMistakes + weight

            tinsert(summary.idleSegments, {
                startTime = busyEnd,
                endTime = nextEv.t or busyEnd,
                duration = idleTime,
            })

            tinsert(syntheticIdles, {
                t = busyEnd,
                spellID = 0,
                spellName = "Idle GCD Gap",
                spellIcon = nil,
                outcome = "IDLE_GAP",
                isSyntheticEvent = true,
                isSyntheticIdle = true,
                powerType = summary.primaryPowerType or 0,
                powerBefore = 0,
                powerAfter = 0,
                powerMax = 100,
                spellCost = 0,
                burstSize = 1,
                pressCount = 1,
                idleSeconds = idleTime,
                rawGapSeconds = rawGap,
                verdict = VERDICTS.IDLE_GAP,
                note = format(
                    "Idle gap: %.1fs dead time (%.1fs between %s -> %s)",
                    idleTime,
                    rawGap,
                    prevEv.spellName or "cast",
                    nextEv.spellName or "cast"
                ),
            })
        end
    end

    if #syntheticIdles > 0 then
        for i = 1, #syntheticIdles do
            tinsert(fight.events, syntheticIdles[i])
        end
        sort(fight.events, SortByTimestamp)
    end
end

local function CalculateFightScore(summary, totalSteps)
    if totalSteps <= 0 then
        return 100
    end

    local earlyPenalty = (summary.weightedEarlyMistakes or 0) * 7.5
    local latePenalty = (summary.weightedLateMistakes or 0) * 5.5
    local overcapPenalty = (summary.weightedOvercapMistakes or 0) * 6.5
    local idlePenalty = (summary.weightedIdleMistakes or 0) * 5.0

    local rawDeduction = earlyPenalty + latePenalty + overcapPenalty + idlePenalty
    local scale = max(1.0, totalSteps / 18.0)
    local normalizedDeduction = rawDeduction / scale

    return floor(max(0, min(100, 100 - normalizedDeduction)) + 0.5)
end

function Analyzer:AnalyzeFight(fight, customThresholds)
    if not fight or not fight.events then
        return
    end

    local thresholds = {
        hoardMultiplier = (customThresholds and customThresholds.hoardMultiplier)
            or DEFAULT_THRESHOLDS.hoardMultiplier,
        hoardHoldSeconds = (customThresholds and customThresholds.hoardHoldSeconds)
            or DEFAULT_THRESHOLDS.hoardHoldSeconds,
        idleGapSeconds = (customThresholds and customThresholds.idleGapSeconds)
            or DEFAULT_THRESHOLDS.idleGapSeconds,
        spamDebounceSeconds = (customThresholds and customThresholds.spamDebounceSeconds)
            or DEFAULT_THRESHOLDS.spamDebounceSeconds,
    }

    for i = #fight.events, 1, -1 do
        if fight.events[i].isSyntheticEvent then
            tremove(fight.events, i)
        else
            fight.events[i].verdict = nil
            fight.events[i].note = nil
            fight.events[i].deficit = nil
            fight.events[i].heldSeconds = nil
            fight.events[i].hoardThreshold = nil
            fight.events[i].wastedAmount = nil
            fight.events[i].overcapSource = nil
            fight.events[i].isPowershift = nil
        end
    end

    sort(fight.events, SortByTimestamp)
    if fight.samples then
        sort(fight.samples, SortByTimestamp)
    end
    if fight.secondarySamples then
        sort(fight.secondarySamples, SortByTimestamp)
    end

    local overcapClusters = ClusterOvercaps(fight.overcaps)
    MergeOvercapsIntoEvents(fight.events, overcapClusters)
    sort(fight.events, SortByTimestamp)

    local primaryPowerType = DeterminePrimaryPowerType(fight)
    local primaryProfile = GetPowerProfile(primaryPowerType)
    local secondaryType, secondaryName = DetermineSecondaryType(fight, primaryPowerType)
    local refSpenderCosts = ComputeReferenceSpenderCosts(fight.events)
    local hoardThresholdsByPower = ComputeHoardThresholdsByPower(fight, refSpenderCosts, thresholds)

    local summary = {
        primaryPowerType = primaryPowerType,
        primaryPowerName = primaryProfile.name,
        secondaryType = secondaryType,
        secondaryName = secondaryName,
        referenceSpenderCost = refSpenderCosts[primaryPowerType] or 0,
        hoardThreshold = hoardThresholdsByPower[primaryPowerType] or 0,
        hoardThresholdsByPower = hoardThresholdsByPower,
        totalEvents = 0,
        efficientCount = 0,
        earlyStarvedCount = 0,
        lateHoardCount = 0,
        overcapWasteCount = 0,
        totalWastedResource = 0,
        weightedEarlyMistakes = 0,
        weightedLateMistakes = 0,
        weightedOvercapMistakes = 0,
    }

    ComputeDruidFormBreakdown(fight, summary)

    local lastSpendTimeByPower = {}
    local prevDruidForm = nil
    local lastCatExitTime = nil

    for i = 1, #fight.events do
        local ev = fight.events[i]
        summary.totalEvents = summary.totalEvents + 1

        local pType = ev.powerType or primaryPowerType
        local profile = GetPowerProfile(pType)
        local pMax = ev.powerMax or 100
        local pBefore = ev.powerBefore or 0
        local cost = ev.spellCost or 0

        if fight.playerClass == "DRUID" and ev.druidForm and ev.druidForm ~= prevDruidForm then
            if prevDruidForm == "CAT" and ev.druidForm ~= "CAT" then
                lastCatExitTime = ev.t
            end
            lastSpendTimeByPower[pType] = ev.t
            prevDruidForm = ev.druidForm
        end

        if ev.isSyntheticEvent then
            local wasted = ev.wastedAmount or 0
            summary.overcapWasteCount = summary.overcapWasteCount + 1
            summary.totalWastedResource = summary.totalWastedResource + wasted
            local severity = max(0.5, min(2.0, (wasted / max(1, pMax)) * 6.0))
            summary.weightedOvercapMistakes = summary.weightedOvercapMistakes + severity

        elseif ev.outcome == "FAILED_RESOURCE" then
            local deficit = max(0, cost - pBefore)
            local presses = ev.pressCount or 1
            ev.verdict = VERDICTS.EARLY_STARVED
            ev.deficit = deficit
            if ev.powerIsSecret then
                ev.note = format(
                    "Too early: insufficient %s (cost %d)%s",
                    profile.name,
                    cost,
                    presses > 1 and format(" — pressed %dx", presses) or ""
                )
            else
                ev.note = format(
                    "Too early: short %d %s (%d/%d)%s",
                    deficit,
                    profile.name,
                    pBefore,
                    cost,
                    presses > 1 and format(" — pressed %dx", presses) or ""
                )
            end

            summary.earlyStarvedCount = summary.earlyStarvedCount + 1
            local mashWeight = 1.0 + 0.25 * min(4, presses - 1)
            summary.weightedEarlyMistakes = summary.weightedEarlyMistakes + mashWeight

        elseif fight.playerClass == "HUNTER"
            and ev.petAlive == false
            and MatchesAnyKeyword(ev.spellName, PET_REQUIRED_KEYWORDS)
        then
            ev.verdict = VERDICTS.EARLY_STARVED
            ev.note = "Pet unavailable/dead when casting " .. (ev.spellName or "pet command")
            summary.earlyStarvedCount = summary.earlyStarvedCount + 1
            summary.weightedEarlyMistakes = summary.weightedEarlyMistakes + 1.0

        elseif (ev.wastedAmount or 0) > 0 then
            local wasted = ev.wastedAmount
            ev.verdict = VERDICTS.OVERCAP_WASTE
            ev.note = format(
                "Overcapped: +%d %s wasted via %s (%d/%d)",
                wasted,
                profile.name,
                ev.overcapSource or ev.spellName,
                pBefore,
                pMax
            )

            summary.overcapWasteCount = summary.overcapWasteCount + 1
            summary.totalWastedResource = summary.totalWastedResource + wasted
            local severity = max(0.6, min(2.0, (wasted / max(1, pMax)) * 6.0))
            summary.weightedOvercapMistakes = summary.weightedOvercapMistakes + severity

            if cost > 0 then
                lastSpendTimeByPower[pType] = ev.t
            end

        elseif ev.secondaryType == SECONDARY.COMBO_POINTS
            and (ev.secondaryBefore or 0) >= (ev.secondaryMax or 5)
            and cost > 0
            and not MatchesAnyKeyword(ev.spellName, FINISHER_KEYWORDS)
        then
            ev.verdict = VERDICTS.OVERCAP_WASTE
            ev.wastedAmount = 1
            ev.note = format(
                "Overcapped: used %s at %d/%d Combo Points",
                ev.spellName or "builder",
                ev.secondaryBefore or 5,
                ev.secondaryMax or 5
            )

            summary.overcapWasteCount = summary.overcapWasteCount + 1
            summary.totalWastedResource = summary.totalWastedResource + 1
            summary.weightedOvercapMistakes = summary.weightedOvercapMistakes + 1.0
            lastSpendTimeByPower[pType] = ev.t

        else
            local isHoard = false
            if ev.outcome == "SUCCEEDED" and cost > 0 and profile.allowHoardCheck and pMax > 0 and not ev.powerIsSecret then
                local refCost = max(cost, refSpenderCosts[pType] or cost)
                local multThresh = refCost * thresholds.hoardMultiplier
                local ratioThresh = pMax * profile.minCapRatio
                local hoardThresh = min(pMax, max(multThresh, ratioThresh))
                local requiredHold = thresholds.hoardHoldSeconds + (profile.hoardHoldBonus or 0)

                ev.hoardThreshold = hoardThresh

                if pBefore >= hoardThresh then
                    local windowStart = lastSpendTimeByPower[pType] or 0
                    local heldSecs = ComputeHeldDurationAbove(
                        fight.samples,
                        pType,
                        windowStart,
                        ev.t,
                        hoardThresh
                    )
                    ev.heldSeconds = heldSecs

                    local spendMultiple = pBefore / max(1, refCost)
                    if heldSecs >= requiredHold or (pBefore >= pMax and spendMultiple >= 2.0) then
                        isHoard = true
                        ev.verdict = VERDICTS.LATE_HOARD
                        ev.note = format(
                            "Late spend: held %d %s (%.1fx cost) for %.1fs before casting",
                            pBefore,
                            profile.name,
                            spendMultiple,
                            heldSecs
                        )

                        summary.lateHoardCount = summary.lateHoardCount + 1
                        local excessRatio = max(1.0, min(2.0, (heldSecs / max(0.5, requiredHold))))
                        summary.weightedLateMistakes = summary.weightedLateMistakes + excessRatio
                    end
                end
            end

            if not isHoard then
                ev.verdict = VERDICTS.EFFICIENT
                summary.efficientCount = summary.efficientCount + 1

                local shiftFormName = (fight.playerClass == "DRUID") and DRUID_SHIFT_SPELL_IDS[ev.spellID] or nil
                if shiftFormName then
                    local isPowershift = (ev.spellID == 768)
                        and (ev.druidForm == "CAT" or (lastCatExitTime and (ev.t - lastCatExitTime) <= 1.5))
                    if isPowershift then
                        ev.isPowershift = true
                        lastCatExitTime = nil
                        ev.note = format(
                            "Powershifted %s (%d -> %d Mana)",
                            shiftFormName,
                            pBefore,
                            ev.powerAfter or max(0, pBefore - cost)
                        )
                    else
                        ev.note = format(
                            "Shifted to %s (%d -> %d Mana)",
                            shiftFormName,
                            pBefore,
                            ev.powerAfter or max(0, pBefore - cost)
                        )
                    end
                else
                    local cpSuffix = ""
                    if ev.secondaryType == SECONDARY.COMBO_POINTS and (ev.secondaryBefore or 0) > 0 then
                        cpSuffix = format(" [%d CP]", ev.secondaryBefore)
                    end

                    if ev.fallbackNotes and #ev.fallbackNotes > 0 then
                        local fb = ev.fallbackNotes[1]
                        ev.note = format(
                            "Efficient fallback (short %d %s for %s)%s",
                            fb.deficit or 0,
                            profile.name,
                            fb.spellName or "primary spell",
                            cpSuffix
                        )
                    elseif cost > 0 then
                        if ev.powerIsSecret then
                            ev.note = format(
                                "Cast (%d %s cost — live pool masked)%s",
                                cost,
                                profile.name,
                                cpSuffix
                            )
                        else
                            ev.note = format(
                                "Efficient spend (%d -> %d %s)%s",
                                pBefore,
                                ev.powerAfter or max(0, pBefore - cost),
                                profile.name,
                                cpSuffix
                            )
                        end
                    else
                        if ev.powerIsSecret then
                            ev.note = format("Clean cast (live %s masked)%s", profile.name, cpSuffix)
                        else
                            ev.note = format("Clean cast (%d %s)%s", pBefore, profile.name, cpSuffix)
                        end
                    end
                end
            end

            if cost > 0 then
                lastSpendTimeByPower[pType] = ev.t
            end
        end
    end

    AnalyzeHunterPetTelemetry(fight, summary)
    AnalyzeShamanTotemTelemetry(fight, summary)
    AnalyzeCastTempoAndIdleGaps(fight, summary, thresholds)

    local totalSteps = summary.efficientCount
        + summary.earlyStarvedCount
        + summary.lateHoardCount
        + summary.overcapWasteCount
        + (summary.idleGapCount or 0)

    fight.summary = summary
    fight.score = CalculateFightScore(summary, totalSteps)
    return fight
end

------------------------------------------------------------------------
-- Post-Fight Chat Report Generator (Top 3 Resource Improvements)
------------------------------------------------------------------------

local REPORT_VERDICT_LABEL = {
    EARLY_STARVED = "Early",
    LATE_HOARD = "Late",
    OVERCAP_WASTE = "Overcap",
    IDLE_GAP = "Idle",
}

local REPORT_VERDICT_COLOR = {
    EARLY_STARVED = "|cfff04047",
    LATE_HOARD = "|cfff5ad24",
    OVERCAP_WASTE = "|cffd159eb",
    IDLE_GAP = "|cfff28538",
}

local function FormatReportClock(sec)
    sec = max(0, sec or 0)
    local mins = floor(sec / 60)
    local rem = floor(sec % 60)
    return format("%d:%02d", mins, rem)
end

function Analyzer:BuildChatReport(fight, useColor)
    if not fight then
        return {}
    end

    local sum = fight.summary or {}
    local score = fight.score or 100
    local lines = {}

    local extraStat = ""
    if fight.playerClass == "HUNTER" and sum.petUptimePct ~= nil then
        extraStat = format(" | Pet Uptime: %d%%", sum.petUptimePct)
    elseif fight.playerClass == "SHAMAN" and sum.avgActiveTotems ~= nil then
        extraStat = format(" | Avg Totems: %.1f/4", sum.avgActiveTotems)
    elseif fight.playerClass == "DRUID" and sum.formBreakdown then
        local fb = sum.formBreakdown
        local parts = {}
        if (fb.CAT or 0) > 0 then tinsert(parts, format("Cat %d%%", fb.CAT)) end
        if (fb.BEAR or 0) > 0 then tinsert(parts, format("Bear %d%%", fb.BEAR)) end
        if (fb.MOONKIN or 0) > 0 then tinsert(parts, format("Moon %d%%", fb.MOONKIN)) end
        if (fb.CASTER or 0) > 0 then tinsert(parts, format("Cast %d%%", fb.CASTER)) end
        if #parts > 0 then
            extraStat = " | Forms: " .. table.concat(parts, "/")
        end
    end

    local tempoStat = ""
    if sum.activeUptimePct ~= nil then
        tempoStat = format(" | Uptime: %d%% (%.1f CPM)", sum.activeUptimePct or 0, sum.cpm or 0)
    end

    if useColor then
        local scoreHex = (score >= 88 and "|cff2ed16b") or (score >= 70 and "|cfff5ad24") or "|cfff04047"
        tinsert(lines, format(
            "|cff5cc8ff[CTE]|r %s (%s) — Score: %s%d%%|r | |cff2ed16b%d Eff|r, |cfff04047%d Early|r, |cfff5ad24%d Late|r, |cffd159eb%d Overcap|r, |cfff28538%d Idle|r%s%s",
            fight.targetName or "Encounter",
            FormatReportClock(fight.duration),
            scoreHex,
            score,
            sum.efficientCount or 0,
            sum.earlyStarvedCount or 0,
            sum.lateHoardCount or 0,
            sum.overcapWasteCount or 0,
            sum.idleGapCount or 0,
            tempoStat,
            extraStat
        ))
    else
        tinsert(lines, format(
            "[CTE] %s (%s) - Score: %d%% | %d Efficient, %d Early, %d Late, %d Overcap, %d Idle%s%s",
            fight.targetName or "Encounter",
            FormatReportClock(fight.duration),
            score,
            sum.efficientCount or 0,
            sum.earlyStarvedCount or 0,
            sum.lateHoardCount or 0,
            sum.overcapWasteCount or 0,
            sum.idleGapCount or 0,
            tempoStat,
            extraStat
        ))
    end

    local grouped = {}
    local groupedList = {}

    for i = 1, #(fight.events or {}) do
        local ev = fight.events[i]
        if ev.verdict and ev.verdict ~= VERDICTS.EFFICIENT then
            local spell = ev.spellName or "Ability"
            local key = ev.verdict .. "::" .. spell
            local bucket = grouped[key]
            if not bucket then
                bucket = {
                    verdict = ev.verdict,
                    spellName = spell,
                    count = 0,
                    impact = 0,
                    sampleNote = ev.note or "",
                    sampleTime = ev.t or 0,
                }
                grouped[key] = bucket
                tinsert(groupedList, bucket)
            end
            bucket.count = bucket.count + 1

            local weight = 1.0
            if ev.verdict == VERDICTS.EARLY_STARVED then
                weight = 1.3 + (0.2 * min(4, (ev.pressCount or 1) - 1))
            elseif ev.verdict == VERDICTS.OVERCAP_WASTE then
                weight = 1.2 + ((ev.wastedAmount or 0) / max(1, ev.powerMax or 100))
            elseif ev.verdict == VERDICTS.LATE_HOARD then
                weight = 1.1 + min(1.5, (ev.heldSeconds or 1.0) * 0.35)
            elseif ev.verdict == VERDICTS.IDLE_GAP then
                weight = 1.1 + min(1.8, (ev.idleSeconds or 0.6) * 0.5)
            end
            bucket.impact = bucket.impact + weight
        end
    end

    if #groupedList == 0 then
        if useColor then
            tinsert(lines, "|cff2ed16b  Clean fight! No early-starved, late-hoard, or overcap issues detected.|r")
        else
            tinsert(lines, "Clean fight! No early-starved, late-hoard, or overcap issues detected.")
        end
        return lines
    end

    sort(groupedList, function(a, b)
        if a.impact ~= b.impact then
            return a.impact > b.impact
        end
        return a.count > b.count
    end)

    local maxItems = min(3, #groupedList)
    for i = 1, maxItems do
        local item = groupedList[i]
        local tag = REPORT_VERDICT_LABEL[item.verdict] or item.verdict
        local countSuffix = (item.count > 1) and format(" (%dx)", item.count) or format(" @ %s", FormatReportClock(item.sampleTime))
        if useColor then
            local cHex = REPORT_VERDICT_COLOR[item.verdict] or "|cffffffff"
            tinsert(lines, format(
                "  %d. %s[%s]|r %s%s — %s",
                i,
                cHex,
                tag,
                item.spellName,
                countSuffix,
                item.sampleNote
            ))
        else
            tinsert(lines, format(
                "%d. [%s] %s%s - %s",
                i,
                tag,
                item.spellName,
                countSuffix,
                item.sampleNote
            ))
        end
    end

    return lines
end

------------------------------------------------------------------------
-- Multi-Fight Comparison Summary (v0.3.0)
------------------------------------------------------------------------

function Analyzer:BuildMultiFightComparison(fights)
    local list = {}
    if type(fights) == "table" then
        for i = 1, #fights do
            if fights[i] then
                tinsert(list, fights[i])
            end
        end
    end

    local count = #list
    if count == 0 then
        return {
            fightCount = 0,
            rows = {},
            avgScore = 0,
            bestScore = 0,
            worstScore = 0,
            bestIdx = 1,
            avgUptimePct = 0,
            avgCpm = 0,
            avgDuration = 0,
            totalIdleSeconds = 0,
            totalEarly = 0,
            totalLate = 0,
            totalOvercap = 0,
            totalIdle = 0,
            scoreDeltaLatestVsAvg = 0,
            uptimeDeltaLatestVsAvg = 0,
        }
    end

    local sumScore = 0
    local sumUptime = 0
    local sumCpm = 0
    local sumDur = 0
    local bestScore = -1
    local worstScore = 101
    local bestIdx = 1

    local totalEarly = 0
    local totalLate = 0
    local totalOvercap = 0
    local totalIdle = 0
    local totalIdleSeconds = 0
    local rows = {}

    for i = 1, count do
        local f = list[i]
        local s = f.summary or {}
        local sc = f.score or 100
        local up = s.activeUptimePct or 0
        local cpm = s.cpm or 0
        local dur = f.duration or 0
        local early = s.earlyStarvedCount or 0
        local late = s.lateHoardCount or 0
        local overcap = s.overcapWasteCount or 0
        local idle = s.idleGapCount or 0
        local idleSec = s.totalIdleSeconds or 0

        sumScore = sumScore + sc
        sumUptime = sumUptime + up
        sumCpm = sumCpm + cpm
        sumDur = sumDur + dur

        if sc > bestScore then
            bestScore = sc
            bestIdx = i
        end
        if sc < worstScore then
            worstScore = sc
        end

        totalEarly = totalEarly + early
        totalLate = totalLate + late
        totalOvercap = totalOvercap + overcap
        totalIdle = totalIdle + idle
        totalIdleSeconds = totalIdleSeconds + idleSec

        tinsert(rows, {
            index = i,
            pinned = f.pinned and true or false,
            targetName = f.targetName or "Encounter",
            duration = dur,
            score = sc,
            uptimePct = up,
            cpm = cpm,
            efficient = s.efficientCount or 0,
            early = early,
            late = late,
            overcap = overcap,
            idle = idle,
            idleSeconds = idleSec,
            isBest = false,
            isWorst = false,
        })
    end

    local avgScore = sumScore / count
    local avgUptimePct = sumUptime / count
    local avgCpm = sumCpm / count
    local avgDuration = sumDur / count

    for i = 1, count do
        local r = rows[i]
        r.scoreDelta = r.score - avgScore
        r.uptimeDelta = r.uptimePct - avgUptimePct
        if count >= 2 then
            if r.score == bestScore then
                r.isBest = true
            end
            if r.score == worstScore and worstScore < bestScore then
                r.isWorst = true
            end
        end
    end

    local latest = rows[1]
    return {
        fightCount = count,
        rows = rows,
        avgScore = avgScore,
        bestScore = bestScore,
        worstScore = worstScore,
        bestIdx = bestIdx,
        avgUptimePct = avgUptimePct,
        avgCpm = avgCpm,
        avgDuration = avgDuration,
        totalIdleSeconds = totalIdleSeconds,
        totalEarly = totalEarly,
        totalLate = totalLate,
        totalOvercap = totalOvercap,
        totalIdle = totalIdle,
        scoreDeltaLatestVsAvg = latest and (latest.score - avgScore) or 0,
        uptimeDeltaLatestVsAvg = latest and (latest.uptimePct - avgUptimePct) or 0,
    }
end
