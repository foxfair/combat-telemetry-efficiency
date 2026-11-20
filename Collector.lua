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
local C_Spell = C_Spell
local LegacyGetSpellInfo = GetSpellInfo
local LegacyGetSpellTexture = GetSpellTexture
local LegacyGetSpellPowerCost = GetSpellPowerCost
local LegacyGetSpellCooldown = GetSpellCooldown

local function CompatGetSpellTexture(spellID)
    if C_Spell and C_Spell.GetSpellTexture then
        local icon = C_Spell.GetSpellTexture(spellID)
        if icon ~= nil then
            return icon
        end
    end
    if LegacyGetSpellTexture then
        local icon = LegacyGetSpellTexture(spellID)
        if icon ~= nil then
            return icon
        end
    end
    return nil
end

local function CompatGetSpellInfo(spellID)
    if LegacyGetSpellInfo then
        local name, rank, icon, castTime, minRange, maxRange, id = LegacyGetSpellInfo(spellID)
        if icon == nil then
            icon = CompatGetSpellTexture(spellID)
        end
        return name, rank, icon, castTime, minRange, maxRange, id
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info then
            local icon = info.iconID or info.originalIconID or CompatGetSpellTexture(spellID)
            return info.name, nil, icon, info.castTime, info.minRange, info.maxRange, info.spellID
        end
    end
    return nil, nil, CompatGetSpellTexture(spellID)
end

local function CompatGetSpellPowerCost(spellID)
    if LegacyGetSpellPowerCost then
        return LegacyGetSpellPowerCost(spellID)
    end
    if C_Spell and C_Spell.GetSpellPowerCost then
        return C_Spell.GetSpellPowerCost(spellID)
    end
    return nil
end

local function CompatGetSpellCooldown(spellID)
    if LegacyGetSpellCooldown then
        return LegacyGetSpellCooldown(spellID)
    end
    if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(spellID)
        if info then
            return info.startTime, info.duration, info.isEnabled, info.modRate
        end
    end
    return 0, 0, true, 1
end

local GetSpellInfo = CompatGetSpellInfo
local GetSpellPowerCost = CompatGetSpellPowerCost
local GetSpellCooldown = CompatGetSpellCooldown
local IsPlayerSpell = IsPlayerSpell
local IsSpellKnown = IsSpellKnown
local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo
local tinsert = table.insert
local max = math.max
local abs = math.abs
local issecretvalue = issecretvalue

local function IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function SafeNumber(v, fallback)
    if v == nil or IsSecret(v) or type(v) ~= "number" then
        return fallback
    end
    return v
end

local function SafeString(v, fallback)
    if v == nil or IsSecret(v) or type(v) ~= "string" then
        return fallback
    end
    return v
end

local function SafeBool(v)
    if v == nil or IsSecret(v) then
        return false
    end
    return v and true or false
end

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
local activeCastEnd = 0
local activeCastGUID = nil
local lastSampleTime = 0
local lastSamplePower = -1
local lastSecSampleTime = 0
local lastSecSampleVal = -1
local totemSlotState = {}
local cachedPowerMax = {}
local cachedPowerVal = {}

local collectorFrame = CreateFrame("Frame")

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
        return nil, SafeNumber(UnitPowerType("player"), 0)
    end

    local formIdx = SafeNumber(GetShapeshiftForm(), 0)
    if formIdx == 0 then
        return "CASTER", 0
    end

    if GetShapeshiftFormInfo then
        local icon, _, _, spellID = GetShapeshiftFormInfo(formIdx)
        local safeSpellID = SafeNumber(spellID, nil)
        if safeSpellID and DRUID_FORM_SPELL_IDS[safeSpellID] then
            local formKey = DRUID_FORM_SPELL_IDS[safeSpellID]
            local pType = (formKey == "BEAR" and 1) or (formKey == "CAT" and 3) or 0
            return formKey, pType
        end

        local safeIcon = SafeString(icon, nil)
        if safeIcon then
            if safeIcon:find("BearForm", 1, true) then
                return "BEAR", 1
            elseif safeIcon:find("CatForm", 1, true) then
                return "CAT", 3
            elseif safeIcon:find("ForceOfNature", 1, true) or safeIcon:find("Moonkin", 1, true) then
                return "MOONKIN", 0
            elseif safeIcon:find("TravelForm", 1, true) or safeIcon:find("AquaticForm", 1, true) then
                return "TRAVEL", 0
            end
        end
    end

    local pType = SafeNumber(UnitPowerType("player"), 0)
    if pType == 1 then
        return "BEAR", 1
    elseif pType == 3 then
        return "CAT", 3
    end
    return "CASTER", 0
