local _, NS = ...

local CreateFrame = CreateFrame
local GetTime = GetTime
local GetCursorPosition = GetCursorPosition
local IsMouseButtonDown = IsMouseButtonDown
local GameTooltip = GameTooltip
local UIParent = UIParent
local Minimap = Minimap
local GetMinimapShape = GetMinimapShape
local tinsert = table.insert
local wipe = wipe
local max = math.max
local min = math.min
local floor = math.floor
local abs = math.abs
local atan2 = math.atan2
local cos = math.cos
local sin = math.sin
local deg = math.deg
local rad = math.rad
local format = string.format
local tonumber = tonumber

local UI = {}
NS.UI = UI

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

local DEFAULT_WINDOW_WIDTH = 856
local DEFAULT_WINDOW_HEIGHT = 524
local MIN_WINDOW_WIDTH = 760
local MAX_WINDOW_WIDTH = 1440
local MIN_WINDOW_HEIGHT = 430
local MAX_WINDOW_HEIGHT = 980
local BAND1_HEIGHT = 32
local BASE_BAND2_HEIGHT = 198
local LOG_ROW_HEIGHT = 22
local DEFAULT_VISIBLE_LOG_ROWS = 7
local CURVE_SLICES = 150
local MINIMAP_RIM_PADDING = 6
local DEFAULT_MINIMAP_ANGLE = 220
local DEFAULT_AUTO_FADE_SECONDS = 10.0
local AUTO_FADE_DURATION = 1.0

local SECONDARY = {
    COMBO_POINTS = 4,
    MANA_BACKUP = 100,
    PET_FOCUS = 102,
    TOTEM_SLOTS = 104,
}

local MINIMAP_BUTTON_ICON = "Interface\\Icons\\INV_Misc_PocketWatch_01"
local OVERCAP_FALLBACK_ICON = "Interface\\Icons\\Spell_Nature_WispSplode"
local IDLE_FALLBACK_ICON = "Interface\\Icons\\Spell_Holy_BorrowedTime"
local DEFAULT_SPELL_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local function ResolveSpellIcon(ev)
    if not ev then
        return DEFAULT_SPELL_ICON
    end
    if ev.isSyntheticIdle then
        return IDLE_FALLBACK_ICON
    end
    if ev.isSyntheticOvercap then
        return ev.spellIcon or OVERCAP_FALLBACK_ICON
    end
    if ev.spellIcon and ev.spellIcon ~= 134400 and ev.spellIcon ~= DEFAULT_SPELL_ICON then
        return ev.spellIcon
    end
    local sid = ev.spellID
    if sid and sid > 0 then
        local tex = nil
        if C_Spell and C_Spell.GetSpellTexture then
            tex = C_Spell.GetSpellTexture(sid)
        elseif GetSpellTexture then
            tex = GetSpellTexture(sid)
        end
        if not tex and C_Spell and C_Spell.GetSpellInfo then
            local info = C_Spell.GetSpellInfo(sid)
            tex = info and (info.iconID or info.originalIconID)
        elseif not tex and GetSpellInfo then
            tex = select(3, GetSpellInfo(sid))
        end
        if tex and (not issecretvalue or not issecretvalue(tex)) then
            ev.spellIcon = tex
            return tex
        end
    end
    return ev.spellIcon or DEFAULT_SPELL_ICON
end

local VERDICT_COLORS = {
    EFFICIENT = { 0.18, 0.82, 0.42, 1.0 },
    EARLY_STARVED = { 0.94, 0.25, 0.28, 1.0 },
    LATE_HOARD = { 0.96, 0.68, 0.14, 1.0 },
    OVERCAP_WASTE = { 0.82, 0.35, 0.92, 1.0 },
    IDLE_GAP = { 0.95, 0.52, 0.22, 1.0 },
}

local VERDICT_HEX = {
    EFFICIENT = "|cff2ed16b",
    EARLY_STARVED = "|cfff04047",
    LATE_HOARD = "|cfff5ad24",
    OVERCAP_WASTE = "|cffd159eb",
    IDLE_GAP = "|cfff28538",
}

local POWER_BAR_COLORS = {
    [0] = { 0.16, 0.48, 0.96 },
    [1] = { 0.88, 0.22, 0.22 },
    [3] = { 0.96, 0.84, 0.18 },
    [4] = { 0.98, 0.72, 0.16 },
    [100] = { 0.25, 0.62, 0.98 },
    [102] = { 0.18, 0.88, 0.76 },
    [104] = { 0.35, 0.75, 0.98 },
}

local DRUID_FORM_COLORS = {
    BEAR    = { 0.88, 0.22, 0.22 },
    CAT     = { 0.96, 0.84, 0.18 },
    MOONKIN = { 0.56, 0.42, 0.96 },
    CASTER  = { 0.16, 0.48, 0.96 },
    TRAVEL  = { 0.30, 0.82, 0.65 },
}

local DRUID_FORM_SHORT = {
    BEAR    = "|cffe03838[Bear]|r",
    CAT     = "|cfff5d62e[Cat]|r",
    MOONKIN = "|cff8f6bf5[Moon]|r",
    CASTER  = "|cff297af5[Cast]|r",
    TRAVEL  = "|cff4dd1a6[Trav]|r",
}

local DRUID_FORM_LABEL = {
    BEAR    = "Bear Form (Rage)",
    CAT     = "Cat Form (Energy + CP)",
    MOONKIN = "Moonkin Form (Mana)",
    CASTER  = "Caster Form (Mana)",
    TRAVEL  = "Travel / Aquatic Form",
}

local TOTEM_SLOT_COLORS = {
    [1] = { 0.95, 0.32, 0.22 },
    [2] = { 0.76, 0.56, 0.28 },
    [3] = { 0.22, 0.68, 0.96 },
    [4] = { 0.65, 0.88, 1.00 },
}

local minimapButton = nil
local pillFrame = nil
local mainFrame = nil
local fightMenuFrame = nil
local settingsPopover = nil
local reportPopover = nil
local dumpFrame = nil
local compareFrame = nil
local isSyncingSettings = false
local selectedFightIndex = 1
local viewLayerMode = "DUAL"
local verdictFilter = "ALL" -- "ALL" | "ISSUES" | "EARLY_STARVED" | "LATE_HOARD" | "OVERCAP_WASTE"
local zoomLevel = 1
local viewStart = 0
local viewEnd = 1
local highlightedEventIndex = nil
local delAllConfirmUntil = 0
local autoFadeArmed = false
local autoFadeStartAt = 0
local autoFadeLastShownSec = -1

local scrubTickPool = {}
local curveFillPool = {}
local curveLinePool = {}
local secCurvePool = {}
local totemBarPool = {}
local formRibbonPool = {}
local idleBandPool = {}
local dashLinePool = {}
local axisLabelPool = {}
local pinPool = {}
local logRowPool = {}
local filteredEvents = {}

local function FormatClock(sec)
    sec = max(0, sec or 0)
    local mins = floor(sec / 60)
    local rem = sec - (mins * 60)
    return format("%d:%04.1f", mins, rem)
end

local function FormatShortClock(sec)
    sec = max(0, sec or 0)
    local mins = floor(sec / 60)
    local rem = floor(sec % 60)
    return format("%d:%02d", mins, rem)
end

local function GetVerdictColor(verdict)
    return VERDICT_COLORS[verdict] or VERDICT_COLORS.EFFICIENT
end

local function GetPowerBarColor(powerType)
    return POWER_BAR_COLORS[powerType] or { 0.28, 0.72, 0.92 }
end

local function ApplyPanelBackdrop(frame, bgAlpha, borderR, borderG, borderB, borderA)
    if not frame.SetBackdrop then
        return
    end
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    frame:SetBackdropColor(0.07, 0.08, 0.10, bgAlpha or 0.94)
    frame:SetBackdropBorderColor(borderR or 0.24, borderG or 0.27, borderB or 0.32, borderA or 0.95)
end

local function CreateActionButton(parent, width, height, text)
    local btn = CreateFrame("Button", nil, parent, BACKDROP_TEMPLATE)
    btn:SetFrameLevel((parent and parent:GetFrameLevel() or 1) + 3)
    btn:SetSize(width, height)
    ApplyPanelBackdrop(btn, 0.95, 0.28, 0.31, 0.36, 1.0)

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER", 0, 0)
    label:SetText(text or "")
    label:SetTextColor(0.90, 0.92, 0.95)
    btn.label = label

    btn:SetScript("OnEnter", function(self)
        if not self.isActive then
            self:SetBackdropBorderColor(0.45, 0.75, 0.95, 1.0)
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if not self.isActive then
            self:SetBackdropBorderColor(0.28, 0.31, 0.36, 1.0)
        end
    end)

    function btn:SetActiveState(active)
        self.isActive = active
        if active then
            self:SetBackdropColor(0.14, 0.30, 0.44, 1.0)
            self:SetBackdropBorderColor(0.32, 0.72, 0.98, 1.0)
            self.label:SetTextColor(1, 1, 1)
        else
            self:SetBackdropColor(0.07, 0.08, 0.10, 0.95)
            self:SetBackdropBorderColor(0.28, 0.31, 0.36, 1.0)
            self.label:SetTextColor(0.86, 0.89, 0.93)
        end
    end

    return btn
end

local function CreateCompactSlider(parent, width, labelText, minVal, maxVal, step, fmtString, onChanged)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width, 40)

    local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    title:SetTextColor(0.86, 0.90, 0.95)
    title:SetText(labelText)

    local valText = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    valText:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
    valText:SetTextColor(0.36, 0.78, 1.0)

    local slider = CreateFrame("Slider", nil, container, BACKDROP_TEMPLATE)
    slider:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
    slider:SetSize(width, 12)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    if slider.SetObeyStepOnDrag then
        slider:SetObeyStepOnDrag(true)
    end
    ApplyPanelBackdrop(slider, 0.95, 0.26, 0.30, 0.36, 1.0)
    slider:SetBackdropColor(0.12, 0.14, 0.18, 1.0)

    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(12, 16)
    thumb:SetColorTexture(0.35, 0.75, 0.98, 1.0)
    slider:SetThumbTexture(thumb)

    slider:SetScript("OnValueChanged", function(_, rawVal)
        local snapped = floor(((rawVal - minVal) / step) + 0.5) * step + minVal
        snapped = max(minVal, min(maxVal, snapped))
        valText:SetText(format(fmtString, snapped))
        if not isSyncingSettings and onChanged then
            onChanged(snapped)
        end
    end)

    function container:SetDisplayValue(val)
        local clamped = max(minVal, min(maxVal, val or minVal))
        slider:SetValue(clamped)
        valText:SetText(format(fmtString, clamped))
    end

    container.slider = slider
    return container
end

local function CreateCompactCheckbox(parent, width, labelText, subText, onToggle)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width, subText and 32 or 20)

    local box = CreateFrame("Frame", nil, btn, BACKDROP_TEMPLATE)
    box:SetSize(15, 15)
    box:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, -2)
    ApplyPanelBackdrop(box, 0.95, 0.32, 0.36, 0.42, 1.0)

    local check = box:CreateTexture(nil, "OVERLAY")
    check:SetPoint("TOPLEFT", 3, -3)
    check:SetPoint("BOTTOMRIGHT", -3, 3)
    check:SetColorTexture(0.22, 0.82, 0.48, 1.0)
    check:Hide()

    local title = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("LEFT", box, "RIGHT", 7, 0)
    title:SetTextColor(0.90, 0.93, 0.97)
    title:SetText(labelText)

    if subText then
        local sub = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
        sub:SetTextColor(0.56, 0.61, 0.68)
        sub:SetText(subText)
    end

    btn.checked = false
    function btn:SetCheckedState(state)
        self.checked = state and true or false
        if self.checked then
            check:Show()
            box:SetBackdropBorderColor(0.28, 0.82, 0.52, 1.0)
        else
            check:Hide()
            box:SetBackdropBorderColor(0.32, 0.36, 0.42, 1.0)
        end
    end

    btn:SetScript("OnEnter", function()
        box:SetBackdropBorderColor(0.45, 0.78, 1.0, 1.0)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetCheckedState(self.checked)
    end)
    btn:SetScript("OnClick", function(self)
        local nextState = not self.checked
        self:SetCheckedState(nextState)
        if not isSyncingSettings and onToggle then
            onToggle(nextState)
        end
    end)

    return btn
end

local function UpdateMinimapButtonPosition()
    if not minimapButton or not Minimap then
        return
    end

    local angleDeg = DEFAULT_MINIMAP_ANGLE
    if NS.Addon and NS.Addon.db and NS.Addon.db.minimap and type(NS.Addon.db.minimap.angle) == "number" then
        angleDeg = NS.Addon.db.minimap.angle
    end

    local radiusX = ((Minimap:GetWidth() or 140) * 0.5) + MINIMAP_RIM_PADDING
    local radiusY = ((Minimap:GetHeight() or 140) * 0.5) + MINIMAP_RIM_PADDING

    local angleRad = rad(angleDeg)
    local x = cos(angleRad) * radiusX
    local y = sin(angleRad) * radiusY

    if GetMinimapShape and GetMinimapShape() == "SQUARE" then
        x = max(-radiusX, min(radiusX, cos(angleRad) * radiusX * 1.4142))
        y = max(-radiusY, min(radiusY, sin(angleRad) * radiusY * 1.4142))
    end

    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function UI:UpdateMinimapButton()
    if not minimapButton then
        return
    end
    UpdateMinimapButtonPosition()
    local hidden = NS.Addon and NS.Addon.db and NS.Addon.db.minimap and NS.Addon.db.minimap.hide
    if hidden then
        minimapButton:Hide()
    else
        minimapButton:Show()
    end
end

function UI:InitMinimapButton()
    if minimapButton or not Minimap then
        self:UpdateMinimapButton()
        return
    end

    local btn = CreateFrame("Button", "CombatTelemetryEfficiencyMinimapButton", Minimap)
    btn:SetSize(32, 32)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetPoint("CENTER", 0, 1)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture(MINIMAP_BUTTON_ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn.icon = icon

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetSize(24, 24)
    hl:SetPoint("CENTER", 0, 1)
    hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    hl:SetBlendMode("ADD")

    btn.isDragging = false

    btn:SetScript("OnDragStart", function(self)
        self.isDragging = true
        self:LockHighlight()
        GameTooltip:Hide()
    end)

    btn:SetScript("OnDragStop", function(self)
        self.isDragging = false
        self:UnlockHighlight()
    end)

    btn:SetScript("OnHide", function(self)
        self.isDragging = false
    end)

    btn:SetScript("OnUpdate", function(self)
        if not self.isDragging then
            return
        end
        local mx, my = Minimap:GetCenter()
        if not mx or not my then
            return
        end
        local cx, cy = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        cx = cx / scale
        cy = cy / scale

        local angleDeg = deg(atan2(cy - my, cx - mx))
        if angleDeg < 0 then
            angleDeg = angleDeg + 360
        end

        if NS.Addon and NS.Addon.db then
            if type(NS.Addon.db.minimap) ~= "table" then
                NS.Addon.db.minimap = {}
            end
            NS.Addon.db.minimap.angle = angleDeg
        end
        UpdateMinimapButtonPosition()
    end)

    btn:SetScript("OnEnter", function(self)
        if self.isDragging then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff5cc8ffCombatTelemetryEfficiency|r", 1, 1, 1)

        local latest = NS.Addon and NS.Addon.GetLatestFight and NS.Addon:GetLatestFight()
        if latest then
            local score = latest.score or 100
            local scoreHex = (score >= 88 and "|cff2ed16b") or (score >= 70 and "|cfff5ad24") or "|cfff04047"
            GameTooltip:AddDoubleLine(
                "Latest Encounter:",
                format("%s (%s%d%%|r)", latest.targetName or "Encounter", scoreHex, score),
                0.75, 0.80, 0.86, 1, 1, 1
            )
        else
            GameTooltip:AddLine("No encounters recorded yet.", 0.65, 0.70, 0.76)
        end

        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cff2ed16bLeft-Click:|r Toggle Review Window", 0.85, 0.88, 0.92)
        GameTooltip:AddLine("|cff66d9ffRight-Click:|r Threshold Settings", 0.85, 0.88, 0.92)
        GameTooltip:AddLine("|cffaaaaaaDrag:|r Move Around Minimap", 0.75, 0.78, 0.82)
        GameTooltip:Show()
    end)

    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            UI:OpenSettings()
        else
            UI:Toggle()
        end
    end)

    minimapButton = btn
    self:UpdateMinimapButton()
