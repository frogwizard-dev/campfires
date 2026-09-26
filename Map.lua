local _, Campfires = ...

local ICON = "Interface\\Icons\\Spell_Fire_Fire"
local PIN_TEMPLATE = "CampfiresMapPinTemplate"

-- World map

CampfiresMapPinMixin = CreateFromMixins(MapCanvasPinMixin)

function CampfiresMapPinMixin:OnLoad()
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    self:SetScalingLimits(1, 1.0, 1.2)
end

-- On continent and world maps the pins are smaller, and clicks go through
-- them so you can still click into a zone.
function CampfiresMapPinMixin:OnAcquired(fire, x, y, zoomedOut)
    self.fire, self.zoomedOut = fire, zoomedOut
    local size = zoomedOut and 10 or 18
    self:SetSize(size, size)
    self:SetPosition(x, y)
    self:SetMouseClickEnabled(not zoomedOut)
    self:SetAlpha(#Campfires.PeopleAt(fire) > 0 and 1 or 0.55)
end

function CampfiresMapPinMixin:OnMouseEnter()
    Campfires.ShowFireTooltip(self, self.fire, self.zoomedOut and "Open the zone map to set a waypoint" or nil)
end

function CampfiresMapPinMixin:OnMouseLeave()
    GameTooltip:Hide()
end

function CampfiresMapPinMixin:OnMouseClickAction(button)
    if button == "LeftButton" then Campfires.GoToFire(self.fire) end
end

local pinProvider = CreateFromMixins(MapCanvasDataProviderMixin)

function pinProvider:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
end

function pinProvider:RefreshAllData()
    self:RemoveAllData()
    local map = self:GetMap()
    local mapID = map:GetMapID()
    if not mapID then return end
    local info = C_Map.GetMapInfo(mapID)
    local zoomedOut = info ~= nil and info.mapType <= Enum.UIMapType.Continent
    local playerZone = Campfires.PlayerZone()
    for _, fire in ipairs(Campfires.fires) do
        if Campfires.IsShown(fire, playerZone) then
            local x, y = Campfires.PositionOnMap(fire, mapID)
            if x then map:AcquirePin(PIN_TEMPLATE, fire, x, y, zoomedOut) end
        end
    end
end

function pinProvider:OnMapChanged()
    self:RefreshAllData()
end

WorldMapFrame:AddDataProvider(pinProvider)

function Campfires.RefreshMap()
    if WorldMapFrame:IsShown() then pinProvider:RefreshAllData() end
end

-- Minimap

-- yards across the minimap at each zoom level
local MINIMAP_SIZE = {
    indoor = { [0] = 300, 240, 180, 120, 80, 50 },
    outdoor = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 },
}

local minimapPins = {}

local function GetMinimapPin(index)
    if minimapPins[index] then return minimapPins[index] end
    local pin = CreateFrame("Frame", nil, Minimap)
    pin:SetSize(14, 14)
    pin:SetFrameLevel(Minimap:GetFrameLevel() + 5)
    local icon = pin:CreateTexture(nil, "OVERLAY")
    icon:SetAllPoints()
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    pin:SetScript("OnEnter", function(self) Campfires.ShowFireTooltip(self, self.fire) end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pin:SetScript("OnMouseUp", function(self) Campfires.GoToFire(self.fire) end)
    minimapPins[index] = pin
    return pin
end

local function UpdateMinimapPins()
    local used = 0
    local here = #Campfires.fires > 0 and Minimap:IsVisible() and Campfires.GetPlayerPosition()
    if here then
        local sizes = IsIndoors() and MINIMAP_SIZE.indoor or MINIMAP_SIZE.outdoor
        local width = Minimap:GetWidth()
        local scale = width / (sizes[Minimap:GetZoom()] or 400)
        local edge = width / 2 - 6
        local facing = C_CVar.GetCVar("rotateMinimap") == "1" and GetPlayerFacing() or nil
        local cos, sin = math.cos(facing or 0), math.sin(facing or 0)
        local playerZone = Campfires.PlayerZone()

        for _, fire in ipairs(Campfires.fires) do
            if fire.continent == here.continent and Campfires.IsShown(fire, playerZone) then
                local east = here.worldY - fire.worldY
                local north = fire.worldX - here.worldX
                if facing then
                    east, north = east * cos + north * sin, north * cos - east * sin
                end
                local x, y = east * scale, north * scale
                local distance = math.sqrt(x * x + y * y)
                -- fires off the minimap sit on its edge, a bit faded
                local offMap = distance > edge
                if offMap then x, y = x * edge / distance, y * edge / distance end

                used = used + 1
                local pin = GetMinimapPin(used)
                pin.fire = fire
                pin:ClearAllPoints()
                pin:SetPoint("CENTER", Minimap, "CENTER", x, y)
                pin:SetAlpha(offMap and 0.6 or 1)
                pin:Show()
            end
        end
    end
    for i = used + 1, #minimapPins do minimapPins[i]:Hide() end
end

local elapsedSinceUpdate = 0
CreateFrame("Frame"):SetScript("OnUpdate", function(_, elapsed)
    elapsedSinceUpdate = elapsedSinceUpdate + elapsed
    if elapsedSinceUpdate < 0.1 then return end
    elapsedSinceUpdate = 0
    UpdateMinimapPins()
end)