end

local function GetActivePowerInfo()
    local rawType, rawToken = UnitPowerType("player")
    local powerType = SafeNumber(rawType, 0)
    local powerToken = SafeString(rawToken, "")

    local rawCurrent = UnitPower("player", powerType)
    local rawMaximum = UnitPowerMax("player", powerType)

    local currentIsSecret = IsSecret(rawCurrent)
    local maxIsSecret = IsSecret(rawMaximum)

    local maximum = SafeNumber(rawMaximum, nil)
    if maximum and maximum > 0 then
        cachedPowerMax[powerType] = maximum
    else
        maximum = cachedPowerMax[powerType] or 100
    end

    local current = SafeNumber(rawCurrent, nil)
    if current ~= nil then
        cachedPowerVal[powerType] = current
    else
        current = cachedPowerVal[powerType] or 0
        if currentFight and (currentIsSecret or maxIsSecret) then
            currentFight.secretPowerDrops = (currentFight.secretPowerDrops or 0) + 1
        end
    end

    return powerType, powerToken, current, maximum, (currentIsSecret or maxIsSecret)
end

local function ReadComboPoints()
    local cp = SafeNumber(UnitPower and UnitPower("player", 4), nil)
    if (not cp or cp == 0) and GetComboPoints then
        cp = SafeNumber(GetComboPoints("player", "target"), 0)
    end
    cp = cp or 0
    local maxCp = SafeNumber(UnitPowerMax and UnitPowerMax("player", 4), 5)
    if maxCp <= 0 then
        maxCp = 5
    end
    return cp, maxCp
end

local function HasLivingPet()
    return SafeBool(UnitExists("pet")) and not SafeBool(UnitIsDead("pet"))
end

local function ReadPetFocus()
    if not HasLivingPet() then
        return 0, 0, false
    end
    local cur = SafeNumber(UnitPower("pet", 2), 0)
    local maximum = SafeNumber(UnitPowerMax("pet", 2), 100)
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
        local rawHave, rawName, rawStart, rawDur, rawIcon = GetTotemInfo(slot)
        local haveTotem = SafeBool(rawHave)
        local name = SafeString(rawName, "")
        local startTime = SafeNumber(rawStart, 0)
        local duration = SafeNumber(rawDur, 0)
        local icon = SafeNumber(rawIcon, nil) or SafeString(rawIcon, nil)
        local remaining = 0
        if haveTotem and startTime > 0 and duration > 0 then
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
            local mana = SafeNumber(UnitPower("player", 0), cachedPowerVal[0] or 0)
            local manaMax = SafeNumber(UnitPowerMax("player", 0), cachedPowerMax[0] or 0)
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

    local cost = SafeNumber(chosen.cost, nil) or SafeNumber(chosen.minCost, 0)
    local cType = SafeNumber(chosen.type, preferredPowerType)
    return cost, cType
end

local function IsSpellOffCooldown(spellID)
    if not GetSpellCooldown then
        return true
    end
    local rawStart, rawDuration = GetSpellCooldown(spellID)
    local start = SafeNumber(rawStart, 0)
    local duration = SafeNumber(rawDuration, 0)
    if start == 0 then
        return true
    end
    if duration <= 1.5 then
        return true
    end
    return ((start + duration) - GetTime()) <= 0.05
end

