local _, Campfires = ...

local ICON = "Interface\\Icons\\Spell_Fire_Fire"
local WIDTH, PADDING = 340, 10
local ROW_HEIGHT, MAX_ROWS, MIN_ROWS = 32, 6, 2
local HEADER_HEIGHT, FOOTER_HEIGHT = 56, 70

local function ShowHelpText(widget)
    GameTooltip:SetOwner(widget, "ANCHOR_RIGHT")
    GameTooltip:SetText(widget.helpText, 1, 1, 1, 1, true)
    GameTooltip:Show()
end

local function HideTooltip()
    GameTooltip:Hide()
end

-- Window

local window = CreateFrame("Frame", "CampfiresFrame", UIParent, "BackdropTemplate")
window:SetSize(WIDTH, HEADER_HEIGHT + MIN_ROWS * ROW_HEIGHT + FOOTER_HEIGHT)
window:SetPoint("CENTER")
window:SetFrameStrata("HIGH")
window:SetClampedToScreen(true)
window:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
window:SetBackdropColor(0, 0, 0, 0.85)
window:EnableMouse(true)
window:SetMovable(true)
window:RegisterForDrag("LeftButton")
window:SetScript("OnDragStart", window.StartMoving)
window:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relativePoint, x, y = self:GetPoint()
    Campfires.db.window = { point, relativePoint, x, y }
end)
window:Hide()
tinsert(UISpecialFrames, "CampfiresFrame") -- close on Escape

local titleIcon = window:CreateTexture(nil, "ARTWORK")
titleIcon:SetSize(18, 18)
titleIcon:SetPoint("TOPLEFT", PADDING, -PADDING)
titleIcon:SetTexture(ICON)
titleIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("LEFT", titleIcon, "RIGHT", 6, 0)
title:SetText("Campfires")

local closeButton = CreateFrame("Button", nil, window, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", 2, 2)

local statusLine = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
statusLine:SetPoint("TOPLEFT", PADDING, -34)
statusLine:SetPoint("TOPRIGHT", -PADDING, -34)
statusLine:SetJustifyH("LEFT")

local topLine = window:CreateTexture(nil, "ARTWORK")
topLine:SetColorTexture(1, 1, 1, 0.12)
topLine:SetHeight(1)
topLine:SetPoint("TOPLEFT", PADDING, -52)
topLine:SetPoint("TOPRIGHT", -PADDING, -52)

local bottomLine = window:CreateTexture(nil, "ARTWORK")
bottomLine:SetColorTexture(1, 1, 1, 0.12)
bottomLine:SetHeight(1)
bottomLine:SetPoint("BOTTOMLEFT", PADDING, FOOTER_HEIGHT - 6)
bottomLine:SetPoint("BOTTOMRIGHT", -PADDING, FOOTER_HEIGHT - 6)

local emptyMessage = window:CreateFontString(nil, "OVERLAY", "GameFontDisable")
emptyMessage:SetPoint("TOP", topLine, "BOTTOM", 0, -14)

-- Each row: distance, zone and who's there on top; camp items and time left underneath.
local rows = {}

local function GetRow(index)
    if rows[index] then return rows[index] end
    local row = CreateFrame("Button", nil, window)
    row:SetHeight(ROW_HEIGHT)
    local top = -4 - (index - 1) * ROW_HEIGHT
    row:SetPoint("TOPLEFT", topLine, "BOTTOMLEFT", 0, top)
    row:SetPoint("TOPRIGHT", topLine, "BOTTOMRIGHT", 0, top)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(22, 22)
    row.icon:SetPoint("LEFT", 2, 0)
    row.icon:SetTexture(ICON)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.distance = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.distance:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, 2)
    row.distance:SetWidth(80)
    row.distance:SetJustifyH("LEFT")

    row.people = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.people:SetPoint("TOPRIGHT", -4, -4)
    row.people:SetWidth(110)
    row.people:SetJustifyH("RIGHT")
    row.people:SetWordWrap(false)

    row.zone = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.zone:SetPoint("LEFT", row.distance, "RIGHT", 4, 0)
    row.zone:SetPoint("RIGHT", row.people, "LEFT", -4, 0)
    row.zone:SetJustifyH("LEFT")
    row.zone:SetWordWrap(false)

    row.timeLeft = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.timeLeft:SetPoint("BOTTOMRIGHT", -4, 4)
    row.timeLeft:SetJustifyH("RIGHT")

    row.items = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.items:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, -2)
    row.items:SetPoint("RIGHT", row.timeLeft, "LEFT", -6, 0)
    row.items:SetJustifyH("LEFT")
    row.items:SetWordWrap(false)

    row:SetScript("OnClick", function(self) Campfires.GoToFire(self.fire) end)
    row:SetScript("OnEnter", function(self) Campfires.ShowFireTooltip(self, self.fire) end)
    row:SetScript("OnLeave", HideTooltip)

    rows[index] = row
    return row
