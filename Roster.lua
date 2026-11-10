-- Roster.lua: who is in the guild and who is online, from the guild roster.
--
-- Members are known by GUID. Addon messages only carry the sender's name
-- (WoW Forever gives "Alice Smith", with a space and no realm; other
-- clients add "-Realm"), and the roster gives names without a realm, so a
-- sender is matched to the roster by the name before any realm. A name two
-- members share is not trusted.
--
-- Every attached addon shares this one roster. Each complete read also
-- tells every addon which members are still in the guild (its Data.Prune),
-- and the events GuildChanged and RosterUpdated go to every addon.
local Lib = LibGuildSync

local Roster = {}
Lib.Roster = Roster

-- An event, to every attached addon.
local function FireAll(event, ...)
    for _, ns in ipairs(Lib.attached) do
        ns.Fire(event, ...)
    end
end

Roster.guildKey = nil  -- the current guild's name
-- [GUID] = { n = roster name, c = class file ("MAGE"), l = level,
--   rk = rank name, ri = rank index (0 = guild master), nt = public note,
--   on = online, lo = about when the member was last online (offline only) }
Roster.members = {}
Roster.ready = false   -- the whole roster has been read at least once
Roster.total = 0

local REQUEST_INTERVAL = 10       -- the server ignores roster requests closer than this
local REFRESH_INTERVAL = 120
local FLAG_REQUEST_INTERVAL = 30  -- at most this often when the server says there is news
local lastRequest = -REQUEST_INTERVAL

local byName = {}  -- [name without realm] = GUID, or false when two members share it

function Roster.Request()
    if GetTime() - lastRequest < REQUEST_INTERVAL then
        return
    end
    lastRequest = GetTime()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

-- "Name-Realm" or "Name" -> "Name".
function Roster.BaseName(name)
    return name:match("^([^%-]+)") or name
end

-- The GUID of the member who sent an addon message, if the roster knows them.
function Roster.GUIDOfSender(sender)
    if type(sender) ~= "string" then
        return nil
    end
    return byName[sender] or byName[Roster.BaseName(sender)] or nil
end

-- Until the whole roster is known, everyone counts as a member (and as online).
function Roster.IsKnownSender(sender)
    return not Roster.ready or Roster.GUIDOfSender(sender) ~= nil
end

function Roster.IsKnownGUID(guid)
    return not Roster.ready or Roster.members[guid] ~= nil
end

function Roster.IsOnline(guid)
    local member = Roster.members[guid]
    if not member then
        return not Roster.ready
    end
    return member.on
end

function Roster.NameOf(guid)
    local member = guid and Roster.members[guid]
    return member and member.n
end

-- How many members are online.
function Roster.OnlineCount()
    local count = 0
    for _, member in pairs(Roster.members) do
        if member.on then
            count = count + 1
        end
    end
    return count
end

local function UpdateGuildKey()
    local key
    if IsInGuild() then
        key = Lib.Plain((GetGuildInfo("player")))
        if not key then
            -- Not loaded yet: keep what we had until it is.
            return Roster.guildKey ~= nil
        end
    end
    if key ~= Roster.guildKey then
        Roster.guildKey = key
        Roster.ready = false
        Roster.members, Roster.total = {}, 0
        byName = {}
        Lib.Debug("guild: %s", tostring(key))
        FireAll("GuildChanged", key)
    end
    return key ~= nil
end

local HOUR, DAY = 3600, 86400

-- About when an offline member was last online. The client only says how
-- long ago, in years, months, days and hours.
local function LastOnline(index, now)
    if type(GetGuildRosterLastOnline) ~= "function" then
        return nil
    end
    local ok, years, months, days, hours = pcall(GetGuildRosterLastOnline, index)
    if not ok then
        return nil
    end
    years, months, days, hours = Lib.Plain(years), Lib.Plain(months), Lib.Plain(days), Lib.Plain(hours)
    if type(years) ~= "number" and type(months) ~= "number" and type(days) ~= "number" and type(hours) ~= "number" then
        return nil
    end
    local ago = ((years or 0) * 365 + (months or 0) * 30 + (days or 0)) * DAY + (hours or 0) * HOUR
    return math.max(now - ago, 0)
end

local function Text(value)
    value = Lib.Plain(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

local function Read()
    if not UpdateGuildKey() then
        return
    end
    local total = Lib.Plain((GetNumGuildMembers())) or 0
    if total == 0 and Roster.ready then
        -- Not loaded (or not readable right now): keep the last read.
        return
    end
    local members, names = {}, {}
    local complete = total > 0
    local now = Lib.Now()
    for i = 1, total do
        local name, rankName, rankIndex, level, _, _, note, _, online, _, class, _, _, isMobile, _, _, guid = GetGuildRosterInfo(i)
        name, guid = Lib.Plain(name), Lib.Plain(guid)
        if type(name) == "string" and Lib.IsGUID(guid) then
            local isOnline = Lib.Plain(online) == true and Lib.Plain(isMobile) ~= true
            local entry = {
                n = name,
                c = Text(class),
                l = Lib.Plain(level),
                rk = Text(rankName),
                ri = Lib.Plain(rankIndex),
                nt = Text(note),
                on = isOnline,
            }
            if type(entry.l) ~= "number" then
                entry.l = nil
            end
            if type(entry.ri) ~= "number" then
                entry.ri = nil
            end
            if not isOnline then
                entry.lo = LastOnline(i, now)
            end
            members[guid] = entry
            for _, key in ipairs({ name, Roster.BaseName(name) }) do
                if names[key] == nil then
                    names[key] = guid
                elseif names[key] ~= guid then
                    names[key] = false
                end
            end
        else
            complete = false
        end
    end
    if total > 0 and not complete and Roster.ready then
        -- A partial read (data still arriving): keep the last complete one.
        return
    end
    Roster.members, Roster.total = members, total
    byName = names
    -- The roster spells our own name best (see Lib.SetPlayerName).
    local player = Lib.player
    local me = player.guid and members[player.guid]
    if me and Roster.BaseName(me.n) ~= player.name then
        Lib.SetPlayerName(Roster.BaseName(me.n))
        Lib.Debug("our name: %s", player.name)
    end
    if complete then
        Roster.ready = true
    end
    for _, ns in ipairs(Lib.attached) do
        if complete then
            Lib.SafeCall(ns.Data.Prune, Roster.guildKey, members)
        end
        ns.Data.ForgetDigests()
    end
    FireAll("RosterUpdated")
end

local readTimer
local function ScheduleRead()
    if readTimer then
        readTimer:Cancel()
    end
    readTimer = C_Timer.NewTimer(0.5, function()
        readTimer = nil
        Read()
    end)
end

function Roster.Init()
    local events = CreateFrame("Frame")
    Lib.RegisterEvents(events, "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE")
    events:SetScript("OnEvent", function(_, event, canRequest)
        if event == "PLAYER_GUILD_UPDATE" then
            UpdateGuildKey()
            Roster.Request()
        elseif Lib.Plain(canRequest) == true and GetTime() - lastRequest >= FLAG_REQUEST_INTERVAL then
            -- The server has newer roster data (members logging in or out)
            -- to give on request; Blizzard's guild window asks for it too.
            Roster.Request()
        end
        ScheduleRead()
    end)
    UpdateGuildKey()
    Roster.Request()
    C_Timer.NewTicker(REFRESH_INTERVAL, function()
        if IsInGuild() then
            Roster.Request()
        end
    end)
end
