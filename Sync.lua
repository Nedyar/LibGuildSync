-- Sync.lua: keeps every client's copy of an addon's guild data the same,
-- one instance per addon.
--
-- Members announce their own changes to the whole guild (U: their full
-- record). On top of that, a client that logs in compares its
-- data with whoever is online and fills in what it lacks:
--
--   1. The newcomer sends H(ello) to the guild with one digest per bucket of
--      members (see Store.lua, Data.Digests).
--   2. Every client whose digests differ waits a short delay, fixed for each
--      pair of names, and then sends O(ffer). Seeing someone else's offer
--      cancels its own, so normally a single client answers.
--   3. The newcomer whispers that client an M(anifest): which version of
--      each member's record it has (its time and Data.STATS numbers that say
--      how complete it is), for the buckets that differ.
--   4. The responder whispers back R(ecords) the newcomer lacks, Q(ueries)
--      the records the newcomer has newer, and E(nd).
--
-- When everybody already agrees, logging in costs a single message.
--
-- The addon tells it when its own record is ready to be announced
-- (Sync.OwnReady) and announces changes with ns.Fire("OwnChanged", kind),
-- kind being any short text of its own (nil for a change of any kind).
-- Optionally it adds:
--   Sync.QUICK_KINDS[kind] = true: changes announced within seconds, not
--       once things are quiet;
--   Sync.WriteOwnChange(record, state, pending): a shorter message for the
--       changes waiting (pending[kind] = true; state.sentT is the time of
--       the record last announced), made with Sync.Begin(type), or nil for
--       the whole record (U);
--   Sync.handlers[type] = function(reader, sender, guildKey, protocol): its
--       own message types (one byte each, other than "UHOMQRE");
--   Sync.LEGACY_TYPES[type] = true: the types heard from members on an
--       older protocol (ns.LEGACY), U only by default, since they cannot
--       read our replies.
local Lib = LibGuildSync