end

local function FillRow(row, fire)
    row.fire = fire
    row.distance:SetText(Campfires.DirectionText(fire) or "far away")
    row.zone:SetText(Campfires.ZoneName(fire.mapID))
    local items = Campfires.ItemNames(fire)
    row.items:SetText(#items > 0 and table.concat(items, ", ") or "Camp items unknown")
    row.timeLeft:SetText(Campfires.BurnTimeText(fire, true))

    local people = Campfires.PeopleSummary(fire)
    if people then
        row.people:SetText(people)
        row.people:SetTextColor(1, 1, 1)
        row.icon:SetDesaturated(false)
        row.icon:SetAlpha(1)
    else
        row.people:SetText("empty, may be out")
        row.people:SetTextColor(1, 0.5, 0.25)
        row.icon:SetDesaturated(true)
        row.icon:SetAlpha(0.6)
    end
end

local function CreateButton(text, width, helpText, onClick)
    local button = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
    button:SetText(text)
    button.helpText = helpText
    button:SetScript("OnEnter", ShowHelpText)
    button:SetScript("OnLeave", HideTooltip)
    button:SetScript("OnClick", onClick)
    return button
end

local shareButton = CreateButton("Share: Everyone", 154,
    "Who sees where you are when you're at a campfire:\n\n"
    .. "|cffffd100Everyone|r: all Campfires users\n"
    .. "|cffffd100Guild & group|r: only your guild and party or raid\n"
    .. "|cffffd100Nobody|r: no one\n\n"
    .. "Click to change. You always see other people's fires.",
    function()
        Campfires.CycleSetting("shareWith", Campfires.SHARE_OPTIONS)
        Campfires.Refresh()
    end)
shareButton:SetPoint("BOTTOMLEFT", PADDING, PADDING + 27)

local showButton = CreateButton("Show: Everywhere", 154,
    "Which fires appear on the world map, the minimap and this list:\n\n"
    .. "|cffffd100Everywhere|r: every fire you know about\n"
    .. "|cffffd100This zone|r: only fires in the zone you're in\n\n"
    .. "Click to change.",
    function()
        Campfires.CycleSetting("showWhere", Campfires.SHOW_OPTIONS)
        Campfires.Refresh()
    end)
showButton:SetPoint("LEFT", shareButton, "RIGHT", 6, 0)

local pingButton = CreateButton("Ping", 90, "Ask other Campfires users about fires in this zone.",
    Campfires.PingZone)
pingButton:SetPoint("BOTTOMLEFT", PADDING, PADDING)

local markButton = CreateButton("Mark here", 90, "Mark a campfire where you're standing and share it.",
    function()
        if Campfires.MarkFireHere() then Campfires.Print("Campfire marked here.") end
    end)
markButton:SetPoint("LEFT", pingButton, "RIGHT", 6, 0)

local alertsCheckbox = CreateFrame("CheckButton", nil, window, "UICheckButtonTemplate")
alertsCheckbox:SetSize(24, 24)
alertsCheckbox:SetPoint("LEFT", markButton, "RIGHT", 10, 0)
alertsCheckbox.helpText = "Raid warning and sound when a new campfire appears nearby."
alertsCheckbox:SetScript("OnEnter", ShowHelpText)
alertsCheckbox:SetScript("OnLeave", HideTooltip)
alertsCheckbox:SetScript("OnClick", function(self)
    Campfires.db.quiet = not self:GetChecked()
    Campfires.Refresh()
end)

local alertsLabel = alertsCheckbox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
alertsLabel:SetPoint("LEFT", alertsCheckbox, "RIGHT", 2, 0)
alertsLabel:SetText("Alerts")

local SITTING_STATUS = {
    all = "|cff66ff66You're at a campfire and sharing it.|r",
    guild = "|cff66ff66You're at a campfire, sharing with guild & group.|r",
    none = "|cffffcc00You're at a campfire (sharing off).|r",
}

local function UpdateWindow()
    if not Campfires.db then return end
    local allFires = Campfires.FiresByDistance()
    local shown, playerZone = {}, Campfires.PlayerZone()
    for _, entry in ipairs(allFires) do
        if Campfires.IsShown(entry.fire, playerZone) then table.insert(shown, entry.fire) end
    end

    local rowCount = math.min(#shown, MAX_ROWS)
    for i = 1, rowCount do
        local row = GetRow(i)
        FillRow(row, shown[i])
        row:Show()
    end
    for i = rowCount + 1, #rows do rows[i]:Hide() end

    if #allFires == 0 then
        emptyMessage:SetText("No campfires known yet.\nSit at a fire, or press Ping to ask around.")
    else
        emptyMessage:SetText("No campfires in this zone.\nSet Show to Everywhere to see all "
            .. #allFires .. " you know about.")
    end
    emptyMessage:SetShown(#shown == 0)
    window:SetHeight(HEADER_HEIGHT + math.max(rowCount, MIN_ROWS) * ROW_HEIGHT + FOOTER_HEIGHT)

    local status = Campfires.IsAtFire() and SITTING_STATUS[Campfires.db.shareWith] or "You're not at a campfire."
    local known = #allFires == 1 and "1 fire known" or (#allFires .. " fires known")
    if rowCount < #allFires then known = known .. " (" .. rowCount .. " shown)" end
    statusLine:SetText(status .. "  |cff888888" .. known .. "|r")

    shareButton:SetText("Share: " .. Campfires.SettingLabel("shareWith", Campfires.SHARE_OPTIONS))
    showButton:SetText("Show: " .. Campfires.SettingLabel("showWhere", Campfires.SHOW_OPTIONS))
    alertsCheckbox:SetChecked(not Campfires.db.quiet)
end

-- distances change as you walk, so keep it updated while it's open
local sinceUpdate = 0
window:SetScript("OnUpdate", function(_, elapsed)
    sinceUpdate = sinceUpdate + elapsed
    if sinceUpdate < 1 then return end
    sinceUpdate = 0
    UpdateWindow()
end)
window:SetScript("OnShow", UpdateWindow)

function Campfires.ToggleWindow()
    window:SetShown(not window:IsShown())
end

function Campfires.RefreshWindow()
    if window:IsShown() then UpdateWindow() end
end

function Campfires.RestoreWindowPosition()
    local saved = Campfires.db.window
    if saved then
        window:ClearAllPoints()
        window:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
    end
end

function Campfires_OnAddonCompartmentClick()
    Campfires.ToggleWindow()
end

-- Minimap button

local minimapButton = CreateFrame("Button", "CampfiresMinimapButton", Minimap)
minimapButton:SetSize(31, 31)
minimapButton:SetFrameStrata("MEDIUM")
minimapButton:SetFrameLevel(8)
minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
minimapButton:RegisterForDrag("LeftButton")
minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local buttonBackground = minimapButton:CreateTexture(nil, "BACKGROUND")
buttonBackground:SetSize(20, 20)
buttonBackground:SetPoint("TOPLEFT", 7, -5)
buttonBackground:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

local buttonIcon = minimapButton:CreateTexture(nil, "ARTWORK")
buttonIcon:SetSize(17, 17)
buttonIcon:SetPoint("TOPLEFT", 7, -6)
buttonIcon:SetTexture(ICON)

local buttonBorder = minimapButton:CreateTexture(nil, "OVERLAY")
buttonBorder:SetSize(53, 53)
buttonBorder:SetPoint("TOPLEFT")
buttonBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

-- how many fires have people at them
local buttonCount = minimapButton:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
buttonCount:SetPoint("BOTTOMRIGHT", -3, 4)

local function PlaceMinimapButton()
    local angle = math.rad(Campfires.db.minimapAngle)
    local radius = Minimap:GetWidth() / 2 + 5
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function DragAroundMinimap()
    local centerX, centerY = Minimap:GetCenter()
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    Campfires.db.minimapAngle = math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX))
    PlaceMinimapButton()
end

minimapButton:SetScript("OnClick", function(_, mouseButton)
    if mouseButton == "RightButton" then Campfires.PingZone() else Campfires.ToggleWindow() end
end)
minimapButton:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", DragAroundMinimap) end)
minimapButton:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Campfires", 1, 0.6, 0.2)
    GameTooltip:AddLine("Left-click: open window", 1, 1, 1)
    GameTooltip:AddLine("Right-click: ping this zone", 1, 1, 1)
    GameTooltip:AddLine("Drag: move button", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
minimapButton:SetScript("OnLeave", HideTooltip)

function Campfires.RefreshMinimapButton()
    local count, playerZone = 0, Campfires.PlayerZone()
    for _, fire in ipairs(Campfires.fires) do
        if #Campfires.PeopleAt(fire) > 0 and Campfires.IsShown(fire, playerZone) then count = count + 1 end
    end
    buttonCount:SetText(count > 0 and count or "")
end

function Campfires.UpdateMinimapButton()
    minimapButton:SetShown(not Campfires.db.minimapHide)
    PlaceMinimapButton()
    Campfires.RefreshMinimapButton()
end
