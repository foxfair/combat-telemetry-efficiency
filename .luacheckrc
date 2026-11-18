std = "lua51"
max_line_length = false

globals = {
    -- Core WoW Client & Frame APIs (WoW Forever 1.60.1 / Interface 16001)
    "CreateFrame",
    "GetTime",
    "GetCursorPosition",
    "UIParent",
    "GameTooltip",
    "DEFAULT_CHAT_FRAME",
    "BackdropTemplateMixin",
    "UISpecialFrames",
    "SlashCmdList",
    "wipe",

    -- Unit & Combat APIs
    "UnitName",
    "UnitGUID",
    "UnitClass",
    "UnitLevel",
    "UnitExists",
    "UnitIsDead",
    "UnitClassification",
    "UnitPower",
    "UnitPowerMax",
    "UnitPowerType",
    "InCombatLockdown",
    "CombatLogGetCurrentEventInfo",

    -- Class, Spellbook, Shapeshift & Totem APIs
    "GetComboPoints",
    "GetTotemInfo",
    "GetShapeshiftForm",
    "GetShapeshiftFormInfo",
    "GetSpellInfo",
    "GetSpellPowerCost",
    "GetSpellCooldown",
    "IsPlayerSpell",
    "IsSpellKnown",

    -- SavedVariables & Slash Globals
    "CombatTelemetryEfficiencyDB",
    "SLASH_COMBATTELEMETRYEFFICIENCY1",
}

ignore = {
    "211", -- Unused local variable
    "212", -- Unused function argument in WoW event handlers
    "213", -- Unused loop variable
}
