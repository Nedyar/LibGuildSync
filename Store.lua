-- Store.lua: an addon's saved database and the rules that merge what
-- different clients know into one view (its ns.Data), one instance per
-- addon.
--
-- <savedVariable> = {
--   schema = 1,
--   guilds = { ["Guild Name"] = {
--       seen = time,
--       members = { ["Player-1234-0ABCDEF0"] = record (on disk it is packed,
--           see Data.PackForSave) plus two local fields:
--               seen = last time the member was in the roster,
--               fh = true when the copy came from the member themselves } } },
--   settings = { locale... },
--   own = { [GUID] = what this account's characters keep for themselves },
--   ...and whatever the addon adds (Data.SanitizeExtra).
-- }
--
-- Members are known by GUID: WoW Forever names have spaces, the guild roster
-- gives them without a realm, and members of one guild live on different
-- realms. Guilds are known by name alone, because the realm the client gives
-- for a guild changes while the login loads.
--
-- Only a record's owner ever changes its contents, and the owner stamps each
-- change with a time (t) that always grows. Every client therefore keeps,
-- for each member, the copy that is newest (then the most complete), and
-- all clients end up with the same one.
--
-- Records hold t (time), av (addon version), n (name) and rl (realm), which
-- this file knows, plus the addon's own fields. The addon tells the rest:
--   ns.Pack.WriteRecord(writer, guid, record, ...) / ns.Pack.ReadRecord(reader,
--       protocol): its packed form;
--   Data.CleanRecord(record, now): a checked copy or nil (Data.CleanBase does
--       the common fields);
--   Data.Stats(record): Data.STATS numbers, how complete a copy is, compared
--       in order when two copies have the same time;
--   optionally Data.CarryMissing(kept, other) and Data.AdoptOwn(own, record)
--       (what a kept copy takes from another; true if it took any),
--       Data.NewOwnRecord(), Data.SanitizeExtra(clean, saved),
--       Data.PackExtra(db) and Data.OnPrune(guild, present, now);
--   and, for an addon that saved its records its own way before it used
--       the library, Data.UpgradeSaved(db) (an older saved form brought up
--       to date, in place, before it is checked), Data.SaveRecord(guid,
--       record) (what is saved for a record) and Data.LoadRecord(saved, key)
--       (guid, record from what was saved under key).
local Lib = LibGuildSync

function Lib.NewStore(ns)
    local Pack = ns.Pack

    local Data = {}

    Data.SCHEMA = 1
    Data.BUCKETS = 16
    Data.STATS = 1

    local DAY = 86400
    local MEMBER_TTL = 30 * DAY   -- members unseen in the roster this long are dropped
    local GUILD_TTL = 180 * DAY   -- guilds not visited this long are dropped
    local FUTURE_SLACK = 300      -- how far a record's time may run ahead of ours

    Data.IsGUID = Lib.IsGUID
    Data.CleanName = Lib.CleanName

    local function IsGuildKey(key)
        return type(key) == "string" and key ~= "" and #key <= 64 and not key:find("|", 1, true)
    end

    -- Records whose owner never stamped them are not shared or compared.
    function Data.IsShareable(record)
        return record ~= nil and record.t >= Lib.MIN_TIME
    end

    -- The common fields of a record, checked: a new table with t, av, n, rl
    -- and the local seen and fh, or nil when it cannot be trusted. now is
    -- given for records from other clients, which may not be dated in the
    -- future.
    function Data.CleanBase(record, now)
        if type(record) ~= "table" then
            return nil
        end
        local t = record.t
        if type(t) ~= "number" or t ~= t or t < Lib.MIN_TIME or t >= 1e12 or (now and t > now + FUTURE_SLACK) then
            return nil
        end
        local clean = {
            t = math.floor(t),
            av = Lib.IsCount(record.av, 999999) and record.av or 0,
            n = Lib.CleanName(record.n),
            rl = Lib.CleanName(record.rl),
        }
        if type(record.seen) == "number" then
            clean.seen = record.seen
        end
        if record.fh == true then
            clean.fh = true
        end
        return clean
    end

    -- The addon replaces these two.
    function Data.CleanRecord(record, now)
        return Data.CleanBase(record, now)
    end

    function Data.Stats()
        return 0
    end

    -- Comparing and merging --------------------------------------------------------

    function Data.StatsOf(record)
        return { Data.Stats(record) }
    end

    -- Positive when the first copy is the one to keep: the newer one, then
    -- the more complete, comparing its stats in order.
    function Data.CompareVersions(t1, stats1, t2, stats2)
        if t1 ~= t2 then
            return t1 > t2 and 1 or -1
        end
        for i = 1, Data.STATS do
            local a, b = stats1[i] or 0, stats2[i] or 0
            if a ~= b then
                return a > b and 1 or -1
            end
        end
        return 0
    end

    function Data.Compare(a, b)
        return Data.CompareVersions(a.t, Data.StatsOf(a), b.t, Data.StatsOf(b))
    end

    -- The copy kept of a member takes what it lacks from the other copy (see
    -- the addon's Data.CarryMissing), and its name and realm. Returns true
    -- if it took any of the addon's data.
    local function CarryMissing(kept, other)
        local changed = Data.CarryMissing and Data.CarryMissing(kept, other) or false
        kept.n = kept.n or other.n
        kept.rl = kept.rl or other.rl
        return changed
    end

    -- Stores a cleaned record. firsthand: it came from its owner, so it
    -- replaces any older copy. Returns true when the stored data changed.
    -- Our own record is only ever changed by us, but what we lost can come
    -- back from the guild (the addon's Data.AdoptOwn).
    function Data.MergeRecord(guild, guid, record, firsthand)
        local old = guild.members[guid]
        if old and guid == ns.playerGUID then
            return Data.AdoptOwn and Data.AdoptOwn(old, record) or false
        end
        if old then
            local wins
            if firsthand then
                wins = record.t >= old.t
            else
                wins = Data.Compare(record, old) > 0
            end
            if not wins then
                return CarryMissing(old, record)
            end
            CarryMissing(record, old)
        end
        record.seen = math.max(record.seen or 0, old and old.seen or 0, Lib.Now())
        record.fh = firsthand or nil
        guild.members[guid] = record
        return true
    end

    -- The guild database ----------------------------------------------------------

    local function NewDB()
        return { schema = Data.SCHEMA, guilds = {}, settings = {}, own = {} }
    end

    -- Keeps the better of two copies of a member (both cleaned).
    local function MergeCopies(members, guid, record)
        local old = members[guid]
        if not old or Data.Compare(record, old) > 0 then
            if old then
                CarryMissing(record, old)
                record.seen = math.max(record.seen or 0, old.seen or 0)
            end
            members[guid] = record
        else
            CarryMissing(old, record)
            old.seen = math.max(old.seen or 0, record.seen or 0)
        end
    end

    -- Records are saved packed (see Data.PackForSave): the client writes
    -- each number of a plain table on its own line, ten times the size.
    -- An addon may save them its own way (Data.SaveRecord, Data.LoadRecord).
    local packedForms = setmetatable({}, { __mode = "k" })

    local function PackRecord(guid, record)
        if Data.SaveRecord then
            return Data.SaveRecord(guid, record)
        end
        return { b = Pack.ToBase64(Pack.RecordString(guid, record)), seen = record.seen, fh = record.fh }
    end

    local function UnpackRecord(saved, key)
        if Data.LoadRecord then
            return Data.LoadRecord(saved, key)
        end
        if type(saved) ~= "table" or type(saved.b) ~= "string" then
            return nil
        end
        local raw = Pack.FromBase64(saved.b)
        if not raw then
            return nil
        end
        local ok, guid, record = pcall(Pack.ReadRecord, Pack.Reader(raw))
        if not ok or type(record) ~= "table" then
            return nil
        end
        record.seen, record.fh = saved.seen, saved.fh
        return guid, record
    end

    -- Checks a database read from disk and returns a clean copy.
    function Data.Sanitize(db)
        local clean = NewDB()
        if type(db) ~= "table" then
            if Data.SanitizeExtra then
                Data.SanitizeExtra(clean, {})
            end
            return clean
        end
        if Data.UpgradeSaved then
            Data.UpgradeSaved(db)
        end
        if type(db.guilds) == "table" then
            for guildKey, guild in pairs(db.guilds) do
                if IsGuildKey(guildKey) and type(guild) == "table" then
                    local cleanGuild = { seen = type(guild.seen) == "number" and guild.seen or 0, members = {} }
                    if type(guild.members) == "table" then
                        for key, saved in pairs(guild.members) do
                            local guid, record = UnpackRecord(saved, key)
                            local cleanRecord = guid == key and Data.IsGUID(guid) and Data.CleanRecord(record)
                            if cleanRecord then
                                MergeCopies(cleanGuild.members, guid, cleanRecord)
                            end
                        end
                    end
                    clean.guilds[guildKey] = cleanGuild
                end
            end
        end
        if type(db.settings) == "table" then
            clean.settings = db.settings
        end
        if type(db.own) == "table" then
            for guid, state in pairs(db.own) do
                if Data.IsGUID(guid) and type(state) == "table" then
                    clean.own[guid] = state
                end
            end
        end
        if Data.SanitizeExtra then
            Data.SanitizeExtra(clean, db)
        end
        return clean
    end

    -- Runs at ADDON_LOADED, once the client has loaded the saved variables.
    function Data.Load()
        local native = _G[ns.SAVED]
        ns.loadInfo = { native = type(native) == "table" }
        local db = Data.Sanitize(native)
        _G[ns.SAVED] = db
        ns.db = db
    end

    -- Runs at logout, right before the client writes the saved variables.
    function Data.PackForSave(db)
        for _, guild in pairs(db.guilds) do
            for guid, record in pairs(guild.members) do
                -- Packing twice (a second logout event) changes nothing.
                if not packedForms[record] then
                    local saved = PackRecord(guid, record)
                    packedForms[saved] = true
                    guild.members[guid] = saved
                end
            end
        end
        if Data.PackExtra then
            Data.PackExtra(db)
        end
    end

    function Data.GetGuild(guildKey, create)
        if not guildKey then
            return nil
        end
        local guild = ns.db.guilds[guildKey]
        if not guild and create then
            guild = { seen = Lib.Now(), members = {} }
            ns.db.guilds[guildKey] = guild
        end
        return guild
    end

    function Data.CurrentGuild(create)
        return Data.GetGuild(ns.Roster.guildKey, create)
    end

    -- Lookups that are rebuilt whenever the data changes (never saved).
    local digestCache = setmetatable({}, { __mode = "k" })

    -- Every change to a guild's data ends here.
    function Data.Changed(guild)
        if guild then
            digestCache[guild] = nil
        end
        ns.Debounce("DataChanged", 0.2, function()
            ns.Fire("DataChanged")
        end)
    end

    function Data.ForgetDigests()
        wipe(digestCache)
    end

    function Data.ResetGuild(guildKey)
        local guild = Data.GetGuild(guildKey)
        if not guild then
            return
        end
        -- Our own record stays: only we can tell what is in it.
        local own = ns.playerGUID and guild.members[ns.playerGUID]
        wipe(guild.members)
        if own then
            guild.members[ns.playerGUID] = own
        end
        Data.Changed(guild)
    end

    -- A record received from another client. firsthand: sent by its owner.
    function Data.Accept(guildKey, guid, record, firsthand)
        if not Data.IsGUID(guid) then
            return false
        end
        record = Data.CleanRecord(record, Lib.Now())
        if not record then
            ns.Debug("rejected the record of %s", guid)
            return false
        end
        local guild = Data.GetGuild(guildKey, true)
        local changed = Data.MergeRecord(guild, guid, record, firsthand)
        if changed then
            Data.Changed(guild)
            ns.Fire("RecordChanged", guid, guild.members[guid])
            if guid == ns.playerGUID then
                ns.Fire("OwnChanged")
            end
        end
        return changed
    end

    -- The name to show for a member: the roster's, else the one they shared.
    function Data.NameOf(guid, record)
        return ns.Roster.NameOf(guid) or (record and record.n) or guid
    end

    -- Finds a member by what the user typed ("Name", "name", "Name-Realm"):
    -- the roster's names first, then the names members shared. Returns the
    -- GUID.
    function Data.FindByName(guild, text)
        local wanted = strtrim(text):match("^([^%-]+)") or text
        wanted = strtrim(wanted):lower()
        for guid, member in pairs(ns.Roster.members) do
            if member.n and member.n:lower() == wanted then
                return guid
            end
        end
        for guid, record in pairs(guild and guild.members or {}) do
            if record.n and record.n:lower() == wanted then
                return guid
            end
        end
    end

    -- After a complete roster read (Roster.lua): members present are marked
    -- as seen, members gone for a month are dropped, and so are guilds
    -- unvisited for half a year.
    function Data.Prune(guildKey, present)
        local guild = Data.GetGuild(guildKey, true)
        local now = Lib.Now()
        local changed = false
        guild.seen = now
        for guid, record in pairs(guild.members) do
            if present[guid] then
                record.seen = now
            elseif (record.seen or record.t) < now - MEMBER_TTL then
                guild.members[guid] = nil
                changed = true
            end
        end
        for otherKey, other in pairs(ns.db.guilds) do
            if otherKey ~= guildKey and other.seen < now - GUILD_TTL then
                ns.db.guilds[otherKey] = nil
            end
        end
        if Data.OnPrune then
            Data.OnPrune(guild, present, now)
        end
        if changed then
            Data.Changed(guild)
        end
    end

    -- Our own record ----------------------------------------------------------------

    -- The current character's record in the current guild. create: make it
    -- when missing (Data.NewOwnRecord, or an empty one).
    function Data.GetOwnRecord(create)
        local guild = Data.CurrentGuild(create)
        if not guild or not ns.playerGUID then
            return nil
        end
        local record = guild.members[ns.playerGUID]
        if not record and create then
            record = Data.NewOwnRecord and Data.NewOwnRecord() or { t = 0 }
            guild.members[ns.playerGUID] = record
        end
        return record
    end

    -- Stamps a change to our own record. kind (optional) says what changed,
    -- for the addon's own ways of announcing it (see Sync.lua).
    function Data.TouchOwn(record, kind)
        local now = Lib.Now()
        record.t = math.max(now, (record.t or 0) + 1)
        record.av = ns.VERSION_NUM
        record.n = Lib.CleanName(ns.playerName) or record.n
        record.rl = Lib.CleanName(ns.realm) or record.rl
        record.fh = true
        record.seen = now
        local guild = Data.CurrentGuild()
        Data.Changed(guild)
        ns.Fire("RecordChanged", ns.playerGUID, record)
        ns.Fire("OwnChanged", kind)
    end

    -- What this account keeps for the current character (never shared).
    function Data.OwnState()
        local state = ns.db.own[ns.playerGUID]
        if not state then
            state = {}
            ns.db.own[ns.playerGUID] = state
        end
        return state
    end

    -- Sync helpers ----------------------------------------------------------------

    function Data.BucketOf(guid)
        return Pack.Hash(guid) % Data.BUCKETS + 1
    end

    -- Identifies one version of a member's record.
    function Data.VersionHash(guid, t, stats)
        return Pack.Hash(guid .. "|" .. t .. "|" .. table.concat(stats, "|"))
    end

    function Data.Fingerprint(guid, record)
        return Pack.Hash(Pack.RecordString(guid, record))
    end

    -- The records worth comparing with other clients: shareable ones of
    -- members who are still in the guild.
    function Data.ForEachShared(guild, callback)
        for guid, record in pairs(guild.members) do
            if Data.IsShareable(record) and ns.Roster.IsKnownGUID(guid) then
                callback(guid, record)
            end
        end
    end

    -- One number per bucket summing up the versions of the records in it.
    -- Two clients with the same digests hold the same data.
    function Data.Digests(guild)
        local cached = digestCache[guild]
        if cached then
            return cached.digests, cached.count
        end
        local digests, count = {}, 0
        for i = 1, Data.BUCKETS do
            digests[i] = 0
        end
        Data.ForEachShared(guild, function(guid, record)
            local bucket = Data.BucketOf(guid)
            digests[bucket] = Pack.AddHash(digests[bucket], Data.VersionHash(guid, record.t, Data.StatsOf(record)))
            count = count + 1
        end)
        digestCache[guild] = { digests = digests, count = count }
        return digests, count
    end

    return Data
end