end

local function CancelAutoFade()
    if not autoFadeArmed then
        return
    end
    autoFadeArmed = false
    autoFadeStartAt = 0
    autoFadeLastShownSec = -1
    if mainFrame then
        mainFrame:SetAlpha(1.0)
        if mainFrame.fadeStatusText then
            mainFrame.fadeStatusText:SetText("")
            mainFrame.fadeStatusText:Hide()
        end
    end
end

local function ArmAutoFade(timeoutSec)
    if not mainFrame then
        return
    end
    local sec = max(3.0, min(30.0, tonumber(timeoutSec) or DEFAULT_AUTO_FADE_SECONDS))
    autoFadeArmed = true
    autoFadeStartAt = GetTime() + sec
    autoFadeLastShownSec = -1
    mainFrame:SetAlpha(1.0)
    if mainFrame.fadeStatusText then
        mainFrame.fadeStatusText:SetText(format("|cff88929eAuto-fade: %ds (click to keep)|r", floor(sec + 0.5)))
        mainFrame.fadeStatusText:Show()
    end
end

local function SyncSettingsPopover()
    if not settingsPopover or not NS.Addon or not NS.Addon.db then
        return
    end
    local db = NS.Addon.db
    isSyncingSettings = true
    settingsPopover.multSlider:SetDisplayValue(db.thresholds.hoardMultiplier or 2.0)
    settingsPopover.holdSlider:SetDisplayValue(db.thresholds.hoardHoldSeconds or 1.0)
    settingsPopover.bufferSlider:SetDisplayValue(db.thresholds.reactionBufferSeconds or 0.25)
    settingsPopover.idleSlider:SetDisplayValue(db.thresholds.idleGapSeconds or 0.6)
    settingsPopover.autoShowCheck:SetCheckedState(db.autoShowAfterCombat == true)
    settingsPopover.fadeSlider:SetDisplayValue(db.autoFadeSeconds or DEFAULT_AUTO_FADE_SECONDS)
    settingsPopover.bannerCheck:SetCheckedState(db.showPostCombatBanner ~= false)
    settingsPopover.multiFightCheck:SetCheckedState(db.recordMultiFights == true)
    settingsPopover.maxFightsSlider:SetDisplayValue(db.maxFights or 10)
    settingsPopover.bossCheck:SetCheckedState(db.bossOnly == true)
    settingsPopover.minimapCheck:SetCheckedState(not (db.minimap and db.minimap.hide))
    isSyncingSettings = false
end

local function ToggleSettingsPopover(anchor)
    if not settingsPopover then
        local pop = CreateFrame("Frame", nil, mainFrame, BACKDROP_TEMPLATE)
        pop:SetSize(264, 526)
        pop:SetFrameStrata("FULLSCREEN_DIALOG")
        pop:EnableMouse(true)
        ApplyPanelBackdrop(pop, 0.98, 0.34, 0.66, 0.94, 1.0)
        pop:Hide()

        local header = pop:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        header:SetPoint("TOPLEFT", pop, "TOPLEFT", 12, -10)
        header:SetText("|cff5cc8ffThreshold & Capture Settings|r")

        local closeX = CreateFrame("Button", nil, pop)
        closeX:SetSize(18, 18)
        closeX:SetPoint("TOPRIGHT", pop, "TOPRIGHT", -6, -6)
        local xLbl = closeX:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        xLbl:SetPoint("CENTER")
        xLbl:SetText("|cff999999x|r")
        closeX:SetScript("OnClick", function()
            pop:Hide()
            if mainFrame and mainFrame.settingsBtn then
                mainFrame.settingsBtn:SetActiveState(false)
            end
        end)

        local multSlider = CreateCompactSlider(
            pop,
            238,
            "Hoard Spender Multiplier",
            1.0,
            5.0,
            0.1,
            "%.1fx",
            function(val)
                if NS.Addon and NS.Addon.db then
                    NS.Addon.db.thresholds.hoardMultiplier = val
                    NS.Addon:ReanalyzeAllFights()
                end
            end
        )
        multSlider:SetPoint("TOPLEFT", pop, "TOPLEFT", 12, -32)
        pop.multSlider = multSlider

        local holdSlider = CreateCompactSlider(
            pop,
            238,
            "Hoard Hold Grace Period",
            0.0,
            10.0,
            0.1,
            "%.1fs",
            function(val)
                if NS.Addon and NS.Addon.db then
                    NS.Addon.db.thresholds.hoardHoldSeconds = val
                    NS.Addon:ReanalyzeAllFights()
                end
            end
        )
        holdSlider:SetPoint("TOPLEFT", multSlider, "BOTTOMLEFT", 0, -8)
        pop.holdSlider = holdSlider

        local bufferSlider = CreateCompactSlider(
            pop,
            238,
            "Human Reaction Buffer",
            0.0,
            1.5,
            0.05,
            "%.2fs",
            function(val)
                if NS.Addon and NS.Addon.db then
                    NS.Addon.db.thresholds.reactionBufferSeconds = val
                    NS.Addon:ReanalyzeAllFights()
                end
            end
        )
        bufferSlider:SetPoint("TOPLEFT", holdSlider, "BOTTOMLEFT", 0, -8)
        pop.bufferSlider = bufferSlider

        local idleSlider = CreateCompactSlider(
            pop,
            238,
            "Idle GCD Grace Period",
            0.2,
            5.0,
            0.1,
            "%.1fs",
            function(val)
                if NS.Addon and NS.Addon.db then
                    NS.Addon.db.thresholds.idleGapSeconds = val
                    NS.Addon:ReanalyzeAllFights()
                end
            end
        )
        idleSlider:SetPoint("TOPLEFT", bufferSlider, "BOTTOMLEFT", 0, -8)
        pop.idleSlider = idleSlider

        local divider = pop:CreateTexture(nil, "ARTWORK")
        divider:SetHeight(1)
        divider:SetPoint("TOPLEFT", idleSlider, "BOTTOMLEFT", 0, -6)
        divider:SetWidth(238)
        divider:SetColorTexture(0.24, 0.27, 0.33, 1.0)

        local autoShowCheck = CreateCompactCheckbox(
            pop,
            238,
            "Auto-Open Window After Combat (Opt-In)",
            "Closes if not clicked before timeout",
            function(checked)
                if NS.Addon and NS.Addon.db then
                    NS.Addon.db.autoShowAfterCombat = checked
                end
            end
        )
        autoShowCheck:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -8)
        pop.autoShowCheck = autoShowCheck

        local fadeSlider = CreateCompactSlider(
            pop,
            238,
            "Auto-Fade Timeout",
            3.0,
            30.0,
            1.0,
            "%.0fs",
            function(val)
                if NS.Addon and NS.Addon.db then
                    NS.Addon.db.autoFadeSeconds = val
                end
            end
        )
        fadeSlider:SetPoint("TOPLEFT", autoShowCheck, "BOTTOMLEFT", 0, -6)
        pop.fadeSlider = fadeSlider

        local bannerCheck = CreateCompactCheckbox(
            pop,
            238,
            "Post-Combat Notification Pill",
            nil,
            function(checked)
                if NS.Addon and NS.Addon.db then
                    NS.Addon.db.showPostCombatBanner = checked
                end
            end
        )
        bannerCheck:SetPoint("TOPLEFT", fadeSlider, "BOTTOMLEFT", 0, -6)
        pop.bannerCheck = bannerCheck

        local multiFightCheck = CreateCompactCheckbox(
            pop,
            238,
            "Record Multiple Fights (History)",
            "Off = Single-fight mode (latest only)",
            function(checked)
                if NS.Addon and NS.Addon.SetRecordMultiFights then
                    NS.Addon:SetRecordMultiFights(checked)
                elseif NS.Addon and NS.Addon.db then
                    NS.Addon.db.recordMultiFights = checked
                end
            end
        )
        multiFightCheck:SetPoint("TOPLEFT", bannerCheck, "BOTTOMLEFT", 0, -6)
        pop.multiFightCheck = multiFightCheck

        local maxFightsSlider = CreateCompactSlider(
            pop,
            238,
            "Multi-Fight History Cap",
            2,
            25,
            1,
            "%d",
            function(val)
                if NS.Addon and NS.Addon.SetMaxFights then
                    NS.Addon:SetMaxFights(val)
                elseif NS.Addon and NS.Addon.db then
                    NS.Addon.db.maxFights = math.floor(val + 0.5)
                end
            end
        )
        maxFightsSlider:SetPoint("TOPLEFT", multiFightCheck, "BOTTOMLEFT", 0, -6)
        pop.maxFightsSlider = maxFightsSlider

        local bossCheck = CreateCompactCheckbox(
            pop,
            238,
            "Boss-Only Recording",
            "Ignore non-boss trash pulls",
            function(checked)
                if NS.Addon and NS.Addon.db then
                    NS.Addon.db.bossOnly = checked
                end
            end
        )
        bossCheck:SetPoint("TOPLEFT", maxFightsSlider, "BOTTOMLEFT", 0, -6)
        pop.bossCheck = bossCheck

        local minimapCheck = CreateCompactCheckbox(
            pop,
            238,
            "Show Minimap Button",
            nil,
            function(checked)
                if NS.Addon and NS.Addon.db then
                    NS.Addon.db.minimap.hide = not checked
                    UI:UpdateMinimapButton()
                end
            end
        )
        minimapCheck:SetPoint("TOPLEFT", bossCheck, "BOTTOMLEFT", 0, -6)
        pop.minimapCheck = minimapCheck

        local resetBtn = CreateActionButton(pop, 114, 22, "Reset Defaults")
        resetBtn:SetPoint("BOTTOMRIGHT", pop, "BOTTOMRIGHT", -12, 10)
        resetBtn:SetScript("OnClick", function()
            if NS.Addon and NS.Addon.db then
                local defs = NS.Addon.DEFAULT_DB
                NS.Addon.db.thresholds.hoardMultiplier = defs and defs.thresholds.hoardMultiplier or 2.0
                NS.Addon.db.thresholds.hoardHoldSeconds = defs and defs.thresholds.hoardHoldSeconds or 1.0
                NS.Addon.db.thresholds.reactionBufferSeconds = defs and defs.thresholds.reactionBufferSeconds or 0.25
                NS.Addon.db.thresholds.idleGapSeconds = defs and defs.thresholds.idleGapSeconds or 0.6
                NS.Addon.db.showPostCombatBanner = true
                NS.Addon.db.autoShowAfterCombat = false
                NS.Addon.db.autoFadeSeconds = DEFAULT_AUTO_FADE_SECONDS
                if NS.Addon.SetRecordMultiFights then NS.Addon:SetRecordMultiFights(false) else NS.Addon.db.recordMultiFights = false end
                if NS.Addon.SetMaxFights then NS.Addon:SetMaxFights(defs and defs.maxFights or 10) else NS.Addon.db.maxFights = 10 end
                NS.Addon.db.bossOnly = false
                NS.Addon.db.minimap.hide = false
                NS.Addon.db.minimap.angle = DEFAULT_MINIMAP_ANGLE
                UI:UpdateMinimapButton()
                SyncSettingsPopover()
                NS.Addon:ReanalyzeAllFights()
            end
        end)

        settingsPopover = pop
    end

    if settingsPopover:IsShown() then
        settingsPopover:Hide()
        anchor:SetActiveState(false)
        return
    end

    if fightMenuFrame and fightMenuFrame:IsShown() then
        fightMenuFrame:Hide()
    end
    if reportPopover and reportPopover:IsShown() then
        reportPopover:Hide()
        if mainFrame and mainFrame.reportBtn then
            mainFrame.reportBtn:SetActiveState(false)
        end
    end

    SyncSettingsPopover()
    settingsPopover:ClearAllPoints()
    settingsPopover:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -3)
    settingsPopover:Show()
    anchor:SetActiveState(true)
end

local function GetActiveFight()
    local fights = NS.Addon and NS.Addon.db and NS.Addon.db.fights
    if not fights or #fights == 0 then
        return nil
    end
    if selectedFightIndex < 1 or selectedFightIndex > #fights then
        selectedFightIndex = 1
    end
    return fights[selectedFightIndex]
end


local REPORT_CHANNELS = {
    { key = "SELF",  label = "Self (Local Chat)" },
    { key = "PARTY", label = "Party Chat (/p)" },
    { key = "RAID",  label = "Raid Chat (/ra)" },
    { key = "GUILD", label = "Guild Chat (/g)" },
    { key = "SAY",   label = "Say (/s)" },
    { key = "DUMP",  label = "Raw Telemetry (Copy)" },
}

