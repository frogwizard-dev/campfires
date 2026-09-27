local _, Campfires = ...

-- Hidden addon messages on the CampfireNet channel (plus guild and group).
-- Fields are split by "|", and the second one is always the protocol version.
-- Keep these the same or older versions stop understanding each other.
--
--   H|1|<position>|<items>|<class>|<burn>        I'm at this fire
--   R|1|<position>|<age>|<people>|<items>|<burn> I know about this fire
--   L|1|<continent>|<x>|<y>                      I've left this fire
--   X|1|<continent>|<x>|<y>                      this fire went out
--   Q|1|<mapID>                                  what fires are in this zone?
--   W|1|<wordingID>                              what's this wording?
--   T|1|<wordingID>|<wording>                    here's the wording
--
-- position = continent|worldX|worldY|mapID|mapX|mapY
-- burn     = seconds left|"e" if exact
-- people   = Name:CLASS,Name:CLASS

local PREFIX = "CAMPFIRES"
local PROTOCOL = 1
local CHANNEL_NAME = "CampfireNet"
local MAX_MESSAGE_LENGTH = 255

-- Anyone can send these messages, so nothing that comes in is taken on trust.
local MAX_WORDING_LENGTH = 150
local RATE_WINDOW, RATE_LIMIT = 30, 30          -- messages from one sender
local NEW_FIRE_WINDOW, NEW_FIRE_LIMIT = 300, 10 -- new fires one sender can tell us about
local ANSWER_COOLDOWN = 20                      -- per zone question / wording
local MAX_FIRES_PER_ANSWER = 5
local LEFT_GRACE = 10                           -- 0.9 sent "left" just before "went out"

C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

-- The channel

local function ChannelNumber()
    local number = GetChannelName(CHANNEL_NAME)
    return number > 0 and number or nil
end

local function IsOurChannel(name)
    return type(name) == "string" and name:lower():find(CHANNEL_NAME:lower(), 1, true) ~= nil
end

-- newer clients moved these into ChatFrameUtil
local RemoveChatChannel = ChatFrame_RemoveChannel or (ChatFrameUtil and ChatFrameUtil.RemoveChannel)
local AddChatFilter = ChatFrame_AddMessageEventFilter or (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)

function Campfires.JoinChannel()
    if not ChannelNumber() then JoinTemporaryChannel(CHANNEL_NAME) end
    if not RemoveChatChannel then return end
    C_Timer.After(2, function()
        for i = 1, NUM_CHAT_WINDOWS do
            local chatFrame = _G["ChatFrame" .. i]
            if chatFrame then pcall(RemoveChatChannel, chatFrame, CHANNEL_NAME) end
        end
    end)
end

-- no "Joined Channel: CampfireNet" in chat
if AddChatFilter then
    AddChatFilter("CHAT_MSG_CHANNEL_NOTICE", function(_, _, _, _, _, channelString, _, _, _, _, channelName)
        return IsOurChannel(channelName) or IsOurChannel(channelString)
    end)
end

-- Sending

-- toAnyone is for messages that don't give away where we are (wordings), so
-- they ignore the Share setting.
local function Send(message, toAnyone)
    local shareWith = toAnyone and "all" or Campfires.db.shareWith
    if shareWith == "none" then return end

    -- Guildmates with the addon are in the channel anyway.
    local channel = shareWith == "all" and ChannelNumber()
    if channel then
        C_ChatInfo.SendAddonMessage(PREFIX, message, "CHANNEL", channel)
    elseif IsInGuild() then
        C_ChatInfo.SendAddonMessage(PREFIX, message, "GUILD")
    end

    -- Group members can be from other realms, so they might not share our channel.
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        C_ChatInfo.SendAddonMessage(PREFIX, message, "INSTANCE_CHAT")
    elseif IsInRaid() then
        C_ChatInfo.SendAddonMessage(PREFIX, message, "RAID")
    elseif IsInGroup() then
        C_ChatInfo.SendAddonMessage(PREFIX, message, "PARTY")
    end
end

local function PositionFields(fire)
    return string.format("%d|%.1f|%.1f|%d|%.4f|%.4f", fire.continent, fire.worldX, fire.worldY,
        fire.mapID or 0, fire.mapX or 0, fire.mapY or 0)
end

local function PlaceFields(fire)
    return string.format("%d|%.1f|%.1f", fire.continent, fire.worldX, fire.worldY)
end