function Lib.NewSync(ns)
    local L = Lib.TextsFor(ns)
    local Pack, Data, Comm, Roster = ns.Pack, ns.Data, ns.Comm, ns.Roster

    local Sync = {}

    local T_UPDATE, T_HELLO, T_OFFER, T_MANIFEST, T_REQUEST, T_RECORDS, T_END = string.byte("UHOMQRE", 1, 7)

    local BROADCAST_QUIET = 30     -- own changes are sent once quiet this long...
    local BROADCAST_MAX_WAIT = 120 -- ...or this long after the first one
    local QUICK_QUIET = 2          -- ...or this long, for the addon's quick kinds
    local LOGIN_DELAY = { 8, 15 }  -- spreads the hellos of a login wave
    local HELLO_INTERVAL = 45 * 60 -- a hello now and then catches anything missed
    local HELLO_TIMEOUT = 15       -- how long a newcomer waits for an offer
    local OFFER_TIMEOUT = 20       -- how long a responder waits for the manifest
    local SESSION_IDLE = 60        -- a session ends after this long without traffic
    local MAX_SESSIONS = 2         -- newcomers one client serves at the same time
    local MAX_RECORDS = 300        -- records per session and direction
    local MAX_MANIFEST = 500
    local MANIFEST_BYTES = 11000   -- fits a message even when nothing compresses
    local BATCH_BYTES = 1200       -- packed record bytes per R message
    local MAX_ROUNDS = 3           -- extra hellos after a sync that changed something

    local hello                    -- our hello waiting for offers: { timer, manual }
    local joined                   -- the session we started: { peer, id, last, received, manual }
    local serving = {}             -- sessions we answer: [newcomer] = { id, state, last }
    local offerTimers = {}         -- [newcomer] = timer of our pending offer
    local rounds = 0
    local newerVersionNoticed = false
    local nextSessionID = math.random(1, 65535)
    local pending = {}             -- kinds of our changes not announced yet
    local quick = false            -- one of them is a quick kind

    Sync.QUICK_KINDS = {}
    Sync.LEGACY_TYPES = { [T_UPDATE] = true }

    -- Our own record has been brought up to date, so what we announce is
    -- current. The addon replaces this.
    function Sync.OwnReady()
        return true
    end

    local function InLockdown()
        return ns.Try(C_ChatInfo.InChatMessagingLockdown) == true
    end

    -- Every message starts with its type and a hash of the guild it is about.
    -- Without a guild (left mid-sync) the hash matches nobody's.
    local function Begin(kind)
        local writer = Pack.Writer()
        writer:Byte(kind)
        writer:UInt(Pack.Hash(Roster.guildKey or ""))
        return writer
    end
    Sync.Begin = Begin

    local function NoteVersion(version)
        if not newerVersionNoticed and type(version) == "number" and version > ns.VERSION_NUM and version < 1000000 then
            newerVersionNoticed = true
            ns.Print(L["a newer version of %s (%s) is in use in your guild."], ns.TITLE, ns.VersionString(version))
        end
    end

    local function InMask(mask, bucket)
        return math.floor(mask / 2 ^ (bucket - 1)) % 2 == 1
    end

    -- Members online who have shared data, i.e. who run the addon.
    local function OnlinePeers(guild)
        local count = 0
        for guid, record in pairs(guild.members) do
            if guid ~= ns.playerGUID and Data.IsShareable(record) and Roster.members[guid] and Roster.members[guid].on then
                count = count + 1
            end
        end
        return count
    end

    local function CountSessions()
        local count = 0
        for _ in pairs(serving) do
            count = count + 1
        end
        return count
    end

    -- Own changes --------------------------------------------------------------

    function Sync.BroadcastOwn()
        local guildKey = Roster.guildKey
        local record = Data.GetOwnRecord(false)
        if not guildKey or not Sync.OwnReady() or not Data.IsShareable(record) then
            return
        end
        local state = Data.OwnState()
        local fingerprint = Data.Fingerprint(ns.playerGUID, record)
        if state.sentFP == fingerprint and state.sentGuild == guildKey then
            wipe(pending)
            quick = false
            return
        end
        local writer = Sync.WriteOwnChange and next(pending) and Sync.WriteOwnChange(record, state, pending)
        if not writer then
            writer = Begin(T_UPDATE)
            Pack.WriteRecord(writer, ns.playerGUID, record)
        end
        if Comm.Send(writer:Result(), "GUILD", nil, "own") then
            state.sentFP, state.sentT, state.sentGuild = fingerprint, record.t, guildKey
            wipe(pending)
            quick = false
            ns.Debug("announced our character")
        end
    end

    local function OnOwnChanged(kind)
        pending[kind or "U"] = true
        quick = quick or Sync.QUICK_KINDS[kind] == true
        ns.Debounce("BroadcastOwn", quick and QUICK_QUIET or BROADCAST_QUIET, Sync.BroadcastOwn, BROADCAST_MAX_WAIT)
    end

    -- Sessions -------------------------------------------------------------------

    local sessionTicker

    local function EndJoined(reason)
        if not joined then
            return
        end
        local session = joined
        joined = nil
        ns.Debug("sync with %s ended (%s), %d records received", session.peer, reason, session.received)
        if session.manual then
            ns.Print(L["sync finished: %d |4record:records; received from %s."], session.received, ns.ShortName(session.peer))
        end
        -- Something changed, so other members may hold even newer data; or the
        -- sync was cut short. Either way, ask again in a while.
        if (session.received > 0 or reason ~= "done") and rounds < MAX_ROUNDS then
            rounds = rounds + 1
            C_Timer.After(90 + math.random() * 60, function()
                Sync.SendHello(false)
            end)
        end
    end

    local function CheckSessions()
        local now = GetTime()
        for newcomer, session in pairs(serving) do
            local limit = session.state == "offered" and OFFER_TIMEOUT or SESSION_IDLE
            if now - session.last > limit and not Comm.HasQueued(newcomer) then
                serving[newcomer] = nil
                ns.Debug("stopped serving %s", newcomer)
            end
        end
        if joined and now - joined.last > SESSION_IDLE and not Comm.HasQueued(joined.peer) then
            EndJoined("timeout")
        end
        if not joined and next(serving) == nil and sessionTicker then
            sessionTicker:Cancel()
            sessionTicker = nil
        end
    end

    local function WatchSessions()
        if not sessionTicker then
            sessionTicker = C_Timer.NewTicker(5, CheckSessions)
        end
    end

    local function SessionWith(peer, id)
        if joined and joined.peer == peer and joined.id == id then
            return joined
        end
        local session = serving[peer]
        if session and session.id == id then
            return session
        end
    end

    local function EndSessionsWith(peer)
        if offerTimers[peer] then
            offerTimers[peer]:Cancel()
            offerTimers[peer] = nil
        end
        serving[peer] = nil
        if joined and joined.peer == peer then
            EndJoined("offline")
        end
    end

    -- Whispers the records of keys to target, in batches. onDone(sent) runs
    -- after the last one went out (sent = true) or could not be sent.
    local function SendRecords(target, id, keys, onDone)
        local guild = Data.CurrentGuild()
        local messages, current = {}, nil
        for _, key in ipairs(keys) do
            local record = guild and guild.members[key]
            if Data.IsShareable(record) then
                local packed = Pack.RecordString(key, record)
                if current and current:Size() + #packed > BATCH_BYTES then
                    messages[#messages + 1] = current:Result()
                    current = nil
                end
                if not current then
                    current = Begin(T_RECORDS)
                    current:UInt(id)
                end
                current:Raw(packed)
            end
        end
        if current then
            messages[#messages + 1] = current:Result()
        end
        local allQueued = true
        for i, payload in ipairs(messages) do
            local isLast = i == #messages
            if not Comm.Send(payload, "WHISPER", target, "bulk", isLast and allQueued and onDone or nil) then
                allQueued = false
            end
        end
        if onDone and (#messages == 0 or not allQueued) then
            onDone(#messages == 0)
        end
        return #messages
    end

    -- Hello and offer ---------------------------------------------------------------

    function Sync.SendHello(manual)
        local guildKey = Roster.guildKey
        if not guildKey then
            if manual then
                ns.Print(L["you are not in a guild (or the guild has not loaded yet)."])
            end
            return
        end
        if hello or joined then
            if manual then
                ns.Print(L["a sync is already running."])
            end
            return
        end
        local digests, count = Data.Digests(Data.GetGuild(guildKey, true))
        local writer = Begin(T_HELLO)
        writer:UInt(count)
        writer:UInt(ns.VERSION_NUM)
        for i = 1, Data.BUCKETS do
            writer:UInt(digests[i])
        end
        -- Offers take longer to come when our own queue is busy.
        local timeout = HELLO_TIMEOUT + (Comm.QueueSize() > 0 and 30 or 0)
        Comm.Send(writer:Result(), "GUILD", nil, "control")
        hello = { manual = manual }
        hello.timer = C_Timer.NewTimer(timeout, function()
            if hello and hello.manual then
                ns.Print(L["nobody online has data you are missing."])
            end
            hello = nil
        end)
        if manual then
            rounds = 0
            ns.Print(L["asking the guild for missing data..."])
        end
        ns.Debug("hello sent (%d records)", count)
    end

    -- (The newcomer's hello proves they are online, whatever our copy of the
    -- roster says.)
    local function SendOffer(newcomer)
        local guild = Data.CurrentGuild(false)
        if serving[newcomer] or CountSessions() >= MAX_SESSIONS or not guild then
            return
        end
        nextSessionID = nextSessionID % 65535 + 1
        local digests = Data.Digests(guild)
        local writer = Begin(T_OFFER)
        writer:Str(newcomer)
        writer:UInt(nextSessionID)
        for i = 1, Data.BUCKETS do
            writer:UInt(digests[i])
        end
        Comm.Send(writer:Result(), "GUILD", nil, "control")
        serving[newcomer] = { id = nextSessionID, state = "offered", last = GetTime() }
        WatchSessions()
        ns.Debug("offered to sync %s", newcomer)
    end

    -- Tells the responder which versions we hold in the buckets that differ.
    local function SendManifest(peer, id, theirDigests)
        local guild = Data.CurrentGuild(true)
        local mine = Data.Digests(guild)
        local mask, differing = 0, {}
        for i = 1, Data.BUCKETS do
            if mine[i] ~= theirDigests[i] then
                mask = mask + 2 ^ (i - 1)
                differing[i] = true
            end
        end
        -- Entries are packed apart first so the manifest stays within one
        -- message; anything left out is caught by a later round.
        local body, count, size = Pack.Writer(), 0, 0
        Data.ForEachShared(guild, function(key, record)
            if differing[Data.BucketOf(key)] and count < MAX_MANIFEST and size < MANIFEST_BYTES then
                local entry = Pack.Writer()
                entry:Str(key)
                entry:UInt(record.t)
                for _, value in ipairs(Data.StatsOf(record)) do
                    entry:UInt(value)
                end
                local packed = entry:Result()
                body:Raw(packed)
                count, size = count + 1, size + #packed
            end
        end)
        local writer = Begin(T_MANIFEST)
        writer:UInt(id)
        writer:UInt(mask)
        writer:UInt(count)
        writer:Raw(body:Result())
        if not Comm.Send(writer:Result(), "WHISPER", peer, "bulk") then
            EndJoined("manifest too large")
        end
    end

    -- Incoming messages ---------------------------------------------------------------

    local handlers = {}

    handlers[T_UPDATE] = function(reader, sender, guildKey, protocol)
        local key, record = Pack.ReadRecord(reader, protocol)
        -- Only the member themselves may announce their record.
        if key ~= Roster.GUIDOfSender(sender) then
            return
        end
        NoteVersion(record.av)
        Data.Accept(guildKey, key, record, true)
    end

    handlers[T_HELLO] = function(reader, sender, guildKey)
        local count, version = reader:UInt(), reader:UInt()
        local theirs = {}
        for i = 1, Data.BUCKETS do
            theirs[i] = reader:UInt()
        end
        NoteVersion(version)
        if serving[sender] or offerTimers[sender] or CountSessions() >= MAX_SESSIONS or Comm.IsPaused() or InLockdown() then
            return
        end
        local guild = Data.GetGuild(guildKey)
        if not guild then
            return
        end
        local mine, myCount = Data.Digests(guild)
        local differs = false
        for i = 1, Data.BUCKETS do
            if mine[i] ~= theirs[i] then
                differs = true
            end
        end
        if not differs then
            return
        end
        -- The delay depends on both names, so different newcomers get different
        -- responders; clients holding less than the newcomer answer last. The
        -- more addon users online, the wider the spread, so that the first offer
        -- is heard before many others go out.
        local spread = math.min(math.max(OnlinePeers(guild) / 8, 1), 5)
        local delay = 0.25 + spread * (Pack.Hash(sender .. "|" .. ns.playerKey) % 1750) / 1000
        if myCount < count then
            delay = delay + 2 * spread
        end
        offerTimers[sender] = C_Timer.NewTimer(delay, function()
            offerTimers[sender] = nil
            SendOffer(sender)
        end)
    end

    handlers[T_OFFER] = function(reader, sender)
        local newcomer, id = reader:Str(), reader:UInt()
        local digests = {}
        for i = 1, Data.BUCKETS do
            digests[i] = reader:UInt()
        end
        -- Someone else answers that newcomer: our offer is not needed.
        if offerTimers[newcomer] then
            offerTimers[newcomer]:Cancel()
            offerTimers[newcomer] = nil
        end
        if not ns.IsMe(newcomer) or not hello or joined then
            return
        end
        hello.timer:Cancel()
        joined = { peer = sender, id = id, last = GetTime(), received = 0, manual = hello.manual }
        hello = nil
        WatchSessions()
        SendManifest(sender, id, digests)
        ns.Debug("syncing with %s", sender)
    end

    handlers[T_MANIFEST] = function(reader, sender, guildKey)
        local id = reader:UInt()
        local session = serving[sender]
        if not session or session.id ~= id or session.state ~= "offered" then
            return
        end
        session.state, session.last = "active", GetTime()
        local mask, count = reader:UInt(), reader:UInt()
        if count > MAX_MANIFEST then
            return
        end
        local theirs = {}
        for _ = 1, count do
            local key = reader:Str()
            local entry = { t = reader:UInt(), stats = {} }
            for i = 1, Data.STATS do
                entry.stats[i] = reader:UInt()
            end
            theirs[key] = entry
        end

        local guild = Data.GetGuild(guildKey, true)
        local toSend, toRequest = {}, {}
        Data.ForEachShared(guild, function(key, record)
            if InMask(mask, Data.BucketOf(key)) and #toSend < MAX_RECORDS then
                local entry = theirs[key]
                if not entry or Data.CompareVersions(record.t, Data.StatsOf(record), entry.t, entry.stats) > 0 then
                    toSend[#toSend + 1] = key
                end
            end
        end)
        for key, entry in pairs(theirs) do
            if #toRequest < MAX_RECORDS and Data.IsGUID(key) and Roster.IsKnownGUID(key) then
                local record = guild.members[key]
                local wanted = not Data.IsShareable(record)
                if not wanted then
                    wanted = Data.CompareVersions(entry.t, entry.stats, record.t, Data.StatsOf(record)) > 0
                end
                if wanted then
                    toRequest[#toRequest + 1] = key
                end
            end
        end

        if #toRequest > 0 then
            local writer = Begin(T_REQUEST)
            writer:UInt(id)
            writer:UInt(#toRequest)
            for _, key in ipairs(toRequest) do
                writer:Str(key)
            end
            Comm.Send(writer:Result(), "WHISPER", sender, "control")
        end
        SendRecords(sender, id, toSend, function(sent)
            -- Without END the newcomer times out and tries again later.
            if not sent then
                return
            end
            local writer = Begin(T_END)
            writer:UInt(id)
            writer:UInt(#toSend)
            Comm.Send(writer:Result(), "WHISPER", sender, "control")
            session.state, session.last = "done", GetTime()
        end)
        ns.Debug("serving %s: sending %d, asking for %d", sender, #toSend, #toRequest)
    end

    handlers[T_REQUEST] = function(reader, sender)
        local id = reader:UInt()
        local session = SessionWith(sender, id)
        if not session then
            return
        end
        session.last = GetTime()
        local count = reader:UInt()
        if count > MAX_RECORDS then
            return
        end
        local keys = {}
        for i = 1, count do
            keys[i] = reader:Str()
        end
        SendRecords(sender, id, keys)
    end

    handlers[T_RECORDS] = function(reader, sender, guildKey, protocol)
        local id = reader:UInt()
        local session = SessionWith(sender, id)
        if not session then
            return
        end
        session.last = GetTime()
        while not reader:AtEnd() do
            local key, record = Pack.ReadRecord(reader, protocol)
            if Roster.IsKnownGUID(key) and Data.Accept(guildKey, key, record, key == Roster.GUIDOfSender(sender)) then
                session.received = (session.received or 0) + 1
            end
        end
    end

    handlers[T_END] = function(reader, sender)
        local id = reader:UInt()
        if joined and joined.peer == sender and joined.id == id then
            EndJoined("done")
        end
    end

    Sync.handlers = handlers

    -- protocol: the one the message came in, for records of an older one.
    local function OnMessage(raw, sender, _, protocol)
        local guildKey = Roster.guildKey
        if not guildKey or not Roster.IsKnownSender(sender) then
            return
        end
        local reader = Pack.Reader(raw)
        local kind = reader:Byte()
        local handler = handlers[kind]
        if protocol and protocol ~= ns.PROTOCOL and not Sync.LEGACY_TYPES[kind] then
            return
        end
        if handler and reader:UInt() == Pack.Hash(guildKey) then
            handler(reader, sender, guildKey, protocol)
        end
    end

    -- Startup ------------------------------------------------------------------------

    local startTicker

    local function Start()
        if startTicker then
            return
        end
        local tries = 0
        startTicker = C_Timer.NewTicker(2, function()
            tries = tries + 1
            local ready = Roster.guildKey and Roster.ready and Sync.OwnReady() and not InLockdown()
            if ready or tries > 150 then
                startTicker:Cancel()
                startTicker = nil
            end
            if ready then
                C_Timer.After(LOGIN_DELAY[1] + math.random() * (LOGIN_DELAY[2] - LOGIN_DELAY[1]), function()
                    Sync.BroadcastOwn()
                    Sync.SendHello(false)
                end)
            end
        end)
    end

    local function Reset()
        for newcomer, timer in pairs(offerTimers) do
            timer:Cancel()
            offerTimers[newcomer] = nil
        end
        wipe(serving)
        if hello then
            hello.timer:Cancel()
            hello = nil
        end
        joined = nil
        rounds = 0
    end

    function Sync.Describe()
        local parts = {}
        if hello then
            parts[#parts + 1] = L["waiting for offers"]
        end
        if joined then
            parts[#parts + 1] = L["receiving from %s (%d |4record:records; so far)"]:format(ns.ShortName(joined.peer), joined.received)
        end
        local count = CountSessions()
        if count > 0 then
            parts[#parts + 1] = L["sending to %d |4member:members;"]:format(count)
        end
        local messages, chunks = Comm.QueueSize()
        if messages > 0 then
            parts[#parts + 1] = L["%d |4message:messages; queued (%d |4part:parts;)"]:format(messages, chunks)
        end
        if Comm.IsPaused() or InLockdown() then
            parts[#parts + 1] = L["paused: addon messages are blocked here"]
        end
        return #parts > 0 and table.concat(parts, "; ") or L["idle"]
    end

    function Sync.Init()
        Comm.handler = OnMessage
        ns.On("OwnChanged", OnOwnChanged)
        ns.On("TargetOffline", EndSessionsWith)
        ns.On("GuildChanged", function()
            Reset()
            Start()
        end)
        Start()
        C_Timer.NewTicker(HELLO_INTERVAL, function()
            C_Timer.After(math.random() * 300, function()
                if not IsInInstance() and not InCombatLockdown() then
                    Sync.SendHello(false)
                end
            end)
        end)
    end
    return Sync
end