local function ToggleReportPopover(anchor)
    if not reportPopover then
        local pop = CreateFrame("Frame", nil, mainFrame, BACKDROP_TEMPLATE)
        local itemH = 22
        pop:SetSize(156, (#REPORT_CHANNELS * itemH) + 28)
        pop:SetFrameStrata("FULLSCREEN_DIALOG")
        pop:EnableMouse(true)
        ApplyPanelBackdrop(pop, 0.98, 0.34, 0.66, 0.94, 1.0)
        pop:Hide()

        local header = pop:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        header:SetPoint("TOPLEFT", pop, "TOPLEFT", 8, -7)
        header:SetText("|cff5cc8ffShare Fight Report|r")

        for i = 1, #REPORT_CHANNELS do
            local ch = REPORT_CHANNELS[i]
            local item = CreateFrame("Button", nil, pop)
            item:SetHeight(itemH)
            item:SetPoint("TOPLEFT", pop, "TOPLEFT", 4, -22 - ((i - 1) * itemH))
            item:SetPoint("TOPRIGHT", pop, "TOPRIGHT", -4, -22 - ((i - 1) * itemH))

            local hl = item:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(0.25, 0.52, 0.82, 0.45)

            local txt = item:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            txt:SetPoint("LEFT", 6, 0)
            txt:SetPoint("RIGHT", -6, 0)
            txt:SetJustifyH("LEFT")
            txt:SetTextColor(0.90, 0.93, 0.96)
            txt:SetText(ch.label)

            item:SetScript("OnClick", function()
                pop:Hide()
                if mainFrame and mainFrame.reportBtn then
                    mainFrame.reportBtn:SetActiveState(false)
                end
                if ch.key == "DUMP" then
                    if NS.Addon and NS.Addon.DumpFightTelemetry then
                        NS.Addon:DumpFightTelemetry("all", GetActiveFight())
                    end
                elseif NS.Addon and NS.Addon.ShareFightReport then
                    NS.Addon:ShareFightReport(GetActiveFight(), ch.key)
                end
            end)
        end

        reportPopover = pop
    end

    if reportPopover:IsShown() then
        reportPopover:Hide()
        anchor:SetActiveState(false)
        return
    end

    if fightMenuFrame and fightMenuFrame:IsShown() then
        fightMenuFrame:Hide()
    end
    if settingsPopover and settingsPopover:IsShown() then
        settingsPopover:Hide()
        if mainFrame and mainFrame.settingsBtn then
            mainFrame.settingsBtn:SetActiveState(false)
        end
    end

    reportPopover:ClearAllPoints()
    reportPopover:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -3)
    reportPopover:Show()
    anchor:SetActiveState(true)
end

local function MatchesVerdictFilter(ev)
    if verdictFilter == "ALL" then
        return true
    elseif verdictFilter == "ISSUES" then
        return ev.verdict ~= nil and ev.verdict ~= "EFFICIENT"
    else
        return ev.verdict == verdictFilter
    end
end

local function RebuildFilteredEvents(fight)
    wipe(filteredEvents)
    if not fight or not fight.events then
        return
    end
    for i = 1, #fight.events do
        local ev = fight.events[i]
        if MatchesVerdictFilter(ev) then
            tinsert(filteredEvents, ev)
        end
    end
end

local function SetViewportRange(fight, newStart, newZoom)
    if not fight then
        viewStart = 0
        viewEnd = 1
        zoomLevel = 1
        return
    end

    local dur = max(0.5, fight.duration or 0.5)
    zoomLevel = max(1, min(8, newZoom or zoomLevel or 1))
    local span = dur / zoomLevel
    local clampedStart = max(0, min(dur - span, newStart or 0))
    viewStart = clampedStart
    viewEnd = min(dur, clampedStart + span)
end

local function CenterViewportOnTime(fight, targetTime)
    if not fight then
        return
    end
    local dur = max(0.5, fight.duration or 0.5)
    local span = dur / max(1, zoomLevel)
    SetViewportRange(fight, targetTime - (span * 0.5), zoomLevel)
end

local function GetFormSegmentAtTime(segments, t)
    if not segments or #segments == 0 then
        return nil
    end
    for i = 1, #segments do
        local seg = segments[i]
        if t >= (seg.startTime or 0) and (not seg.endTime or t <= seg.endTime) then
            return seg
        end
    end
    return segments[#segments]
end

local function SamplePrimaryAtTime(samples, powerType, t)
    if not samples or #samples == 0 then
        return 0, 100
    end
    local lastPower = nil
    local lastMax = 100
    for i = 1, #samples do
        local s = samples[i]
        if not powerType or s.powerType == powerType then
            if s.t <= t then
                lastPower = s.power
                lastMax = s.powerMax or lastMax
            else
                if lastPower == nil then
                    return s.power, s.powerMax or 100
                end
                return lastPower, lastMax
            end
        end
    end
    return lastPower or 0, lastMax
end

local function SampleSecondaryAtTime(secSamples, secType, t)
    if not secSamples or #secSamples == 0 then
        return 0, 5, nil
    end
    local lastVal = nil
    local lastMax = 5
    local lastExtra = nil
    for i = 1, #secSamples do
        local s = secSamples[i]
        if not secType or s.secondaryType == secType then
            if s.t <= t then
                lastVal = s.value
                lastMax = s.maxValue or lastMax
                lastExtra = s.extra
            else
                if lastVal == nil then
                    return s.value, s.maxValue or 5, s.extra
                end
                return lastVal, lastMax, lastExtra
            end
        end
    end
    return lastVal or 0, lastMax, lastExtra
end


local function SampleTempoAtTime(events, t, windowHalf)
    if not events or #events == 0 then
        return 0
    end
    local half = windowHalf or 2.0
    local wStart = t - half
    local wEnd = t + half
    local wSpan = max(0.5, wEnd - wStart)

    -- Compute fraction of the sliding window covered by active GCD/cast intervals
    local active = 0
    local curS = nil
    local curE = nil

    for i = 1, #events do
        local ev = events[i]
        if not ev.isSyntheticEvent and ev.outcome == "SUCCEEDED" then
            local evStart = ev.t or 0
            local evEnd = evStart + max(1.5, ev.castTime or 0)
            if evEnd >= wStart and evStart <= wEnd then
                local cs = max(wStart, evStart)
                local ce = min(wEnd, evEnd)
                if curS == nil then
                    curS = cs
                    curE = ce
                elseif cs <= curE then
                    if ce > curE then
                        curE = ce
                    end
                else
                    active = active + (curE - curS)
                    curS = cs
                    curE = ce
                end
            end
        end
    end
    if curS ~= nil then
        active = active + (curE - curS)
    end
    return max(0, min(1, active / wSpan))
end

local function SavePillPosition(frame)
    if not frame or not NS.Addon or not NS.Addon.db then
        return
    end
    local point, _, relativePoint, xOfs, yOfs = frame:GetPoint(1)
    if point then
        NS.Addon.db.pillPos = {
            point = point,
            relativePoint = relativePoint or point,
            x = xOfs or 0,
            y = yOfs or 0,
        }
    end
end

local function RestorePillPosition(frame)
    if not frame then
        return
    end
    frame:ClearAllPoints()
    local pos = NS.Addon and NS.Addon.db and NS.Addon.db.pillPos
    if type(pos) == "table" and type(pos.point) == "string" then
        frame:SetPoint(pos.point, UIParent, pos.relativePoint or pos.point, pos.x or 0, pos.y or 0)
    else
        frame:SetPoint("TOP", UIParent, "TOP", 0, -96)
    end
end

local function EnsureNotificationPill()
    if pillFrame then
        return pillFrame
    end

    local f = CreateFrame("Button", "CombatTelemetryEfficiencyPill", UIParent, BACKDROP_TEMPLATE)
    f:SetSize(376, 32)
    RestorePillPosition(f)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:RegisterForClicks("LeftButtonUp")
    ApplyPanelBackdrop(f, 0.94, 0.25, 0.58, 0.85, 1.0)
    f:Hide()

    local accent = f:CreateTexture(nil, "ARTWORK")
    accent:SetSize(4, 30)
    accent:SetPoint("LEFT", f, "LEFT", 1, 0)
    accent:SetColorTexture(0.20, 0.82, 0.45, 1.0)
    f.accent = accent

    local text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", accent, "RIGHT", 8, 0)
    text:SetPoint("RIGHT", f, "RIGHT", -26, 0)
    text:SetJustifyH("LEFT")
    f.text = text

    local closeBtn = CreateFrame("Button", nil, f)
    closeBtn:SetSize(18, 18)
    closeBtn:SetPoint("RIGHT", f, "RIGHT", -5, 0)
    closeBtn:SetFrameLevel(f:GetFrameLevel() + 2)
    local closeTxt = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    closeTxt:SetPoint("CENTER")
    closeTxt:SetText("|cff999999x|r")
    closeBtn:SetScript("OnClick", function()
        f:Hide()
    end)

    f.autoHideAt = 0
    f.isDragging = false
    f:SetScript("OnDragStart", function(self)
        self.isDragging = true
        self.autoHideAt = 0
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self.isDragging = false
        self.autoHideAt = GetTime() + 18.0
        SavePillPosition(self)
    end)
    f:SetScript("OnUpdate", function(self)
        if not self.isDragging and self.autoHideAt > 0 and not self:IsMouseOver() and GetTime() >= self.autoHideAt then
            self:Hide()
        end
    end)

    f:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(0.45, 0.82, 1.0, 1.0)
    end)
    f:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.25, 0.58, 0.85, 1.0)
    end)

    f:SetScript("OnClick", function(self)
        if self.isDragging then
            return
        end
        self:Hide()
        selectedFightIndex = 1
        UI:Show()
    end)

    pillFrame = f
    return f
end

function UI:ShowPostCombatPill(fight)
    if not fight then
        return
    end
    local pill = EnsureNotificationPill()
    RestorePillPosition(pill)
    local score = fight.score or 100
    local scoreHex = "|cff2ed16b"
    local r, g, b = 0.20, 0.82, 0.45

    if score < 70 then
        scoreHex = "|cfff04047"
        r, g, b = 0.94, 0.25, 0.28
    elseif score < 88 then
        scoreHex = "|cfff5ad24"
        r, g, b = 0.96, 0.68, 0.14
    end

    pill.accent:SetColorTexture(r, g, b, 1.0)
    pill.text:SetText(format(
        "|cff5cc8ffCTE:|r %s (%s) — %s%d%%|r  |cffaaaaaa[Click to Review]|r",
        fight.targetName or "Encounter",
        FormatShortClock(fight.duration),
        scoreHex,
        score
    ))
    pill.autoHideAt = GetTime() + 18.0
    pill:Show()
end

local function RenderBand1(fight)
    local band = mainFrame.band1
    for i = 1, #scrubTickPool do
        scrubTickPool[i]:Hide()
    end

    if not fight then
        band.viewport:Hide()
        return
    end

    local width = band:GetWidth() - 4
    local height = band:GetHeight() - 4
    local dur = max(0.5, fight.duration or 0.5)

    local tickIdx = 0
    for i = 1, #filteredEvents do
        local ev = filteredEvents[i]
        if ev.verdict and ev.verdict ~= "EFFICIENT" then
            tickIdx = tickIdx + 1
            local tex = scrubTickPool[tickIdx]
            if not tex then
                tex = band:CreateTexture(nil, "ARTWORK")
                scrubTickPool[tickIdx] = tex
            end
            local c = GetVerdictColor(ev.verdict)
            local x = 2 + ((ev.t / dur) * width)
            tex:ClearAllPoints()
            tex:SetSize(2, height - 4)
            tex:SetPoint("LEFT", band, "LEFT", x, 0)
            tex:SetColorTexture(c[1], c[2], c[3], 0.95)
            tex:Show()
        end
    end

    local startRatio = max(0, min(1, viewStart / dur))
    local endRatio = max(startRatio + 0.02, min(1, viewEnd / dur))
    local boxLeft = 2 + (startRatio * width)
    local boxWidth = max(18, (endRatio - startRatio) * width)

    band.viewport:ClearAllPoints()
    band.viewport:SetPoint("TOPLEFT", band, "TOPLEFT", boxLeft, -2)
    band.viewport:SetSize(boxWidth, height)
    band.viewport:Show()
end

