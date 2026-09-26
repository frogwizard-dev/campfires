local _, Campfires = ...
local Print = Campfires.Print

local commands = {}

local function AddCommand(name, usage, description, run)
    table.insert(commands, { name = name, usage = usage, description = description, run = run })
end

local function ShowHelp()
    Print("/fires: open or close the Campfires window")
    for _, command in ipairs(commands) do
        local usage = command.usage ~= "" and (" " .. command.usage) or ""
        Print("/fires " .. command.name .. usage .. ": " .. command.description)
    end
end

AddCommand("list", "", "list known fires in chat, nearest first", function()
    Campfires.PruneFires()
    local list = Campfires.FiresByDistance()
    if #list == 0 then Print("No campfires known. Try /fires ping.") end
    for i, entry in ipairs(list) do Print(i .. ". " .. Campfires.Summary(entry.fire)) end
end)

AddCommand("go", "[n]", "set a waypoint to the nearest fire, or the nth in the list", function(arg)
    local entry = Campfires.FiresByDistance()[tonumber(arg) or 1]
    if entry then Campfires.GoToFire(entry.fire) else Print("No such fire.") end
end)

AddCommand("add", "", "mark a fire where you're standing", function()
    if Campfires.MarkFireHere() then Print("Campfire marked here.") end
end)

AddCommand("ping", "", "ask other players about fires in this zone", Campfires.PingZone)

AddCommand("clear", "", "forget every fire", function()
    wipe(Campfires.fires)
    Campfires.Refresh()
    Print("Forgot all fires.")
end)

local shareWords = { everyone = "all", all = "all", guild = "guild", group = "guild",
    nobody = "none", none = "none", off = "none" }

AddCommand("share", "[everyone|guild|nobody]", "who sees where you are when you're at a fire", function(arg)
    local choice = shareWords[arg:lower()]
    if choice then
        Campfires.db.shareWith = choice
    else
        Campfires.CycleSetting("shareWith", Campfires.SHARE_OPTIONS)
    end
    Print("Sharing with: " .. Campfires.SettingLabel("shareWith", Campfires.SHARE_OPTIONS)
        .. ". You'll still see other people's fires.")
    Campfires.Refresh()
end)

local showWords = { zone = "zone", here = "zone", everywhere = "all", all = "all" }

AddCommand("show", "[zone|everywhere]", "show fires in this zone only, or everywhere", function(arg)
    local choice = showWords[arg:lower()]
    if choice then
        Campfires.db.showWhere = choice
    else
        Campfires.CycleSetting("showWhere", Campfires.SHOW_OPTIONS)
    end
    Print("Showing fires: " .. Campfires.SettingLabel("showWhere", Campfires.SHOW_OPTIONS) .. ".")
    Campfires.Refresh()
end)

AddCommand("quiet", "", "turn alerts about new fires on or off", function()
    Campfires.db.quiet = not Campfires.db.quiet
    Print("Alerts " .. (Campfires.db.quiet and "off." or "on."))
    Campfires.Refresh()
end)

AddCommand("range", "<yards>", "how close a new fire has to be for a raid warning", function(arg)
    Campfires.db.alertRange = tonumber(arg) or Campfires.db.alertRange
    Print("Alert range: " .. Campfires.db.alertRange .. " yds.")
end)

AddCommand("linger", "<seconds>", "how long fires nobody is at stay listed", function(arg)
    Campfires.db.linger = tonumber(arg) or Campfires.db.linger
    Print("Empty fires stay listed for " .. Campfires.db.linger .. "s.")
end)

AddCommand("minimap", "", "show or hide the minimap button", function()
    Campfires.db.minimapHide = not Campfires.db.minimapHide
    Campfires.UpdateMinimapButton()
    Print("Minimap button " .. (Campfires.db.minimapHide and "hidden." or "shown."))
end)

AddCommand("camp", "", "show what your Camp Benefits buff says is at the camp", function()
    local items = Campfires.ParseItems(Campfires.ItemsFromTooltip(Campfires.CampBenefitsText()))
    if #items == 0 then Print("No Camp Benefits found on you.") end
    for _, item in ipairs(items) do Print(Campfires.ItemLine(item)) end
end)

AddCommand("auras", "", "list your buffs and debuffs with their spell IDs", function()
    local any = false
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        Campfires.ForEachAura(filter, function(name, spellID)
            any = true
            local note = Campfires.IsSittingAura(name, spellID) and " |cff66ff66<- sitting at a fire|r" or ""
            Print(string.format("%s %s (%s)%s", filter == "HELPFUL" and "Buff:" or "Debuff:",
                tostring(name), tostring(spellID), note))
        end)
    end
    if not any then Print("You have no auras.") end
end)

AddCommand("aura", "<spellID|name|reset>", "count another aura as sitting at a fire", function(arg)
    local db = Campfires.db
    if arg == "" then
        local ids, names = {}, {}
        for id in pairs(Campfires.WELCOMING_IDS) do table.insert(ids, tostring(id)) end
        for id in pairs(db.extraAuraIDs) do table.insert(ids, tostring(id)) end
        for _, name in ipairs(Campfires.WELCOMING_NAMES) do table.insert(names, name) end
        for _, name in ipairs(db.extraAuraNames) do table.insert(names, name) end
        Print("Matching names: " .. table.concat(names, ", ") .. "; spell IDs: " .. table.concat(ids, ", "))
    elseif arg:lower() == "reset" then
        db.extraAuraIDs, db.extraAuraNames = {}, {}
        Print("Aura matching reset to Welcoming Campfire.")
    elseif tonumber(arg) then
        db.extraAuraIDs[tonumber(arg)] = true
        Print("Spell ID " .. arg .. " now counts as sitting at a campfire.")
    else
        table.insert(db.extraAuraNames, arg:lower())
        Print("Auras containing \"" .. arg .. "\" now count as sitting at a campfire.")
    end
    Campfires.UpdateSitting()
end)

AddCommand("help", "", "show this list", ShowHelp)

SLASH_CAMPFIRES1 = "/fires"
SLASH_CAMPFIRES2 = "/campfires"

SlashCmdList.CAMPFIRES = function(input)
    local name, arg = input:match("^%s*(%S*)%s*(.-)%s*$")
    name = name:lower()
    if name == "" then
        Campfires.ToggleWindow()
        return
    end
    for _, command in ipairs(commands) do
        if command.name == name then
            command.run(arg)
            return
        end
    end
    ShowHelp()
end
