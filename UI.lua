local _, NS = ...

local CreateFrame = CreateFrame
local GetTime = GetTime
local GameTooltip = GameTooltip
local UIParent = UIParent
local tinsert = table.insert
local wipe = wipe
local max = math.max
local min = math.min
local floor = math.floor
local abs = math.abs
local format = string.format

local UI = {}
NS.UI = UI

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

local WINDOW_WIDTH = 812
local WINDOW_HEIGHT = 496
local BAND1_HEIGHT = 32
local BAND2_HEIGHT = 198
local LOG_ROW_HEIGHT = 22
local VISIBLE_LOG_ROWS = 7
local CURVE_SLICES = 150

local SECONDARY = {
    COMBO_POINTS = 4,
    MANA_BACKUP = 100,
    PET_FOCUS = 102,
    TOTEM_SLOTS = 104,
}

local OVERCAP_FALLBACK_ICON = "Interface\Icons\Spell_Nature_WispSplode"
local DEFAULT_SPELL_ICON = "Interface\Icons\INV_Misc_QuestionMark"

local VERDICT_COLORS = {
    EFFICIENT = { 0.18, 0.82, 0.42, 1.0 },
    EARLY_STARVED = { 0.94, 0.25, 0.28, 1.0 },
    LATE_HOARD = { 0.96, 0.68, 0.14, 1.0 },
    OVERCAP_WASTE = { 0.82, 0.35, 0.92, 1.0 },
}

local VERDICT_HEX = {
    EFFICIENT = "|cff2ed16b",
    EARLY_STARVED = "|cfff04047",
    LATE_HOARD = "|cfff5ad24",
    OVERCAP_WASTE = "|cffd159eb",
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

local pillFrame = nil
local mainFrame = nil
local fightMenuFrame = nil
local settingsPopover = nil
local isSyncingSettings = false
local selectedFightIndex = 1
local viewLayerMode = "DUAL"
local zoomLevel = 1
local viewStart = 0
local viewEnd = 1
local highlightedEventIndex = nil

local scrubTickPool = {}
local curveFillPool = {}
local curveLinePool = {}
local secCurvePool = {}
local totemBarPool = {}
local formRibbonPool = {}
local dashLinePool = {}
local axisLabelPool = {}
local pinPool = {}
local logRowPool = {}
local filteredEvents = {}

------------------------------------------------------------------------
-- Formatting, Backdrop & Widget Primitives
------------------------------------------------------------------------

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
        bgFile = "Interface\Buttons\WHITE8x8",
        edgeFile = "Interface\Buttons\WHITE8x8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    frame:SetBackdropColor(0.07, 0.08, 0.10, bgAlpha or 0.94)
    frame:SetBackdropBorderColor(borderR or 0.24, borderG or 0.27, borderB or 0.32, borderA or 0.95)
end

local function CreateActionButton(parent, width, height, text)
    local btn = CreateFrame("Button", nil, parent, BACKDROP_TEMPLATE)
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

------------------------------------------------------------------------
-- Settings Popover
------------------------------------------------------------------------

local function SyncSettingsPopover()
    if not settingsPopover or not NS.Addon or not NS.Addon.db then
        return
    end
    local db = NS.Addon.db
    isSyncingSettings = true
    settingsPopover.multSlider:SetDisplayValue(db.thresholds.hoardMultiplier or 2.0)
    settingsPopover.holdSlider:SetDisplayValue(db.thresholds.hoardHoldSeconds or 1.0)
    settingsPopover.bannerCheck:SetCheckedState(db.showPostCombatBanner ~= false)
    settingsPopover.bossCheck:SetCheckedState(db.bossOnly == true)
    isSyncingSettings = false
end

local function ToggleSettingsPopover(anchor)
    if not settingsPopover then
        local pop = CreateFrame("Frame", nil, mainFrame, BACKDROP_TEMPLATE)
        pop:SetSize(264, 238)
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

        local divider = pop:CreateTexture(nil, "ARTWORK")
        divider:SetHeight(1)
        divider:SetPoint("TOPLEFT", holdSlider, "BOTTOMLEFT", 0, -6)
        divider:SetWidth(238)
        divider:SetColorTexture(0.24, 0.27, 0.33, 1.0)

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
        bannerCheck:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -8)
        pop.bannerCheck = bannerCheck

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
        bossCheck:SetPoint("TOPLEFT", bannerCheck, "BOTTOMLEFT", 0, -6)
        pop.bossCheck = bossCheck

        local resetBtn = CreateActionButton(pop, 114, 22, "Reset Defaults")
        resetBtn:SetPoint("BOTTOMRIGHT", pop, "BOTTOMRIGHT", -12, 10)
        resetBtn:SetScript("OnClick", function()
            if NS.Addon and NS.Addon.db then
                local defs = NS.Addon.DEFAULT_DB
                NS.Addon.db.thresholds.hoardMultiplier = defs and defs.thresholds.hoardMultiplier or 2.0
                NS.Addon.db.thresholds.hoardHoldSeconds = defs and defs.thresholds.hoardHoldSeconds or 1.0
                NS.Addon.db.showPostCombatBanner = true
                NS.Addon.db.bossOnly = false
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

    SyncSettingsPopover()
    settingsPopover:ClearAllPoints()
    settingsPopover:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -3)
    settingsPopover:Show()
    anchor:SetActiveState(true)