local function HighlightEventSync(eventIndex, shouldScrollLog)
    highlightedEventIndex = eventIndex

    for i = 1, #pinPool do
        local pin = pinPool[i]
        if pin:IsShown() then
            if pin.eventIndex == eventIndex then
                pin.highlight:Show()
            else
                pin.highlight:Hide()
            end
        end
    end

    for i = 1, #logRowPool do
        local row = logRowPool[i]
        if row:IsShown() then
            if row.eventIndex == eventIndex then
                row.bg:SetColorTexture(0.22, 0.36, 0.52, 0.65)
            else
                row.bg:SetColorTexture(0.11, 0.12, 0.15, (row.rowIndex % 2 == 0) and 0.55 or 0.25)
            end
        end
    end

    if shouldScrollLog and eventIndex and mainFrame and mainFrame.band3 then
        local scrollFrame = mainFrame.band3.scrollFrame
        local targetOffset = max(0, (eventIndex - 3) * LOG_ROW_HEIGHT)
        local maxScroll = max(0, (#filteredEvents - VISIBLE_LOG_ROWS) * LOG_ROW_HEIGHT)
        scrollFrame:SetVerticalScroll(min(targetOffset, maxScroll))
    end
end

local function RenderDruidFormRibbon(canvas, fight, plotW, span)
    if fight.playerClass ~= "DRUID" or not fight.formSegments or #fight.formSegments == 0 then
        return false
    end

    local ribbonH = 6
    local ribIdx = 0
    for i = 1, #fight.formSegments do
        local seg = fight.formSegments[i]
        local segStart = seg.startTime or 0
        local segEnd = seg.endTime or (fight.duration or segStart)
        local visStart = max(viewStart, segStart)
        local visEnd = min(viewEnd, segEnd)

        if visEnd > visStart then
            ribIdx = ribIdx + 1
            local tex = formRibbonPool[ribIdx]
            if not tex then
                tex = canvas:CreateTexture(nil, "OVERLAY")
                formRibbonPool[ribIdx] = tex
            end
            local fc = DRUID_FORM_COLORS[seg.form] or DRUID_FORM_COLORS.CASTER
            local xLeft = ((visStart - viewStart) / span) * plotW
            local segW = max(2, ((visEnd - visStart) / span) * plotW)

            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT", canvas, "TOPLEFT", xLeft, -1)
            tex:SetSize(segW, ribbonH)
            tex:SetColorTexture(fc[1], fc[2], fc[3], 0.95)
            tex:Show()
        end
    end

    return true
end

local function RenderDruidMultiFormSecondary(canvas, fight, plotW, plotH, span, topOffset)
    if viewLayerMode == "PRIMARY" then
        return
    end

    local sliceW = plotW / CURVE_SLICES
    local cpRGB = GetPowerBarColor(SECONDARY.COMBO_POINTS)
    local manaRGB = GetPowerBarColor(SECONDARY.MANA_BACKUP)

    for i = 1, CURVE_SLICES do
        local sampleT = viewStart + (((i - 0.5) / CURVE_SLICES) * span)
        local seg = GetFormSegmentAtTime(fight.formSegments, sampleT)
        local formKey = seg and seg.form or "CASTER"
        local xLeft = (i - 1) * sliceW

        if formKey == "CAT" then
            local cpVal, cpMax = SampleSecondaryAtTime(fight.secondarySamples, SECONDARY.COMBO_POINTS, sampleT)
            if cpVal > 0 then
                local fillRatio = max(0, min(1, cpVal / max(1, cpMax)))
                local bar = secCurvePool[i]
                if not bar then
                    bar = canvas:CreateTexture(nil, "OVERLAY")
                    secCurvePool[i] = bar
                end
                bar:ClearAllPoints()
                bar:SetPoint("TOPLEFT", canvas, "TOPLEFT", xLeft, -topOffset)
                bar:SetSize(sliceW + 0.6, max(2, fillRatio * 10))
                if cpVal >= cpMax then
                    bar:SetColorTexture(1.0, 0.45, 0.15, 0.92)
                else
                    bar:SetColorTexture(cpRGB[1], cpRGB[2], cpRGB[3], 0.80)
                end
                bar:Show()
            end
        elseif formKey == "BEAR" then
            local mVal, mMax = SampleSecondaryAtTime(fight.secondarySamples, SECONDARY.MANA_BACKUP, sampleT)
            if mMax > 0 then
                local ratio = max(0, min(1, mVal / max(1, mMax)))
                local yPos = max(2, ratio * (plotH - 6))
                local lineSeg = secCurvePool[i]
                if not lineSeg then
                    lineSeg = canvas:CreateTexture(nil, "OVERLAY")
                    secCurvePool[i] = lineSeg
                end
                lineSeg:ClearAllPoints()
                lineSeg:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", xLeft, yPos)
                lineSeg:SetSize(sliceW + 0.6, 2)
                lineSeg:SetColorTexture(manaRGB[1], manaRGB[2], manaRGB[3], 0.90)
                lineSeg:Show()
            end
        end
    end
end

local function RenderSecondaryOverlay(canvas, fight, plotW, plotH, span, secType, topOffset)
    if not secType or viewLayerMode == "PRIMARY" then
        return
    end

    local sliceW = plotW / CURVE_SLICES
    local secRGB = GetPowerBarColor(secType)

    if secType == SECONDARY.TOTEM_SLOTS then
        local laneH = 5
        local laneGap = 1
        local barIdx = 0

        for i = 1, CURVE_SLICES do
            local sampleT = viewStart + (((i - 0.5) / CURVE_SLICES) * span)
            local _, _, slots = SampleSecondaryAtTime(fight.secondarySamples, secType, sampleT)
            if type(slots) == "table" then
                local xLeft = (i - 1) * sliceW
                for slot = 1, 4 do
                    local st = slots[slot]
                    if st and st.active then
                        barIdx = barIdx + 1
                        local tex = totemBarPool[barIdx]
                        if not tex then
                            tex = canvas:CreateTexture(nil, "OVERLAY")
                            totemBarPool[barIdx] = tex
                        end
                        local sc = TOTEM_SLOT_COLORS[slot]
                        local yTop = -3 - ((slot - 1) * (laneH + laneGap))
                        tex:ClearAllPoints()
                        tex:SetPoint("TOPLEFT", canvas, "TOPLEFT", xLeft, yTop)
                        tex:SetSize(sliceW + 0.6, laneH)
                        tex:SetColorTexture(sc[1], sc[2], sc[3], 0.88)
                        tex:Show()
                    end
                end
            end
        end

    elseif secType == SECONDARY.COMBO_POINTS then
        local stripH = 12
        for i = 1, CURVE_SLICES do
            local sampleT = viewStart + (((i - 0.5) / CURVE_SLICES) * span)
            local cpVal, cpMax = SampleSecondaryAtTime(fight.secondarySamples, secType, sampleT)
            if cpVal > 0 then
                local fillRatio = max(0, min(1, cpVal / max(1, cpMax)))
                local xLeft = (i - 1) * sliceW
                local bar = secCurvePool[i]
                if not bar then
                    bar = canvas:CreateTexture(nil, "OVERLAY")
                    secCurvePool[i] = bar
                end
                bar:ClearAllPoints()
                bar:SetPoint("TOPLEFT", canvas, "TOPLEFT", xLeft, -topOffset)
                bar:SetSize(sliceW + 0.6, max(2, fillRatio * stripH))
                if cpVal >= cpMax then
                    bar:SetColorTexture(1.0, 0.45, 0.15, 0.92)
                else
                    bar:SetColorTexture(secRGB[1], secRGB[2], secRGB[3], 0.78)
                end
                bar:Show()
            end
        end

    elseif secType == SECONDARY.PET_FOCUS or secType == SECONDARY.MANA_BACKUP then
        for i = 1, CURVE_SLICES do
            local sampleT = viewStart + (((i - 0.5) / CURVE_SLICES) * span)
            local sVal, sMax, extra = SampleSecondaryAtTime(fight.secondarySamples, secType, sampleT)
            local showSlice = (sMax > 0)
            if secType == SECONDARY.PET_FOCUS and extra and extra.petAlive == false then
                showSlice = false
            end

            if showSlice then
                local ratio = max(0, min(1, sVal / max(1, sMax)))
                local yPos = max(2, ratio * (plotH - 6))
                local xLeft = (i - 1) * sliceW
                local seg = secCurvePool[i]
                if not seg then
                    seg = canvas:CreateTexture(nil, "OVERLAY")
                    secCurvePool[i] = seg
                end
                seg:ClearAllPoints()
                seg:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", xLeft, yPos)
                seg:SetSize(sliceW + 0.6, 2)
                seg:SetColorTexture(secRGB[1], secRGB[2], secRGB[3], 0.92)
                seg:Show()
            end
        end
    end
end

local function RenderBand2(fight)
    local canvas = mainFrame.band2.canvas

    for i = 1, #curveFillPool do
        curveFillPool[i]:Hide()
        curveLinePool[i]:Hide()
    end
    for i = 1, #secCurvePool do
        secCurvePool[i]:Hide()
    end
    for i = 1, #totemBarPool do
        totemBarPool[i]:Hide()
    end
    for i = 1, #formRibbonPool do
        formRibbonPool[i]:Hide()
    end
    for i = 1, #idleBandPool do
        idleBandPool[i]:Hide()
    end
    for i = 1, #dashLinePool do
        dashLinePool[i]:Hide()
    end
    for i = 1, #axisLabelPool do
        axisLabelPool[i]:Hide()
    end
    for i = 1, #pinPool do
        pinPool[i]:Hide()
    end
    mainFrame.band2.thresholdLabel:Hide()
    mainFrame.band2.legendLabel:Hide()

    if not fight then
        return
    end

    local plotW = canvas:GetWidth()
    local plotH = canvas:GetHeight()
    local span = max(0.25, viewEnd - viewStart)
    local primaryPowerType = (fight.summary and fight.summary.primaryPowerType) or 0
    local secondaryType = fight.summary and fight.summary.secondaryType
    local barRGB = GetPowerBarColor(primaryPowerType)
    local isMultiFormDruid = (fight.playerClass == "DRUID" and fight.formSegments and #fight.formSegments > 0)

    local hasFormRibbon = RenderDruidFormRibbon(canvas, fight, plotW, span)
    local topStripOffset = hasFormRibbon and 8 or 2

    -- Shaded vertical zones for detected Idle GCD Gaps
    local idleSegs = fight.summary and fight.summary.idleSegments
    if idleSegs and #idleSegs > 0 then
        local bandIdx = 0
        for i = 1, #idleSegs do
            local seg = idleSegs[i]
            local visStart = max(viewStart, seg.startTime or 0)
            local visEnd = min(viewEnd, seg.endTime or 0)
            if visEnd > visStart then
                bandIdx = bandIdx + 1
                local tex = idleBandPool[bandIdx]
                if not tex then
                    tex = canvas:CreateTexture(nil, "BACKGROUND")
                    idleBandPool[bandIdx] = tex
                end
                local xLeft = ((visStart - viewStart) / span) * plotW
                local segW = max(2, ((visEnd - visStart) / span) * plotW)
                tex:ClearAllPoints()
                tex:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", xLeft, 1)
                tex:SetSize(segW, plotH - 2)
                tex:SetColorTexture(0.95, 0.42, 0.18, 0.16)
                tex:Show()
            end
        end
    end

    local useTempoCurve = (fight.secretPowerDrops or 0) > 0
    local sampleMax = 100
    if viewLayerMode ~= "SECONDARY" then
        local sliceW = plotW / CURVE_SLICES
        for i = 1, CURVE_SLICES do
            local sampleT = viewStart + (((i - 0.5) / CURVE_SLICES) * span)
            local ratio = 0
            local sliceRGB = barRGB

            if useTempoCurve then
                ratio = SampleTempoAtTime(fight.events, sampleT, 2.0)
                sliceRGB = { 0.24, 0.78, 0.92 }
            else
                local slicePowerType = primaryPowerType
                if isMultiFormDruid then
                    local seg = GetFormSegmentAtTime(fight.formSegments, sampleT)
                    if seg then
                        slicePowerType = seg.powerType
                        sliceRGB = DRUID_FORM_COLORS[seg.form] or barRGB
                    end
                end
                local pVal, pMax = SamplePrimaryAtTime(fight.samples, slicePowerType, sampleT)
                if pMax > 0 then
                    sampleMax = pMax
                end
                ratio = max(0, min(1, pVal / max(1, pMax)))
            end

            local barH = max(1, ratio * (plotH - 8))
            local xLeft = (i - 1) * sliceW

            local fill = curveFillPool[i]
            if not fill then
                fill = canvas:CreateTexture(nil, "ARTWORK")
                curveFillPool[i] = fill
            end
            fill:ClearAllPoints()
            fill:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", xLeft, 1)
            fill:SetSize(sliceW + 0.6, barH)
            fill:SetColorTexture(sliceRGB[1], sliceRGB[2], sliceRGB[3], 0.22)
            fill:Show()

            local topEdge = curveLinePool[i]
            if not topEdge then
                topEdge = canvas:CreateTexture(nil, "OVERLAY")
                curveLinePool[i] = topEdge
            end
            topEdge:ClearAllPoints()
            topEdge:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", xLeft, barH)
            topEdge:SetSize(sliceW + 0.6, 2)
            topEdge:SetColorTexture(sliceRGB[1], sliceRGB[2], sliceRGB[3], 0.90)
            topEdge:Show()
        end
    end

    if isMultiFormDruid then
        RenderDruidMultiFormSecondary(canvas, fight, plotW, plotH, span, topStripOffset)
    else
        RenderSecondaryOverlay(canvas, fight, plotW, plotH, span, secondaryType, topStripOffset)
    end

    local legend = mainFrame.band2.legendLabel
    if useTempoCurve then
        legend:SetText("|cff3dc7ebCurve: Rolling GCD Tempo %|r  |  |cfff28538Shaded: Idle Gaps|r  |cff88929e(1.60.1 live pool masked)|r")
    elseif isMultiFormDruid then
        legend:SetText("|cffe03838Bear|r / |cfff5d62eCat+CP|r / |cff8f6bf5Moonkin|r / |cff297af5Caster|r")
    else
        local pName = (fight.summary and fight.summary.primaryPowerName) or "Resource"
        local sName = fight.summary and fight.summary.secondaryName
        if sName and viewLayerMode ~= "PRIMARY" then
            legend:SetText(format("|cffd8e2eePrimary: %s|r  |  |cff5cc8ffOverlay: %s|r", pName, sName))
        else
            legend:SetText(format("|cffd8e2eeResource: %s|r", pName))
        end
    end
    legend:ClearAllPoints()
    legend:SetPoint(
        "TOPLEFT",
        canvas,
        "TOPLEFT",
        6,
        (secondaryType == SECONDARY.TOTEM_SLOTS) and -30 or (hasFormRibbon and -20 or -16)
    )
    legend:Show()

    local hoardThresh = fight.summary and fight.summary.hoardThreshold or 0
    if not useTempoCurve and viewLayerMode ~= "SECONDARY" and hoardThresh > 0 and sampleMax > 0 and hoardThresh < sampleMax then
        local threshRatio = max(0.05, min(0.96, hoardThresh / sampleMax))
        local threshY = threshRatio * (plotH - 8)
        local dashCount = 34
        local stepW = plotW / dashCount

        for d = 1, dashCount do
            local dash = dashLinePool[d]
            if not dash then
                dash = canvas:CreateTexture(nil, "OVERLAY")
                dashLinePool[d] = dash
            end
            dash:ClearAllPoints()
            dash:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", (d - 1) * stepW, threshY)
            dash:SetSize(stepW * 0.55, 1)
            dash:SetColorTexture(0.96, 0.68, 0.14, 0.55)
            dash:Show()
        end

        local multVal = (NS.Addon and NS.Addon.db and NS.Addon.db.thresholds.hoardMultiplier) or 2.0
        local tLabel = mainFrame.band2.thresholdLabel
        tLabel:ClearAllPoints()
        tLabel:SetPoint("BOTTOMRIGHT", canvas, "BOTTOMRIGHT", -4, threshY + 3)
        tLabel:SetText(format("|cfff5ad24%.1fx Spender (%d)|r", multVal, floor(hoardThresh + 0.5)))
        tLabel:Show()
    end

    local tickCount = 6
    for tIdx = 0, tickCount do
        local ratio = tIdx / tickCount
        local tVal = viewStart + (ratio * span)
        local lbl = axisLabelPool[tIdx + 1]
        if not lbl then
            lbl = mainFrame.band2:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            lbl:SetTextColor(0.62, 0.66, 0.72)
            axisLabelPool[tIdx + 1] = lbl
        end
        lbl:ClearAllPoints()
        lbl:SetPoint("TOP", canvas, "BOTTOMLEFT", ratio * plotW, -3)
        lbl:SetText(FormatClock(tVal))
        lbl:Show()
    end

    local visibleList = {}
    for idx = 1, #filteredEvents do
        local ev = filteredEvents[idx]
        if ev.t >= viewStart and ev.t <= viewEnd then
            tinsert(visibleList, { index = idx, ev = ev })
        end
    end

    local clusters = {}
    for i = 1, #visibleList do
        local item = visibleList[i]
        local prevCluster = clusters[#clusters]
        if prevCluster and abs(item.ev.t - prevCluster.t) <= 0.025 then
            tinsert(prevCluster.items, item)
        else
            tinsert(clusters, {
                t = item.ev.t,
                items = { item },
            })
        end
    end

    local pinIdx = 0
    for c = 1, #clusters do
        local cluster = clusters[c]
        local stackSize = #cluster.items
        local isMacroStack = stackSize > 1
        local iconSize = isMacroStack and 17 or 21
        local xCenter = ((cluster.t - viewStart) / span) * plotW
        xCenter = max(iconSize * 0.5 + 2, min(plotW - iconSize * 0.5 - 2, xCenter))

        local baseEv = cluster.items[1].ev
        local pRatio
        if useTempoCurve then
            pRatio = baseEv.isSyntheticIdle and 0.18 or SampleTempoAtTime(fight.events, cluster.t, 2.0)
        elseif baseEv.isSyntheticIdle then
            pRatio = 0.18
        else
            pRatio = max(0, min(1, (baseEv.powerBefore or 0) / max(1, baseEv.powerMax or sampleMax)))
        end
        local baseY = max(4, min(plotH - iconSize - 8, pRatio * (plotH - iconSize - 12) + 4))
        local stackDir = (baseY + (stackSize * (iconSize + 2)) > plotH - 8) and -1 or 1

        for s = 1, stackSize do
            local item = cluster.items[s]
            local ev = item.ev
            pinIdx = pinIdx + 1

            local pin = pinPool[pinIdx]
            if not pin then
                pin = CreateFrame("Button", nil, canvas, BACKDROP_TEMPLATE)
                pin:SetFrameLevel(canvas:GetFrameLevel() + 5)

                local icon = pin:CreateTexture(nil, "ARTWORK")
                icon:SetPoint("TOPLEFT", 2, -2)
                icon:SetPoint("BOTTOMRIGHT", -2, 2)
                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                pin.icon = icon

                local badge = pin:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
                badge:SetPoint("BOTTOMRIGHT", pin, "BOTTOMRIGHT", 2, -2)
                pin.badge = badge

                local macroTag = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                macroTag:SetPoint("TOPLEFT", pin, "TOPLEFT", 1, -1)
                macroTag:SetText("|cff66d9ffM|r")
                pin.macroTag = macroTag

                local hl = pin:CreateTexture(nil, "OVERLAY")
                hl:SetPoint("TOPLEFT", -3, 3)
                hl:SetPoint("BOTTOMRIGHT", 3, -3)
                hl:SetColorTexture(1.0, 1.0, 1.0, 0.35)
                hl:Hide()
                pin.highlight = hl

                pin:SetScript("OnEnter", function(self)
                    local e = self.eventData
                    if not e then
                        return
                    end
                    HighlightEventSync(self.eventIndex, true)

                    GameTooltip:SetOwner(self, "ANCHOR_TOP")
                    local hex = VERDICT_HEX[e.verdict] or "|cffffffff"
                    GameTooltip:AddLine(
                        format("%s (%s)", e.spellName or "Ability", FormatClock(e.t)),
                        1, 1, 1
                    )
                    if e.druidForm and DRUID_FORM_LABEL[e.druidForm] then
                        GameTooltip:AddDoubleLine(
                            "Active Form:",
                            DRUID_FORM_LABEL[e.druidForm],
                            0.7, 0.75, 0.8, 0.96, 0.84, 0.25
                        )
                    end
                    GameTooltip:AddLine(
                        format("%s%s|r", hex, e.note or e.verdict or ""),
                        0.9, 0.9, 0.9, true
                    )
                    if (e.spellCost or 0) > 0 then
                        GameTooltip:AddDoubleLine(
                            "Resource Before / Cost:",
                            format("%d / %d", e.powerBefore or 0, e.spellCost),
                            0.7, 0.75, 0.8, 1, 1, 1
                        )
                    end
                    if e.secondaryType == SECONDARY.COMBO_POINTS then
                        GameTooltip:AddDoubleLine(
                            "Combo Points:",
                            format("%d / %d", e.secondaryBefore or 0, e.secondaryMax or 5),
                            0.7, 0.75, 0.8, 1.0, 0.82, 0.25
                        )
                    elseif e.secondaryType == SECONDARY.PET_FOCUS then
                        GameTooltip:AddDoubleLine(
                            "Pet Focus:",
                            e.petAlive and format("%d / %d", e.secondaryBefore or 0, e.secondaryMax or 100) or "No Active Pet",
                            0.7, 0.75, 0.8, 0.25, 0.92, 0.80
                        )
                    elseif e.secondaryType == SECONDARY.TOTEM_SLOTS then
                        GameTooltip:AddDoubleLine(
                            "Active Totems:",
                            format("%d / 4 slots", e.secondaryBefore or 0),
                            0.7, 0.75, 0.8, 0.45, 0.82, 1.0
                        )
                    end
                    if (e.burstSize or 1) > 1 then
                        GameTooltip:AddLine(
                            format("|cff66d9ffMacro Burst:|r %d simultaneous spells", e.burstSize),
                            0.7, 0.85, 1.0
                        )
                    end
                    GameTooltip:Show()
                end)

                pin:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                    HighlightEventSync(nil, false)
                end)

                pinPool[pinIdx] = pin
            end

            local yOffset = baseY + ((s - 1) * (iconSize + 2) * stackDir)
            yOffset = max(2, min(plotH - iconSize - 8, yOffset))

            pin:ClearAllPoints()
            pin:SetSize(iconSize, iconSize)
            pin:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", xCenter - (iconSize * 0.5), yOffset)

            local cBorder = GetVerdictColor(ev.verdict)
            ApplyPanelBackdrop(pin, 1.0, cBorder[1], cBorder[2], cBorder[3], 1.0)

            local texPath = ResolveSpellIcon(ev)
            pin.icon:SetTexture(texPath)

            if (ev.pressCount or 1) > 1 and not ev.isSyntheticOvercap then
                pin.badge:SetText(format("|cffff4d4dx%d|r", ev.pressCount))
                pin.badge:Show()
            else
                pin.badge:Hide()
            end

            if isMacroStack and s == stackSize then
                pin.macroTag:Show()
            else
                pin.macroTag:Hide()
            end

            if highlightedEventIndex == item.index then
                pin.highlight:Show()
            else
                pin.highlight:Hide()
            end

            pin.eventIndex = item.index
            pin.eventData = ev
            pin:Show()
        end
    end
end

local function GetVisibleLogRowCount()
    if mainFrame and mainFrame.band3 and mainFrame.band3.clipFrame then
        local h = mainFrame.band3.clipFrame:GetHeight() or 0
        if h > LOG_ROW_HEIGHT then
            return max(4, floor(h / LOG_ROW_HEIGHT))
        end
    end
    return DEFAULT_VISIBLE_LOG_ROWS
end

local function RenderBand3(fight)
    local band3 = mainFrame.band3
    local scrollFrame = band3.scrollFrame
    local totalRows = #filteredEvents
    local visRows = GetVisibleLogRowCount()

    band3.content:SetHeight(max(visRows * LOG_ROW_HEIGHT, totalRows * LOG_ROW_HEIGHT))

    local offset = scrollFrame:GetVerticalScroll() or 0
    local firstIndex = floor(offset / LOG_ROW_HEIGHT) + 1

    for i = 1, #logRowPool do
        logRowPool[i]:Hide()
    end

    for r = 1, visRows + 1 do
        local row = logRowPool[r]
        if not row then
            row = CreateFrame("Button", nil, band3.clipFrame)
            row:SetHeight(LOG_ROW_HEIGHT)
            row:SetPoint("LEFT", band3.clipFrame, "LEFT", 0, 0)
            row:SetPoint("RIGHT", band3.clipFrame, "RIGHT", -18, 0)
            row.rowIndex = r

            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            row.bg = bg

            local timeTxt = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            timeTxt:SetPoint("LEFT", row, "LEFT", 6, 0)
            timeTxt:SetWidth(50)
            timeTxt:SetJustifyH("LEFT")
            timeTxt:SetTextColor(0.72, 0.76, 0.82)
            row.timeTxt = timeTxt

            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(16, 16)
            icon:SetPoint("LEFT", timeTxt, "RIGHT", 4, 0)
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            row.icon = icon

            local spellTxt = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            spellTxt:SetPoint("LEFT", icon, "RIGHT", 6, 0)
            spellTxt:SetWidth(174)
            spellTxt:SetJustifyH("LEFT")
            row.spellTxt = spellTxt

            local powerTxt = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            powerTxt:SetPoint("LEFT", spellTxt, "RIGHT", 6, 0)
            powerTxt:SetWidth(112)
            powerTxt:SetJustifyH("LEFT")
            powerTxt:SetTextColor(0.85, 0.88, 0.92)
            row.powerTxt = powerTxt

            local gapTxt = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            gapTxt:SetPoint("LEFT", powerTxt, "RIGHT", 4, 0)
            gapTxt:SetWidth(46)
            gapTxt:SetJustifyH("LEFT")
            gapTxt:SetTextColor(0.62, 0.66, 0.72)
            row.gapTxt = gapTxt

            local noteTxt = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            noteTxt:SetPoint("LEFT", gapTxt, "RIGHT", 6, 0)
            noteTxt:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            noteTxt:SetJustifyH("LEFT")
            row.noteTxt = noteTxt

            row:SetScript("OnEnter", function(self)
                if self.eventIndex then
                    HighlightEventSync(self.eventIndex, false)
                end
            end)
            row:SetScript("OnLeave", function()
                HighlightEventSync(nil, false)
            end)
            row:SetScript("OnClick", function(self)
                local activeFight = GetActiveFight()
                if activeFight and self.eventData then
                    CenterViewportOnTime(activeFight, self.eventData.t)
                    RenderBand1(activeFight)
                    RenderBand2(activeFight)
                end
            end)

            logRowPool[r] = row
        end

        local dataIdx = firstIndex + r - 1
        local ev = filteredEvents[dataIdx]
        if fight and ev then
            local yTop = -((r - 1) * LOG_ROW_HEIGHT)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", band3.clipFrame, "TOPLEFT", 0, yTop)
            row:SetPoint("TOPRIGHT", band3.clipFrame, "TOPRIGHT", -18, yTop)

            row.eventIndex = dataIdx
            row.eventData = ev

            if highlightedEventIndex == dataIdx then
                row.bg:SetColorTexture(0.22, 0.36, 0.52, 0.65)
            else
                row.bg:SetColorTexture(0.11, 0.12, 0.15, (dataIdx % 2 == 0) and 0.55 or 0.25)
            end

            row.timeTxt:SetText(FormatClock(ev.t))
            row.icon:SetTexture(ResolveSpellIcon(ev))

            local prefix = ""
            if ev.druidForm and DRUID_FORM_SHORT[ev.druidForm] then
                prefix = DRUID_FORM_SHORT[ev.druidForm] .. " "
            end

            local badges = ""
            if ev.isPreCast then
                badges = badges .. " |cff45e0a2[Q]|r"
            end
            if ev.isPowershift then
                badges = badges .. " |cff33e6c2[PS]|r"
            end
            if (ev.burstSize or 1) > 1 then
                badges = badges .. " |cff66d9ff[M]|r"
            end
            if (ev.pressCount or 1) > 1 and not ev.isSyntheticOvercap then
                badges = badges .. format(" |cffff4d4dx%d|r", ev.pressCount)
            end
            row.spellTxt:SetText(prefix .. (ev.spellName or "Ability") .. badges)

            local resStr
            if ev.isSyntheticIdle then
                resStr = format("|cfff28538-%.1fs idle|r", ev.idleSeconds or 0)
            elseif ev.isSyntheticOvercap then
                resStr = format("%d/%d", ev.powerBefore or 0, ev.powerMax or 100)
            elseif ev.powerIsSecret then
                if ev.estimatedPowerBefore ~= nil then
                    if (ev.spellCost or 0) > 0 then
                        resStr = format("|cff88929e~%d|r (-%d)", ev.estimatedPowerBefore, ev.spellCost)
                    else
                        resStr = format("|cff88929e~%d|r", ev.estimatedPowerBefore)
                    end
                elseif (ev.spellCost or 0) > 0 then
                    resStr = format("|cff88929eSecret|r (-%d)", ev.spellCost)
                else
                    resStr = "|cff88929eSecret|r"
                end
            else
                resStr = format("%d->%d", ev.powerBefore or 0, ev.powerAfter or 0)
            end

            if ev.secondaryType == SECONDARY.COMBO_POINTS then
                resStr = resStr .. format(" |cffffcc33(%dCP)|r", ev.secondaryBefore or 0)
            elseif ev.secondaryType == SECONDARY.PET_FOCUS and ev.petAlive then
                resStr = resStr .. format(" |cff33e6c2(P:%d)|r", ev.secondaryBefore or 0)
            elseif ev.secondaryType == SECONDARY.TOTEM_SLOTS then
                resStr = resStr .. format(" |cff66ccff(%d/4T)|r", ev.secondaryBefore or 0)
            end
            row.powerTxt:SetText(resStr)

            local prevEv = filteredEvents[dataIdx - 1]
            local gap = prevEv and max(0, (ev.t or 0) - (prevEv.t or 0)) or (ev.t or 0)
            row.gapTxt:SetText(format("+%.1fs", gap))

            local hex = VERDICT_HEX[ev.verdict] or "|cffffffff"
            row.noteTxt:SetText(hex .. (ev.note or ev.verdict or "") .. "|r")
            row:Show()
        else
            row:Hide()
        end
    end
end

function UI:Refresh()
    if not mainFrame or not mainFrame:IsShown() then
        return
    end

    if settingsPopover and settingsPopover:IsShown() then
        SyncSettingsPopover()
    end

    local fight = GetActiveFight()
    RebuildFilteredEvents(fight)

    if not fight then
        mainFrame.fightDropBtn.label:SetText("No Recorded Fights")
        mainFrame.scoreText:SetText("|cff888888Score: --|r")
        mainFrame.summaryText:SetText("Enter combat to record rotation telemetry, then open /cte to inspect.")
        mainFrame.layerBtn.label:SetText("View: Dual")
        if mainFrame.pinBtn then
            mainFrame.pinBtn:SetActiveState(false)
            mainFrame.pinBtn.label:SetText("Pin")
            mainFrame.pinBtn:SetEnabled(false)
        end
        if mainFrame.delBtn then
            mainFrame.delBtn:SetEnabled(false)
        end
        if mainFrame.delAllBtn then
            delAllConfirmUntil = 0
            mainFrame.delAllBtn:SetActiveState(false)
            mainFrame.delAllBtn.label:SetText("Delete All")
            mainFrame.delAllBtn:SetEnabled(false)
        end
        if mainFrame.compareBtn then
            local isMulti = NS.Addon and NS.Addon.IsMultiFightMode and NS.Addon:IsMultiFightMode()
            if isMulti then
                mainFrame.compareBtn:Show()
                mainFrame.compareBtn:SetEnabled(false)
            else
                mainFrame.compareBtn:Hide()
            end
        end
        if mainFrame.filterChips then
            for key, chip in pairs(mainFrame.filterChips) do
                chip.label:SetText(chip.baseLabel)
                chip:SetActiveState(verdictFilter == key)
            end
        end
        RenderBand1(nil)
        RenderBand2(nil)
        RenderBand3(nil)
        return
    end

    local fights = NS.Addon.db.fights
    local score = fight.score or 100
    local scoreHex = (score >= 88 and "|cff2ed16b") or (score >= 70 and "|cfff5ad24") or "|cfff04047"

    local pinTag = fight.pinned and "|cffffd100[P]|r " or ""
    mainFrame.fightDropBtn.label:SetText(format(
        "%s#%d %s (%s)  v",
        pinTag,
        selectedFightIndex,
        fight.targetName or "Encounter",
        FormatShortClock(fight.duration)
    ))
    mainFrame.scoreText:SetText(format("Score: %s%d%%|r", scoreHex, score))

    local sum = fight.summary
    if sum then
        local extraStat = ""
        if fight.playerClass == "HUNTER" and sum.petUptimePct ~= nil then
            extraStat = format("  |  |cff33e6c2Pet Uptime: %d%%|r", sum.petUptimePct)
        elseif fight.playerClass == "SHAMAN" and sum.avgActiveTotems ~= nil then
            extraStat = format("  |  |cff66ccffTotems: %.1f/4|r", sum.avgActiveTotems)
        elseif fight.playerClass == "DRUID" and sum.formBreakdown then
            local fb = sum.formBreakdown
            local parts = {}
            if (fb.CAT or 0) > 0 then
                tinsert(parts, format("|cfff5d62eCat %d%%|r", fb.CAT))
            end
            if (fb.BEAR or 0) > 0 then
                tinsert(parts, format("|cffe03838Bear %d%%|r", fb.BEAR))
            end
            if (fb.MOONKIN or 0) > 0 then
                tinsert(parts, format("|cff8f6bf5Moon %d%%|r", fb.MOONKIN))
            end
            if (fb.CASTER or 0) > 0 then
                tinsert(parts, format("|cff297af5Cast %d%%|r", fb.CASTER))
            end
            if #parts > 0 then
                extraStat = "  |  " .. table.concat(parts, " ")
            end
        end

        local tempoTag = ""
        if sum.activeUptimePct ~= nil then
            tempoTag = format("  |  |cff5cc8ffUptime %d%% (%.1f CPM)|r", sum.activeUptimePct or 0, sum.cpm or 0)
        end
        mainFrame.summaryText:SetText(format(
            "|cff2ed16b%d Eff|r | |cfff04047%d Early|r | |cfff5ad24%d Late|r | |cffd159eb%d Over|r | |cfff28538%d Idle|r%s%s",
            sum.efficientCount or 0,
            sum.earlyStarvedCount or 0,
            sum.lateHoardCount or 0,
            sum.overcapWasteCount or 0,
            sum.idleGapCount or 0,
            tempoTag,
            extraStat
        ))
    else
        mainFrame.summaryText:SetText("")
    end

    local modeLabel = (viewLayerMode == "DUAL" and "View: Dual")
        or (viewLayerMode == "PRIMARY" and "View: Primary")
        or "View: Secondary"
    mainFrame.layerBtn.label:SetText(modeLabel)

    mainFrame.prevBtn:SetEnabled(selectedFightIndex < #fights)
    mainFrame.nextBtn:SetEnabled(selectedFightIndex > 1)

    if mainFrame.pinBtn then
        mainFrame.pinBtn:SetEnabled(true)
        if fight.pinned then
            mainFrame.pinBtn:SetActiveState(true)
            mainFrame.pinBtn:SetBackdropColor(0.34, 0.27, 0.08, 1.0)
            mainFrame.pinBtn:SetBackdropBorderColor(0.98, 0.80, 0.22, 1.0)
            mainFrame.pinBtn.label:SetText("|cffffd100Pinned|r")
        else
            mainFrame.pinBtn:SetActiveState(false)
            mainFrame.pinBtn.label:SetText("Pin")
        end
    end
    if mainFrame.delBtn then
        mainFrame.delBtn:SetEnabled(true)
    end
    if mainFrame.delAllBtn then
        mainFrame.delAllBtn:SetEnabled(true)
        if delAllConfirmUntil <= GetTime() then
            delAllConfirmUntil = 0
            mainFrame.delAllBtn:SetActiveState(false)
            mainFrame.delAllBtn.label:SetText("Delete All")
        end
    end
    if mainFrame.compareBtn then
        local isMulti = NS.Addon and NS.Addon.IsMultiFightMode and NS.Addon:IsMultiFightMode()
        if isMulti or #fights > 1 then
            mainFrame.compareBtn:Show()
            mainFrame.compareBtn:SetEnabled(#fights > 0)
            mainFrame.compareBtn.label:SetText(format("Compare (%d)", #fights))
        else
            mainFrame.compareBtn:Hide()
        end
    end

    if mainFrame.filterChips then
        local totalAll = #(fight.events or {})
        local earlyCnt = (sum and sum.earlyStarvedCount) or 0
        local lateCnt = (sum and sum.lateHoardCount) or 0
        local overcapCnt = (sum and sum.overcapWasteCount) or 0
        local idleCnt = (sum and sum.idleGapCount) or 0
        local issuesCnt = earlyCnt + lateCnt + overcapCnt + idleCnt

        local counts = {
            ALL = totalAll,
            ISSUES = issuesCnt,
            EARLY_STARVED = earlyCnt,
            LATE_HOARD = lateCnt,
            OVERCAP_WASTE = overcapCnt,
            IDLE_GAP = idleCnt,
        }
        for key, chip in pairs(mainFrame.filterChips) do
            local cnt = counts[key] or 0
            chip.label:SetText(format("%s (%d)", chip.baseLabel, cnt))
            local isActive = (verdictFilter == key)
            chip:SetActiveState(isActive)
            if isActive and chip.activeRGB then
                local c = chip.activeRGB
                chip:SetBackdropColor(c[1] * 0.28, c[2] * 0.28, c[3] * 0.28, 1.0)
                chip:SetBackdropBorderColor(c[1], c[2], c[3], 1.0)
            end
        end
    end

    for z, btn in pairs(mainFrame.zoomButtons) do
        btn:SetActiveState(zoomLevel == z)
    end

    RenderBand1(fight)
    RenderBand2(fight)
    RenderBand3(fight)
    if compareFrame and compareFrame:IsShown() and UI.RefreshCompareWindow then
        UI:RefreshCompareWindow()
    end
end

local function ToggleFightDropdown(anchor)
    if not fightMenuFrame then
        local menu = CreateFrame("Frame", nil, mainFrame, BACKDROP_TEMPLATE)
        menu:SetFrameStrata("FULLSCREEN_DIALOG")
        ApplyPanelBackdrop(menu, 0.98, 0.35, 0.65, 0.90, 1.0)
        menu.buttons = {}
        menu:Hide()
        fightMenuFrame = menu
    end

    if fightMenuFrame:IsShown() then
        fightMenuFrame:Hide()
        return
    end

    if settingsPopover and settingsPopover:IsShown() then
        settingsPopover:Hide()
        if mainFrame and mainFrame.settingsBtn then
            mainFrame.settingsBtn:SetActiveState(false)
        end
    end
    if reportPopover and reportPopover:IsShown() then
        reportPopover:Hide()
        if mainFrame and mainFrame.reportBtn then
            mainFrame.reportBtn:SetActiveState(false)
        end
    end

    local fights = (NS.Addon and NS.Addon.db and NS.Addon.db.fights) or {}
    if #fights == 0 then
        return
    end

    for i = 1, #fightMenuFrame.buttons do
        fightMenuFrame.buttons[i]:Hide()
    end

    local itemH = 22
    fightMenuFrame:SetSize(250, (#fights * itemH) + 8)
    fightMenuFrame:ClearAllPoints()
    fightMenuFrame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)

    for i = 1, #fights do
        local f = fights[i]
        local item = fightMenuFrame.buttons[i]
        if not item then
            item = CreateFrame("Button", nil, fightMenuFrame)
            item:SetHeight(itemH)
            local hl = item:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(0.25, 0.52, 0.82, 0.45)

            local txt = item:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            txt:SetPoint("LEFT", 8, 0)
            txt:SetPoint("RIGHT", -8, 0)
            txt:SetJustifyH("LEFT")
            item.txt = txt

            item:SetScript("OnClick", function(self)
                selectedFightIndex = self.fightIdx
                verdictFilter = "ALL"
                highlightedEventIndex = nil
                if mainFrame and mainFrame.band3 and mainFrame.band3.scrollFrame then
                    mainFrame.band3.scrollFrame:SetVerticalScroll(0)
                end
                SetViewportRange(GetActiveFight(), 0, 1)
                fightMenuFrame:Hide()
                UI:Refresh()
            end)
            fightMenuFrame.buttons[i] = item
        end

        item.fightIdx = i
        item:SetPoint("TOPLEFT", fightMenuFrame, "TOPLEFT", 4, -4 - ((i - 1) * itemH))
        item:SetPoint("TOPRIGHT", fightMenuFrame, "TOPRIGHT", -4, -4 - ((i - 1) * itemH))
        item.txt:SetText(format(
            "%s#%d %s (%s) — %d%%",
            f.pinned and "|cffffd100[P]|r " or "",
            i,
            f.targetName or "Encounter",
            FormatShortClock(f.duration),
            f.score or 100
        ))
        item:Show()
    end

    fightMenuFrame:Show()
end

local function SaveMainWindowPosition(frame)
    if not frame or not NS.Addon or not NS.Addon.db then
        return
    end
    local point, _, relativePoint, xOfs, yOfs = frame:GetPoint(1)
    if point then
        NS.Addon.db.windowPos = {
            point = point,
            relativePoint = relativePoint or point,
            x = xOfs or 0,
            y = yOfs or 0,
        }
    end
end

local function SaveMainWindowSize(frame)
    if not frame or not NS.Addon or not NS.Addon.db then
        return
    end
    local w = floor((frame:GetWidth() or DEFAULT_WINDOW_WIDTH) + 0.5)
    local h = floor((frame:GetHeight() or DEFAULT_WINDOW_HEIGHT) + 0.5)
    NS.Addon.db.windowSize = {
        w = max(MIN_WINDOW_WIDTH, min(MAX_WINDOW_WIDTH, w)),
        h = max(MIN_WINDOW_HEIGHT, min(MAX_WINDOW_HEIGHT, h)),
    }
end

local function ApplyMainWindowResponsiveLayout(frame)
    if not frame then
        return
    end
    local w = frame:GetWidth() or DEFAULT_WINDOW_WIDTH
    local h = frame:GetHeight() or DEFAULT_WINDOW_HEIGHT

    -- Scale Band 2 proportionally when taller, leaving generous room for Band 3 rows
    local extraH = h - DEFAULT_WINDOW_HEIGHT
    local b2H = max(150, min(340, floor(BASE_BAND2_HEIGHT + (extraH * 0.35) + 0.5)))
    if frame.band2 then
        frame.band2:SetHeight(b2H)
    end
    if frame.band3 and frame.band3.content then
        frame.band3.content:SetWidth(max(400, w - 52))
    end
end

local function RestoreMainWindowSize(frame)
    if not frame then
        return
    end
    local sz = NS.Addon and NS.Addon.db and NS.Addon.db.windowSize
    local w = DEFAULT_WINDOW_WIDTH
    local h = DEFAULT_WINDOW_HEIGHT
    if type(sz) == "table" then
        if type(sz.w) == "number" then
            w = max(MIN_WINDOW_WIDTH, min(MAX_WINDOW_WIDTH, sz.w))
        end
        if type(sz.h) == "number" then
            h = max(MIN_WINDOW_HEIGHT, min(MAX_WINDOW_HEIGHT, sz.h))
        end
    end
    frame:SetSize(w, h)
    ApplyMainWindowResponsiveLayout(frame)
end

local function RestoreMainWindowPosition(frame)
    if not frame then
        return
    end
    frame:ClearAllPoints()
    local pos = NS.Addon and NS.Addon.db and NS.Addon.db.windowPos
    if type(pos) == "table" and type(pos.point) == "string" then
        frame:SetPoint(pos.point, UIParent, pos.relativePoint or pos.point, pos.x or 0, pos.y or 0)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

function UI:ResetWindowPosition()
    if NS.Addon and NS.Addon.db then
        NS.Addon.db.windowPos = nil
        NS.Addon.db.windowSize = nil
        NS.Addon.db.pillPos = nil
    end
    if mainFrame then
        RestoreMainWindowSize(mainFrame)
        RestoreMainWindowPosition(mainFrame)
        if mainFrame:IsShown() then
            self:Refresh()
        end
    end
    if pillFrame then
        RestorePillPosition(pillFrame)
    end
end

local function BeginMainWindowDrag()
    if not mainFrame then
        return
    end
    CancelAutoFade()
    mainFrame:StartMoving()
end

local function EndMainWindowDrag()
    if not mainFrame then
        return
    end
    mainFrame:StopMovingOrSizing()
    SaveMainWindowPosition(mainFrame)
end

local function AttachMainDragForwarder(targetFrame)
    if not targetFrame then
        return
    end
    targetFrame:EnableMouse(true)
    targetFrame:RegisterForDrag("LeftButton")
    targetFrame:SetScript("OnMouseDown", function()
        CancelAutoFade()
    end)
    targetFrame:SetScript("OnDragStart", BeginMainWindowDrag)
    targetFrame:SetScript("OnDragStop", EndMainWindowDrag)
end

local function EnsureMainFrame()
    if mainFrame then
        return mainFrame
    end

    local f = CreateFrame("Frame", "CombatTelemetryEfficiencyMainFrame", UIParent, BACKDROP_TEMPLATE)
    RestoreMainWindowSize(f)
    RestoreMainWindowPosition(f)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT)
    else
        if f.SetMinResize then
            f:SetMinResize(MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT)
        end
        if f.SetMaxResize then
            f:SetMaxResize(MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT)
        end
    end
    f:SetClampedToScreen(true)
    f:SetScript("OnSizeChanged", function(self)
        ApplyMainWindowResponsiveLayout(self)
        if self:IsShown() then
            UI:Refresh()
        end
    end)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnMouseDown", function()
        CancelAutoFade()
    end)
    f:SetScript("OnDragStart", BeginMainWindowDrag)
    f:SetScript("OnDragStop", EndMainWindowDrag)
    f:SetScript("OnUpdate", function(self)
        if not autoFadeArmed then
            return
        end

        -- Any click inside the CTE window (including child buttons, tabs, or log rows) locks it open
        if IsMouseButtonDown and self:IsMouseOver() and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) then
            CancelAutoFade()
            return
        end

        -- If the user opened any child popover, lock the window open
        if (settingsPopover and settingsPopover:IsShown())
            or (reportPopover and reportPopover:IsShown())
            or (fightMenuFrame and fightMenuFrame:IsShown())
        then
            CancelAutoFade()
            return
        end

        local now = GetTime()
        local remaining = autoFadeStartAt - now
        if remaining > 0 then
            local wholeSec = floor(remaining + 0.999)
            if wholeSec ~= autoFadeLastShownSec then
                autoFadeLastShownSec = wholeSec
                if self.fadeStatusText then
                    self.fadeStatusText:SetText(format("|cff88929eAuto-fade: %ds (click to keep)|r", wholeSec))
                    self.fadeStatusText:Show()
                end
            end
            return
        end

        local elapsedFade = now - autoFadeStartAt
        if elapsedFade >= AUTO_FADE_DURATION then
            CancelAutoFade()
            self:Hide()
            return
        end

        local alpha = max(0, 1.0 - (elapsedFade / AUTO_FADE_DURATION))
        self:SetAlpha(alpha)
    end)
    f:SetScript("OnHide", function()
        CancelAutoFade()
        if fightMenuFrame then
            fightMenuFrame:Hide()
        end
        if settingsPopover then
            settingsPopover:Hide()
        end
        if reportPopover then
            reportPopover:Hide()
        end
        if f.settingsBtn then
            f.settingsBtn:SetActiveState(false)
        end
        if f.reportBtn then
            f.reportBtn:SetActiveState(false)
        end
        delAllConfirmUntil = 0
        if f.delAllBtn then
            f.delAllBtn:SetActiveState(false)
            f.delAllBtn.label:SetText("Delete All")
        end
    end)
    ApplyPanelBackdrop(f, 0.96, 0.26, 0.30, 0.36, 1.0)
    f:Hide()

    tinsert(UISpecialFrames, "CombatTelemetryEfficiencyMainFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
    title:SetText("|cff5cc8ffCombatTelemetryEfficiency|r")

    local headerDrag = CreateFrame("Frame", nil, f)
    headerDrag:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    headerDrag:SetPoint("TOPRIGHT", f, "TOPRIGHT", -36, -4)
    headerDrag:SetHeight(46)
    headerDrag:SetFrameLevel(f:GetFrameLevel())
    AttachMainDragForwarder(headerDrag)

    local closeBtn = CreateActionButton(f, 22, 22, "X")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -9)
    closeBtn:SetScript("OnClick", function()
        f:Hide()
    end)

    local prevBtn = CreateActionButton(f, 22, 22, "<")
    prevBtn:SetPoint("LEFT", title, "RIGHT", 12, 0)
    prevBtn:SetScript("OnClick", function()
        selectedFightIndex = selectedFightIndex + 1
        verdictFilter = "ALL"
        highlightedEventIndex = nil
        if mainFrame and mainFrame.band3 and mainFrame.band3.scrollFrame then
            mainFrame.band3.scrollFrame:SetVerticalScroll(0)
        end
        SetViewportRange(GetActiveFight(), 0, 1)
        UI:Refresh()
    end)
    f.prevBtn = prevBtn

    local fightDropBtn = CreateActionButton(f, 180, 22, "No Recorded Fights")
    fightDropBtn:SetPoint("LEFT", prevBtn, "RIGHT", 3, 0)
    fightDropBtn:SetScript("OnClick", function(self)
        ToggleFightDropdown(self)
    end)
    f.fightDropBtn = fightDropBtn

    local nextBtn = CreateActionButton(f, 22, 22, ">")
    nextBtn:SetPoint("LEFT", fightDropBtn, "RIGHT", 3, 0)
    nextBtn:SetScript("OnClick", function()
        selectedFightIndex = max(1, selectedFightIndex - 1)
        verdictFilter = "ALL"
        highlightedEventIndex = nil
        if mainFrame and mainFrame.band3 and mainFrame.band3.scrollFrame then
            mainFrame.band3.scrollFrame:SetVerticalScroll(0)
        end
        SetViewportRange(GetActiveFight(), 0, 1)
        UI:Refresh()
    end)
    f.nextBtn = nextBtn

    local scoreText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    scoreText:SetPoint("LEFT", nextBtn, "RIGHT", 12, 0)
    f.scoreText = scoreText

    f.zoomButtons = {}
    local zoomLevels = { 1, 2, 4 }
    local anchorRight = closeBtn
    for idx = #zoomLevels, 1, -1 do
        local z = zoomLevels[idx]
        local zBtn = CreateActionButton(f, 28, 22, z .. "x")
        zBtn:SetPoint("RIGHT", anchorRight, "LEFT", -4, 0)
        zBtn:SetScript("OnClick", function()
            local fight = GetActiveFight()
            local mid = (viewStart + viewEnd) * 0.5
            SetViewportRange(fight, mid - ((fight and fight.duration or 1) / (2 * z)), z)
            UI:Refresh()
        end)
        f.zoomButtons[z] = zBtn
        anchorRight = zBtn
    end

    local layerBtn = CreateActionButton(f, 96, 22, "View: Dual")
    layerBtn:SetPoint("RIGHT", anchorRight, "LEFT", -6, 0)
    layerBtn:SetScript("OnClick", function()
        if viewLayerMode == "DUAL" then
            viewLayerMode = "PRIMARY"
        elseif viewLayerMode == "PRIMARY" then
            viewLayerMode = "SECONDARY"
        else
            viewLayerMode = "DUAL"
        end
        UI:Refresh()
    end)
    f.layerBtn = layerBtn

    local settingsBtn = CreateActionButton(f, 62, 22, "Settings")
    settingsBtn:SetPoint("RIGHT", layerBtn, "LEFT", -6, 0)
    settingsBtn:SetScript("OnClick", function(self)
        ToggleSettingsPopover(self)
    end)
    f.settingsBtn = settingsBtn

    local reportBtn = CreateActionButton(f, 54, 22, "Report")
    reportBtn:SetPoint("RIGHT", settingsBtn, "LEFT", -6, 0)
    reportBtn:SetScript("OnClick", function(self)
        ToggleReportPopover(self)
    end)
    f.reportBtn = reportBtn

    local summaryText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    summaryText:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -36)
    f.summaryText = summaryText

    local delAllBtn = CreateActionButton(f, 64, 18, "Delete All")
    delAllBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -33)
    delAllBtn:SetScript("OnEnter", function(self)
        if self:IsEnabled() and delAllConfirmUntil <= GetTime() then
            self:SetBackdropBorderColor(0.94, 0.30, 0.32, 1.0)
            self.label:SetTextColor(1.0, 0.55, 0.55)
        end
    end)
    delAllBtn:SetScript("OnLeave", function(self)
        if delAllConfirmUntil <= GetTime() then
            self:SetBackdropBorderColor(0.28, 0.31, 0.36, 1.0)
            self.label:SetTextColor(0.86, 0.89, 0.93)
        end
    end)
    delAllBtn:SetScript("OnUpdate", function(self)
        if delAllConfirmUntil > 0 and GetTime() >= delAllConfirmUntil then
            delAllConfirmUntil = 0
            self:SetActiveState(false)
            self.label:SetText("Delete All")
        end
    end)
    delAllBtn:SetScript("OnClick", function(self)
        if delAllConfirmUntil > GetTime() then
            delAllConfirmUntil = 0
            self:SetActiveState(false)
            self.label:SetText("Delete All")
            if NS.Addon and NS.Addon.ClearHistory then
                NS.Addon:ClearHistory(true)
                selectedFightIndex = 1
                verdictFilter = "ALL"
                highlightedEventIndex = nil
                SetViewportRange(GetActiveFight(), 0, 1)
                UI:Refresh()
            end
        else
            delAllConfirmUntil = GetTime() + 3.0
            self:SetActiveState(true)
            self:SetBackdropColor(0.45, 0.10, 0.12, 1.0)
            self:SetBackdropBorderColor(0.96, 0.28, 0.30, 1.0)
            self.label:SetText("|cffff6666Confirm?|r")
        end
    end)
    f.delAllBtn = delAllBtn

    local delBtn = CreateActionButton(f, 44, 18, "Delete")
    delBtn:SetPoint("RIGHT", delAllBtn, "LEFT", -4, 0)
    delBtn:SetScript("OnEnter", function(self)
        if self:IsEnabled() then
            self:SetBackdropBorderColor(0.94, 0.30, 0.32, 1.0)
            self.label:SetTextColor(1.0, 0.55, 0.55)
        end
    end)
    delBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.28, 0.31, 0.36, 1.0)
        self.label:SetTextColor(0.86, 0.89, 0.93)
    end)
    delBtn:SetScript("OnClick", function()
        if NS.Addon and NS.Addon.DeleteFight then
            NS.Addon:DeleteFight(selectedFightIndex)
            verdictFilter = "ALL"
            highlightedEventIndex = nil
            SetViewportRange(GetActiveFight(), 0, 1)
            UI:Refresh()
        end
    end)
    f.delBtn = delBtn

    local pinBtn = CreateActionButton(f, 52, 18, "Pin")
    pinBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
    pinBtn:SetScript("OnClick", function()
        if NS.Addon and NS.Addon.TogglePinFight then
            NS.Addon:TogglePinFight(selectedFightIndex)
        end
    end)
    f.pinBtn = pinBtn

    local compareBtn = CreateActionButton(f, 82, 18, "Compare")
    compareBtn:SetPoint("RIGHT", pinBtn, "LEFT", -4, 0)
    compareBtn:SetScript("OnClick", function()
        UI:ToggleCompareWindow()
    end)
    compareBtn:Hide()
    f.compareBtn = compareBtn

    local fadeStatusText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fadeStatusText:SetPoint("RIGHT", compareBtn, "LEFT", -10, 0)
    fadeStatusText:SetJustifyH("RIGHT")
    fadeStatusText:Hide()
    f.fadeStatusText = fadeStatusText

    local band1 = CreateFrame("Frame", nil, f, BACKDROP_TEMPLATE)
    band1:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -54)
    band1:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -54)
    band1:SetHeight(BAND1_HEIGHT)
    band1:EnableMouse(true)
    ApplyPanelBackdrop(band1, 0.90, 0.22, 0.25, 0.30, 1.0)
    f.band1 = band1

    local viewport = CreateFrame("Frame", nil, band1, BACKDROP_TEMPLATE)
    viewport:SetFrameLevel(band1:GetFrameLevel() + 3)
    ApplyPanelBackdrop(viewport, 0.25, 0.40, 0.78, 1.0, 1.0)
    viewport:SetBackdropColor(0.32, 0.65, 0.98, 0.24)
    band1.viewport = viewport

    local isDraggingViewport = false
    local dragOffsetPx = 0

    band1:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then
            return
        end
        local fight = GetActiveFight()
        if not fight then
            return
        end
        local cursorX = select(1, GetCursorPosition()) / self:GetEffectiveScale()
        local left = self:GetLeft()
        local width = max(1, self:GetWidth())
        local clickRatio = max(0, min(1, (cursorX - left) / width))
        local dur = max(0.5, fight.duration or 0.5)
        local span = dur / max(1, zoomLevel)

        isDraggingViewport = true
        dragOffsetPx = span * 0.5
        SetViewportRange(fight, (clickRatio * dur) - dragOffsetPx, zoomLevel)
        RenderBand1(fight)
        RenderBand2(fight)
    end)

    band1:SetScript("OnMouseUp", function()
        isDraggingViewport = false
    end)

    band1:SetScript("OnUpdate", function(self)
        if not isDraggingViewport then
            return
        end
        local fight = GetActiveFight()
        if not fight then
            isDraggingViewport = false
            return
        end
        local cursorX = select(1, GetCursorPosition()) / self:GetEffectiveScale()
        local left = self:GetLeft()
        local width = max(1, self:GetWidth())
        local ratio = max(0, min(1, (cursorX - left) / width))
        local dur = max(0.5, fight.duration or 0.5)
        SetViewportRange(fight, (ratio * dur) - dragOffsetPx, zoomLevel)
        RenderBand1(fight)
        RenderBand2(fight)
    end)

    local band2 = CreateFrame("Frame", nil, f, BACKDROP_TEMPLATE)
    band2:SetPoint("TOPLEFT", band1, "BOTTOMLEFT", 0, -6)
    band2:SetPoint("TOPRIGHT", band1, "BOTTOMRIGHT", 0, -6)
    band2:SetHeight(BASE_BAND2_HEIGHT)
    ApplyPanelBackdrop(band2, 0.92, 0.22, 0.25, 0.30, 1.0)
    f.band2 = band2

    local y100 = band2:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    y100:SetPoint("TOPLEFT", band2, "TOPLEFT", 6, -6)
    y100:SetText("|cff88929e100%|r")

    local y50 = band2:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    y50:SetPoint("LEFT", band2, "LEFT", 6, 6)
    y50:SetText("|cff88929e50%|r")

    local y0 = band2:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    y0:SetPoint("BOTTOMLEFT", band2, "BOTTOMLEFT", 6, 18)
    y0:SetText("|cff88929e0%|r")

    local canvas = CreateFrame("Frame", nil, band2, BACKDROP_TEMPLATE)
    canvas:SetPoint("TOPLEFT", band2, "TOPLEFT", 42, -6)
    canvas:SetPoint("BOTTOMRIGHT", band2, "BOTTOMRIGHT", -10, 18)
    canvas:EnableMouseWheel(true)
    ApplyPanelBackdrop(canvas, 0.96, 0.18, 0.20, 0.24, 1.0)
    band2.canvas = canvas

    local thresholdLabel = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    thresholdLabel:Hide()
    band2.thresholdLabel = thresholdLabel

    local legendLabel = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    legendLabel:Hide()
    band2.legendLabel = legendLabel

    canvas:SetScript("OnMouseWheel", function(self, delta)
        CancelAutoFade()
        local fight = GetActiveFight()
        if not fight then
            return
        end
        local cursorX = select(1, GetCursorPosition()) / self:GetEffectiveScale()
        local ratio = max(0, min(1, (cursorX - self:GetLeft()) / max(1, self:GetWidth())))
        local focusTime = viewStart + ratio * (viewEnd - viewStart)
        local nextZoom = (delta > 0) and min(8, zoomLevel * 1.5) or max(1, zoomLevel / 1.5)
        local newSpan = max(0.5, fight.duration or 0.5) / nextZoom
        SetViewportRange(fight, focusTime - (ratio * newSpan), nextZoom)
        UI:Refresh()
    end)

    local band3 = CreateFrame("Frame", nil, f, BACKDROP_TEMPLATE)
    band3:SetPoint("TOPLEFT", band2, "BOTTOMLEFT", 0, -6)
    band3:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
    ApplyPanelBackdrop(band3, 0.92, 0.22, 0.25, 0.30, 1.0)
    f.band3 = band3

    -- Band 3 Verdict Filter Chip Bar
    local filterBar = CreateFrame("Frame", nil, band3)
    filterBar:SetHeight(24)
    filterBar:SetPoint("TOPLEFT", band3, "TOPLEFT", 2, -2)
    filterBar:SetPoint("TOPRIGHT", band3, "TOPRIGHT", -2, -2)

    local filterLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    filterLabel:SetPoint("LEFT", filterBar, "LEFT", 6, 0)
    filterLabel:SetText("|cff88929eFilter:|r")

    local FILTER_DEFS = {
        { key = "ALL",           label = "All",     width = 66, rgb = { 0.35, 0.72, 0.98 } },
        { key = "ISSUES",        label = "Issues",  width = 78, rgb = { 0.96, 0.56, 0.22 } },
        { key = "EARLY_STARVED", label = "Early",   width = 72, rgb = { 0.94, 0.25, 0.28 } },
        { key = "LATE_HOARD",    label = "Late",    width = 68, rgb = { 0.96, 0.68, 0.14 } },
        { key = "OVERCAP_WASTE", label = "Overcap", width = 82, rgb = { 0.82, 0.35, 0.92 } },
        { key = "IDLE_GAP",      label = "Idle",    width = 68, rgb = { 0.95, 0.52, 0.22 } },
    }

    f.filterChips = {}
    local chipAnchor = filterLabel
    for idx = 1, #FILTER_DEFS do
        local def = FILTER_DEFS[idx]
        local chip = CreateActionButton(filterBar, def.width, 18, def.label)
        chip:SetPoint("LEFT", chipAnchor, "RIGHT", (idx == 1) and 8 or 5, 0)
        chip.baseLabel = def.label
        chip.activeRGB = def.rgb
        chip:SetScript("OnClick", function()
            verdictFilter = def.key
            highlightedEventIndex = nil
            if band3.scrollFrame then
                band3.scrollFrame:SetVerticalScroll(0)
            end
            UI:Refresh()
        end)
        f.filterChips[def.key] = chip
        chipAnchor = chip
    end

    local filterHint = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    filterHint:SetPoint("RIGHT", filterBar, "RIGHT", -8, 0)
    filterHint:SetText("|cff6e7682Filters timeline pins & step log|r")

    local headerBg = band3:CreateTexture(nil, "ARTWORK")
    headerBg:SetHeight(20)
    headerBg:SetPoint("TOPLEFT", band3, "TOPLEFT", 1, -27)
    headerBg:SetPoint("TOPRIGHT", band3, "TOPRIGHT", -1, -27)
    headerBg:SetColorTexture(0.13, 0.15, 0.19, 1.0)

    local hTime = band3:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hTime:SetPoint("LEFT", headerBg, "LEFT", 6, 0)
    hTime:SetText("Time")

    local hAction = band3:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hAction:SetPoint("LEFT", headerBg, "LEFT", 60, 0)
    hAction:SetText("Action / Macro")

    local hPower = band3:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hPower:SetPoint("LEFT", headerBg, "LEFT", 260, 0)
    hPower:SetText("Primary + Secondary")

    local hGap = band3:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hGap:SetPoint("LEFT", headerBg, "LEFT", 378, 0)
    hGap:SetText("Gap")

    local hNote = band3:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hNote:SetPoint("LEFT", headerBg, "LEFT", 430, 0)
    hNote:SetText("Verdict & Diagnostic Note")

    local clipFrame = CreateFrame("Frame", nil, band3)
    clipFrame:SetPoint("TOPLEFT", band3, "TOPLEFT", 2, -48)
    clipFrame:SetPoint("BOTTOMRIGHT", band3, "BOTTOMRIGHT", -2, 2)
    band3.clipFrame = clipFrame

    local scrollFrame = CreateFrame("ScrollFrame", "CombatTelemetryEfficiencyLogScroll", clipFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", clipFrame, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", clipFrame, "BOTTOMRIGHT", -22, 0)
    band3.scrollFrame = scrollFrame

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(DEFAULT_WINDOW_WIDTH - 52, DEFAULT_VISIBLE_LOG_ROWS * LOG_ROW_HEIGHT)
    scrollFrame:SetScrollChild(content)
    band3.content = content

    scrollFrame:SetScript("OnVerticalScroll", function()
        local activeFight = GetActiveFight()
        if activeFight then
            RenderBand3(activeFight)
        end
    end)

    -- Bottom-right resize grip handle (drag to resize main CTE window)
    local resizeGrip = CreateFrame("Button", nil, f)
    resizeGrip:SetSize(18, 18)
    resizeGrip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -3, 3)
    resizeGrip:SetFrameLevel(f:GetFrameLevel() + 10)
    resizeGrip:EnableMouse(true)

    local gripTex = resizeGrip:CreateTexture(nil, "OVERLAY")
    gripTex:SetAllPoints()
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")

    local gripHl = resizeGrip:CreateTexture(nil, "HIGHLIGHT")
    gripHl:SetAllPoints()
    gripHl:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")

    resizeGrip:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            CancelAutoFade()
            gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
            f:StartSizing("BOTTOMRIGHT")
        end
    end)
    resizeGrip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
        SaveMainWindowSize(f)
        SaveMainWindowPosition(f)
        ApplyMainWindowResponsiveLayout(f)
        UI:Refresh()
    end)
    resizeGrip:SetScript("OnEnter", function()
        GameTooltip:SetOwner(resizeGrip, "ANCHOR_TOPLEFT")
        GameTooltip:SetText("Drag to Resize Window", 1.0, 0.82, 0.25)
        GameTooltip:AddLine("Double-click to reset default size", 0.75, 0.80, 0.86)
        GameTooltip:Show()
    end)
    resizeGrip:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    resizeGrip:SetScript("OnDoubleClick", function()
        if NS.Addon and NS.Addon.db then
            NS.Addon.db.windowSize = nil
        end
        RestoreMainWindowSize(f)
        UI:Refresh()
    end)
    f.resizeGrip = resizeGrip

    ApplyMainWindowResponsiveLayout(f)
    mainFrame = f
    return f
