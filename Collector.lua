local _, NS = ...

local CreateFrame = CreateFrame
local GetTime = GetTime
local UnitGUID = UnitGUID
local UnitClass = UnitClass
local UnitExists = UnitExists
local UnitIsDead = UnitIsDead
local UnitPower = UnitPower
local UnitPowerMax = UnitPowerMax
local UnitPowerType = UnitPowerType
local GetComboPoints = GetComboPoints
local GetTotemInfo = GetTotemInfo
local GetShapeshiftForm = GetShapeshiftForm
local GetShapeshiftFormInfo = GetShapeshiftFormInfo
local GetSpellInfo = GetSpellInfo
local GetSpellPowerCost = GetSpellPowerCost
local GetSpellCooldown = GetSpellCooldown
local IsPlayerSpell = IsPlayerSpell
local IsSpellKnown = IsSpellKnown
local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo
local tinsert = table.insert
local max = math.max
local abs = math.abs

local Collector = {}
NS.Collector = Collector

Collector.SECONDARY_TYPES = {
    COMBO_POINTS = 4, -- Rogue & Cat-Form Druid (0..5)
    MANA_BACKUP = 100, -- Druid Mana pool while shapeshifted in Bear/Cat
    PET_FOCUS = 102,   -- Hunter Pet Focus (0..100)
    TOTEM_SLOTS = 104, -- Shaman active totem count (0..4) + per-slot timers
}

local SECONDARY = Collector.SECONDARY_TYPES

local MACRO_BURST_WINDOW = 0.015
local ERROR_CORRELATION_WINDOW = 0.060
local BURST_FLUSH_DELAY = 0.120
local SPAM_DEBOUNCE_WINDOW = 0.400
local SAMPLE_MIN_INTERVAL = 0.20

local DRUID_FORM_SPELL_IDS = {
    [5487]  = "BEAR",    -- Bear Form
    [9634]  = "BEAR",    -- Dire Bear Form
    [768]   = "CAT",     -- Cat Form
    [24858] = "MOONKIN", -- Moonkin Form
    [783]   = "TRAVEL",  -- Travel Form
    [1066]  = "TRAVEL",  -- Aquatic Form
}

local RESOURCE_ERROR_GLOBALS = {
    "ERR_OUT_OF_MANA",
    "ERR_OUT_OF_RAGE",
    "ERR_OUT_OF_ENERGY",
    "ERR_OUT_OF_FOCUS",
    "ERR_OUT_OF_POWER_DISPLAY",
    "ERR_NOT_ENOUGH_RESOURCES",
}

local RESOURCE_ERRORS = {}
for _, globalName in ipairs(RESOURCE_ERROR_GLOBALS) do
    local localized = _G[globalName]
    if type(localized) == "string" and localized ~= "" then
        RESOURCE_ERRORS[localized] = true
    end
end

local isRecording = false
local playerGUID = nil
local playerClass = nil
local currentFight = nil
local activeBurst = nil
local castGuidIndex = {}
local lastStarvedBySpell = {}
local lastSampleTime = 0
local lastSamplePower = -1
local lastSecSampleTime = 0
local lastSecSampleVal = -1
local totemSlotState = {}

local collectorFrame = CreateFrame("Frame")

------------------------------------------------------------------------
-- Spellbook, Stance & Resource Helpers
------------------------------------------------------------------------

local function IsSpellUnlocked(spellID)
    if not spellID or spellID <= 0 then
        return false
    end
    if IsPlayerSpell and IsPlayerSpell(spellID) then
        return true
    end
    if IsSpellKnown then
        if IsSpellKnown(spellID) or IsSpellKnown(spellID, true) then
            return true
        end
    end
    return false
end

local function DetectDruidForm()
    if playerClass ~= "DRUID" or not GetShapeshiftForm then
        return nil, UnitPowerType("player")
    end

    local formIdx = GetShapeshiftForm() or 0
    if formIdx == 0 then
        return "CASTER", 0
    end

    if GetShapeshiftFormInfo then
        local icon, _, _, spellID = GetShapeshiftFormInfo(formIdx)
        if spellID and DRUID_FORM_SPELL_IDS[spellID] then
            local formKey = DRUID_FORM_SPELL_IDS[spellID]
            local pType = (formKey == "BEAR" and 1) or (formKey == "CAT" and 3) or 0
            return formKey, pType
        end

        if type(icon) == "string" then
            if icon:find("BearForm", 1, true) then
                return "BEAR", 1
            elseif icon:find("CatForm", 1, true) then
                return "CAT", 3
            elseif icon:find("ForceOfNature", 1, true) or icon:find("Moonkin", 1, true) then
                return "MOONKIN", 0
            elseif icon:find("TravelForm", 1, true) or icon:find("AquaticForm", 1, true) then
                return "TRAVEL", 0
            end
        end
    end

    local pType = UnitPowerType("player") or 0
    if pType == 1 then
        return "BEAR", 1
    elseif pType == 3 then
        return "CAT", 3
    end
    return "CASTER", 0