end

------------------------------------------------------------------------
-- Data Filtering, Stance & Viewport Math
------------------------------------------------------------------------

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

local function RebuildFilteredEvents(fight)
    wipe(filteredEvents)
    if not fight or not fight.events then
        return
    end
    for i = 1, #fight.events do
        tinsert(filteredEvents, fight.events[i])
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

------------------------------------------------------------------------
-- Post-Combat Notification Pill
------------------------------------------------------------------------

local function EnsureNotificationPill()
    if pillFrame then
        return pillFrame
    end

    local f = CreateFrame("Button", "CombatTelemetryEfficiencyPill", UIParent, BACKDROP_TEMPLATE)
    f:SetSize(360, 32)
    f:SetPoint("TOP", UIParent, "TOP", 0, -96)
    f:SetFrameStrata("HIGH")
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
    local closeTxt = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    closeTxt:SetPoint("CENTER")
    closeTxt:SetText("|cff999999x|r")
    closeBtn:SetScript("OnClick", function()
        f:Hide()
    end)

    f.autoHideAt = 0
    f:SetScript("OnUpdate", function(self)
        if self.autoHideAt > 0 and not self:IsMouseOver() and GetTime() >= self.autoHideAt then
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

------------------------------------------------------------------------
-- Band 1: Overview Scrub & Zoom Bar
------------------------------------------------------------------------

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

------------------------------------------------------------------------
-- Band 2: Dual-Resource Sparkline, Form Ribbon, Totem Tracks & Pins
------------------------------------------------------------------------

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

    local sampleMax = 100
    if viewLayerMode ~= "SECONDARY" then
        local sliceW = plotW / CURVE_SLICES
        for i = 1, CURVE_SLICES do
            local sampleT = viewStart + (((i - 0.5) / CURVE_SLICES) * span)
            local slicePowerType = primaryPowerType
            local sliceRGB = barRGB

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
            local ratio = max(0, min(1, pVal / max(1, pMax)))
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
    if isMultiFormDruid then
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
    if viewLayerMode ~= "SECONDARY" and hoardThresh > 0 and sampleMax > 0 and hoardThresh < sampleMax then
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
        local pRatio = max(0, min(1, (baseEv.powerBefore or 0) / max(1, baseEv.powerMax or sampleMax)))
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

            local texPath = ev.spellIcon or (ev.isSyntheticOvercap and OVERCAP_FALLBACK_ICON) or DEFAULT_SPELL_ICON
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

------------------------------------------------------------------------
-- Band 3: Synchronized Step Log
------------------------------------------------------------------------

local function RenderBand3(fight)
    local band3 = mainFrame.band3
    local scrollFrame = band3.scrollFrame
    local totalRows = #filteredEvents

    band3.content:SetHeight(max(VISIBLE_LOG_ROWS * LOG_ROW_HEIGHT, totalRows * LOG_ROW_HEIGHT))

    local offset = scrollFrame:GetVerticalScroll() or 0
    local firstIndex = floor(offset / LOG_ROW_HEIGHT) + 1

    for r = 1, VISIBLE_LOG_ROWS + 1 do
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
            row.icon:SetTexture(
                ev.spellIcon or (ev.isSyntheticOvercap and OVERCAP_FALLBACK_ICON) or DEFAULT_SPELL_ICON
            )

            local prefix = ""
            if ev.druidForm and DRUID_FORM_SHORT[ev.druidForm] then
                prefix = DRUID_FORM_SHORT[ev.druidForm] .. " "
            end

            local badges = ""
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
            if ev.isSyntheticOvercap then
                resStr = format("%d/%d", ev.powerBefore or 0, ev.powerMax or 100)
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

------------------------------------------------------------------------
-- Full Window Refresh & Fight Dropdown
------------------------------------------------------------------------

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
        RenderBand1(nil)
        RenderBand2(nil)
        RenderBand3(nil)
        return
    end

    local fights = NS.Addon.db.fights
    local score = fight.score or 100
    local scoreHex = (score >= 88 and "|cff2ed16b") or (score >= 70 and "|cfff5ad24") or "|cfff04047"

    mainFrame.fightDropBtn.label:SetText(format(
        "#%d %s (%s)  v",
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

        mainFrame.summaryText:SetText(format(
            "|cff2ed16b%d Efficient|r  |  |cfff04047%d Early|r  |  |cfff5ad24%d Late|r  |  |cffd159eb%d Overcap|r%s",
            sum.efficientCount or 0,
            sum.earlyStarvedCount or 0,
            sum.lateHoardCount or 0,
            sum.overcapWasteCount or 0,
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

    for z, btn in pairs(mainFrame.zoomButtons) do
        btn:SetActiveState(zoomLevel == z)
    end

    RenderBand1(fight)
    RenderBand2(fight)
    RenderBand3(fight)
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
                highlightedEventIndex = nil
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
            "#%d %s (%s) — %d%%",
            i,
            f.targetName or "Encounter",
            FormatShortClock(f.duration),
            f.score or 100
        ))
        item:Show()
    end

    fightMenuFrame:Show()
end

------------------------------------------------------------------------
-- Main Review Frame Construction
------------------------------------------------------------------------

local function EnsureMainFrame()
    if mainFrame then
        return mainFrame
    end

    local f = CreateFrame("Frame", "CombatTelemetryEfficiencyMainFrame", UIParent, BACKDROP_TEMPLATE)
    f:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetScript("OnHide", function()
        if fightMenuFrame then
            fightMenuFrame:Hide()
        end
        if settingsPopover then
            settingsPopover:Hide()
        end
        if f.settingsBtn then
            f.settingsBtn:SetActiveState(false)
        end
    end)
    ApplyPanelBackdrop(f, 0.96, 0.26, 0.30, 0.36, 1.0)
    f:Hide()

    tinsert(UISpecialFrames, "CombatTelemetryEfficiencyMainFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
    title:SetText("|cff5cc8ffCombatTelemetryEfficiency|r")

    local closeBtn = CreateActionButton(f, 22, 22, "X")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -9)
    closeBtn:SetScript("OnClick", function()
        f:Hide()
    end)

    local prevBtn = CreateActionButton(f, 22, 22, "<")
    prevBtn:SetPoint("LEFT", title, "RIGHT", 12, 0)
    prevBtn:SetScript("OnClick", function()
        selectedFightIndex = selectedFightIndex + 1
        highlightedEventIndex = nil
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
        highlightedEventIndex = nil
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

    local summaryText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    summaryText:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -36)
    f.summaryText = summaryText

    -- BAND 1: Overview Scrub Bar
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

    -- BAND 2: Resource Sparkline, Form Ribbon & Dual-Resource Overlay
    local band2 = CreateFrame("Frame", nil, f, BACKDROP_TEMPLATE)
    band2:SetPoint("TOPLEFT", band1, "BOTTOMLEFT", 0, -6)
    band2:SetPoint("TOPRIGHT", band1, "BOTTOMRIGHT", 0, -6)
    band2:SetHeight(BAND2_HEIGHT)
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

    -- BAND 3: Synchronized Step Log
    local band3 = CreateFrame("Frame", nil, f, BACKDROP_TEMPLATE)
    band3:SetPoint("TOPLEFT", band2, "BOTTOMLEFT", 0, -6)
    band3:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
    ApplyPanelBackdrop(band3, 0.92, 0.22, 0.25, 0.30, 1.0)
    f.band3 = band3

    local headerBg = band3:CreateTexture(nil, "ARTWORK")
    headerBg:SetHeight(20)
    headerBg:SetPoint("TOPLEFT", band3, "TOPLEFT", 1, -1)
    headerBg:SetPoint("TOPRIGHT", band3, "TOPRIGHT", -1, -1)
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
    clipFrame:SetPoint("TOPLEFT", band3, "TOPLEFT", 2, -22)
    clipFrame:SetPoint("BOTTOMRIGHT", band3, "BOTTOMRIGHT", -2, 2)
    band3.clipFrame = clipFrame

    local scrollFrame = CreateFrame("ScrollFrame", "CombatTelemetryEfficiencyLogScroll", clipFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", clipFrame, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", clipFrame, "BOTTOMRIGHT", -22, 0)
    band3.scrollFrame = scrollFrame

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(WINDOW_WIDTH - 52, VISIBLE_LOG_ROWS * LOG_ROW_HEIGHT)
    scrollFrame:SetScrollChild(content)
    band3.content = content

    scrollFrame:SetScript("OnVerticalScroll", function()
        local activeFight = GetActiveFight()
        if activeFight then
            RenderBand3(activeFight)
        end
    end)

    mainFrame = f
    return f
end

------------------------------------------------------------------------
-- Public UI API
------------------------------------------------------------------------

function UI:Show()
    local f = EnsureMainFrame()
    selectedFightIndex = 1
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

function UI:OnFightRecorded(fight)
    if NS.Addon and NS.Addon.db and NS.Addon.db.showPostCombatBanner then
        self:ShowPostCombatPill(fight)
    end
    if mainFrame and mainFrame:IsShown() then
        selectedFightIndex = 1
        highlightedEventIndex = nil
        SetViewportRange(fight, 0, 1)
        self:Refresh()
    end
end