end

function UI:Show()
    local f = EnsureMainFrame()
    RestoreMainWindowSize(f)
    RestoreMainWindowPosition(f)
    CancelAutoFade()
    f:SetAlpha(1.0)
    selectedFightIndex = 1
    verdictFilter = "ALL"
    highlightedEventIndex = nil
    SetViewportRange(GetActiveFight(), 0, 1)
    f:Show()
    self:Refresh()
end

function UI:Hide()
    if mainFrame then
        mainFrame:Hide()
    end
end

function UI:Toggle()
    local f = EnsureMainFrame()
    if f:IsShown() then
        f:Hide()
    else
        self:Show()
    end
end

function UI:OpenSettings()
    local f = EnsureMainFrame()
    if not f:IsShown() then
        self:Show()
    end
    if f.settingsBtn then
        if not settingsPopover or not settingsPopover:IsShown() then
            ToggleSettingsPopover(f.settingsBtn)
        end
    end
end

function UI:OnFightRecorded(fight)
    local db = NS.Addon and NS.Addon.db
    local autoShow = db and (db.autoShowAfterCombat == true)

    if autoShow then
        local wasManuallyOpen = (mainFrame and mainFrame:IsShown() and not autoFadeArmed)
        local f = EnsureMainFrame()
        if pillFrame and pillFrame:IsShown() then
            pillFrame:Hide()
        end
        selectedFightIndex = 1
        verdictFilter = "ALL"
        highlightedEventIndex = nil
        SetViewportRange(fight, 0, 1)
        f:SetAlpha(1.0)
        f:Show()
        self:Refresh()

        if not wasManuallyOpen then
            ArmAutoFade(db and db.autoFadeSeconds or DEFAULT_AUTO_FADE_SECONDS)
        end
        return
    end

    if (not db) or (db.showPostCombatBanner ~= false) then
        self:ShowPostCombatPill(fight)
    end
    if mainFrame and mainFrame:IsShown() then
        selectedFightIndex = 1
        verdictFilter = "ALL"
        highlightedEventIndex = nil
        SetViewportRange(fight, 0, 1)
        self:Refresh()
    end
