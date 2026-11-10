-- LibGuildSync: shared code for guild addons: hidden addon messages, the
-- guild roster, a saved database of the members' records and the sync that
-- keeps every member's copy of it the same.
--
-- An addon attaches to it once its files load:
--
--   LibGuildSync.Attach(ns, {
--       title = "My Guild Addon",        -- in the messages the player sees
--       tag = "MGA",                     -- in the debug log
--       prefix = "MyGuildAddon",         -- its addon message prefix
--       trialPrefix = "MyGuildAddonDev", trial = false,
--       protocol = "1", legacy = nil,    -- its protocol, older ones still read
--       savedVariable = "MyGuildAddonDB",
--   })
--
-- and starts it at PLAYER_LOGIN with LibGuildSync.Start(ns). Attach puts in
-- the addon's namespace (ns) its own instances of the parts that belong to
-- one addon (ns.Comm, ns.Data, ns.Sync: its prefix, protocol, records and
-- saved data), the parts every addon shares (ns.Roster, the player's name
-- and GUID) and the helpers below. The addon then teaches ns.Pack and
-- ns.Data its records (see Store.lua).
--
-- Each addon keeps its own prefix and protocol, so moving an addon onto the
-- library changes nothing in the messages it sends.
local _, private = ...

local Lib = {}
LibGuildSync = Lib
Lib.VERSION = C_AddOns.GetAddOnMetadata("LibGuildSync", "Version") or "0.0.0"

-- The namespaces of the attached addons, in the order they attached.
Lib.attached = {}

-- Helpers ------------------------------------------------------------------------

-- "1.2.3" -> 10203. Records carry it so a newer client in the guild is noticed.
function Lib.VersionNumber(version)
    local major, minor, patch = tostring(version):match("^(%d+)%.(%d+)%.?(%d*)")
    if not major then
        return 0
    end
    return tonumber(major) * 10000 + tonumber(minor) * 100 + (tonumber(patch) or 0)
end

function Lib.VersionString(number)
    return ("%d.%d.%d"):format(math.floor(number / 10000), math.floor(number / 100) % 100, number % 100)
end

-- WoW Forever runs the Midnight addon API, where some results are "secret":
-- using one in a condition, or even comparing it with nil, raises an error.
-- Anything that might be secret goes through Plain() before it is looked at.
local issecretvalue = issecretvalue or function() return false end

function Lib.Plain(value)
    if issecretvalue(value) then
        return nil
    end
    return value
end

-- A plain number, or nil.
function Lib.Number(value)
    value = Lib.Plain(value)
    return type(value) == "number" and value or nil
end

-- True when two values hold the same data (tables compared field by field).
function Lib.Same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    for key, value in pairs(a) do
        if not Lib.Same(value, b[key]) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

-- Tables from the API can be secret as a whole during a lockdown, and
-- reading their fields then raises.
local canaccesstable = canaccesstable

function Lib.CanRead(tbl)
    if type(tbl) ~= "table" then
        return false
    end
    -- Called directly: it answers for the function that calls it.
    return not canaccesstable or canaccesstable(tbl) ~= false
end

-- RegisterEvent raises for an event this client does not have, which would
-- abort the rest of the file, so every registration is wrapped.
function Lib.RegisterEvents(frame, ...)
    for i = 1, select("#", ...) do
        pcall(frame.RegisterEvent, frame, (select(i, ...)))
    end
end

function Lib.Now()
    return GetServerTime()
end

-- Calls fn(...), reporting an error as a normal Lua error instead of
-- stopping the caller. (Arguments are not passed through xpcall itself,
-- which plain Lua 5.1 does not support.)
function Lib.SafeCall(fn, ...)
    local args, count = { ... }, select("#", ...)
    xpcall(function()
        fn(unpack(args, 1, count))
    end, geterrorhandler())
end

-- Realm names as they appear in "Name-Realm": no spaces or dashes.
function Lib.NormalizeRealm(realm)
    return (realm:gsub("[%s%-]", ""))
end

function Lib.ShortName(fullName)
    return Ambiguate(fullName, "guild")
end

-- Checks shared by the addons' records.
Lib.MIN_TIME = 1600000000   -- September 2020: older times are bogus

function Lib.IsCount(value, max)
    return type(value) == "number" and value >= 0 and value <= max and value == math.floor(value)
