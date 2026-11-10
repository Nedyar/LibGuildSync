-- Sync Fixture: a minimal addon on LibGuildSync, for the library's tests.
-- Each member shares a note (v) and a sorted list of numbers (k, nil until
-- known), which the tests set with ns.SetOwn.
--
-- Its protocol is "3" (SYNC_FIXTURE_PROTOCOL changes it for a client); it
-- still reads "2", whose records carry no list.
local ADDON_NAME, ns = ...
ns.ADDON_NAME = ADDON_NAME
ns.LOCALE = SYNC_FIXTURE_LOCALE or "enUS"

local Lib = LibGuildSync
Lib.Attach(ns, {
    title = "Sync Fixture",
    tag = "SF",
    prefix = "SyncFixture",
    trialPrefix = "SyncFixtureDev",
    trial = SYNC_FIXTURE_TRIAL == true,
    protocol = SYNC_FIXTURE_PROTOCOL or "3",
    legacy = { ["2"] = true },
    savedVariable = "SyncFixtureDB",
})

local Pack, Data = ns.Pack, ns.Data
Pack.LIMITS = { text = 64, note = 100 }

-- Records --------------------------------------------------------------------------

-- Length-prefixed, so fields added later are skipped by older readers.
function Pack.WriteRecord(writer, guid, record)
    local body = Pack.Writer()
    body:Str(guid)
    body:Str(record.n or "")
    body:UInt(record.t)
    body:UInt(record.av or 0)
    body:Str(record.rl or "")
    body:Str(record.v or "")
    if ns.PROTOCOL ~= "2" then
        if record.k then
            body:Byte(1)
            Pack.WriteList(body, record.k)
        else
            body:Byte(0)
        end
    end
    writer:Str(body:Result())
end

function Pack.ReadRecord(reader, protocol)
    reader = reader:Sub(reader:UInt())
    local guid = reader:Str()
    local record = { n = reader:Str(), t = reader:UInt(), av = reader:UInt(), rl = reader:Str(), v = reader:Str(Pack.LIMITS.note) }
    if record.n == "" then
        record.n = nil
    end
    if record.rl == "" then
        record.rl = nil
    end
    if protocol ~= "2" and reader:Byte() == 1 then
        record.k = Pack.ReadList(reader, 100)
    end
    return guid, record
end

Data.STATS = 2

-- Known list first, then its length.
function Data.Stats(record)
    return record.k and 1 or 0, record.k and #record.k or 0
end

function Data.CleanRecord(record, now)
    local clean = Data.CleanBase(record, now)
    if not clean then
        return nil
    end
    clean.v = type(record.v) == "string" and record.v:sub(1, Pack.LIMITS.note) or ""
    if record.k ~= nil then
        if type(record.k) ~= "table" then
            return nil
        end
        clean.k = {}
        for i, id in ipairs(record.k) do
            if not Lib.IsID(id) then
                return nil
            end
            clean.k[i] = id
        end
    end
    return clean
end

function Data.CarryMissing(kept, other)
    if kept.k == nil and other.k ~= nil then
        kept.k = other.k
        return true
    end
    return false
end

function Data.AdoptOwn(own, record)
    return Data.CarryMissing(own, record)
end

-- Our record ----------------------------------------------------------------------------

function ns.SetOwn(v, k)
    local record = Data.GetOwnRecord(true)
    record.v, record.k = v, k
    Data.TouchOwn(record)
end

-- Stamped once the guild is known.
function ns.Sync.OwnReady()
    return ns.ready == true
end

local function Ready()
    local record = Data.GetOwnRecord(true)
    if record and ns.Roster.ready then
        if not Data.IsShareable(record) or record.av ~= ns.VERSION_NUM then
            Data.TouchOwn(record)
        end
        ns.ready = true
    end
end

local events = CreateFrame("Frame")
ns.RegisterEvents(events, "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LOGOUT")
events:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" and name == ADDON_NAME then
        Data.Load()
    elseif event == "PLAYER_LOGIN" then
        Lib.Start(ns)
        ns.On("RosterUpdated", Ready)
    elseif event == "PLAYER_LOGOUT" then
        Data.PackForSave(ns.db)
    end
end)
