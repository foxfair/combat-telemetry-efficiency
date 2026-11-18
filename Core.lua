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
local tonumber = tonumber
local wipe = wipe
local tinsert = table.insert
local tremove = table.remove
local format = string.format
local lower = string.lower
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
        self:Print("Commands: /cte | /cte mult <1.0-5.0> | /cte hold <0.0-10.0> | /cte boss | /cte rescore | /cte clear")
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