end

function Lib.IsID(value)
    return type(value) == "number" and value > 0 and value < 2147483648 and value == math.floor(value)
end

function Lib.IsTime(value)
    return type(value) == "number" and value == math.floor(value) and value >= Lib.MIN_TIME and value < 1e12
end

function Lib.IsGUID(guid)
    return type(guid) == "string" and #guid <= 64 and guid:find("^Player%-%d+%-%x+$") ~= nil
end

-- A name as given by another client, safe to show: no escape sequences.
function Lib.CleanName(name, maxLength)
    if type(name) ~= "string" then
        return nil
    end
    name = name:gsub("[|%c]", "")
    if name == "" or #name > (maxLength or 64) then
        return nil
    end
    return name
end

-- The library's texts, in an addon's language (ns.LOCALE, see the addon's
-- Locales.lua), as a table like the addon's own L.
function Lib.TextsFor(ns)
    return setmetatable({}, {
        __index = function(_, key)
            return private.Texts(ns.LOCALE)[key]
        end,
    })
end

-- The player ---------------------------------------------------------------------

-- Who we are, read once at login: realm, guid, name ("Alice Smith") and key,
-- how our addon messages are signed ("Alice Smith-Realm").
Lib.player = {}

local function CopyPlayer(ns)
    local player = Lib.player
    ns.realm, ns.playerGUID, ns.playerName, ns.playerKey = player.realm, player.guid, player.name, player.key
end

-- The roster spells our name best (see Roster.lua).
function Lib.SetPlayerName(name)
    local player = Lib.player
    player.name = name
    player.key = name .. "-" .. player.realm
    for _, ns in ipairs(Lib.attached) do
        CopyPlayer(ns)
    end
end

local function ReadPlayer()
    local player = Lib.player
    if player.guid then
        return
    end
    player.realm = Lib.Plain(GetNormalizedRealmName()) or Lib.NormalizeRealm(GetRealmName())
    player.guid = Lib.Plain(UnitGUID("player"))
    -- WoW Forever names have two parts, and UnitName gives them apart
    -- ("Alice", "Smith"). The roster's spelling replaces this once it is
    -- read (see Roster.lua).
    local first, second = UnitName("player")
    first, second = Lib.Plain(first), Lib.Plain(second)
    Lib.SetPlayerName(second and second ~= "" and (first .. " " .. second) or first)
end

-- True when a message sender is ourselves ("Name Surname", or with a realm).
function Lib.IsMe(sender)
    local player = Lib.player
    return sender == player.name or sender == player.key
        or (player.guid ~= nil and Lib.Roster.GUIDOfSender(sender) == player.guid)
end

-- One addon's own helpers -----------------------------------------------------------

