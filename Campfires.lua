local ADDON_NAME, Campfires = ...

local SAME_FIRE_YARDS = 25   -- reports closer together than this are the same fire
local BURN_TIME = 15 * 60    -- a Basic Campfire burns for exactly 15 minutes
local PERSON_TIMEOUT = 75    -- haven't heard from someone in this long, they've gone
local IGNORE_AFTER_OUT = 60
local MAX_FIRES = 50         -- so someone flooding fake fires can't grow the list forever
local ALERT_COOLDOWN = 20
local BASIC_CAMPFIRE = 818

Campfires.BURN_TIME = BURN_TIME
-- On a fresh login the game can still call you "Unknown" while addons load, so
-- this gets asked again once you're in the world.
local function LearnPlayer()
    Campfires.playerName = UnitName("player")
    Campfires.playerClass = select(2, UnitClass("player"))
end
LearnPlayer()

function Campfires.IsPlayerKnown()
    return Campfires.playerClass ~= nil and Campfires.playerName ~= UNKNOWNOBJECT
end
Campfires.fires = {}

Campfires.SHARE_OPTIONS = {
    { value = "all", label = "Everyone" },
    { value = "guild", label = "Guild & group" },
    { value = "none", label = "Nobody" },
}

Campfires.SHOW_OPTIONS = {
    { value = "all", label = "Everywhere" },
    { value = "zone", label = "This zone" },
}

local defaults = {
    shareWith = "all",
    showWhere = "all",
    quiet = false,
    alertRange = 250,
    linger = 180, -- seconds an empty fire stays listed
    minimapHide = false,
    minimapAngle = 200,
    extraAuraIDs = {},
    extraAuraNames = {},
    wordings = {},
    fires = {},
    ignored = {}, -- lowercase name -> name, from /fires ignore
    muted = {},   -- lowercase name -> { name, expires }, sent data no real copy of the addon would
}

function Campfires.Print(...)
    print("|cffff9933Campfires|r:", ...)
end

-- The retail client can hide aura details from addons in combat.
function Campfires.IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function IsOption(value, options)
    for _, option in ipairs(options) do
        if option.value == value then return true end
    end
    return false
end

local function LoadSettings()
    CampfiresDB = CampfiresDB or {}
    local db = CampfiresDB
    for key, value in pairs(defaults) do
        if db[key] == nil then
            db[key] = type(value) == "table" and CopyTable(value) or value
        end
    end

    -- leftovers from older versions
    db.auraNames, db.auraIDs, db.benefitInfo, db.hostAt = nil, nil, nil, nil
    if db.linger == 300 then db.linger = 180 end
    if db.share == false then db.shareWith = "none" end
    db.share = nil
    -- pre-0.10 fires used different field names; they'd have burned out by now anyway
    if db.fires[1] and db.fires[1].wx then wipe(db.fires) end
    -- older versions would save any wording another player sent
    for id, wording in pairs(db.wordings) do
        if not Campfires.IsCleanWording(wording) then db.wordings[id] = nil end
    end
    for key, muted in pairs(db.muted) do
        if time() >= muted.expires then db.muted[key] = nil end
    end

    if not IsOption(db.shareWith, Campfires.SHARE_OPTIONS) then db.shareWith = "all" end
    if not IsOption(db.showWhere, Campfires.SHOW_OPTIONS) then db.showWhere = "all" end

    Campfires.db = db
    Campfires.fires = db.fires
end