local function RecordPowerSample(now, force)
    if not currentFight then
        return
    end

    local powerType, _, current, maximum, isSecretPower = GetActivePowerInfo()
    local elapsed = now - lastSampleTime
    local delta = isSecretPower and 0 or abs(current - lastSamplePower)

    if maximum > 0 and (force or elapsed >= SAMPLE_MIN_INTERVAL or delta >= 5) then
        lastSampleTime = now
        lastSamplePower = current
        tinsert(currentFight.samples, {
            t = now - currentFight.startTime,
            powerType = powerType,
            power = current,
            powerMax = maximum,
            isSecret = isSecretPower and true or false,
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

local function OnTotemUpdate(slot)
    if not isRecording or not currentFight or playerClass ~= "SHAMAN" then
        return
    end
    if not slot or slot < 1 or slot > 4 or not GetTotemInfo then
        return
    end

    local now = GetTime()
    local relTime = now - currentFight.startTime
    local rawHave, rawName, rawStart, rawDur, rawIcon = GetTotemInfo(slot)
    local haveTotem = SafeBool(rawHave)
    local name = SafeString(rawName, "")
    local startTime = SafeNumber(rawStart, 0)
    local duration = SafeNumber(rawDur, 0)
    local icon = SafeNumber(rawIcon, nil) or SafeString(rawIcon, nil)
    local prev = totemSlotState[slot]

    if haveTotem and name ~= "" and duration > 0 then
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
        powerIsSecret = entry.powerIsSecret and true or false,
        spellCost = cost,
        castTime = entry.castTime or 0,
        finishTime = entry.finishTime and (entry.finishTime - currentFight.startTime) or nil,
        isPreCast = entry.isPreCast and true or false,
        preCastLead = entry.preCastLead or 0,
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

    local powerType, _, currentPower, maxPower, powerIsSecret = GetActivePowerInfo()
    local spellCost, costPowerType = GetSpellCostForPower(spellID, powerType)
    if costPowerType ~= powerType then
        local rawAltCur = UnitPower("player", costPowerType)
        local rawAltMax = UnitPowerMax("player", costPowerType)
        powerIsSecret = IsSecret(rawAltCur) or IsSecret(rawAltMax)
        currentPower = SafeNumber(rawAltCur, cachedPowerVal[costPowerType] or currentPower)
        maxPower = SafeNumber(rawAltMax, cachedPowerMax[costPowerType] or maxPower)
        powerType = costPowerType
    end

    local secType, secVal, secMax, extra = GetSecondaryState(now, powerType)
    local druidForm = (playerClass == "DRUID") and select(1, DetectDruidForm()) or nil
    local rawName, _, rawIcon, rawCastTime = GetSpellInfo(spellID)
    local name = SafeString(rawName, nil)
    local icon = SafeNumber(rawIcon, nil) or SafeString(rawIcon, nil)
    local castTimeSec = max(0, SafeNumber(rawCastTime, 0) / 1000.0)
    local safeCastGUID = SafeString(castGUID, nil)

    -- Detect Spell-Queue / Pre-Cast: player pressed next spell inside the spell queue window before active cast finished
    local isPreCast = false
    local preCastLead = 0
    if activeCastEnd > now and (activeCastEnd - now) <= 0.65 and safeCastGUID ~= activeCastGUID then
        isPreCast = true
        preCastLead = activeCastEnd - now
    end

    local entry = {
        sentTime = now,
        finishTime = nil,
        isPreCast = isPreCast,
        preCastLead = preCastLead,
        spellID = spellID,
        spellName = name or ("Spell #" .. tostring(spellID)),
        spellIcon = icon,
        castGUID = safeCastGUID,
        powerType = powerType,
        powerBefore = currentPower,
        powerMax = maxPower,
        powerIsSecret = powerIsSecret and true or false,
        spellCost = spellCost,
        castTime = castTimeSec,
        druidForm = druidForm,
        secondaryType = secType,
        secondaryBefore = secVal,
        secondaryMax = secMax,
        petAlive = extra and extra.petAlive or nil,
        offCD = IsSpellOffCooldown(spellID),
        state = "PENDING",
    }

    if castTimeSec > 0 then
        activeCastEnd = now + castTimeSec
        activeCastGUID = safeCastGUID
    end

    tinsert(activeBurst.entries, entry)
    if safeCastGUID then
        castGuidIndex[safeCastGUID] = entry
    end
end

local function OnSpellcastSent(unit, _, castGUID, spellID)
    if not isRecording or SafeString(unit, "") ~= "player" then
        return
    end
    local safeSpellID = SafeNumber(spellID, nil)
    if not safeSpellID or not IsSpellUnlocked(safeSpellID) then
        return
    end

    local now = GetTime()
    RecordPowerSample(now, false)
    AppendToBurst(now, safeSpellID, SafeString(castGUID, nil))
end

local function OnSpellcastSucceeded(unit, castGUID, spellID)
    if not isRecording then
        return
    end

    local safeUnit = SafeString(unit, "")
    local safeSpellID = SafeNumber(spellID, nil)
    local safeCastGUID = SafeString(castGUID, nil)
    local now = GetTime()

    if safeUnit == "pet" and playerClass == "HUNTER" and currentFight and safeSpellID then
        local petFocus, petMax = ReadPetFocus()
        local rawName, _, rawIcon = GetSpellInfo(safeSpellID)
        local name = SafeString(rawName, nil)
        local icon = SafeNumber(rawIcon, nil) or SafeString(rawIcon, nil)
        local cost = GetSpellCostForPower(safeSpellID, 2)
        tinsert(currentFight.petCasts, {
            t = now - currentFight.startTime,
            spellID = safeSpellID,
            spellName = name or ("Pet Spell #" .. tostring(safeSpellID)),
            spellIcon = icon,
            focusBefore = petFocus + (cost or 0),
            focusAfter = petFocus,
            focusMax = petMax,
            cost = cost or 0,
        })
        RecordPowerSample(now, true)
        return
    end

    if safeUnit ~= "player" then
        return
    end

    local entry = safeCastGUID and castGuidIndex[safeCastGUID]
    if entry then
        entry.state = "SUCCEEDED"
        entry.finishTime = now
        if safeCastGUID == activeCastGUID then
            activeCastEnd = now
            activeCastGUID = nil
        end
    elseif safeSpellID and IsSpellUnlocked(safeSpellID) then
        AppendToBurst(now, safeSpellID, safeCastGUID)
        local latest = activeBurst.entries[#activeBurst.entries]
        if latest then
            latest.state = "SUCCEEDED"
            latest.finishTime = now
        end
    end

    RecordPowerSample(now, true)
end

local function OnSpellcastFailed(unit, castGUID)
    if not isRecording or SafeString(unit, "") ~= "player" then
        return
    end
    local safeCastGUID = SafeString(castGUID, nil)
    local entry = safeCastGUID and castGuidIndex[safeCastGUID]
    if entry and entry.state == "PENDING" then
        entry.state = "FAILED_OTHER"
        if safeCastGUID == activeCastGUID then
            activeCastEnd = 0
            activeCastGUID = nil
        end
    end
end

local function OnUIErrorMessage(arg1, arg2)
    if not isRecording or not activeBurst then
        return
    end

    local msg = SafeString(arg2, nil) or SafeString(arg1, nil)
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
    if not isRecording or not currentFight or not CombatLogGetCurrentEventInfo then
        return
    end

    local _, rawSub, _, _, _, _, _, rawDestGUID, _, _, _,
          rawSpellID, rawSpellName, _, rawAmount, rawOver, rawPType = CombatLogGetCurrentEventInfo()

    local subevent = SafeString(rawSub, "")
    if subevent ~= "SPELL_ENERGIZE" and subevent ~= "SPELL_PERIODIC_ENERGIZE" then
        return
    end

    local destGUID = SafeString(rawDestGUID, nil)
    if not destGUID then
        return
    end

    local petGUID = SafeBool(UnitExists("pet")) and SafeString(UnitGUID("pet"), nil) or nil
    if destGUID ~= playerGUID and destGUID ~= petGUID then
        return
    end

    local isPet = (destGUID == petGUID and destGUID ~= playerGUID)
    local unitToken = isPet and "pet" or "player"
    local activeType = isPet and 2 or SafeNumber(UnitPowerType("player"), 0)
    local pType = SafeNumber(rawPType, activeType)
    local currentPower = SafeNumber(UnitPower(unitToken, pType), cachedPowerVal[pType] or 0)
    local maxPower = SafeNumber(UnitPowerMax(unitToken, pType), cachedPowerMax[pType] or 0)

    local amount = SafeNumber(rawAmount, 0)
    local overEnergize = SafeNumber(rawOver, 0)
    local spellID = SafeNumber(rawSpellID, 0)
    local spellName = SafeString(rawSpellName, "Resource Gain")

    local wasted = 0
    if overEnergize > 0 then
        wasted = overEnergize
    elseif maxPower > 0 and currentPower >= maxPower and amount > 0 then
        wasted = amount
    end

    if wasted > 0 then
        tinsert(currentFight.overcaps, {
            t = GetTime() - currentFight.startTime,
            spellID = spellID,
            spellName = isPet and ("Pet: " .. spellName) or spellName,
            powerType = isPet and SECONDARY.PET_FOCUS or pType,
            amount = amount,
            wasted = wasted,
            powerMax = maxPower,
            isPet = isPet,
        })
    end
end

function Collector:Init()
    playerGUID = SafeString(UnitGUID("player"), nil)
    local _, cls = UnitClass("player")
    playerClass = SafeString(cls, nil)
    -- Prime out-of-combat power cache so max/current fallback values are ready before combat
    pcall(GetActivePowerInfo)

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
            local unit = SafeString(..., "")
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
        end
    end)

    collectorFrame:SetScript("OnUpdate", function()
        if isRecording and activeBurst then
            if (GetTime() - activeBurst.lastSentTime) >= BURST_FLUSH_DELAY then
                Collector:FlushActiveBurst()
            end
        end
    end)

    -- Register combat events once out of combat to avoid ADDON_ACTION_BLOCKED during lockdown.
    -- Note: COMBAT_LOG_EVENT_UNFILTERED is intentionally omitted (triggers ADDON_ACTION_FORBIDDEN on 1.60.1).
    pcall(collectorFrame.RegisterUnitEvent, collectorFrame, "UNIT_SPELLCAST_SENT", "player")
    pcall(collectorFrame.RegisterUnitEvent, collectorFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "pet")
    pcall(collectorFrame.RegisterUnitEvent, collectorFrame, "UNIT_SPELLCAST_FAILED", "player")
    pcall(collectorFrame.RegisterUnitEvent, collectorFrame, "UNIT_SPELLCAST_FAILED_QUIET", "player")
    pcall(collectorFrame.RegisterUnitEvent, collectorFrame, "UNIT_POWER_FREQUENT", "player", "pet")
    pcall(collectorFrame.RegisterUnitEvent, collectorFrame, "UNIT_DISPLAYPOWER", "player")
    pcall(collectorFrame.RegisterEvent, collectorFrame, "UPDATE_SHAPESHIFT_FORM")
    pcall(collectorFrame.RegisterEvent, collectorFrame, "UNIT_COMBO_POINTS")
    pcall(collectorFrame.RegisterEvent, collectorFrame, "PLAYER_TOTEM_UPDATE")
    pcall(collectorFrame.RegisterEvent, collectorFrame, "UI_ERROR_MESSAGE")
end

function Collector:StartCombat(meta)
    playerGUID = SafeString(UnitGUID("player"), nil) or meta.playerGUID
    local _, cls = UnitClass("player")
    playerClass = SafeString(cls, nil) or meta.playerClass

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
        secretPowerDrops = 0,
        score = nil,
    }

    activeCastEnd = 0
    activeCastGUID = nil
    isRecording = true



    if playerClass == "DRUID" then
        pcall(RecordFormTransition, meta.startTime)
    end

    if playerClass == "SHAMAN" and GetTotemInfo then
        for slot = 1, 4 do
            local rawHave, rawName, rawStart, rawDur, rawIcon = GetTotemInfo(slot)
            local haveTotem = SafeBool(rawHave)
            local name = SafeString(rawName, "")
            local startTime = SafeNumber(rawStart, 0)
            local duration = SafeNumber(rawDur, 0)
            local icon = SafeNumber(rawIcon, nil) or SafeString(rawIcon, nil)
            if haveTotem and name ~= "" and duration > 0 then
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

    pcall(RecordPowerSample, meta.startTime, true)
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

    currentFight.endTime = now
    currentFight.duration = max(0, now - currentFight.startTime)

    local finished = currentFight
    currentFight = nil
    castGuidIndex = {}
    lastStarvedBySpell = {}
    totemSlotState = {}
    return finished
end