end

local function GetActivePowerInfo()
    local powerType, powerToken = UnitPowerType("player")
    local current = UnitPower("player", powerType) or 0
    local maximum = UnitPowerMax("player", powerType) or 0
    return powerType, powerToken, current, maximum
end

local function ReadComboPoints()
    local cp = UnitPower and UnitPower("player", 4) or 0
    if (not cp or cp == 0) and GetComboPoints then
        cp = GetComboPoints("player", "target") or 0
    end
    local maxCp = (UnitPowerMax and UnitPowerMax("player", 4)) or 5
    if maxCp <= 0 then
        maxCp = 5
    end
    return cp, maxCp
end

local function HasLivingPet()
    return UnitExists("pet") and not UnitIsDead("pet")
end

local function ReadPetFocus()
    if not HasLivingPet() then
        return 0, 0, false
    end
    local cur = UnitPower("pet", 2) or 0
    local maximum = UnitPowerMax("pet", 2) or 100
    if maximum <= 0 then
        maximum = 100
    end
    return cur, maximum, true
end

local function ReadTotemSnapshot(now)
    if not GetTotemInfo then
        return 0, 4, nil
    end
    local activeCount = 0
    local slots = {}
    for slot = 1, 4 do
        local haveTotem, name, startTime, duration, icon = GetTotemInfo(slot)
        local remaining = 0
        if haveTotem and startTime and duration and duration > 0 then
            remaining = max(0, (startTime + duration) - now)
            if remaining > 0 then
                activeCount = activeCount + 1
            else
                haveTotem = false
            end
        else
            haveTotem = false
        end
        slots[slot] = {
            active = haveTotem and true or false,
            name = name,
            startTime = startTime or 0,
            duration = duration or 0,
            remaining = remaining,
            icon = icon,
        }
    end
    return activeCount, 4, slots
end

local function GetSecondaryState(now, primaryPowerType)
    if playerClass == "ROGUE" then
        local cp, maxCp = ReadComboPoints()
        return SECONDARY.COMBO_POINTS, cp, maxCp, nil
    elseif playerClass == "DRUID" then
        local formKey = DetectDruidForm()
        if formKey == "CAT" or primaryPowerType == 3 then
            local cp, maxCp = ReadComboPoints()
            return SECONDARY.COMBO_POINTS, cp, maxCp, { druidForm = formKey }
        elseif formKey == "BEAR" or primaryPowerType == 1 then
            local mana = UnitPower("player", 0) or 0
            local manaMax = UnitPowerMax("player", 0) or 0
            if manaMax > 0 then
                return SECONDARY.MANA_BACKUP, mana, manaMax, { druidForm = formKey }
            end
        end
        return nil, 0, 0, nil
    elseif playerClass == "HUNTER" then
        local petFocus, petMax, alive = ReadPetFocus()
        if alive then
            return SECONDARY.PET_FOCUS, petFocus, petMax, { petAlive = true }
        end
        return SECONDARY.PET_FOCUS, 0, 100, { petAlive = false }
    elseif playerClass == "SHAMAN" then
        local activeCount, maxSlots, slots = ReadTotemSnapshot(now)
        return SECONDARY.TOTEM_SLOTS, activeCount, maxSlots, slots
    end
    return nil, 0, 0, nil
end

local function GetSpellCostForPower(spellID, preferredPowerType)
    if not GetSpellPowerCost then
        return 0, preferredPowerType
    end
    local costs = GetSpellPowerCost(spellID)
    if type(costs) ~= "table" or #costs == 0 then
        return 0, preferredPowerType
    end

    local chosen = costs[1]
    for i = 1, #costs do
        if costs[i].type == preferredPowerType then
            chosen = costs[i]
            break
        end
    end

    local cost = chosen.cost or chosen.minCost or 0
    return cost, chosen.type or preferredPowerType
end