local function BurnFields(fire)
    return string.format("%d|%s", math.max(0, fire.burnsOut - time()), fire.burnsOutExact and "e" or "")
end

-- Drops items off the end until the message fits.
local function WithItems(head, items, tail)
    local message = head .. items .. tail
    while #message > MAX_MESSAGE_LENGTH and items ~= "" do
        items = items:match("^(.*),[^,]*$") or ""
        message = head .. items .. tail
    end
    return message
end

function Campfires.SendHeartbeat(fire, items)
    local head = string.format("H|%d|%s|", PROTOCOL, PositionFields(fire))
    Send(WithItems(head, items, "|" .. (Campfires.playerClass or "") .. "|" .. BurnFields(fire)))
end

function Campfires.SendFireReport(fire)
    -- only pass on people we've heard from ourselves
    local people = {}
    for _, name in ipairs(Campfires.PeopleAt(fire)) do
        if Campfires.IsConfirmed(fire, name) and #people < 4 then
            local class = fire.classes and fire.classes[name]
            table.insert(people, class and (name .. ":" .. class) or name)
        end
    end
    local head = string.format("R|%d|%s|%d|%s|", PROTOCOL, PositionFields(fire),
        time() - fire.lastSeen, table.concat(people, ","))
    Send(WithItems(head, fire.items or "", "|" .. BurnFields(fire)))
end

function Campfires.SendLeftFire(fire)
    Send(string.format("L|%d|%s", PROTOCOL, PlaceFields(fire)))
end

function Campfires.SendFireOut(fire)
    Send(string.format("X|%d|%s", PROTOCOL, PlaceFields(fire)))
end

-- Asking about a zone. Everyone who knows a fire could answer, so they each
-- wait a moment and skip any fire someone else has already mentioned.

local lastAskedAbout = {}
local firesToReport = {}

-- The question gives away which zone we're in, so it follows the Share setting.
function Campfires.AskAboutZone(evenIfRecent)
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return end
    local last = lastAskedAbout[mapID]
    if not evenIfRecent and last and GetTime() - last < 15 then return end
    lastAskedAbout[mapID] = GetTime()
    Send(string.format("Q|%d|%d", PROTOCOL, mapID))
end

function Campfires.PingZone()
    Campfires.AskAboutZone(true)
    Campfires.Print("Asked other users about fires in " .. Campfires.PlayerZoneName() .. ".")
end

local function SendQueuedReports()
    for fire in pairs(firesToReport) do Campfires.SendFireReport(fire) end
    wipe(firesToReport)
end

local function SomeoneMentioned(position)
    for fire in pairs(firesToReport) do
        if Campfires.IsSameFire(fire, position) then firesToReport[fire] = nil end
    end
end

-- Answering is capped per zone, or someone asking over and over could make
-- everyone flood the channel with answers.
local lastAnsweredZone = {}

local function OnZoneQuestion(mapID)
    if GetTime() - (lastAnsweredZone[mapID] or -math.huge) < ANSWER_COOLDOWN then return end
    lastAnsweredZone[mapID] = GetTime()

    -- the few most useful fires: ones with people at them, then the most recent
    local inZone = {}
    for _, fire in ipairs(Campfires.fires) do
        if fire.mapID == mapID then table.insert(inZone, fire) end
    end
    table.sort(inZone, function(a, b)
        local aBusy, bBusy = next(a.people) ~= nil, next(b.people) ~= nil
        if aBusy ~= bBusy then return aBusy end
        return a.lastSeen > b.lastSeen
    end)
    for i = 1, math.min(#inZone, MAX_FIRES_PER_ANSWER) do firesToReport[inZone[i]] = true end
    if #inZone > 0 then C_Timer.After(1 + math.random() * 3, SendQueuedReports) end
end

-- Camp items
--
-- Camp Benefits lists each item as "Name: effect". To keep messages short an
-- item goes out as its name, the numbers in its effect, and a checksum of the
-- rest of the wording:
--
--   "Faction Banner: Spirit increased by 14."  ->  "Faction Banner=14#0fd3"
--
-- A better banner with bigger numbers or extra stats still reads right, and
-- anyone who hasn't seen a wording before asks for it (W) once.

local function IsItemName(name)
    -- also rules out other "x: y" lines like "60 |4minute:minutes; remaining"
    return type(name) == "string" and #name <= 30 and name:match("^%a[%a%s'%-]*$") ~= nil
end

-- Wordings from other players end up in everyone's tooltips, so no escape
-- codes (textures, colours, links) and nothing silly long.
function Campfires.IsCleanWording(wording)
    return type(wording) == "string" and #wording <= MAX_WORDING_LENGTH and not wording:find("[%c|]")
end

local function SplitNumbers(effect)
    effect = effect:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "")
    -- "1 |4hour:hours;" is the game's "hour or hours, whichever fits". Keep both
    -- as "[hour/hours]" and pick one when the number goes back in (ItemLine).
    effect = effect:gsub("|4([^:;|]*):([^;|]*);", "[%1/%2]")
    local numbers = {}
    local wording = effect:gsub("%d+%.?%d*", function(number)
        local after = ""
        if number:sub(-1) == "." then number, after = number:sub(1, -2), "." end -- full stop, not a decimal
        table.insert(numbers, number)
        return "#" .. after
    end)
    return wording, numbers