-- Print, a debug log kept in memory (shown while ns.debugEnabled), Try,
-- events between the addon's parts, and Debounce.
local function AddOwnHelpers(ns, config)
    local title, tag = config.title, config.tag or config.title

    function ns.Print(message, ...)
        if select("#", ...) > 0 then
            message = message:format(...)
        end
        print("|cff33ccff" .. title .. "|r: " .. message)
    end

    ns.debugLog = {}
    function ns.Debug(message, ...)
        if select("#", ...) > 0 then
            local ok, text = pcall(string.format, message, ...)
            message = ok and text or message
        end
        local line = date("%H:%M:%S ") .. message
        local log = ns.debugLog
        log[#log + 1] = line
        if #log > 300 then
            table.remove(log, 1)
        end
        if ns.debugEnabled then
            print("|cff888888" .. tag .. "|r " .. line)
        end
    end

    -- Calls fn, returning nothing instead of raising when the client lacks
    -- it or it fails. For the undocumented API the addon cannot be sure of.
    function ns.Try(fn, ...)
        if type(fn) ~= "function" then
            return nil
        end
        local results = { pcall(fn, ...) }
        if not results[1] then
            ns.Debug("call failed: %s", tostring(results[2]))
            return nil
        end
        return unpack(results, 2, table.maxn(results))
    end

    -- Callbacks between the parts of the addon. Each listener runs on its
    -- own, so an error in one is reported without stopping the others.
    local listeners = {}
    function ns.On(event, callback)
        listeners[event] = listeners[event] or {}
        table.insert(listeners[event], callback)
    end
    function ns.Fire(event, ...)
        for _, callback in ipairs(listeners[event] or {}) do
            Lib.SafeCall(callback, ...)
        end
    end

    -- Runs fn once things have been quiet for delay seconds. With maxWait,
    -- it runs at the latest maxWait seconds after the first call.
    local debounced = {}
    function ns.Debounce(key, delay, fn, maxWait)
        local now = GetTime()
        local entry = debounced[key]
        if entry then
            entry.timer:Cancel()
        else
            entry = { first = now }
            debounced[key] = entry
        end
        local wait = delay
        if maxWait then
            wait = math.min(delay, entry.first + maxWait - now)
        end
        entry.timer = C_Timer.NewTimer(math.max(wait, 0), function()
            debounced[key] = nil
            fn()
        end)
    end

    -- "3 days", "5 min"... in the addon's language.
    local L = Lib.TextsFor(ns)
    function ns.Ago(timestamp)
        local seconds = math.max(Lib.Now() - timestamp, 0)
        if seconds < 60 then
            return L["a moment"]
        end
        -- Limited to one unit, SecondsToTime only uses a unit from 1.5 of
        -- it, so from 60 to 89 seconds it gives nothing.
        local text = SecondsToTime(seconds, true, true, 1)
        if text == "" then
            text = SecondsToTime(seconds, true, true, 2)
        end
        return text
    end
end

-- Logs a line in every attached addon's debug log (for the shared parts).
function Lib.Debug(message, ...)
    for _, ns in ipairs(Lib.attached) do
        ns.Debug(message, ...)
    end
end

-- Attaching ------------------------------------------------------------------------

local SHARED = {
    "VersionNumber", "VersionString", "Plain", "Number", "Same", "CanRead", "RegisterEvents", "Now", "SafeCall",
    "NormalizeRealm", "ShortName", "IsMe", "SetPlayerName",
}

function Lib.Attach(ns, config)
    assert(type(ns.ADDON_NAME) == "string", "set ns.ADDON_NAME before attaching")
    ns.Lib = Lib
    ns.TITLE = config.title
    ns.VERSION = C_AddOns.GetAddOnMetadata(ns.ADDON_NAME, "Version") or "0.0.0"
    ns.VERSION_NUM = Lib.VersionNumber(ns.VERSION)
    -- Addon messages go out on PREFIX and are heard on every prefix in
    -- LISTEN. While a version with a new protocol is tried in game before
    -- its release (TRIAL), it talks on a prefix of its own: members on the
    -- released version do not hear it, so they are not asked to update to a
    -- version they cannot get yet, and their own messages are still heard.
    -- Prefixes hold at most 16 characters.
    ns.TRIAL = config.trial == true
    ns.PREFIX = ns.TRIAL and config.trialPrefix or config.prefix
    ns.LISTEN = { [ns.PREFIX] = true, [config.prefix] = true }
    ns.PROTOCOL = config.protocol
    ns.LEGACY = config.legacy or {}
    ns.SAVED = config.savedVariable
    for _, name in ipairs(SHARED) do
        ns[name] = Lib[name]
    end
    AddOwnHelpers(ns, config)
    -- The addon adds its records' LIMITS, WriteRecord and ReadRecord.
    ns.Pack = setmetatable({}, { __index = Lib.Pack })
    function ns.Pack.RecordString(key, record, ...)
        local writer = Lib.Pack.Writer()
        ns.Pack.WriteRecord(writer, key, record, ...)
        return writer:Result()
    end
    ns.Roster = Lib.Roster
    ns.Data = Lib.NewStore(ns)
    ns.Comm = Lib.NewComm(ns)
    ns.Sync = Lib.NewSync(ns)
    table.insert(Lib.attached, ns)
    return ns
end

local rosterStarted = false

-- At PLAYER_LOGIN: our name and GUID, the shared roster (once), and the
-- addon's messages and sync.
function Lib.Start(ns)
    ReadPlayer()
    CopyPlayer(ns)
    ns.loginTime = GetTime()
    if not rosterStarted then
        rosterStarted = true
        xpcall(Lib.Roster.Init, geterrorhandler())
    end
    xpcall(ns.Comm.Init, geterrorhandler())
    xpcall(ns.Sync.Init, geterrorhandler())
end