end

------------------------------------------------------------------------
-- Copyable Raw Telemetry Dump Popup (/cte dump)
------------------------------------------------------------------------

local function EnsureDumpFrame()
    if dumpFrame then
        return dumpFrame
    end

    local f = CreateFrame("Frame", "CombatTelemetryEfficiencyDumpFrame", UIParent, BACKDROP_TEMPLATE)
    f:SetSize(660, 430)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    ApplyPanelBackdrop(f, 0.97, 0.32, 0.64, 0.92, 1.0)
    f:Hide()

    tinsert(UISpecialFrames, "CombatTelemetryEfficiencyDumpFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
    title:SetText("|cff5cc8ffCTE Raw Telemetry Dump|r")

    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("LEFT", title, "RIGHT", 10, 0)
    subtitle:SetTextColor(0.72, 0.78, 0.85)
    f.subtitle = subtitle

    f.title = title

    local closeBtn = CreateActionButton(f, 22, 22, "X")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -9)
    closeBtn:SetScript("OnClick", function()
        f:Hide()
    end)

    local selectAllBtn = CreateActionButton(f, 82, 22, "Select All")
    selectAllBtn:SetPoint("RIGHT", closeBtn, "LEFT", -6, 0)
    selectAllBtn:SetScript("OnClick", function()
        f.editBox:SetFocus()
        f.editBox:HighlightText()
    end)

    local fmtBtn = CreateActionButton(f, 64, 22, "JSON")
    fmtBtn:SetPoint("RIGHT", selectAllBtn, "LEFT", -6, 0)
    fmtBtn:Hide()
    fmtBtn:SetScript("OnClick", function(self)
        if not f.hasJsonPair then
            return
        end
        f.showJson = not f.showJson
        if f.showJson and f.jsonText then
            self.label:SetText("Text")
            f.editBox:SetText(f.jsonText)
        else
            self.label:SetText("JSON")
            f.editBox:SetText(f.plainText or "")
        end
        f.scrollFrame:SetVerticalScroll(0)
        f.editBox:SetFocus()
        f.editBox:HighlightText()
    end)
    f.fmtBtn = fmtBtn

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -34)
    hint:SetTextColor(0.58, 0.64, 0.72)
    hint:SetText("Press Ctrl+C to copy selected telemetry (or click Select All). Press Esc to close.")

    local boxContainer = CreateFrame("Frame", nil, f, BACKDROP_TEMPLATE)
    boxContainer:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -52)
    boxContainer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)
    ApplyPanelBackdrop(boxContainer, 0.96, 0.20, 0.23, 0.28, 1.0)

    local scrollFrame = CreateFrame("ScrollFrame", "CombatTelemetryEfficiencyDumpScroll", boxContainer, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", boxContainer, "TOPLEFT", 6, -6)
    scrollFrame:SetPoint("BOTTOMRIGHT", boxContainer, "BOTTOMRIGHT", -26, 6)
    f.scrollFrame = scrollFrame

    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(GameFontHighlightSmall)
    editBox:SetWidth(600)
    editBox:SetTextInsets(4, 4, 4, 4)
    editBox:SetScript("OnEscapePressed", function()
        f:Hide()
    end)
    editBox:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        local lineCount = 1
        for _ in string.gmatch(text, "\n") do
            lineCount = lineCount + 1
        end
        self:SetHeight(max(340, lineCount * 15 + 24))
    end)
    scrollFrame:SetScrollChild(editBox)
    f.editBox = editBox

    boxContainer:EnableMouse(true)
    boxContainer:SetScript("OnMouseDown", function()
        editBox:SetFocus()
    end)

    dumpFrame = f
    return f