local function IsSpellOffCooldown(spellID)
    if not GetSpellCooldown then
        return true
    end
    local start, duration = GetSpellCooldown(spellID)
    if not start or start == 0 then
        return true
    end
    if duration and duration <= 1.5 then
        return true
    end
    return ((start + duration) - GetTime()) <= 0.05
end

------------------------------------------------------------------------
-- Dual-Resource Timeline Sampling & Druid Form Transitions
------------------------------------------------------------------------

local function RecordPowerSample(now, force)
    if not currentFight then
        return
    end

    local powerType, _, current, maximum = GetActivePowerInfo()
    local elapsed = now - lastSampleTime
    local delta = abs(current - lastSamplePower)

    if maximum > 0 and (force or elapsed >= SAMPLE_MIN_INTERVAL or delta >= 5) then
        lastSampleTime = now
        lastSamplePower = current
        tinsert(currentFight.samples, {
            t = now - currentFight.startTime,
            powerType = powerType,
            power = current,
            powerMax = maximum,
        })
    end

    local secType, secVal, secMax, extra = GetSecondaryState(now, powerType)
    if secType then
        local secElapsed = now - lastSecSampleTime
        local secChanged = (secVal ~= lastSecSampleVal)
        if force or secChanged or secElapsed >= SAMPLE_MIN_INTERVAL then
            lastSecSampleTime = now
            lastSecSampleVal = secVal
            tinsert(currentFight.secondarySamples, {
                t = now - currentFight.startTime,
                secondaryType = secType,
                value = secVal,
                maxValue = secMax,
                extra = extra,
            })
        end
    end
end

