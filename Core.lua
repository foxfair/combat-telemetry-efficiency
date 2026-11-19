local ADDON_NAME, NS = ...

local CreateFrame = CreateFrame
local GetTime = GetTime
local UnitName = UnitName
local UnitGUID = UnitGUID
local UnitClass = UnitClass
local UnitLevel = UnitLevel
local UnitExists = UnitExists
local UnitClassification = UnitClassification
local InCombatLockdown = InCombatLockdown
local SendChatMessage = SendChatMessage
local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local IsInGuild = IsInGuild
local issecretvalue = issecretvalue
local tonumber = tonumber

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
local wipe = wipe
local tinsert = table.insert
local tremove = table.remove
local format = string.format
local lower = string.lower
local upper = string.upper
local match = string.match

local Addon = {}
NS.Addon = Addon

local MAX_SAVED_FIGHTS = 10
local MIN_FIGHT_DURATION = 3.0

local MIN_HOARD_MULTIPLIER = 1.0
local MAX_HOARD_MULTIPLIER = 5.0
local MIN_HOARD_HOLD_SECONDS = 0.0
local MAX_HOARD_HOLD_SECONDS = 10.0
local MIN_AUTO_FADE_SECONDS = 3.0
local MAX_AUTO_FADE_SECONDS = 30.0
local MIN_IDLE_GAP_SECONDS = 0.2
local MAX_IDLE_GAP_SECONDS = 5.0
local MAX_STORED_ERRORS = 40

local DEFAULT_DB = {
    version = 1,
    maxFights = MAX_SAVED_FIGHTS,
    minDuration = MIN_FIGHT_DURATION,
    showPostCombatBanner = true,
    autoShowAfterCombat = false,
    autoFadeSeconds = 10.0,
    bossOnly = false,
    debug = false,
    errorLog = {},
    minimap = {
        hide = false,
        angle = 220,
    },
    windowPos = nil,
    pillPos = nil,
    thresholds = {
        hoardMultiplier = 2.0,
        hoardHoldSeconds = 1.0,
        idleGapSeconds = 0.6,
        spamDebounceSeconds = 0.40,
    },
    fights = {},
}

Addon.DEFAULT_DB = DEFAULT_DB

local function ApplyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then
                dst[k] = {}
            end
            ApplyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local function IsBossUnit(unit)
    if not unit or not UnitExists(unit) then
        return false
    end
    local classification = SafeString(UnitClassification(unit), "")
    if classification == "worldboss" then
        return true
    end
    local level = SafeNumber(UnitLevel(unit), 0)
    return level == -1
end