end

function UI:ShowDumpWindow(text, subtitleText, titleText, plainText, jsonText, initialJson)
    local f = EnsureDumpFrame()
    f.title:SetText("|cff5cc8ff" .. (titleText or "CTE Telemetry Dump") .. "|r")
    f.subtitle:SetText(subtitleText or "")
    f.plainText = plainText or text or ""
    f.jsonText = jsonText
    f.hasJsonPair = (jsonText ~= nil)
    f.showJson = f.hasJsonPair and (initialJson == true) or false

    if f.fmtBtn then
        if f.hasJsonPair then
            f.fmtBtn:Show()
            f.fmtBtn.label:SetText(f.showJson and "Text" or "JSON")
        else
            f.fmtBtn:Hide()
        end
    end

    local displayText = f.showJson and (f.jsonText or f.plainText) or (text or f.plainText)
    f.editBox:SetText(displayText)
    f.scrollFrame:SetVerticalScroll(0)
    f:Show()
    f.editBox:SetFocus()
    f.editBox:HighlightText()
end


------------------------------------------------------------------------
-- Side-by-Side Multi-Fight Comparison Summary Window (v0.3.1 — Gold/Amber & Emerald Theme)
------------------------------------------------------------------------

local COMPARE_ROW_HEIGHT = 24
local COMPARE_VISIBLE_ROWS = 12

