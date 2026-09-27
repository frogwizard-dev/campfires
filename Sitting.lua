local _, Campfires = ...

-- Sitting down by a fire gives Welcoming Campfire, a one-minute countdown that
-- then turns into Camp Benefits (which lasts an hour, long after you've left).
-- So Welcoming Campfire starts us sharing the fire, and after that we count as
-- there until we walk away, it burns out, or Campfire Nearby disappears.

local WELCOMING_IDS = { [1229739] = true }
local WELCOMING_NAMES = { "welcoming campfire" }
local NEARBY_ID = 1283391

local AT_FIRE_YARDS = 25
local HEARTBEAT_INTERVAL = 30
local RESUME_WITHIN = 10 * 60

Campfires.WELCOMING_IDS = WELCOMING_IDS
Campfires.WELCOMING_NAMES = WELCOMING_NAMES

local IsSecret = Campfires.IsSecret

-- Buffs

-- fn(name, spellID, auraInstanceID, appliedAt) for each aura; stops if fn returns true.
function Campfires.ForEachAura(filter, fn)
    for index = 1, 255 do
        local aura = C_UnitAuras.GetAuraDataByIndex("player", index, filter)
        if not aura then return end
        local appliedAt
        if not IsSecret(aura.duration) and not IsSecret(aura.expirationTime) and aura.duration > 0 then
            appliedAt = aura.expirationTime - aura.duration
        end
        if fn(aura.name, aura.spellId, aura.auraInstanceID, appliedAt) then return true end
    end
end

local function HasAura(matches)
    return Campfires.ForEachAura("HELPFUL", matches) or Campfires.ForEachAura("HARMFUL", matches) or false
end

-- Matched by name too, in case a patch changes the spell ID.
function Campfires.IsSittingAura(name, spellID)
    if IsSecret(name) or IsSecret(spellID) then return false end
    local db = Campfires.db
    if WELCOMING_IDS[spellID] or db.extraAuraIDs[spellID] then return true end
    if type(name) ~= "string" then return false end
    name = name:lower()
    for _, names in ipairs({ WELCOMING_NAMES, db.extraAuraNames }) do
        for _, part in ipairs(names) do
            if name:find(part, 1, true) then return true end
        end
    end
    return false
end

local function IsNearFire()
    return HasAura(function(name, spellID)
        if IsSecret(name) or IsSecret(spellID) then return false end
        return spellID == NEARBY_ID or (type(name) == "string" and name:lower():find("campfire nearby", 1, true) ~= nil)
    end)
end

-- The Camp Benefits tooltip text. With `since`, a buff from before then is
-- from some other camp and doesn't count.
function Campfires.CampBenefitsText(since)
    local text
    Campfires.ForEachAura("HELPFUL", function(name, _, auraInstanceID, appliedAt)
        if IsSecret(name) or type(name) ~= "string" or not name:lower():find("camp benefits", 1, true) then
            return false
        end
        if not since or (appliedAt and appliedAt >= since) then
            local tooltip = C_TooltipInfo.GetUnitBuffByAuraInstanceID("player", auraInstanceID, "HELPFUL")
            local lines = {}
            for _, line in ipairs(tooltip and tooltip.lines or {}) do
                if type(line.leftText) == "string" and not IsSecret(line.leftText) then
                    table.insert(lines, line.leftText)
                end
            end
            text = table.concat(lines, "\n")
        end
        return true
    end)
    return text
end

-- Being at a fire

local currentFire
local satAt              -- where we sat down
local satDownTime        -- GetTime() we sat down, to tell this camp's Camp Benefits from an old one
local ourItems = ""
local lastHeartbeat = 0
local hadNearbyBuff = false
local outCheckQueued = false

function Campfires.IsAtFire()
    return currentFire ~= nil
end

function Campfires.IsOurFire(fire)
    return fire ~= nil and fire == currentFire
end

-- When we're at the fire, our own Camp Benefits says what's there, whatever
-- anyone else claims.
function Campfires.OwnItemsFor(fire)
    if fire == currentFire and ourItems ~= "" then return ourItems end
end

local function SendHeartbeat()
    lastHeartbeat = GetTime()
    -- puts the fire back if /fires clear got rid of it
    local previous = currentFire
    currentFire = Campfires.RecordSighting(previous, time(), Campfires.playerName, true)
    if currentFire ~= previous then
        Campfires.LimitBurnTime(currentFire, previous.burnsOut - time(), previous.burnsOutExact)
    end
    Campfires.SetClass(currentFire, Campfires.playerName, Campfires.playerClass)
    if ourItems ~= "" then currentFire.items = ourItems end

    local saved = Campfires.db.sittingAt
    if saved then
        saved.savedAt = time()
        saved.burnsOut, saved.burnsOutExact = currentFire.burnsOut, currentFire.burnsOutExact
    end
    Campfires.SendHeartbeat(currentFire, ourItems)
end

-- Takes us off every fire that lists us (saved ones included, after a reload).
local function LeaveAllFires()
    local changed = false
    for _, fire in ipairs(Campfires.fires) do
        if fire.people[Campfires.playerName] then
            fire.people[Campfires.playerName] = nil
            Campfires.SendLeftFire(fire)
            changed = true
        end
    end
    if changed then Campfires.Refresh() end
end

local SHARING_MESSAGES = {
    all = "You're at a campfire. Sharing its location with other Campfires users.",
    guild = "You're at a campfire. Sharing its location with your guild and group.",
    none = "You're at a campfire (sharing is off).",
}

local function StartSitting(fire, spot, sinceTime)
    currentFire, satAt, satDownTime, ourItems = fire, spot, sinceTime, ""
    Campfires.db.sittingAt = {
        continent = fire.continent, worldX = fire.worldX, worldY = fire.worldY,
        mapID = fire.mapID, mapX = fire.mapX, mapY = fire.mapY,
        spotX = spot.worldX, spotY = spot.worldY, savedAt = time(),
    }
    SendHeartbeat()
    if not Campfires.db.quiet then Campfires.Print(SHARING_MESSAGES[Campfires.db.shareWith]) end
    Campfires.Refresh()
end

local function StopSitting()
    currentFire, satAt, satDownTime, ourItems = nil, nil, nil, ""
    hadNearbyBuff = false
    Campfires.db.sittingAt = nil
    LeaveAllFires()
    Campfires.Refresh()
end

-- Still where we sat, but Campfire Nearby's gone. No other fire can be within
-- 100 yds, so this one's gone out; tell everyone now rather than letting it linger.
local function ConfirmFireOut()
    outCheckQueued = false
    if not currentFire or InCombatLockdown() or IsNearFire() then return end
    local fire = currentFire
    -- before StopSitting says we've left, or nobody will take our word for it
    Campfires.SendFireOut(fire)
    Campfires.RemoveFire(fire)
    StopSitting()
    if not Campfires.db.quiet then Campfires.Print("The campfire went out.") end
end

local function IsNear(here, spot)
    local yards = Campfires.YardsBetween(here, spot)
    return yards ~= nil and yards <= AT_FIRE_YARDS
end

-- After a reload, carry on if we're still sitting where we were.
local function ResumeAfterReload(here)
    local saved = Campfires.db.sittingAt
    if not saved or time() - saved.savedAt >= RESUME_WITHIN then return end
    local spot = { continent = saved.continent, worldX = saved.spotX, worldY = saved.spotY }
    if not IsNear(here, spot) then return end
    local fire = Campfires.RecordSighting(saved, time(), nil, true)
    if saved.burnsOut then Campfires.LimitBurnTime(fire, saved.burnsOut - time(), saved.burnsOutExact) end
    if time() < fire.burnsOut then StartSitting(fire, spot, 0) end
end

function Campfires.UpdateSitting()
    if InCombatLockdown() or not Campfires.IsPlayerKnown() then return end
    Campfires.PruneFires()
    if currentFire and time() >= currentFire.burnsOut then StopSitting() end

    local sitting = HasAura(Campfires.IsSittingAura)
    local here = Campfires.GetPlayerPosition()

    -- IsReportedOut: Welcoming Campfire can outlive the fire by a few seconds
    if sitting and here and not Campfires.IsReportedOut(here) then
        if not (currentFire and IsNear(here, satAt)) then
            if currentFire then StopSitting() end
            StartSitting(Campfires.RecordSighting(here, time(), nil, true), here, GetTime())
        end
    elseif currentFire then
        if here and not IsNear(here, satAt) then StopSitting() end
    elseif here then
        ResumeAfterReload(here)
    end

    if not currentFire then
        LeaveAllFires()
        return
    end

    -- Wait a few seconds before believing Campfire Nearby is gone; it can blip
    -- during loading screens.
    if IsNearFire() then
        hadNearbyBuff = true
    elseif hadNearbyBuff and not outCheckQueued then
        outCheckQueued = true
        C_Timer.After(3, ConfirmFireOut)
    end

    if not sitting then
        local items = Campfires.ItemsFromTooltip(Campfires.CampBenefitsText(satDownTime - 1))
        if items ~= "" and items ~= ourItems then
            ourItems = items
            SendHeartbeat()
            Campfires.Refresh()
        end
    end
end

-- UNIT_AURA fires a lot, so wait a moment and check once.
local checkQueued = false

function Campfires.QueueSittingCheck()
    if checkQueued then return end
    checkQueued = true
    C_Timer.After(0.3, function()
        checkQueued = false
        Campfires.UpdateSitting()
    end)
end

-- Runs every 5 seconds. Catches us walking off between aura changes.
function Campfires.SittingTick()
    if not currentFire then return end
    Campfires.UpdateSitting()
    if currentFire and GetTime() - lastHeartbeat >= HEARTBEAT_INTERVAL then SendHeartbeat() end
end