end

-- Only there to catch garbled messages. Anyone can make up a wording and its
-- ID, which is why wordings are checked with IsCleanWording.
local function WordingID(wording)
    local hash = 0
    for i = 1, #wording do hash = (hash * 31 + wording:byte(i)) % 2147483647 end
    return string.format("%04x", hash % 65536)
end

function Campfires.ParseItems(text)
    local items = {}
    for entry in (text or ""):gmatch("[^,]+") do
        local name, numbers, wordingID = entry:match("^([^=#]+)=?([%d%./]*)#?(%x*)$")
        if IsItemName(name) and #items < 10 then
            local item = { name = name, numbers = {}, wordingID = #wordingID == 4 and wordingID or nil }
            for number in numbers:gmatch("[^/]+") do
                if #item.numbers < 6 and #number <= 8 then table.insert(item.numbers, number) end
            end
            table.insert(items, item)
        end
    end
    return items
end

function Campfires.EncodeItems(items)
    local entries = {}
    for _, item in ipairs(items) do
        local entry = item.name
        if item.wordingID then
            entry = entry .. "=" .. table.concat(item.numbers, "/") .. "#" .. item.wordingID
        end
        table.insert(entries, entry)
    end
    return table.concat(entries, ",")
end

-- Turns the Camp Benefits tooltip into the shared format, remembering each wording.
function Campfires.ItemsFromTooltip(text)
    local items = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local name, effect = line:match("^%s*([^:]-)%s*:%s*(.+)$")
        if IsItemName(name) then
            local wording, numbers = SplitNumbers(effect)
            local item = { name = name, numbers = numbers }
            -- anything other players would reject gets shared by name only
            if Campfires.IsCleanWording(wording) then
                item.wordingID = WordingID(wording)
                Campfires.db.wordings[item.wordingID] = wording
            end
            table.insert(items, item)
        end
    end
    return Campfires.EncodeItems(items)
end

-- "Faction Banner: Spirit increased by 14.", or "Faction Banner (14)" until we
-- know the wording.
function Campfires.ItemLine(item)
    local name = "|cffffd100" .. item.name .. "|r"
    local wording = item.wordingID and Campfires.db.wordings[item.wordingID]
    if wording then
        local i = 0
        local text = wording:gsub("#", function()
            i = i + 1
            return item.numbers[i] or "?"
        end)
        text = text:gsub("(%d+%.?%d*)(%s*)%[([^/%]]*)/([^%]]*)%]", function(number, space, one, many)
            return number .. space .. (tonumber(number) == 1 and one or many)
        end)
        return name .. ": " .. text
    end
    if #item.numbers > 0 then return name .. " (" .. table.concat(item.numbers, ", ") .. ")" end
    return name
end

function Campfires.ItemNames(fire)
    local names = {}
    for _, item in ipairs(Campfires.ParseItems(fire.items)) do table.insert(names, item.name) end
    return names
end

-- Lots of people can see a new item at once, so asking and answering both
-- wait a random moment and drop out if someone else gets there first.

local wordingsToAskFor, lastAskedFor = {}, {}
local wordingsToAnswer, lastAnsweredWording = {}, {}

local function AskForWordings()
    for wordingID in pairs(wordingsToAskFor) do
        if not Campfires.db.wordings[wordingID] then
            lastAskedFor[wordingID] = GetTime()
            Send(string.format("W|%d|%s", PROTOCOL, wordingID), true)
        end
    end
    wipe(wordingsToAskFor)
end

local function AnswerWordings()
    for wordingID in pairs(wordingsToAnswer) do
        local message = string.format("T|%d|%s|%s", PROTOCOL, wordingID, Campfires.db.wordings[wordingID])
        if #message <= MAX_MESSAGE_LENGTH then Send(message, true) end
    end
    wipe(wordingsToAnswer)
end

local function AskAboutUnknownWordings(items)
    local any = false
    for _, item in ipairs(items) do
        local id = item.wordingID
        if id and not Campfires.db.wordings[id] and GetTime() - (lastAskedFor[id] or -math.huge) > 60 then
            wordingsToAskFor[id] = true
            any = true
        end
    end
    if any then C_Timer.After(0.5 + math.random() * 2, AskForWordings) end
end

-- Receiving

local function WithoutRealm(name)
    -- the realm part doesn't reliably match our own realm name on this client
    return name and name:match("^[^%-%s]+")
end

-- Letters only (accented letters are more than one byte), like a real character name.
local function IsPlayerName(name)
    return type(name) == "string" and #name <= 48 and name:match("^[%a\128-\255]+$") ~= nil
end

local function IsClassName(class)
    return class == "" or (#class <= 12 and class:match("^%u+$") ~= nil)
end

-- tonumber() also takes "nan" and "inf", which would make a mess of distances.
local function ReadNumber(text, min, max)
    local number = tonumber(text)
    if number and number == number and number >= min and number <= max then return number end
end

-- Ignoring people: your own list, the game's ignore list, and anyone muted for
-- sending things no real copy of Campfires would.

local STRIKES_TO_MUTE = 3
local STRIKE_WINDOW = 10 * 60
local MUTE_TIME = 60 * 60

local strikes = {} -- lowercase name -> { count, since }
local lastMuteNotice = -math.huge

function Campfires.IsIgnored(name)
    local key = name:lower()
    local db = Campfires.db
    if db.ignored[key] then return true end
    local muted = db.muted[key]
    if muted and time() < muted.expires then return true end
    return C_FriendList.IsIgnored(name) == true
end

function Campfires.IgnorePlayer(name)
    Campfires.db.ignored[name:lower()] = name
    Campfires.ForgetPlayer(name)
end

function Campfires.UnignorePlayer(name)
    local key = name:lower()
    local wasIgnored = Campfires.db.ignored[key] ~= nil or Campfires.db.muted[key] ~= nil
    Campfires.db.ignored[key], Campfires.db.muted[key], strikes[key] = nil, nil, nil
    return wasIgnored
end

function Campfires.IgnoredPlayers()
    local list = {}
    for _, name in pairs(Campfires.db.ignored) do table.insert(list, name) end
    for _, muted in pairs(Campfires.db.muted) do
        local left = muted.expires - time()
        if left > 0 then
            table.insert(list, muted.name .. " (muted for another " .. Campfires.ShortDuration(left) .. ")")
        end
    end
    table.sort(list)
    return list
end

-- Only for things an honest copy of the addon, old or new, never sends. Anything
-- that can happen by bad timing just gets ignored instead.
local function Strike(sender)
    local key, now = sender:lower(), time()
    local record = strikes[key]
    if not record or now - record.since > STRIKE_WINDOW then
        record = { count = 0, since = now }
        strikes[key] = record
    end
    record.count = record.count + 1
    if record.count < STRIKES_TO_MUTE then return end

    strikes[key] = nil
    Campfires.db.muted[key] = { name = sender, expires = now + MUTE_TIME }
    Campfires.ForgetPlayer(sender)
    -- at most one of these a minute, so a crowd of fake senders can't fill chat
    if GetTime() - lastMuteNotice >= 60 then
        lastMuteNotice = GetTime()
        Campfires.Print(sender .. " is sending fake campfire data, so you won't see anything from them for an hour. "
            .. "/fires unignore " .. sender .. " to undo.")
    end
end

local messageCounts = {}   -- sender -> { since, count }
local newFiresFrom = {}    -- sender -> times they told us about a fire we didn't know
local lastCleanup = 0

local function ForgetOldSenders(now)
    if now - lastCleanup < 300 then return end
    lastCleanup = now
    for sender, counter in pairs(messageCounts) do
        if now - counter.since > RATE_WINDOW then messageCounts[sender] = nil end
    end
    for sender, times in pairs(newFiresFrom) do
        if now - times[#times] > NEW_FIRE_WINDOW then newFiresFrom[sender] = nil end
    end
end

local function IsFlooding(sender)
    local now = GetTime()
    ForgetOldSenders(now)
    local counter = messageCounts[sender]
    if not counter or now - counter.since > RATE_WINDOW then
        messageCounts[sender] = { since = now, count = 1 }
        return false
    end
    counter.count = counter.count + 1
    if counter.count == RATE_LIMIT + 1 then Strike(sender) end
    return counter.count > RATE_LIMIT
end

-- Not a strike: someone answering zone questions as you travel can tell you
-- about a lot of fires honestly.
local function MayAddFire(sender)
    local now, times = GetTime(), newFiresFrom[sender] or {}
    for i = #times, 1, -1 do
        if now - times[i] > NEW_FIRE_WINDOW then table.remove(times, i) end
    end
    if #times >= NEW_FIRE_LIMIT then return false end
    table.insert(times, now)
    newFiresFrom[sender] = times
    return true
end

-- The position in fields 3-5 (and the map in 6-8, which older versions leave as 0).
local function ReadPosition(sender, fields)
    local continent = ReadNumber(fields[3], 0, 100000)
    local worldX, worldY = ReadNumber(fields[4], -100000, 100000), ReadNumber(fields[5], -100000, 100000)
    if not (continent and worldX and worldY) then
        Strike(sender)
        return
    end
    local position = { continent = continent, worldX = worldX, worldY = worldY }
    local mapID, mapX, mapY = ReadNumber(fields[6], 1, 1000000), ReadNumber(fields[7], 0, 1), ReadNumber(fields[8], 0, 1)
    if mapID and mapX and mapY then
        position.mapID, position.mapX, position.mapY = mapID, mapX, mapY
    end
    return position
end

-- Seconds left on a fire. Versions before 0.7 don't send it at all.
local function ReadBurnTime(sender, text)
    if not text or text == "" then return end
    local seconds = ReadNumber(text, 0, Campfires.BURN_TIME)
    if not seconds then Strike(sender) end
    return seconds
end

-- Whether anyone besides `name` is confirmed at the fire right now.
local function OthersAt(fire, name)
    for _, other in ipairs(Campfires.PeopleAt(fire)) do
        if other ~= name and Campfires.IsConfirmed(fire, other) then return true end
    end
    return false
end

-- Where an H or R is about, and whether it's a fire we didn't know. Nothing if
-- the fire's just gone out, or the sender has told us about too many new ones.
local function ReadFireNews(sender, fields)
    local position = ReadPosition(sender, fields)
    if not position then return end
    SomeoneMentioned(position)
    if Campfires.IsReportedOut(position) then return end
    local isNew = Campfires.FindFire(position) == nil
    if isNew and not MayAddFire(sender) then return end
    return position, isNew
end

local function TakeItems(fire, items)
    if Campfires.OwnItemsFor(fire) then return end
    local parsed = Campfires.ParseItems(items)
    local cleaned = Campfires.EncodeItems(parsed)
    if cleaned ~= "" and cleaned ~= fire.items then
        fire.items = cleaned
        Campfires.Refresh()
    end
    AskAboutUnknownWordings(parsed)
end

local handlers = {}
local lastLeft = {} -- sender -> { fire, at }

function handlers.H(sender, fields)
    local class = fields[10] or ""
    if not IsClassName(class) then return Strike(sender) end
    local burnTime = ReadBurnTime(sender, fields[11])
    local position, isNew = ReadFireNews(sender, fields)
    if not position then return end

    local fire = Campfires.RecordSighting(position, time(), sender)
    if isNew then fire.source = sender end
    Campfires.SetClass(fire, sender, class)
    -- one person can't cut a fire short while other people are sitting at it
    if not OthersAt(fire, sender) then
        Campfires.LimitBurnTime(fire, burnTime, fields[12] == "e")
    end
    TakeItems(fire, fields[9])
end

function handlers.R(sender, fields)
    -- versions before 0.7 had no 15-minute limit, so old news can honestly be old
    local age = ReadNumber(fields[9], 0, 24 * 60 * 60)
    if not age then return Strike(sender) end
    local burnTime = ReadBurnTime(sender, fields[12])
    local position, isNew = ReadFireNews(sender, fields)
    if not position or age > Campfires.db.linger or age > Campfires.BURN_TIME then return end

    local seenAt = time() - age
    local fire = Campfires.RecordSighting(position, seenAt)
    if isNew then fire.source = sender end

    local count = 0
    for entry in (fields[10] or ""):gmatch("[^,]+") do
        count = count + 1
        if count > 4 then break end
        local name, class = entry:match("^([^:]+):?(%u*)$")
        name = WithoutRealm(name)
        if not IsPlayerName(name) then return Strike(sender) end
        -- don't let an old report put us back at a fire we've left
        local isUs = name == Campfires.playerName and not Campfires.IsAtFire()
        -- versions up to 0.12 could list someone as "Unknown" straight after logging in
        local isUnknown = name == UNKNOWNOBJECT
        if not isUs and not isUnknown and not Campfires.IsIgnored(name) and (fire.people[name] or 0) < seenAt then
            fire.unconfirmed = fire.unconfirmed or {}
            if name == sender then
                fire.unconfirmed[name] = nil
            elseif not fire.people[name] then
                fire.unconfirmed[name] = true
            end
            fire.people[name] = seenAt
            Campfires.SetClass(fire, name, class)
        end
    end

    -- a report only gets to say how long a fire has left if it's news to us
    if isNew then Campfires.LimitBurnTime(fire, burnTime, fields[13] == "e") end
    TakeItems(fire, fields[11])
end

function handlers.L(sender, fields)
    local position = ReadPosition(sender, fields)
    local fire = position and Campfires.FindFire(position)
    if fire and fire.people[sender] then
        fire.people[sender] = nil
        lastLeft[sender] = { fire = fire, at = time() }
        Campfires.Refresh()
    end
end

-- Only someone at the fire can say it's gone out, and it only goes once nobody
-- else is left there. Anyone really still there would notice it go out too.
function handlers.X(sender, fields)
    local position = ReadPosition(sender, fields)
    local fire = position and Campfires.FindFire(position)
    if not fire then return end
    local left = lastLeft[sender]
    local justLeft = left and left.fire == fire and time() - left.at <= LEFT_GRACE
    if not fire.people[sender] and not justLeft then return end
    fire.people[sender] = nil
    SomeoneMentioned(position)
    if OthersAt(fire, sender) then
        Campfires.Refresh()
    else
        Campfires.RemoveFire(position)
    end
end

function handlers.Q(sender, fields)
    local mapID = ReadNumber(fields[3], 1, 1000000)
    if not mapID then return Strike(sender) end
    OnZoneQuestion(mapID)
end

function handlers.W(sender, fields)
    local id = fields[3] and fields[3]:match("^%x%x%x%x$")
    if not id then return Strike(sender) end
    lastAskedFor[id] = GetTime() -- someone else asked, so we'll hear the answer too
    wordingsToAskFor[id] = nil
    if Campfires.db.wordings[id] and GetTime() - (lastAnsweredWording[id] or -math.huge) >= ANSWER_COOLDOWN then
        lastAnsweredWording[id] = GetTime()
        wordingsToAnswer[id] = true
        C_Timer.After(0.3 + math.random() * 1.5, AnswerWordings)
    end
end

local function OnWordingAnswer(sender, id, wording)
    wordingsToAnswer[id] = nil
    -- no real copy of the addon shares a wording with codes in it, or one that
    -- doesn't match its ID; long ones only just started being turned down
    if wording:find("[%c|]") or WordingID(wording) ~= id then return Strike(sender) end
    if Campfires.db.wordings[id] or not Campfires.IsCleanWording(wording) then return end
    Campfires.db.wordings[id] = wording
    Campfires.Refresh()
end

function Campfires.OnAddonMessage(prefix, message, _, sender)
    -- until we know our own name we can't tell our echoed messages from anyone else's
    if prefix ~= PREFIX or not Campfires.IsPlayerKnown() then return end
    sender = WithoutRealm(sender)
    if sender == Campfires.playerName then return end -- the channel echoes our own messages back
    if not IsPlayerName(sender) or Campfires.IsIgnored(sender) or IsFlooding(sender) then return end

    -- a wording can have "|" in it, so T isn't split up
    local id, wording = message:match("^T|" .. PROTOCOL .. "|(%x%x%x%x)|(.+)$")
    if id then
        OnWordingAnswer(sender, id, wording)
        return
    end

    local fields = { strsplit("|", message) }
    local handler = handlers[fields[1]]
    if handler and tonumber(fields[2]) == PROTOCOL then handler(sender, fields) end
end