local function JsonEscape(str)
    local s = tostring(str or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    return '"' .. s .. '"'
end

local function JsonNum(val, fallback)
    local n = tonumber(val)
    if not n or n ~= n or n == math.huge or n == -math.huge then
        return tostring(fallback or 0)
    end
    return tostring(n)
end

local function JsonBool(val)
    return val and "true" or "false"
end

function Addon:RecordError(source, detail, isSecretDrop)
    local db = self:EnsureDB()
    if type(db.errorLog) ~= "table" then
        db.errorLog = {}
    end

    local safeSource = SafeString(source, "Runtime")
    local safeDetail = SafeString(detail, "Unknown error")
    local _, classFile = UnitClass("player")
    local safeClass = SafeString(classFile, "UNKNOWN")
    local entry = {
        timestamp = date and date("%Y-%m-%d %H:%M:%S") or tostring(time()),
        uptime = format("%.1fs", GetTime() or 0),
        playerClass = safeClass,
        source = safeSource,
        detail = safeDetail,
        secretDrop = isSecretDrop and true or false,
    }

    tinsert(db.errorLog, 1, entry)
    while #db.errorLog > MAX_STORED_ERRORS do
        tremove(db.errorLog)
    end
end

function Addon:GetErrorLog()
    local db = self:EnsureDB()
    if type(db.errorLog) ~= "table" then
        db.errorLog = {}
    end
    return db.errorLog
end

function Addon:ClearErrorLog()
    local db = self:EnsureDB()
    db.errorLog = {}
    self:Print("Cleared stored CTE error log.")
end

function Addon:BuildErrorLogText()
    local entries = self:GetErrorLog()
    if #entries == 0 then
        return "CTE Error Log: 0 recorded errors or secret-value drops.\n\nNo errors logged across sessions."
    end

    local lines = {
        format("CTE Error Log | Total Stored: %d (newest first)", #entries),
        "------------------------------------------------------------------------",
    }
    for i = 1, #entries do
        local e = entries[i]
        local kind = e.secretDrop and "SECRET_DROP" or "ERROR"
        tinsert(lines, format(
            "#%02d [%s] (%s | %s) %s: %s",
            i,
            e.timestamp or "?",
            e.playerClass or "?",
            kind,
            e.source or "Runtime",
            e.detail or ""
        ))
    end
    return table.concat(lines, "\n")
end

function Addon:HandleErrorsCommand(arg)
    local trimmed = lower(match(arg or "", "^%s*(.-)%s*$"))
    if trimmed == "clear" or trimmed == "reset" then
        self:ClearErrorLog()
        return
    end

    local text = self:BuildErrorLogText()
    local entries = self:GetErrorLog()
    local subtitle = format("%d stored entry(s)", #entries)

    if trimmed == "chat" then
        for line in string.gmatch(text, "[^\n]+") do
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9966" .. line .. "|r")
        end
        return
    end

    if NS.UI and NS.UI.ShowDumpWindow then
        NS.UI:ShowDumpWindow(text, subtitle, "CTE Error & Diagnostic Log", nil, nil)
    else
        for line in string.gmatch(text, "[^\n]+") do
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9966" .. line .. "|r")
        end
    end
end

function Addon:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[CTE]|r " .. tostring(msg))
end

function Addon:Debug(msg)
    if self.db and self.db.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff999999[CTE Debug]|r " .. tostring(msg))
    end
end

function Addon:GetLatestFight()
    if not self.db or not self.db.fights or #self.db.fights == 0 then
        return nil
    end
    return self.db.fights[1]
end

function Addon:StoreFight(fight)
    if not fight or not self.db then
        return
    end
    tinsert(self.db.fights, 1, fight)
    local limit = self.db.maxFights or MAX_SAVED_FIGHTS

    -- Evict oldest UNPINNED fights first so pinned parses stay protected
    while #self.db.fights > limit do
        local evictIdx = nil
        for i = #self.db.fights, 1, -1 do
            if not self.db.fights[i].pinned then
                evictIdx = i
                break
            end
        end
        if evictIdx then
            tremove(self.db.fights, evictIdx)
        else
            -- All stored fights are pinned; preserve them instead of evicting
            break
        end
    end
end

function Addon:TogglePinFight(index)
    if not self.db or not self.db.fights or #self.db.fights == 0 then
        self:Print("No recorded fight to pin.")
        return nil
    end
    local idx = index or 1
    local fight = self.db.fights[idx]
    if not fight then
        return nil
    end
    fight.pinned = not fight.pinned
    if NS.UI and NS.UI.Refresh then
        NS.UI:Refresh()
    end
    self:Print(format(
        "%s fight #%d (%s).",
        fight.pinned and "|cffffd100Pinned|r" or "Unpinned",
        idx,
        fight.targetName or "Encounter"
    ))
    return fight.pinned
end

function Addon:DeleteFight(index)
    if not self.db or not self.db.fights or #self.db.fights == 0 then
        self:Print("No recorded fight to delete.")
        return false
    end
    local idx = index or 1
    local fight = self.db.fights[idx]
    if not fight then
        return false
    end
    local name = fight.targetName or "Encounter"
    tremove(self.db.fights, idx)
    if NS.UI and NS.UI.Refresh then
        NS.UI:Refresh()
    end
    self:Print(format("Deleted fight #%d (%s).", idx, name))
    return true
end

function Addon:ClearHistory(includePinned)
    if not self.db or not self.db.fights then
        return
    end

    if includePinned then
        wipe(self.db.fights)
        if NS.UI and NS.UI.Refresh then
            NS.UI:Refresh()
        end
        self:Print("Cleared all recorded fight history (including pinned fights).")
        return
    end

    local keptPinned = 0
    for i = #self.db.fights, 1, -1 do
        if self.db.fights[i].pinned then
            keptPinned = keptPinned + 1
        else
            tremove(self.db.fights, i)
        end
    end

    if NS.UI and NS.UI.Refresh then
        NS.UI:Refresh()
    end

    if keptPinned > 0 then
        self:Print(format("Cleared unpinned fights (kept %d pinned). Use '/cte clear all' to wipe pinned fights.", keptPinned))
    else
        self:Print("Cleared all recorded fight history.")
    end
end

function Addon:ReanalyzeAllFights()
    if not self.db or not self.db.fights then
        return 0
    end
    local count = #self.db.fights
    if NS.Analyzer and NS.Analyzer.AnalyzeFight then
        for i = 1, count do
            NS.Analyzer:AnalyzeFight(self.db.fights[i], self.db.thresholds)
        end
    end
    if NS.UI and NS.UI.Refresh then
        NS.UI:Refresh()
    end
    return count
end

function Addon:PrintRescoreSummary(prefixMsg)
    local count = self:ReanalyzeAllFights()
    local latest = self:GetLatestFight()
    if count > 0 and latest then
        self:Print(format(
            "%s Re-scored %d fight(s) — Latest (%s): |cff5cc8ff%d%%|r.",
            prefixMsg,
            count,
            latest.targetName or "Encounter",
            latest.score or 100
        ))
    else
        self:Print(prefixMsg .. " (No stored fights to re-score yet.)")
    end
end



function Addon:BuildFightDumpText(fight, arg)
    local targetFight = fight or self:GetLatestFight()
    if not targetFight then
        return nil, "No recorded fight to dump. Enter combat first."
    end

    local trimmed = lower(match(arg or "", "^%s*(.-)%s*$"))
    local events = targetFight.events or {}
    local totalEvents = #events
    local limit = totalEvents -- Default to full fight in copyable window

    if trimmed ~= "" and trimmed ~= "all" then
        local parsed = tonumber(trimmed)
        if parsed and parsed > 0 then
            limit = math.floor(parsed)
        else
            return nil, "Usage: /cte dump [count|all]  (or /cte dump chat [count|all])"
        end
    end

    local startIdx = math.max(1, totalEvents - limit + 1)
    local lines = {}

    local header = format(
        "CTE Dump | Target: %s | Duration: %.2fs | Class: %s | Score: %s%% | Events: %d (showing %d-%d) | Samples: %d | SecSamples: %d | Overcaps: %d",
        targetFight.targetName or "Unknown",
        targetFight.duration or 0,
        targetFight.playerClass or "?",
        tostring(targetFight.score or 100),
        totalEvents,
        totalEvents > 0 and startIdx or 0,
        totalEvents,
        #(targetFight.samples or {}),
        #(targetFight.secondarySamples or {}),
        #(targetFight.overcaps or {})
    )
    tinsert(lines, header)

    if targetFight.formSegments and #targetFight.formSegments > 0 then
        local segParts = {}
        for i = 1, #targetFight.formSegments do
            local s = targetFight.formSegments[i]
            tinsert(segParts, format("%s(%.1f-%.1fs)", s.form or "?", s.startTime or 0, s.endTime or targetFight.duration or 0))
        end
        tinsert(lines, "Forms: " .. table.concat(segParts, " -> "))
    end

    if targetFight.totemEvents and #targetFight.totemEvents > 0 then
        tinsert(lines, format("Totem Events: %d recorded", #targetFight.totemEvents))
    end

    if (targetFight.secretPowerDrops or 0) > 0 then
        tinsert(lines, format("Note: Client returned secret power values %d time(s) during combat (fallback values used).", targetFight.secretPowerDrops))
    end
        if not targetFight._loggedSecretDrop then
            targetFight._loggedSecretDrop = true
            self:RecordError(
                "Collector:Power",
                format("Fight vs %s had %d secret power sample(s) (1.60.1 combat masking)", targetFight.targetName or "Unknown", targetFight.secretPowerDrops),
                true
            )
        end

    if targetFight.summary and targetFight.summary.activeUptimePct ~= nil then
        tinsert(lines, format(
            "Tempo: Active GCD Uptime %d%% | %.1f CPM | Idle Gaps: %d (%.1fs dead time)",
            targetFight.summary.activeUptimePct or 0,
            targetFight.summary.cpm or 0,
            targetFight.summary.idleGapCount or 0,
            targetFight.summary.totalIdleSeconds or 0
        ))
    end

    tinsert(lines, "------------------------------------------------------------------------")

    for i = startIdx, totalEvents do
        local ev = events[i]
        local formTag = ev.druidForm and ("[" .. ev.druidForm .. "] ") or ""
        local secTag = ""
        if ev.secondaryType ~= nil then
            secTag = format(" sec=%d/%d", ev.secondaryBefore or 0, ev.secondaryMax or 0)
        end
        local burstTag = ((ev.burstSize or 1) > 1) and format(" burst=%d", ev.burstSize) or ""
        local pressTag = ((ev.pressCount or 1) > 1) and format(" x%d", ev.pressCount) or ""
        local delta = (ev.powerAfter or 0) - (ev.powerBefore or 0)

        tinsert(lines, format(
            "#%02d t=%05.2fs | %s%s (id=%d) %s | p%d: %d->%d (d=%+d, cost=%d)%s%s%s | %s",
            i,
            ev.t or 0,
            formTag,
            ev.spellName or "?",
            ev.spellID or 0,
            ev.outcome or "?",
            ev.powerType or -1,
            ev.powerBefore or 0,
            ev.powerAfter or 0,
            delta,
            ev.spellCost or 0,
            secTag,
            burstTag,
            pressTag,
            ev.verdict or "NONE"
        ))
    end

    local subtitle = format(
        "%s (%.1fs) — %d/%d events",
        targetFight.targetName or "Unknown",
        targetFight.duration or 0,
        totalEvents > 0 and (totalEvents - startIdx + 1) or 0,
        totalEvents
    )
    return table.concat(lines, "\n"), subtitle
end

function Addon:BuildFightJsonText(fight, arg)
    local targetFight = fight or self:GetLatestFight()
    if not targetFight then
        return nil, "No recorded fight to export. Enter combat first."
    end

    local trimmed = lower(match(arg or "", "^%s*(.-)%s*$"))
    local events = targetFight.events or {}
    local totalEvents = #events
    local limit = totalEvents

    if trimmed ~= "" and trimmed ~= "all" and trimmed ~= "json" then
        local parsed = tonumber(trimmed)
        if parsed and parsed > 0 then
            limit = math.floor(parsed)
        else
            return nil, "Usage: /cte dump [json|chat] [count|all]"
        end
    end

    local startIdx = math.max(1, totalEvents - limit + 1)
    local sum = targetFight.summary or {}
    local evJson = {}

    for i = startIdx, totalEvents do
        local ev = events[i]
        tinsert(evJson, format(
            '    {"idx":%d,"t":%s,"spellID":%s,"spellName":%s,"outcome":%s,"powerType":%s,"powerBefore":%s,"powerAfter":%s,"powerMax":%s,"powerIsSecret":%s,"spellCost":%s,"castTime":%s,"verdict":%s,"note":%s}',
            i,
            JsonNum(ev.t, 0),
            JsonNum(ev.spellID, 0),
            JsonEscape(ev.spellName or "?"),
            JsonEscape(ev.outcome or "?"),
            JsonNum(ev.powerType, -1),
            JsonNum(ev.powerBefore, 0),
            JsonNum(ev.powerAfter, 0),
            JsonNum(ev.powerMax, 100),
            JsonBool(ev.powerIsSecret),
            JsonNum(ev.spellCost, 0),
            JsonNum(ev.castTime, 0),
            JsonEscape(ev.verdict or "NONE"),
            JsonEscape(ev.note or "")
        ))
    end

    local jsonStr = table.concat({
        "{",
        format('  "version": %s,', JsonEscape(C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "0.2.2")),
        format('  "targetName": %s,', JsonEscape(targetFight.targetName or "Unknown")),
        format('  "playerClass": %s,', JsonEscape(targetFight.playerClass or "UNKNOWN")),
        format('  "duration": %s,', JsonNum(targetFight.duration, 0)),
        format('  "score": %s,', JsonNum(targetFight.score, 100)),
        format('  "secretPowerDrops": %s,', JsonNum(targetFight.secretPowerDrops, 0)),
        format('  "summary": {"activeUptimePct":%s,"cpm":%s,"idleGapCount":%s,"totalIdleSeconds":%s,"efficient":%s,"earlyStarved":%s,"lateHoard":%s,"overcapWaste":%s},',
            JsonNum(sum.activeUptimePct, 0),
            JsonNum(sum.cpm, 0),
            JsonNum(sum.idleGapCount, 0),
            JsonNum(sum.totalIdleSeconds, 0),
            JsonNum(sum.efficientCount, 0),
            JsonNum(sum.earlyStarvedCount, 0),
            JsonNum(sum.lateHoardCount, 0),
            JsonNum(sum.overcapWasteCount, 0)
        ),
        '  "events": [',
        table.concat(evJson, ",\n"),
        "  ]",
        "}",
    }, "\n")

    local subtitle = format(
        "%s (%.1fs) — JSON %d/%d events",
        targetFight.targetName or "Unknown",
        targetFight.duration or 0,
        totalEvents > 0 and (totalEvents - startIdx + 1) or 0,
        totalEvents
    )
    return jsonStr, subtitle
end

function Addon:DumpFightTelemetry(arg, fight)
    local trimmed = match(arg or "", "^%s*(.-)%s*$")
    local firstToken, rest = match(trimmed, "^(%S+)%s*(.-)$")
    local firstLower = firstToken and lower(firstToken) or ""
    local toChat = false
    local wantJson = false
    local countArg = trimmed

    if firstLower == "chat" then
        toChat = true
        local secToken, secRest = match(rest or "", "^(%S+)%s*(.-)$")
        if secToken and lower(secToken) == "json" then
            wantJson = true
            countArg = (secRest ~= "" and secRest) or "all"
        else
            countArg = (rest ~= "" and rest) or "20"
        end
    elseif firstLower == "json" then
        wantJson = true
        countArg = (rest ~= "" and rest) or "all"
    end

    local textDump, textSubOrErr = self:BuildFightDumpText(fight, countArg)
    if not textDump then
        self:Print(textSubOrErr)
        return
    end

    if toChat then
        local outLines = textDump
        if wantJson then
            local jDump = self:BuildFightJsonText(fight, countArg)
            if jDump then
                outLines = jDump
            end
        end
        for line in string.gmatch(outLines, "[^\n]+") do
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa" .. line .. "|r")
        end
        return
    end

    local jsonDump, jsonSub = self:BuildFightJsonText(fight, countArg)
    if NS.UI and NS.UI.ShowDumpWindow then
        NS.UI:ShowDumpWindow(
            wantJson and (jsonDump or textDump) or textDump,
            wantJson and (jsonSub or textSubOrErr) or textSubOrErr,
            "CTE Telemetry Dump",
            textDump,
            jsonDump,
            wantJson
        )
        return
    end

    for line in string.gmatch(textDump, "[^\n]+") do
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa" .. line .. "|r")
    end
end

function Addon:ShareFightReport(fight, channel)
    local targetFight = fight or self:GetLatestFight()
    if not targetFight then
        self:Print("No recorded fight available to report.")
        return false
    end

    if not NS.Analyzer or not NS.Analyzer.BuildChatReport then
        self:Print("Analyzer report generator is unavailable.")
        return false
    end

    local targetChannel = upper(match(channel or "SELF", "^%s*(.-)%s*$"))
    if targetChannel == "" or targetChannel == "LOCAL" or targetChannel == "PRINT" then
        targetChannel = "SELF"
    end

    if targetChannel == "RAID" then
        if not (IsInRaid and IsInRaid()) then
            self:Print("Not in a raid group — printing report to local chat instead.")
            targetChannel = "SELF"
        end
    elseif targetChannel == "PARTY" then
        if not (IsInGroup and IsInGroup()) then
            self:Print("Not in a party — printing report to local chat instead.")
            targetChannel = "SELF"
        end
    elseif targetChannel == "GUILD" then
        if not (IsInGuild and IsInGuild()) then
            self:Print("Not in a guild — printing report to local chat instead.")
            targetChannel = "SELF"
        end
    elseif targetChannel ~= "SELF" and targetChannel ~= "SAY" then
        self:Print("Invalid channel. Supported channels: self, party, raid, guild, say.")
        return false
    end

    local useColor = (targetChannel == "SELF")
    local lines = NS.Analyzer:BuildChatReport(targetFight, useColor)
    if not lines or #lines == 0 then
        self:Print("Could not generate report for this encounter.")
        return false
    end

    if targetChannel == "SELF" then
        for i = 1, #lines do
            DEFAULT_CHAT_FRAME:AddMessage(lines[i])
        end
    else
        for i = 1, #lines do
            SendChatMessage(lines[i], targetChannel)
        end
    end
    return true
end

function Addon:CheckBossEngagement(unit, explicitBossName)
    if not self.inCombat then
        return
    end
    if explicitBossName then
        self.sawBossEncounter = true
        self.bossEncounterName = explicitBossName
        return
    end
    if IsBossUnit(unit) then
        self.sawBossEncounter = true
        self.bossEncounterName = SafeString(UnitName(unit), nil) or self.bossEncounterName
    end
end

function Addon:OnCombatStart()
    if self.inCombat then
        return
    end
    self.inCombat = true
    self.sawBossEncounter = IsBossUnit("target") or IsBossUnit("boss1")
    local targetName = SafeString(UnitName("target"), nil)
    local bossName = SafeString(UnitName("boss1"), nil)
    self.bossEncounterName = self.sawBossEncounter and (targetName or bossName) or nil

    local _, classFile = UnitClass("player")
    local meta = {
        id = format("%d-%d", math.floor(GetTime()), math.random(1000, 9999)),
        timestamp = time(),
        playerGUID = SafeString(UnitGUID("player"), nil),
        playerClass = SafeString(classFile, "UNKNOWN"),
        playerLevel = SafeNumber(UnitLevel("player"), 60),
        targetName = self.bossEncounterName or targetName or "Unknown Target",
        startTime = GetTime(),
        endTime = nil,
        duration = 0,
    }

    if NS.Collector and NS.Collector.StartCombat then
        NS.Collector:StartCombat(meta)
    end
    self:Debug("Combat started vs " .. meta.targetName)
end

function Addon:OnCombatEnd()
    if not self.inCombat then
        return
    end
    self:CheckBossEngagement("target")
    self.inCombat = false

    local fight = nil
    if NS.Collector and NS.Collector.StopCombat then
        fight = NS.Collector:StopCombat()
    end

    if not fight then
        return
    end

    if self.bossEncounterName and (not fight.targetName or fight.targetName == "Unknown Target") then
        fight.targetName = self.bossEncounterName
    end
    fight.isBoss = self.sawBossEncounter and true or false

    if self.db and self.db.bossOnly and not fight.isBoss then
        self:Debug(format("Discarded non-boss fight vs %s (bossOnly enabled)", fight.targetName or "Unknown"))
        return
    end

    local minDur = (self.db and self.db.minDuration) or MIN_FIGHT_DURATION
    if fight.duration < minDur or #fight.events == 0 then
        self:Debug(format("Discarded short/empty fight (%.1fs, %d events)", fight.duration, #fight.events))
        return
    end

    if NS.Analyzer and NS.Analyzer.AnalyzeFight then
        NS.Analyzer:AnalyzeFight(fight, self.db.thresholds)
    end

    self:StoreFight(fight)

    if NS.UI and NS.UI.OnFightRecorded then
        NS.UI:OnFightRecorded(fight)
    elseif self.db.showPostCombatBanner then
        local scoreText = fight.score and format("Score: %d%% | ", fight.score) or ""
        self:Print(format(
            "Recorded %s (%.1fs) — %s%d steps captured. Type /cte to inspect.",
            fight.targetName,
            fight.duration,
            scoreText,
            #fight.events
        ))
    end
end

function Addon:HandleMultiplierCommand(arg)
    local trimmed = lower(match(arg or "", "^%s*(.-)%s*$"))
    if trimmed == "" then
        self:Print(format(
            "Current hoardMultiplier: |cff5cc8ff%.2fx|r (range %.1f–%.1f, default %.1fx).",
            self.db.thresholds.hoardMultiplier,
            MIN_HOARD_MULTIPLIER,
            MAX_HOARD_MULTIPLIER,
            DEFAULT_DB.thresholds.hoardMultiplier
        ))
        return
    end

    if trimmed == "default" or trimmed == "reset" then
        self.db.thresholds.hoardMultiplier = DEFAULT_DB.thresholds.hoardMultiplier
        self:PrintRescoreSummary(format("Reset hoardMultiplier to |cff5cc8ff%.2fx|r.", self.db.thresholds.hoardMultiplier))
        return
    end

    local val = tonumber(trimmed)
    if not val or val < MIN_HOARD_MULTIPLIER or val > MAX_HOARD_MULTIPLIER then
        self:Print(format(
            "Invalid multiplier. Usage: /cte mult <%.1f–%.1f> or /cte mult default",
            MIN_HOARD_MULTIPLIER,
            MAX_HOARD_MULTIPLIER
        ))
        return
    end

    self.db.thresholds.hoardMultiplier = val
    self:PrintRescoreSummary(format("Set hoardMultiplier to |cff5cc8ff%.2fx|r.", val))
end

function Addon:HandleHoldCommand(arg)
    local trimmed = lower(match(arg or "", "^%s*(.-)%s*$"))
    if trimmed == "" then
        self:Print(format(
            "Current hoardHoldSeconds: |cff5cc8ff%.2fs|r (range %.1f–%.1f, default %.1fs).",
            self.db.thresholds.hoardHoldSeconds,
            MIN_HOARD_HOLD_SECONDS,
            MAX_HOARD_HOLD_SECONDS,
            DEFAULT_DB.thresholds.hoardHoldSeconds
        ))
        return
    end

    if trimmed == "default" or trimmed == "reset" then
        self.db.thresholds.hoardHoldSeconds = DEFAULT_DB.thresholds.hoardHoldSeconds
        self:PrintRescoreSummary(format("Reset hoardHoldSeconds to |cff5cc8ff%.2fs|r.", self.db.thresholds.hoardHoldSeconds))
        return
    end

    local val = tonumber(trimmed)
    if not val or val < MIN_HOARD_HOLD_SECONDS or val > MAX_HOARD_HOLD_SECONDS then
        self:Print(format(
            "Invalid hold duration. Usage: /cte hold <%.1f–%.1f> or /cte hold default",
            MIN_HOARD_HOLD_SECONDS,
            MAX_HOARD_HOLD_SECONDS
        ))
        return
    end

    self.db.thresholds.hoardHoldSeconds = val
    self:PrintRescoreSummary(format("Set hoardHoldSeconds to |cff5cc8ff%.2fs|r.", val))
end

function Addon:HandleIdleCommand(arg)
    local trimmed = lower(match(arg or "", "^%s*(.-)%s*$"))
    if trimmed == "" then
        self:Print(format(
            "Current idleGapSeconds: |cff5cc8ff%.2fs|r (dead time after 1.5s GCD/cast; range %.1f–%.1f, default %.1fs).",
            self.db.thresholds.idleGapSeconds or DEFAULT_DB.thresholds.idleGapSeconds,
            MIN_IDLE_GAP_SECONDS,
            MAX_IDLE_GAP_SECONDS,
            DEFAULT_DB.thresholds.idleGapSeconds
        ))
        return
    end

    if trimmed == "default" or trimmed == "reset" then
        self.db.thresholds.idleGapSeconds = DEFAULT_DB.thresholds.idleGapSeconds
        self:PrintRescoreSummary(format("Reset idleGapSeconds to |cff5cc8ff%.2fs|r.", self.db.thresholds.idleGapSeconds))
        return
    end

    local val = tonumber(trimmed)
    if not val or val < MIN_IDLE_GAP_SECONDS or val > MAX_IDLE_GAP_SECONDS then
        self:Print(format(
            "Invalid idle grace. Usage: /cte idle <%.1f–%.1f> or /cte idle default",
            MIN_IDLE_GAP_SECONDS,
            MAX_IDLE_GAP_SECONDS
        ))
        return
    end

    self.db.thresholds.idleGapSeconds = val
    self:PrintRescoreSummary(format("Set idleGapSeconds to |cff5cc8ff%.2fs|r.", val))
end

function Addon:HandleFadeCommand(arg)
    local trimmed = lower(match(arg or "", "^%s*(.-)%s*$"))
    if trimmed == "" then
        self:Print(format(
            "Auto-open after combat: %s (opt-in) | Fade timeout: |cff5cc8ff%.0fs|r (range %.0f–%.0fs, default %.0fs).",
            self.db.autoShowAfterCombat and "|cff2ed16bON|r" or "|cffaaaaaaOFF|r",
            self.db.autoFadeSeconds or DEFAULT_DB.autoFadeSeconds,
            MIN_AUTO_FADE_SECONDS,
            MAX_AUTO_FADE_SECONDS,
            DEFAULT_DB.autoFadeSeconds
        ))
        return
    end

    if trimmed == "off" or trimmed == "disable" then
        self.db.autoShowAfterCombat = false
        if NS.UI and NS.UI.Refresh then
            NS.UI:Refresh()
        end
        self:Print("Auto-open after combat: |cffaaaaaaOFF|r")
        return
    end

    if trimmed == "on" or trimmed == "enable" then
        self.db.autoShowAfterCombat = true
        if NS.UI and NS.UI.Refresh then
            NS.UI:Refresh()
        end
        self:Print(format("Auto-open after combat: |cff2ed16bON|r (%.0fs auto-fade timeout).", self.db.autoFadeSeconds or DEFAULT_DB.autoFadeSeconds))
        return
    end

    if trimmed == "default" or trimmed == "reset" then
        self.db.autoShowAfterCombat = DEFAULT_DB.autoShowAfterCombat
        self.db.autoFadeSeconds = DEFAULT_DB.autoFadeSeconds
        if NS.UI and NS.UI.Refresh then
            NS.UI:Refresh()
        end
        self:Print(format("Reset auto-open to |cffaaaaaaOFF|r (opt-in) and fade timeout to |cff5cc8ff%.0fs|r.", self.db.autoFadeSeconds))
        return
    end

    local val = tonumber(trimmed)
    if not val or val < MIN_AUTO_FADE_SECONDS or val > MAX_AUTO_FADE_SECONDS then
        self:Print(format(
            "Invalid timeout. Usage: /cte fade <%.0f–%.0f | on | off | default>",
            MIN_AUTO_FADE_SECONDS,
            MAX_AUTO_FADE_SECONDS
        ))
        return
    end

    self.db.autoShowAfterCombat = true
    self.db.autoFadeSeconds = val
    if NS.UI and NS.UI.Refresh then
        NS.UI:Refresh()
    end
    self:Print(format("Set post-combat auto-fade timeout to |cff5cc8ff%.0fs|r.", val))
end

function Addon:HandleSlashCommand(input)
    local trimmed = match(input or "", "^%s*(.-)%s*$")
    local rawCmd, rest = match(trimmed, "^(%S+)%s*(.-)$")
    local cmd = rawCmd and lower(rawCmd) or ""

    if cmd == "" or cmd == "show" or cmd == "toggle" then
        if NS.UI and NS.UI.Toggle then
            NS.UI:Toggle()
        else
            local latest = self:GetLatestFight()
            if latest then
                self:Print(format(
                    "Latest fight: %s (%.1fs, %d events, %d resource samples)",
                    latest.targetName,
                    latest.duration,
                    #latest.events,
                    #latest.samples
                ))
            else
                self:Print("No fights recorded yet. Enter combat to begin recording.")
            end
        end
    elseif cmd == "report" or cmd == "share" then
        local ch = (rest ~= "" and rest) or "SELF"
        self:ShareFightReport(nil, ch)
    elseif cmd == "center" or cmd == "resetpos" then
        self.db.windowPos = nil
        self.db.pillPos = nil
        if NS.UI and NS.UI.ResetWindowPosition then
            NS.UI:ResetWindowPosition()
        end
        self:Print("Reset CTE window and notification pill positions.")
    elseif cmd == "minimap" or cmd == "icon" then
        self.db.minimap.hide = not self.db.minimap.hide
        if NS.UI and NS.UI.UpdateMinimapButton then
            NS.UI:UpdateMinimapButton()
        end
        if NS.UI and NS.UI.Refresh then
            NS.UI:Refresh()
        end
        self:Print("Minimap button: " .. (self.db.minimap.hide and "|cffaaaaaaHIDDEN|r" or "|cff2ed16bSHOWN|r"))
    elseif cmd == "mult" or cmd == "multiplier" or cmd == "hoardmult" then
        self:HandleMultiplierCommand(rest)
    elseif cmd == "hold" or cmd == "holdsec" or cmd == "hoardhold" then
        self:HandleHoldCommand(rest)
    elseif cmd == "fade" or cmd == "autofade" then
        self:HandleFadeCommand(rest)
    elseif cmd == "idle" or cmd == "gcd" then
        self:HandleIdleCommand(rest)
    elseif cmd == "boss" or cmd == "bossonly" then
        self.db.bossOnly = not self.db.bossOnly
        if NS.UI and NS.UI.Refresh then
            NS.UI:Refresh()
        end
        self:Print("Boss-only recording: " .. (self.db.bossOnly and "|cff2ed16bON|r" or "|cffaaaaaaOFF|r"))
    elseif cmd == "rescore" or cmd == "reanalyze" then
        self:PrintRescoreSummary("Manual re-analysis complete.")
    elseif cmd == "pin" or cmd == "unpin" then
        local idx = tonumber(rest) or 1
        self:TogglePinFight(idx)
    elseif cmd == "del" or cmd == "delete" then
        local idx = tonumber(rest) or 1
        self:DeleteFight(idx)
    elseif cmd == "clear" or cmd == "reset" then
        self:ClearHistory(lower(rest) == "all")
    elseif cmd == "dump" or cmd == "raw" then
        self:DumpFightTelemetry(rest)
    elseif cmd == "errors" or cmd == "err" then
        self:HandleErrorsCommand(rest)
    elseif cmd == "debug" then
        self.db.debug = not self.db.debug
        self:Print("Debug logging: " .. (self.db.debug and "ON" or "OFF"))
    elseif cmd == "status" then
        self:Print(format(
            "InCombat: %s | Fights: %d/%d | BossOnly: %s | idle: %.2fs | mult: %.2fx | hold: %.2fs",
            tostring(self.inCombat or false),
            #self.db.fights,
            self.db.maxFights,
            self.db.bossOnly and "ON" or "OFF",
            self.db.thresholds.idleGapSeconds or DEFAULT_DB.thresholds.idleGapSeconds,
            self.db.thresholds.hoardMultiplier,
            self.db.thresholds.hoardHoldSeconds
        ))
    else
        self:Print("Commands: /cte | /cte dump [json|chat] [N|all] | /cte errors [chat|clear] | /cte idle <0.2-5.0> | /cte fade <3-30|off> | /cte pin [idx] | /cte del [idx] | /cte report [ch] | /cte minimap | /cte boss | /cte clear [all]")
    end
end

function Addon:EnsureDB()
    if not self.db then
        if type(CombatTelemetryEfficiencyDB) ~= "table" then
            CombatTelemetryEfficiencyDB = {}
        end
        ApplyDefaults(CombatTelemetryEfficiencyDB, DEFAULT_DB)
        self.db = CombatTelemetryEfficiencyDB
    end
    return self.db
end

local function SafeCall(label, fn, ...)
    if type(fn) ~= "function" then
        return true
    end
    local ok, err = pcall(fn, ...)
    if not ok then
        Addon:RecordError(label, tostring(err), false)
        Addon:Print("|cffff4d4dError in " .. label .. ":|r " .. tostring(err))
    end
    return ok
end

-- Register /cte at top level so the slash command is always available
SLASH_COMBATTELEMETRYEFFICIENCY1 = "/cte"
SlashCmdList["COMBATTELEMETRYEFFICIENCY"] = function(msg)
    Addon:EnsureDB()
    SafeCall("HandleSlashCommand", Addon.HandleSlashCommand, Addon, msg)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
pcall(eventFrame.RegisterEvent, eventFrame, "ENCOUNTER_START")

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        Addon:EnsureDB()

        if NS.Collector and NS.Collector.Init then
            SafeCall("Collector:Init", NS.Collector.Init, NS.Collector)
        end

        if NS.UI and NS.UI.InitMinimapButton then
            SafeCall("UI:InitMinimapButton", NS.UI.InitMinimapButton, NS.UI)
        end

        if InCombatLockdown() then
            SafeCall("OnCombatStart", Addon.OnCombatStart, Addon)
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        Addon:EnsureDB()
        SafeCall("OnCombatStart", Addon.OnCombatStart, Addon)
    elseif event == "PLAYER_REGEN_ENABLED" then
        Addon:EnsureDB()
        SafeCall("OnCombatEnd", Addon.OnCombatEnd, Addon)
    elseif event == "PLAYER_TARGET_CHANGED" then
        Addon:CheckBossEngagement("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        Addon:CheckBossEngagement("mouseover")
    elseif event == "ENCOUNTER_START" then
        Addon:CheckBossEngagement(nil, arg2 or "Boss Encounter")
    end
end)