local function RecordFormTransition(now)
    if not isRecording or not currentFight or playerClass ~= "DRUID" then
        return
    end

    local relTime = now - currentFight.startTime
    local formKey, formPowerType = DetectDruidForm()
    local segments = currentFight.formSegments
    local activeSeg = segments[#segments]

    if activeSeg and activeSeg.form == formKey and activeSeg.endTime == nil then
        return
    end

    RecordPowerSample(now, true)

    if activeSeg and activeSeg.endTime == nil then
        activeSeg.endTime = relTime
    end

    tinsert(segments, {
        form = formKey,
        powerType = formPowerType,
        startTime = relTime,
        endTime = nil,
    })

    RecordPowerSample(now, true)
end

------------------------------------------------------------------------
-- Shaman Totem Slot Transition Tracker
------------------------------------------------------------------------

local function OnTotemUpdate(slot)
    if not isRecording or not currentFight or playerClass ~= "SHAMAN" then
        return
    end
    if not slot or slot < 1 or slot > 4 or not GetTotemInfo then
        return
    end

    local now = GetTime()
    local relTime = now - currentFight.startTime
    local haveTotem, name, startTime, duration, icon = GetTotemInfo(slot)
    local prev = totemSlotState[slot]

    if haveTotem and name and name ~= "" and duration and duration > 0 then
        local clippedRemaining = 0
        local prevName = nil
        local emptyGap = nil

        if prev and prev.active and prev.endTime > now then
            clippedRemaining = prev.endTime - now
            prevName = prev.name
        elseif prev and prev.lastExpiredAt and prev.lastExpiredAt > 0 then
            emptyGap = max(0, relTime - prev.lastExpiredAt)
        end

        totemSlotState[slot] = {
            active = true,
            name = name,
            startTime = startTime,
            duration = duration,
            endTime = startTime + duration,
            icon = icon,
            lastExpiredAt = nil,
        }

        tinsert(currentFight.totemEvents, {
            t = relTime,
            slot = slot,
            action = "DROPPED",
            totemName = name,
            duration = duration,
            icon = icon,
            clippedRemaining = clippedRemaining,
            clippedTotemName = prevName,
            emptyGap = emptyGap,
        })
    else
        if prev and prev.active then
            totemSlotState[slot] = {
                active = false,
                lastExpiredAt = relTime,
            }
            tinsert(currentFight.totemEvents, {
                t = relTime,
                slot = slot,
                action = "EXPIRED",
                totemName = prev.name,
            })
        end
    end

    RecordPowerSample(now, true)
end

------------------------------------------------------------------------
-- 15ms Macro Burst Resolution
------------------------------------------------------------------------

local function BuildEventRecord(entry, outcome, burstSize, fallbackNotes)
    local powerBefore = entry.powerBefore
    local cost = entry.spellCost
    local powerAfter = powerBefore
    if outcome == "SUCCEEDED" and cost > 0 then
        powerAfter = max(0, powerBefore - cost)
    end

    return {
        t = entry.sentTime - currentFight.startTime,
        spellID = entry.spellID,
        spellName = entry.spellName,
        spellIcon = entry.spellIcon,
        castGUID = entry.castGUID,
        outcome = outcome,
        powerType = entry.powerType,
        powerBefore = powerBefore,
        powerAfter = powerAfter,
        powerMax = entry.powerMax,
        spellCost = cost,
        druidForm = entry.druidForm,
        secondaryType = entry.secondaryType,
        secondaryBefore = entry.secondaryBefore,
        secondaryMax = entry.secondaryMax,
        petAlive = entry.petAlive,
        burstSize = burstSize,
        pressCount = 1,
        fallbackNotes = fallbackNotes,
        verdict = nil,
        note = nil,
    }
end

function Collector:FlushActiveBurst()
    if not activeBurst or not currentFight then
        activeBurst = nil
        return
    end

    local burst = activeBurst
    activeBurst = nil

    local succeededEntries = {}
    local resourceFailedEntries = {}

    for i = 1, #burst.entries do
        local entry = burst.entries[i]
        if entry.castGUID then
            castGuidIndex[entry.castGUID] = nil
        end

        if entry.state == "SUCCEEDED" then
            tinsert(succeededEntries, entry)
        elseif entry.state == "FAILED_RESOURCE" then
            tinsert(resourceFailedEntries, entry)
        end
    end

    if #succeededEntries > 0 then
        local fallbackNotes = nil
        if #resourceFailedEntries > 0 then
            fallbackNotes = {}
            for i = 1, #resourceFailedEntries do
                local f = resourceFailedEntries[i]
                local deficit = max(0, f.spellCost - f.powerBefore)
                tinsert(fallbackNotes, {
                    spellID = f.spellID,
                    spellName = f.spellName,
                    deficit = deficit,
                })
            end
        end

        local runningPower = succeededEntries[1].powerBefore
        for i = 1, #succeededEntries do
            local entry = succeededEntries[i]
            if i > 1 and entry.powerType == succeededEntries[i - 1].powerType then
                entry.powerBefore = runningPower
            end
            local rec = BuildEventRecord(
                entry,
                "SUCCEEDED",
                #succeededEntries,
                (i == 1) and fallbackNotes or nil
            )
            runningPower = rec.powerAfter
            tinsert(currentFight.events, rec)
        end
        return
    end

    if #resourceFailedEntries > 0 then
        local primaryFail = resourceFailedEntries[1]
        local debounce = (NS.Addon and NS.Addon.db and NS.Addon.db.thresholds.spamDebounceSeconds)
            or SPAM_DEBOUNCE_WINDOW

        local prev = lastStarvedBySpell[primaryFail.spellID]
        local relTime = primaryFail.sentTime - currentFight.startTime
        if prev and (relTime - prev.t) <= debounce then
            prev.pressCount = (prev.pressCount or 1) + 1
            prev.powerBefore = primaryFail.powerBefore
            return
        end

        local rec = BuildEventRecord(primaryFail, "FAILED_RESOURCE", 1, nil)
        lastStarvedBySpell[primaryFail.spellID] = rec
        tinsert(currentFight.events, rec)
    end
end

local function AppendToBurst(now, spellID, castGUID)
    if activeBurst and (now - activeBurst.startTime) > MACRO_BURST_WINDOW then
        Collector:FlushActiveBurst()
    end

    if not activeBurst then
        activeBurst = {
            startTime = now,
            lastSentTime = now,
            entries = {},
        }
    else
        activeBurst.lastSentTime = now
    end

    local powerType, _, currentPower, maxPower = GetActivePowerInfo()
    local spellCost, costPowerType = GetSpellCostForPower(spellID, powerType)
    if costPowerType ~= powerType then
        currentPower = UnitPower("player", costPowerType) or currentPower
        maxPower = UnitPowerMax("player", costPowerType) or maxPower
        powerType = costPowerType
    end

    local secType, secVal, secMax, extra = GetSecondaryState(now, powerType)
    local druidForm = (playerClass == "DRUID") and select(1, DetectDruidForm()) or nil
    local name, _, icon = GetSpellInfo(spellID)

    local entry = {
        sentTime = now,
        spellID = spellID,
        spellName = name or ("Spell #" .. tostring(spellID)),
        spellIcon = icon,
        castGUID = castGUID,
        powerType = powerType,
        powerBefore = currentPower,
        powerMax = maxPower,
        spellCost = spellCost,
        druidForm = druidForm,
        secondaryType = secType,
        secondaryBefore = secVal,
        secondaryMax = secMax,
        petAlive = extra and extra.petAlive or nil,
        offCD = IsSpellOffCooldown(spellID),
        state = "PENDING",
    }

    tinsert(activeBurst.entries, entry)
    if castGUID then
        castGuidIndex[castGUID] = entry
    end
end

------------------------------------------------------------------------
-- Event Handlers
------------------------------------------------------------------------

local function OnSpellcastSent(unit, _, castGUID, spellID)
    if not isRecording or unit ~= "player" then
        return
    end
    if not IsSpellUnlocked(spellID) then
        return
    end

    local now = GetTime()
    RecordPowerSample(now, false)
    AppendToBurst(now, spellID, castGUID)
end

local function OnSpellcastSucceeded(unit, castGUID, spellID)
    if not isRecording then
        return
    end

    local now = GetTime()

    if unit == "pet" and playerClass == "HUNTER" and currentFight then
        local petFocus, petMax = ReadPetFocus()
        local name, _, icon = GetSpellInfo(spellID)
        local cost = GetSpellCostForPower(spellID, 2)
        tinsert(currentFight.petCasts, {
            t = now - currentFight.startTime,
            spellID = spellID,
            spellName = name or ("Pet Spell #" .. tostring(spellID)),
            spellIcon = icon,
            focusBefore = petFocus + (cost or 0),
            focusAfter = petFocus,
            focusMax = petMax,
            cost = cost or 0,
        })
        RecordPowerSample(now, true)
        return
    end

    if unit ~= "player" then
        return
    end

    local entry = castGUID and castGuidIndex[castGUID]
    if entry then
        entry.state = "SUCCEEDED"
    elseif IsSpellUnlocked(spellID) then
        AppendToBurst(now, spellID, castGUID)
        local latest = activeBurst.entries[#activeBurst.entries]
        if latest then
            latest.state = "SUCCEEDED"
        end
    end

    RecordPowerSample(now, true)
end

local function OnSpellcastFailed(unit, castGUID)
    if not isRecording or unit ~= "player" then
        return
    end
    local entry = castGUID and castGuidIndex[castGUID]
    if entry and entry.state == "PENDING" then
        entry.state = "FAILED_OTHER"
    end
end

local function OnUIErrorMessage(arg1, arg2)
    if not isRecording or not activeBurst then
        return
    end

    local msg = (type(arg2) == "string" and arg2) or (type(arg1) == "string" and arg1)
    if not msg or not RESOURCE_ERRORS[msg] then
        return
    end

    local now = GetTime()
    for i = #activeBurst.entries, 1, -1 do
        local entry = activeBurst.entries[i]
        if (now - entry.sentTime) <= ERROR_CORRELATION_WINDOW then
            if entry.state == "PENDING" or entry.state == "FAILED_OTHER" then
                entry.state = "FAILED_RESOURCE"
                break
            end
        end
    end
end

local function OnCombatLogEvent()
    if not isRecording or not currentFight then
        return
    end

    local _, subevent, _, _, _, _, _, destGUID, _, _, _,
          spellID, spellName, _, amount, overEnergize, powerType = CombatLogGetCurrentEventInfo()

    local petGUID = UnitExists("pet") and UnitGUID("pet") or nil
    if destGUID ~= playerGUID and destGUID ~= petGUID then
        return
    end

    if subevent == "SPELL_ENERGIZE" or subevent == "SPELL_PERIODIC_ENERGIZE" then
        local isPet = (destGUID == petGUID and destGUID ~= playerGUID)
        local unitToken = isPet and "pet" or "player"
        local activeType = isPet and 2 or UnitPowerType("player")
        local pType = powerType or activeType
        local currentPower = UnitPower(unitToken, pType) or 0
        local maxPower = UnitPowerMax(unitToken, pType) or 0

        local wasted = 0
        if type(overEnergize) == "number" and overEnergize > 0 then
            wasted = overEnergize
        elseif maxPower > 0 and currentPower >= maxPower and type(amount) == "number" and amount > 0 then
            wasted = amount
        end

        if wasted > 0 then
            tinsert(currentFight.overcaps, {
                t = GetTime() - currentFight.startTime,
                spellID = spellID,
                spellName = isPet and ("Pet: " .. (spellName or "Focus")) or spellName,
                powerType = isPet and SECONDARY.PET_FOCUS or pType,
                amount = amount or 0,
                wasted = wasted,
                powerMax = maxPower,
                isPet = isPet,
            })
        end
    end
end

------------------------------------------------------------------------
-- Public Lifecycle API
------------------------------------------------------------------------

function Collector:Init()
    playerGUID = UnitGUID("player")
    local _, cls = UnitClass("player")
    playerClass = cls

    collectorFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "UNIT_SPELLCAST_SENT" then
            OnSpellcastSent(...)
        elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
            OnSpellcastSucceeded(...)
        elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_FAILED_QUIET" then
            OnSpellcastFailed(...)
        elseif event == "UI_ERROR_MESSAGE" then
            OnUIErrorMessage(...)
        elseif event == "UNIT_POWER_FREQUENT" then
            local unit = ...
            if isRecording and (unit == "player" or unit == "pet") then
                RecordPowerSample(GetTime(), false)
            end
        elseif event == "UNIT_COMBO_POINTS" then
            if isRecording then
                RecordPowerSample(GetTime(), true)
            end
        elseif event == "PLAYER_TOTEM_UPDATE" then
            local slot = ...
            OnTotemUpdate(slot)
        elseif event == "UPDATE_SHAPESHIFT_FORM" or event == "UNIT_DISPLAYPOWER" then
            if isRecording and playerClass == "DRUID" then
                RecordFormTransition(GetTime())
            end
        elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
            OnCombatLogEvent()
        end
    end)

    collectorFrame:SetScript("OnUpdate", function()
        if isRecording and activeBurst then
            if (GetTime() - activeBurst.lastSentTime) >= BURST_FLUSH_DELAY then
                Collector:FlushActiveBurst()
            end
        end
    end)
end

function Collector:StartCombat(meta)
    playerGUID = UnitGUID("player")
    local _, cls = UnitClass("player")
    playerClass = cls or meta.playerClass

    activeBurst = nil
    castGuidIndex = {}
    lastStarvedBySpell = {}
    totemSlotState = {}
    lastSampleTime = 0
    lastSamplePower = -1
    lastSecSampleTime = 0
    lastSecSampleVal = -1

    currentFight = {
        id = meta.id,
        timestamp = meta.timestamp,
        playerGUID = playerGUID,
        playerClass = playerClass,
        playerLevel = meta.playerLevel,
        targetName = meta.targetName,
        startTime = meta.startTime,
        endTime = nil,
        duration = 0,
        events = {},
        samples = {},
        secondarySamples = {},
        formSegments = {},
        overcaps = {},
        petCasts = {},
        totemEvents = {},
        score = nil,
    }

    isRecording = true

    if playerClass == "DRUID" then
        RecordFormTransition(meta.startTime)
    end

    if playerClass == "SHAMAN" and GetTotemInfo then
        for slot = 1, 4 do
            local haveTotem, name, startTime, duration, icon = GetTotemInfo(slot)
            if haveTotem and name and duration and duration > 0 then
                totemSlotState[slot] = {
                    active = true,
                    name = name,
                    startTime = startTime,
                    duration = duration,
                    endTime = startTime + duration,
                    icon = icon,
                }
            end
        end
    end

    RecordPowerSample(meta.startTime, true)

    collectorFrame:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
    collectorFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "pet")
    collectorFrame:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
    collectorFrame:RegisterUnitEvent("UNIT_SPELLCAST_FAILED_QUIET", "player")
    collectorFrame:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player", "pet")
    collectorFrame:RegisterUnitEvent("UNIT_DISPLAYPOWER", "player")
    collectorFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
    collectorFrame:RegisterEvent("UNIT_COMBO_POINTS")
    collectorFrame:RegisterEvent("PLAYER_TOTEM_UPDATE")
    collectorFrame:RegisterEvent("UI_ERROR_MESSAGE")
    collectorFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
end

function Collector:StopCombat()
    if not isRecording or not currentFight then
        return nil
    end

    local now = GetTime()
    self:FlushActiveBurst()
    RecordPowerSample(now, true)

    if currentFight.formSegments and #currentFight.formSegments > 0 then
        local lastSeg = currentFight.formSegments[#currentFight.formSegments]
        if lastSeg and lastSeg.endTime == nil then
            lastSeg.endTime = now - currentFight.startTime
        end
    end

    isRecording = false
    collectorFrame:UnregisterAllEvents()

    currentFight.endTime = now
    currentFight.duration = max(0, now - currentFight.startTime)

    local finished = currentFight
    currentFight = nil
    castGuidIndex = {}
    lastStarvedBySpell = {}
    totemSlotState = {}
    return finished
end
