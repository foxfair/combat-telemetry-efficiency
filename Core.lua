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
local tonumber = tonumber
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

local DEFAULT_DB = {
    version = 1,
    maxFights = MAX_SAVED_FIGHTS,
    minDuration = MIN_FIGHT_DURATION,
    showPostCombatBanner = true,
    bossOnly = false,
    debug = false,
    minimap = {
        hide = false,
        angle = 220,
    },
    thresholds = {
        hoardMultiplier = 2.0,
        hoardHoldSeconds = 1.0,
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
    local classification = UnitClassification(unit)
    if classification == "worldboss" then
        return true
    end
    local level = UnitLevel(unit)
    return level == -1
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
    while #self.db.fights > limit do
        tremove(self.db.fights)
    end
end

function Addon:ClearHistory()
    if self.db and self.db.fights then
        wipe(self.db.fights)
    end
    if NS.UI and NS.UI.Refresh then
        NS.UI:Refresh()
    end
    self:Print("Cleared all recorded fight history.")
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

function Addon:DumpFightTelemetry(arg, fight)
    local trimmed = match(arg or "", "^%s*(.-)%s*$")
    local firstToken, rest = match(trimmed, "^(%S+)%s*(.-)$")
    local toChat = false
    local countArg = trimmed

    if firstToken and lower(firstToken) == "chat" then
        toChat = true
        countArg = (rest ~= "" and rest) or "20"
    end

    local dumpText, subtitleOrErr = self:BuildFightDumpText(fight, countArg)
    if not dumpText then
        self:Print(subtitleOrErr)
        return
    end

    if not toChat and NS.UI and NS.UI.ShowDumpWindow then
        NS.UI:ShowDumpWindow(dumpText, subtitleOrErr)
        return
    end

    for line in string.gmatch(dumpText, "[^\n]+") do
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
        self.bossEncounterName = UnitName(unit) or self.bossEncounterName
    end
end

function Addon:OnCombatStart()
    if self.inCombat then
        return
    end
    self.inCombat = true
    self.sawBossEncounter = IsBossUnit("target") or IsBossUnit("boss1")
    self.bossEncounterName = self.sawBossEncounter and (UnitName("target") or UnitName("boss1")) or nil

    local _, classFile = UnitClass("player")
    local meta = {
        id = format("%d-%d", math.floor(GetTime()), math.random(1000, 9999)),
        timestamp = time(),
        playerGUID = UnitGUID("player"),
        playerClass = classFile,
        playerLevel = UnitLevel("player"),
        targetName = self.bossEncounterName or UnitName("target") or "Unknown Target",
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
    elseif cmd == "boss" or cmd == "bossonly" then
        self.db.bossOnly = not self.db.bossOnly
        if NS.UI and NS.UI.Refresh then
            NS.UI:Refresh()
        end
        self:Print("Boss-only recording: " .. (self.db.bossOnly and "|cff2ed16bON|r" or "|cffaaaaaaOFF|r"))
    elseif cmd == "rescore" or cmd == "reanalyze" then
        self:PrintRescoreSummary("Manual re-analysis complete.")
    elseif cmd == "clear" or cmd == "reset" then
        self:ClearHistory()
    elseif cmd == "dump" or cmd == "raw" then
        self:DumpFightTelemetry(rest)
    elseif cmd == "debug" then
        self.db.debug = not self.db.debug
        self:Print("Debug logging: " .. (self.db.debug and "ON" or "OFF"))
    elseif cmd == "status" then
        self:Print(format(
            "InCombat: %s | Fights: %d/%d | BossOnly: %s | mult: %.2fx | hold: %.2fs",
            tostring(self.inCombat or false),
            #self.db.fights,
            self.db.maxFights,
            self.db.bossOnly and "ON" or "OFF",
            self.db.thresholds.hoardMultiplier,
            self.db.thresholds.hoardHoldSeconds
        ))
    else
        self:Print("Commands: /cte | /cte report [self|party|raid|guild|say] | /cte dump [count|all] | /cte minimap | /cte mult <1.0-5.0> | /cte hold <0.0-10.0> | /cte boss | /cte rescore | /cte clear")
    end
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
        if type(CombatTelemetryEfficiencyDB) ~= "table" then
            CombatTelemetryEfficiencyDB = {}
        end
        ApplyDefaults(CombatTelemetryEfficiencyDB, DEFAULT_DB)
        Addon.db = CombatTelemetryEfficiencyDB

        if NS.Collector and NS.Collector.Init then
            NS.Collector:Init()
        end

        if NS.UI and NS.UI.InitMinimapButton then
            NS.UI:InitMinimapButton()
        end

        SLASH_COMBATTELEMETRYEFFICIENCY1 = "/cte"
        SlashCmdList["COMBATTELEMETRYEFFICIENCY"] = function(msg)
            Addon:HandleSlashCommand(msg)
        end

        if InCombatLockdown() then
            Addon:OnCombatStart()
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        Addon:OnCombatStart()
    elseif event == "PLAYER_REGEN_ENABLED" then
        Addon:OnCombatEnd()
    elseif event == "PLAYER_TARGET_CHANGED" then
        Addon:CheckBossEngagement("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        Addon:CheckBossEngagement("mouseover")
    elseif event == "ENCOUNTER_START" then
        Addon:CheckBossEngagement(nil, arg2 or "Boss Encounter")
    end
end)