local function EnsureCompareFrame()
    if compareFrame then
        return compareFrame
    end

    local f = CreateFrame("Frame", "CombatTelemetryEfficiencyCompareFrame", UIParent, BACKDROP_TEMPLATE)
    f:SetSize(820, 430)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    -- Warm charcoal-espresso backdrop with rich Gold/Amber border (distinct from main window's blue)
    ApplyPanelBackdrop(f, 0.97, 0.88, 0.62, 0.20, 1.0)
    f:SetBackdropColor(0.11, 0.09, 0.08, 0.97)
    f:Hide()

    tinsert(UISpecialFrames, "CombatTelemetryEfficiencyCompareFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
    title:SetText("|cffffc94dCTE Multi-Fight Comparison Summary|r")

    local modeBadge = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    modeBadge:SetPoint("LEFT", title, "RIGHT", 10, 0)
    f.modeBadge = modeBadge

    local closeBtn = CreateActionButton(f, 22, 22, "X")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -9)
    closeBtn:SetScript("OnClick", function()
        f:Hide()
    end)

    local exportBtn = CreateActionButton(f, 92, 22, "Copy Table")
    exportBtn:SetPoint("RIGHT", closeBtn, "LEFT", -6, 0)
    exportBtn:SetScript("OnClick", function()
        if NS.Addon and NS.Addon.BuildMultiFightSummaryText then
            local txt, sub = NS.Addon:BuildMultiFightSummaryText()
            if txt then
                UI:ShowDumpWindow(txt, sub, "CTE Multi-Fight Comparison Export", nil, nil)
            end
        end
    end)

    -- 4 Aggregate KPI Summary Cards with distinct accent borders (Gold, Emerald, Violet, Coral)
    local cardSpecs = {
        { key = "avgScore",  label = "Avg / Best Score",            border = { 0.88, 0.66, 0.22 }, titleHex = "|cffffcf5c" },
        { key = "avgUptime", label = "Avg GCD Uptime & CPM",        border = { 0.22, 0.78, 0.56 }, titleHex = "|cff45e0a2" },
        { key = "latestVs",  label = "Latest (#1) vs Avg",          border = { 0.76, 0.44, 0.92 }, titleHex = "|cffd28aff" },
        { key = "mistakes",  label = "Total Mistakes Across Fights",border = { 0.92, 0.44, 0.28 }, titleHex = "|cffff8c66" },
    }
    f.cards = {}
    local cardGap = 8
    local totalInnerW = 820 - 24
    local cardW = (totalInnerW - (cardGap * 3)) / 4
    for idx = 1, 4 do
        local spec = cardSpecs[idx]
        local card = CreateFrame("Frame", nil, f, BACKDROP_TEMPLATE)
        card:SetSize(cardW, 54)
        if idx == 1 then
            card:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -38)
        else
            card:SetPoint("LEFT", f.cards[idx - 1], "RIGHT", cardGap, 0)
        end
        ApplyPanelBackdrop(card, 0.95, spec.border[1], spec.border[2], spec.border[3], 0.90)
        card:SetBackdropColor(0.14, 0.12, 0.10, 0.95)

        local lbl = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -7)
        lbl:SetText(spec.titleHex .. spec.label .. "|r")

        local val = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        val:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -22)
        val:SetPoint("RIGHT", card, "RIGHT", -8, 0)
        val:SetJustifyH("LEFT")

        local sub = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        sub:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 8, 6)
        sub:SetPoint("RIGHT", card, "RIGHT", -8, 0)
        sub:SetJustifyH("LEFT")

        card.val = val
        card.sub = sub
        f.cards[spec.key] = card
    end

    -- Side-by-Side Comparison Table Container
    local tableBox = CreateFrame("Frame", nil, f, BACKDROP_TEMPLATE)
    tableBox:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -100)
    tableBox:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)
    ApplyPanelBackdrop(tableBox, 0.95, 0.42, 0.33, 0.20, 1.0)
    tableBox:SetBackdropColor(0.10, 0.09, 0.08, 0.95)

    local hdrBg = tableBox:CreateTexture(nil, "ARTWORK")
    hdrBg:SetHeight(22)
    hdrBg:SetPoint("TOPLEFT", tableBox, "TOPLEFT", 1, -1)
    hdrBg:SetPoint("TOPRIGHT", tableBox, "TOPRIGHT", -1, -1)
    hdrBg:SetColorTexture(0.20, 0.16, 0.11, 1.0)

    local cols = {
        { text = "#",          x = 8,   w = 34,  justify = "LEFT" },
        { text = "Encounter",  x = 44,  w = 188, justify = "LEFT" },
        { text = "Dur",        x = 236, w = 48,  justify = "RIGHT" },
        { text = "Score",      x = 290, w = 52,  justify = "RIGHT" },
        { text = "vs Avg",     x = 346, w = 56,  justify = "RIGHT" },
        { text = "Uptime",     x = 408, w = 54,  justify = "RIGHT" },
        { text = "CPM",        x = 466, w = 46,  justify = "RIGHT" },
        { text = "Eff",        x = 518, w = 36,  justify = "RIGHT" },
        { text = "Early",      x = 558, w = 42,  justify = "RIGHT" },
        { text = "Late",       x = 604, w = 40,  justify = "RIGHT" },
        { text = "Over",       x = 648, w = 40,  justify = "RIGHT" },
        { text = "Idle",       x = 692, w = 40,  justify = "RIGHT" },
        { text = "Tag",        x = 738, w = 52,  justify = "LEFT" },
    }

    for i = 1, #cols do
        local c = cols[i]
        local h = tableBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("LEFT", hdrBg, "LEFT", c.x, 0)
        h:SetWidth(c.w)
        h:SetJustifyH(c.justify)
        h:SetText("|cffe6c88a" .. c.text .. "|r")
    end

    local scrollFrame = CreateFrame("ScrollFrame", "CombatTelemetryEfficiencyCompareScroll", tableBox, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", tableBox, "TOPLEFT", 2, -25)
    scrollFrame:SetPoint("BOTTOMRIGHT", tableBox, "BOTTOMRIGHT", -24, 4)
    f.scrollFrame = scrollFrame

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(770, COMPARE_VISIBLE_ROWS * COMPARE_ROW_HEIGHT)
    scrollFrame:SetScrollChild(content)
    f.content = content
    f.rowPool = {}
    f.cols = cols

    local emptyHint = tableBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyHint:SetPoint("CENTER", tableBox, "CENTER", 0, -8)
    emptyHint:Hide()
    f.emptyHint = emptyHint

    compareFrame = f
    return f
end

function UI:RefreshCompareWindow()
    local f = EnsureCompareFrame()
    local fights = (NS.Addon and NS.Addon.db and NS.Addon.db.fights) or {}
    local isMulti = NS.Addon and NS.Addon.IsMultiFightMode and NS.Addon:IsMultiFightMode()
    local cap = (NS.Addon and NS.Addon.db and NS.Addon.db.maxFights) or 10

    if isMulti then
        f.modeBadge:SetText(format("|cff45e0a2Multi-Fight Mode ON|r |cffb8a890(%d/%d stored — click any row to inspect)|r", #fights, cap))
    else
        f.modeBadge:SetText("|cffffb347Single-Fight Mode|r |cffb8a890(enable Multi-Fight in Settings or /cte mode multi)|r")
    end

    local cmp = (NS.Analyzer and NS.Analyzer.BuildMultiFightComparison)
        and NS.Analyzer:BuildMultiFightComparison(fights)
        or { fightCount = 0, rows = {} }

    for i = 1, #f.rowPool do
        f.rowPool[i]:Hide()
    end

    if cmp.fightCount == 0 then
        f.cards.avgScore.val:SetText("|cff9e9282--|r")
        f.cards.avgScore.sub:SetText("|cff7d7265No stored fights|r")
        f.cards.avgUptime.val:SetText("|cff9e9282--|r")
        f.cards.avgUptime.sub:SetText("|cff7d7265Enter combat to record|r")
        f.cards.latestVs.val:SetText("|cff9e9282--|r")
        f.cards.latestVs.sub:SetText("|cff7d7265--|r")
        f.cards.mistakes.val:SetText("|cff9e92820|r")
        f.cards.mistakes.sub:SetText("|cff7d7265Early 0 | Late 0 | Idle 0|r")
        f.emptyHint:SetText("No recorded fights yet. Enable Multi-Fight mode and complete 2+ fights to compare.")
        f.emptyHint:Show()
        return
    end

    f.emptyHint:Hide()

    local avgHex = (cmp.avgScore >= 88 and "|cff45e0a2") or (cmp.avgScore >= 70 and "|cffffc94d") or "|cffff5e5e"
    f.cards.avgScore.val:SetText(format("%s%.1f%%|r  |cffb8a890(Best %d%%)|r", avgHex, cmp.avgScore, cmp.bestScore))
    f.cards.avgScore.sub:SetText(format("|cff9e9282Lowest: %d%% across %d fight(s)|r", cmp.worstScore, cmp.fightCount))

    f.cards.avgUptime.val:SetText(format("|cff45e0a2%.0f%%|r  |cfff2e6d0(%.1f CPM)|r", cmp.avgUptimePct, cmp.avgCpm))
    f.cards.avgUptime.sub:SetText(format("|cff9e9282Avg Duration: %.1fs|r", cmp.avgDuration))

    local dScore = cmp.scoreDeltaLatestVsAvg or 0
    local dHex = (dScore >= 0.5 and "|cff45e0a2") or (dScore <= -0.5 and "|cffff5e5e") or "|cfff2e6d0"
    local dUp = cmp.uptimeDeltaLatestVsAvg or 0
    local uHex = (dUp >= 0.5 and "|cff45e0a2") or (dUp <= -0.5 and "|cffff5e5e") or "|cff9e9282"
    f.cards.latestVs.val:SetText(format("%s%+.1f%%|r  |cffb8a890Score|r", dHex, dScore))
    f.cards.latestVs.sub:SetText(format("%s%+.0f%% Uptime|r |cff9e9282vs session avg|r", uHex, dUp))

    local totalMistakes = cmp.totalEarly + cmp.totalLate + cmp.totalOvercap + cmp.totalIdle
    f.cards.mistakes.val:SetText(format("|cffffb347%d|r  |cffb8a890(%.1fs dead)|r", totalMistakes, cmp.totalIdleSeconds))
    f.cards.mistakes.sub:SetText(format(
        "|cffff5e5eE:%d|r |cffffc94dL:%d|r |cffd28affO:%d|r |cffff8c66I:%d|r",
        cmp.totalEarly, cmp.totalLate, cmp.totalOvercap, cmp.totalIdle
    ))

    f.content:SetHeight(max(COMPARE_VISIBLE_ROWS * COMPARE_ROW_HEIGHT, #cmp.rows * COMPARE_ROW_HEIGHT))

    for i = 1, #cmp.rows do
        local r = cmp.rows[i]
        local row = f.rowPool[i]
        if not row then
            row = CreateFrame("Button", nil, f.content)
            row:SetHeight(COMPARE_ROW_HEIGHT)
            row:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, -((i - 1) * COMPARE_ROW_HEIGHT))
            row:SetPoint("TOPRIGHT", f.content, "TOPRIGHT", 0, -((i - 1) * COMPARE_ROW_HEIGHT))

            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            row.bg = bg

            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(0.88, 0.64, 0.20, 0.25)

            row.cells = {}
            for cIdx = 1, #f.cols do
                local col = f.cols[cIdx]
                local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                fs:SetPoint("LEFT", row, "LEFT", col.x - 2, 0)
                fs:SetWidth(col.w)
                fs:SetJustifyH(col.justify)
                row.cells[cIdx] = fs
            end
            f.rowPool[i] = row
        end

        if r.index == selectedFightIndex then
            row.bg:SetColorTexture(0.42, 0.30, 0.12, 0.55)
        elseif i % 2 == 0 then
            row.bg:SetColorTexture(0.16, 0.13, 0.10, 0.65)
        else
            row.bg:SetColorTexture(0.12, 0.10, 0.08, 0.45)
        end

        local sHex = (r.score >= 88 and "|cff45e0a2") or (r.score >= 70 and "|cffffc94d") or "|cffff5e5e"
        local sd = r.scoreDelta or 0
        local sdHex = (sd >= 0.5 and "|cff45e0a2") or (sd <= -0.5 and "|cffff5e5e") or "|cff9e9282"
        local pinPrefix = r.pinned and "|cffffd100[P]|r " or ""
        local tagStr = r.isBest and "|cff45e0a2BEST|r"
            or (r.isWorst and "|cffff5e5eLOW|r" or (r.index == 1 and "|cffffc94dNEW|r" or ""))

        row.cells[1]:SetText(format("|cffb8a890#%d|r", r.index))
        row.cells[2]:SetText(pinPrefix .. (r.targetName or "Encounter"))
        row.cells[3]:SetText(FormatShortClock(r.duration))
        row.cells[4]:SetText(format("%s%d%%|r", sHex, r.score))
        row.cells[5]:SetText(format("%s%+.1f|r", sdHex, sd))
        row.cells[6]:SetText(format("|cff45e0a2%d%%|r", r.uptimePct))
        row.cells[7]:SetText(format("%.1f", r.cpm))
        row.cells[8]:SetText(format("|cff45e0a2%d|r", r.efficient))
        row.cells[9]:SetText(r.early > 0 and format("|cffff5e5e%d|r", r.early) or "|cff7d72650|r")
        row.cells[10]:SetText(r.late > 0 and format("|cffffc94d%d|r", r.late) or "|cff7d72650|r")
        row.cells[11]:SetText(r.overcap > 0 and format("|cffd28aff%d|r", r.overcap) or "|cff7d72650|r")
        row.cells[12]:SetText(r.idle > 0 and format("|cffff8c66%d|r", r.idle) or "|cff7d72650|r")
        row.cells[13]:SetText(tagStr)

        local targetIdx = r.index
        row:SetScript("OnClick", function()
            selectedFightIndex = targetIdx
            verdictFilter = "ALL"
            highlightedEventIndex = nil
            local main = EnsureMainFrame()
            if main.band3 and main.band3.scrollFrame then
                main.band3.scrollFrame:SetVerticalScroll(0)
            end
            SetViewportRange(GetActiveFight(), 0, 1)
            main:Show()
            UI:Refresh()
        end)

        row:Show()
    end
end

function UI:OpenCompareWindow()
    local f = EnsureCompareFrame()
    self:RefreshCompareWindow()
    f:Show()
end

function UI:ToggleCompareWindow()
    local f = EnsureCompareFrame()
    if f:IsShown() then
        f:Hide()
    else
        self:OpenCompareWindow()
    end
end