function Campfires.CycleSetting(key, options)
    local db = Campfires.db
    for i, option in ipairs(options) do
        if option.value == db[key] then
            db[key] = options[i % #options + 1].value
            return
        end
    end
    db[key] = options[1].value
end

function Campfires.SettingLabel(key, options)
    for _, option in ipairs(options) do
        if option.value == Campfires.db[key] then return option.label end
    end
    return options[1].label
end

-- Changes tend to arrive in bunches, so wait a frame and redraw everything once.
local redrawQueued = false

function Campfires.Refresh()
    if redrawQueued then return end
    redrawQueued = true
    C_Timer.After(0, function()
        redrawQueued = false
        Campfires.RefreshMap()
        Campfires.RefreshWindow()
        Campfires.RefreshMinimapButton()
    end)
end

-- Positions

-- A position (and a fire) has continent, worldX and worldY in yards (X points
-- north, Y points west), plus the mapID, mapX and mapY it was taken on.
function Campfires.GetPlayerPosition()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return end
    local mapPosition = C_Map.GetPlayerMapPosition(mapID, "player")
    if not mapPosition then return end
    local continent, worldPosition = C_Map.GetWorldPosFromMapPos(mapID, mapPosition)
    if not continent then return end
    local worldX, worldY = worldPosition:GetXY()
    local mapX, mapY = mapPosition:GetXY()
    return {
        continent = continent, worldX = worldX, worldY = worldY,
        mapID = mapID, mapX = mapX, mapY = mapY,
    }
end

function Campfires.YardsBetween(a, b)
    if a.continent ~= b.continent then return end
    local dx, dy = a.worldX - b.worldX, a.worldY - b.worldY
    return math.sqrt(dx * dx + dy * dy)
end

function Campfires.IsSameFire(a, b)
    local yards = Campfires.YardsBetween(a, b)
    return yards ~= nil and yards <= SAME_FIRE_YARDS
end

local COMPASS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

function Campfires.DirectionTo(position)
    local here = Campfires.GetPlayerPosition()
    if not here or here.continent ~= position.continent then return end
    local east = here.worldY - position.worldY
    local north = position.worldX - here.worldX
    local degrees = math.deg(math.atan2(east, north)) % 360
    return math.sqrt(east * east + north * north), COMPASS[math.floor((degrees + 22.5) / 45) % 8 + 1]
end

function Campfires.DirectionText(position)
    local yards, direction = Campfires.DirectionTo(position)
    if not yards then return end
    if yards < 10 then return "right here" end
    return string.format("%d yds %s", yards, direction)
end

function Campfires.PositionOnMap(position, mapID)
    if position.mapID == mapID and position.mapX then
        return position.mapX, position.mapY
    end
    local ok, _, mapPosition = pcall(C_Map.GetMapPosFromWorldPos, position.continent,
        CreateVector2D(position.worldX, position.worldY), mapID)
    if not ok or not mapPosition then return end
    local x, y = mapPosition:GetXY()
    if x < 0 or x > 1 or y < 0 or y > 1 then return end
    return x, y
end

function Campfires.ZoneName(mapID)
    local info = mapID and C_Map.GetMapInfo(mapID)
    return info and info.name or "Unknown zone"
end

-- Cities and caves have their own maps, but for "this zone" they count as the
-- zone they're in. The hierarchy never changes, so the answers are cached.
local zoneForMap = {}

function Campfires.ZoneContaining(mapID)
    if not mapID then return end
    if zoneForMap[mapID] == nil then
        local zoneID, info = mapID, C_Map.GetMapInfo(mapID)
        while info and info.mapType > Enum.UIMapType.Zone and info.parentMapID > 0 do
            zoneID = info.parentMapID
            info = C_Map.GetMapInfo(zoneID)
        end
        zoneForMap[mapID] = zoneID
    end
    return zoneForMap[mapID]
end

function Campfires.PlayerZone()
    return Campfires.ZoneContaining(C_Map.GetBestMapForUnit("player"))
end

function Campfires.PlayerZoneName()
    return Campfires.ZoneName(C_Map.GetBestMapForUnit("player"))
end

function Campfires.TimeAgo(seconds)
    if seconds < 60 then return seconds .. "s ago" end
    return math.floor(seconds / 60) .. "m ago"
end

function Campfires.ShortDuration(seconds)
    if seconds < 60 then return math.max(0, math.floor(seconds)) .. "s" end
    return math.floor(seconds / 60) .. "m"
end

-- Fires
--
-- Each fire is a position plus:
--   people         name -> time() we last heard from them there
--   unconfirmed    names we've only heard about from someone else's report
--   classes        name -> class, for colouring names
--   lastSeen       time() of the latest news
--   burnsOut       time() it's out by: exact if we saw it placed, otherwise the latest it could be
--   burnsOutExact  whether burnsOut is exact
--   items          what's at the camp (see Network.lua)
--   source         who first told us about it

function Campfires.FindFire(position)
    for _, fire in ipairs(Campfires.fires) do
        if Campfires.IsSameFire(fire, position) then return fire end
    end
end

-- The game tells us who sent each message, so someone saying they're at a fire
-- is really them. A report that someone *else* is there could be made up, so
-- those names get a "?" until we hear from the person themselves.
function Campfires.IsConfirmed(fire, name)
    return not (fire.unconfirmed and fire.unconfirmed[name])
end

-- Confirmed names first.
function Campfires.PeopleAt(fire)
    local names, now = {}, time()
    for name, lastHeard in pairs(fire.people) do
        if now - lastHeard <= PERSON_TIMEOUT then table.insert(names, name) end
    end
    table.sort(names, function(a, b)
        local aConfirmed, bConfirmed = Campfires.IsConfirmed(fire, a), Campfires.IsConfirmed(fire, b)
        if aConfirmed ~= bConfirmed then return aConfirmed end
        return a < b
    end)
    return names
end

function Campfires.ColoredName(fire, name)
    if not Campfires.IsConfirmed(fire, name) then return "|cff999999" .. name .. "?|r" end
    local class = fire.classes and fire.classes[name]
    local color = class and RAID_CLASS_COLORS[class]
    if not color then return name end
    return "|c" .. color.colorStr .. name .. "|r"
end

function Campfires.SetClass(fire, name, class)
    if type(class) ~= "string" or #class > 12 or not class:match("^%u+$") then return end
    fire.classes = fire.classes or {}
    fire.classes[name] = class
end

-- "Bob +2", or nil if nobody's there
function Campfires.PeopleSummary(fire)
    local names = Campfires.PeopleAt(fire)
    if #names == 0 then return end
    local summary = Campfires.ColoredName(fire, names[1])
    if #names > 1 then summary = summary .. " +" .. (#names - 1) end
    return summary
end

-- Anyone who saw the fire knows it can't last more than 15 minutes after that,
-- so keep the soonest time we hear about. Whoever placed it knows exactly.
function Campfires.LimitBurnTime(fire, secondsLeft, exact)
    secondsLeft = tonumber(secondsLeft)
    if not secondsLeft then return end
    local burnsOut = time() + secondsLeft
    if not fire.burnsOut or burnsOut < fire.burnsOut then fire.burnsOut = burnsOut end
    if exact then fire.burnsOutExact = true end
end

function Campfires.BurnTimeText(fire, short)
    local left = Campfires.ShortDuration(fire.burnsOut - time())
    if short then
        return fire.burnsOutExact and (left .. " left") or ("up to " .. left)
    end
    return (fire.burnsOutExact and "Burns out in " or "Burns out within ") .. left
end

local lastAlert = -math.huge

local function AlertAboutNewFire(fire)
    if Campfires.db.quiet or GetTime() - lastAlert < ALERT_COOLDOWN then return end
    local yards, direction = Campfires.DirectionTo(fire)
    if yards and yards <= Campfires.db.alertRange then
        local message = string.format("Campfire %d yds %s", yards, direction)
        RaidNotice_AddMessage(RaidWarningFrame, message, ChatTypeInfo["RAID_WARNING"])
        PlaySound(SOUNDKIT.RAID_WARNING)
        Campfires.Print(message .. " (" .. Campfires.StatusText(fire) .. "). /fires go to set a waypoint.")
        lastAlert = GetTime()
    elseif fire.mapID == C_Map.GetBestMapForUnit("player") then
        Campfires.Print("New campfire: " .. Campfires.Summary(fire))
        lastAlert = GetTime()
    end
end

-- Drops the stalest fire nobody's at (or failing that, the stalest one) once
-- there are too many.
local function MakeRoom()
    local fires = Campfires.fires
    while #fires > MAX_FIRES do
        local worst, worstScore
        for i, fire in ipairs(fires) do
            if not Campfires.IsOurFire(fire) then
                local score = fire.lastSeen + (next(fire.people) and 1e9 or 0)
                if not worstScore or score < worstScore then worst, worstScore = i, score end
            end
        end
        if not worst then return end
        table.remove(fires, worst)
    end
end

-- There was a fire at `position` at time `seenAt` (with `person` at it, if
-- given). ours = we found it ourselves, so don't alert about it.
function Campfires.RecordSighting(position, seenAt, person, ours)
    local fire = Campfires.FindFire(position)
    local isNew = not fire
    if isNew then
        fire = {
            continent = position.continent, worldX = position.worldX, worldY = position.worldY,
            mapID = position.mapID, mapX = position.mapX, mapY = position.mapY,
            people = {}, lastSeen = seenAt, burnsOut = seenAt + BURN_TIME,
        }
        table.insert(Campfires.fires, fire)
        MakeRoom()
    elseif seenAt > fire.lastSeen then
        fire.lastSeen = seenAt
    end
    if person then
        if (fire.people[person] or 0) < seenAt then fire.people[person] = seenAt end
        if fire.unconfirmed then fire.unconfirmed[person] = nil end
        -- nobody can be at two fires at once
        for _, other in ipairs(Campfires.fires) do
            if other ~= fire then other.people[person] = nil end
        end
    end
    if isNew and not ours then AlertAboutNewFire(fire) end
    Campfires.Refresh()
    return fire
end

function Campfires.MarkFireHere(justPlaced)
    local here = Campfires.GetPlayerPosition()
    if not here then
        Campfires.Print("Can't get your position here.")
        return
    end
    local fire = Campfires.RecordSighting(here, time(), nil, true)
    if justPlaced then Campfires.LimitBurnTime(fire, BURN_TIME, true) end
    Campfires.SendFireReport(fire)
    return fire
end

-- Fires that went out stay here for a minute, so a report that was already on
-- its way doesn't bring them back.
local recentlyOut = {}

function Campfires.IsReportedOut(position)
    local now = time()
    for i = #recentlyOut, 1, -1 do
        local out = recentlyOut[i]
        if now > out.expires then
            table.remove(recentlyOut, i)
        elseif Campfires.IsSameFire(out, position) then
            return true
        end
    end
    return false
end

function Campfires.RemoveFire(position)
    table.insert(recentlyOut, {
        continent = position.continent, worldX = position.worldX, worldY = position.worldY,
        expires = time() + IGNORE_AFTER_OUT,
    })
    local fires = Campfires.fires
    for i = #fires, 1, -1 do
        if Campfires.IsSameFire(fires[i], position) then table.remove(fires, i) end
    end
    Campfires.Refresh()
end

-- Drops everything we've heard from someone: them at any fire, and fires only
-- they told us about that nobody else is at.
function Campfires.ForgetPlayer(name)
    local key = name:lower()
    local fires = Campfires.fires
    for i = #fires, 1, -1 do
        local fire = fires[i]
        for person in pairs(fire.people) do
            if person:lower() == key then
                fire.people[person] = nil
                if fire.unconfirmed then fire.unconfirmed[person] = nil end
            end
        end
        if fire.source and fire.source:lower() == key and not next(fire.people) then
            table.remove(fires, i)
        end
    end
    Campfires.Refresh()
end

function Campfires.PruneFires()
    local now, changed = time(), false
    local fires = Campfires.fires
    for i = #fires, 1, -1 do
        local fire = fires[i]
        for name, lastHeard in pairs(fire.people) do
            if now - lastHeard > PERSON_TIMEOUT then
                fire.people[name] = nil
                if fire.unconfirmed then fire.unconfirmed[name] = nil end
                changed = true
            end
        end
        local burnedOut = now >= fire.burnsOut
        local abandoned = not next(fire.people) and now - fire.lastSeen > Campfires.db.linger
        if burnedOut or abandoned then
            table.remove(fires, i)
            changed = true
        end
    end
    if changed then Campfires.Refresh() end
end

-- Whether the map, minimap and window should show this fire (the Show setting).
function Campfires.IsShown(fire, playerZone)
    if not Campfires.db or Campfires.db.showWhere ~= "zone" then return true end
    playerZone = playerZone or Campfires.PlayerZone()
    return playerZone ~= nil and Campfires.ZoneContaining(fire.mapID) == playerZone
end

function Campfires.FiresByDistance()
    local list = {}
    for _, fire in ipairs(Campfires.fires) do
        table.insert(list, { fire = fire, yards = Campfires.DirectionTo(fire) or math.huge })
    end
    table.sort(list, function(a, b) return a.yards < b.yards end)
    return list
end

function Campfires.StatusText(fire)
    local people = Campfires.PeopleSummary(fire)
    if people then return people .. " at the fire" end
    return "nobody there, last seen " .. Campfires.TimeAgo(time() - fire.lastSeen) .. ", may have burned out"
end

function Campfires.Summary(fire)
    local summary = string.format("%s, %s: %s (%s)",
        Campfires.DirectionText(fire) or "far away",
        Campfires.ZoneName(fire.mapID),
        Campfires.StatusText(fire),
        Campfires.BurnTimeText(fire, true))
    local items = Campfires.ItemNames(fire)
    if #items > 0 then summary = summary .. " [" .. table.concat(items, ", ") .. "]" end
    return summary
end

function Campfires.ShowFireTooltip(owner, fire, hint)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Campfire", 1, 0.6, 0.2)
    local direction = Campfires.DirectionText(fire)
    if direction then GameTooltip:AddLine(direction, 1, 1, 1) end
    GameTooltip:AddLine(Campfires.BurnTimeText(fire), 0.8, 0.8, 0.8)

    local people = Campfires.PeopleAt(fire)
    if #people > 0 then
        local anyUnconfirmed = false
        for i, name in ipairs(people) do
            anyUnconfirmed = anyUnconfirmed or not Campfires.IsConfirmed(fire, name)
            people[i] = Campfires.ColoredName(fire, name)
        end
        GameTooltip:AddLine("At the fire: " .. table.concat(people, ", "), 1, 1, 1, true)
        if anyUnconfirmed then
            GameTooltip:AddLine("? = passed on by another player, not heard from them yet", 0.6, 0.6, 0.6, true)
        end
    else
        local lastSeen = Campfires.TimeAgo(time() - fire.lastSeen)
        GameTooltip:AddLine("Nobody's here now, last seen " .. lastSeen .. ".", 1, 0.5, 0.25)
        GameTooltip:AddLine("It may have burned out.", 1, 0.5, 0.25)
    end

    local items = Campfires.ParseItems(fire.items)
    if #items > 0 then
        GameTooltip:AddLine(" ")
        for _, item in ipairs(items) do GameTooltip:AddLine(Campfires.ItemLine(item), 1, 1, 1, true) end
    end
    GameTooltip:AddLine(hint or "Click to set a waypoint", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

function Campfires.GoToFire(fire)
    local mapID, x, y = fire.mapID, fire.mapX, fire.mapY
    if not mapID then
        mapID = C_Map.GetBestMapForUnit("player")
        x, y = Campfires.PositionOnMap(fire, mapID)
    end

    if x and TomTom then
        TomTom:AddWaypoint(mapID, x, y, { title = "Campfire", persistent = false })
    elseif x and C_Map.CanSetUserWaypointOnMap(mapID) then
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    else
        Campfires.Print("Couldn't set a waypoint on this map.")
        return
    end
    Campfires.Print("Waypoint set: " .. Campfires.Summary(fire))
end

-- Events

local events = {}
local hasEnteredWorld = false

function events.ADDON_LOADED(name)
    if name ~= ADDON_NAME then return end
    LoadSettings()
    Campfires.PruneFires()
    Campfires.RestoreWindowPosition()
    Campfires.UpdateMinimapButton()
    C_Timer.NewTicker(5, function()
        Campfires.PruneFires()
        Campfires.SittingTick()
    end)
end

events.PLAYER_LOGIN = LearnPlayer

function events.PLAYER_ENTERING_WORLD()
    LearnPlayer()
    if hasEnteredWorld then
        Campfires.AskAboutZone()
    else
        -- join late, or the hidden channel can take /1 from General
        hasEnteredWorld = true
        C_Timer.After(10, Campfires.JoinChannel)
        C_Timer.After(13, function() Campfires.AskAboutZone(true) end)
    end
    Campfires.QueueSittingCheck()
end

function events.ZONE_CHANGED_NEW_AREA()
    if hasEnteredWorld then Campfires.AskAboutZone() end
    Campfires.Refresh()
end

function events.UNIT_AURA()
    Campfires.QueueSittingCheck()
end

function events.PLAYER_REGEN_ENABLED()
    Campfires.QueueSittingCheck()
end

function events.CHAT_MSG_ADDON(...)
    Campfires.OnAddonMessage(...)
end

function events.UNIT_SPELLCAST_SUCCEEDED(_, _, spellID)
    if not Campfires.IsSecret(spellID) and spellID == BASIC_CAMPFIRE then
        Campfires.MarkFireHere(true)
    end
end

local eventFrame = CreateFrame("Frame")
for event in pairs(events) do
    if event == "UNIT_AURA" or event == "UNIT_SPELLCAST_SUCCEEDED" then
        eventFrame:RegisterUnitEvent(event, "player")
    else
        eventFrame:RegisterEvent(event)
    end
end
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" or Campfires.db then events[event](...) end
end)
