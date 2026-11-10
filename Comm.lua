-- Comm.lua: hidden addon messages between clients, one instance per addon.
--
-- Addon messages (SendAddonMessage / CHAT_MSG_ADDON) never show in any chat
-- window. GUILD reaches every online guild member; WHISPER reaches one, and
-- only under the name exactly as the server gave it as a sender (WoW
-- Forever refuses "Name Surname-Realm"), so senders are never rewritten.
--
-- A message is any packed string (see Pack.lua). It is compressed when that
-- helps, encoded as Base64 (messages may not contain NUL bytes) and split
-- into chunks of at most 255 bytes, each with a 6-character header:
--   [1] protocol version   [2] "z" compressed or "p" plain
--   [3-4] message id       [5] part number   [6] last part number
-- (the last four as Base64 digits, so a message has at most 64 parts).
-- Each addon sends on its own prefix (ns.PREFIX, heard on every prefix in
-- ns.LISTEN) with its own protocol (ns.PROTOCOL); messages of an older
-- protocol it still reads (ns.LEGACY) reach its handler with that protocol.
--
-- The server allows each prefix about 10 messages at once and 1 more per
-- second, and refuses addon messages during boss encounters, Mythic+ runs
-- and PvP matches. Chunks therefore wait in a queue that stays under those
-- limits and pauses while messaging is locked down.
local Lib = LibGuildSync

function Lib.NewComm(ns)
    local Pack = Lib.Pack
    local L = Lib.TextsFor(ns)

    local Comm = {}

    local PROTOCOL, LEGACY = ns.PROTOCOL, ns.LEGACY
    local HEADER = 6
    local CHUNK = 255 - HEADER
    local MAX_PARTS = 64
    local COMPRESS_MIN = 64      -- shorter messages are sent as they are
    local REASSEMBLY_TIMEOUT = 30
    local MAX_PENDING_PER_SENDER = 8
    local MAX_PENDING_BYTES = 200000
    local DUPLICATE_WINDOW = 5   -- short: a sender's message IDs restart after a /reload
    local LOCKDOWN_CHECK = 3

    local RESULT = Enum.SendAddonMessageResult or {}
    local R_SUCCESS = RESULT.Success or 0
    local R_THROTTLE = RESULT.AddonMessageThrottle or 3
    local R_CHANNEL_THROTTLE = RESULT.ChannelThrottle or 8
    local R_NOT_IN_GUILD = RESULT.NotInGuild or 10
    local R_LOCKDOWN = RESULT.AddOnMessageLockdown or 11
    local R_OFFLINE = RESULT.TargetOffline or 12

    local COMPRESSION = Enum.CompressionMethod and Enum.CompressionMethod.Zlib

    local floor, ceil = math.floor, math.ceil

    -- Encoding -------------------------------------------------------------------

    local Encoding = C_EncodingUtil or {}

    local function Compress(text)
        if #text < COMPRESS_MIN or not Encoding.CompressString then
            return text, false
        end
        local ok, out = pcall(Encoding.CompressString, text, COMPRESSION)
        if ok and type(out) == "string" and #out < #text then
            return out, true
        end
        return text, false
    end

    local function Decompress(text)
        if not Encoding.DecompressString then
            return nil
        end
        local ok, out = pcall(Encoding.DecompressString, text, COMPRESSION)
        if ok and type(out) == "string" then
            return out
        end
    end

    local function ToBase64(text)
        if Encoding.EncodeBase64 then
            local ok, out = pcall(Encoding.EncodeBase64, text)
            if ok and type(out) == "string" then
                return out
            end
        end
        return Pack.ToBase64(text)
    end

    local function FromBase64(text)
        if Encoding.DecodeBase64 then
            local ok, out = pcall(Encoding.DecodeBase64, text)
            if ok and type(out) == "string" then
                return out
            end
        end
        return Pack.FromBase64(text)
    end

    Comm.Compress, Comm.Decompress = Compress, Decompress
    Comm.ToBase64, Comm.FromBase64 = ToBase64, FromBase64

    -- Send queue ---------------------------------------------------------------------

    -- Lanes in priority order: short control messages, our own updates, then
    -- bulk sync data.
    local LANES = { "control", "own", "bulk" }
    local queue = { control = {}, own = {}, bulk = {} }

    -- Token buckets: tokens refill at rate per second up to cap. Whispers adapt
    -- their rate to the throttle answers they get.
    local buckets = {
        GUILD = { tokens = 8, cap = 8, rate = 1 },
        WHISPER = { tokens = 5, cap = 5, rate = 2, minRate = 0.5, maxRate = 4, successes = 0 },
    }

    local nextMessageID = math.random(0, 4095)
    local pausedUntil = 0
    local lastTick
    local ticker = CreateFrame("Frame")
    ticker:Hide()

    -- Names we whispered lately, to hide the "No player named..." line a
    -- whisper to someone who just logged out can cause.
    local recentWhispers = {}

    local function InLockdown()
        return ns.Try(C_ChatInfo.InChatMessagingLockdown) == true
    end

    local function QueueEmpty()
        for _, lane in ipairs(LANES) do
            if #queue[lane] > 0 then
                return false
            end
        end
        return true
    end

    function Comm.QueueSize()
        local messages, chunks = 0, 0
        for _, lane in ipairs(LANES) do
            for _, message in ipairs(queue[lane]) do
                messages = messages + 1
                chunks = chunks + #message.chunks - message.next + 1
            end
        end
        return messages, chunks
    end

    function Comm.IsPaused()
        return GetTime() < pausedUntil
    end

    function Comm.HasQueued(target)
        for _, lane in ipairs(LANES) do
            for _, message in ipairs(queue[lane]) do
                if message.target == target then
                    return true
                end
            end
        end
        return false
    end

    local function Finish(lane, index, message, sent)
        table.remove(queue[lane], index)
        if message.onDone then
            ns.SafeCall(message.onDone, sent)
        end
    end

    -- Drops every queued message for a target (it went offline).
    function Comm.DropTarget(target)
        for _, lane in ipairs(LANES) do
            for i = #queue[lane], 1, -1 do
                local message = queue[lane][i]
                if message.target == target then
                    Finish(lane, i, message, false)
                end
            end
        end
    end

    local function DropChannel(channel)
        for _, lane in ipairs(LANES) do
            for i = #queue[lane], 1, -1 do
                local message = queue[lane][i]
                if message.channel == channel then
                    Finish(lane, i, message, false)
                end
            end
        end
    end

    -- Sends the next chunk of message; false when it must wait.
    local function SendChunk(lane, index, message, now)
        local bucket = buckets[message.channel]
        local chunk = message.chunks[message.next]
        local ok, result = pcall(C_ChatInfo.SendAddonMessage, ns.PREFIX, chunk, message.channel, message.target)
        result = ns.Plain(result)
        if not ok then
            ns.Debug("send failed: %s", tostring(result))
            Finish(lane, index, message, false)
            return
        end
        if result == nil or result == true or result == R_SUCCESS then
            bucket.tokens = bucket.tokens - 1
            if message.target then
                recentWhispers[message.target] = now
            end
            if bucket.successes then
                bucket.successes = bucket.successes + 1
                if bucket.successes >= 20 and bucket.rate < bucket.maxRate then
                    bucket.rate = bucket.rate + 0.25
                    bucket.successes = 0
                end
            end
            message.next = message.next + 1
            if message.next > #message.chunks then
                Finish(lane, index, message, true)
            end
        elseif result == R_THROTTLE or result == R_CHANNEL_THROTTLE then
            bucket.tokens = 0
            message.retryAt = now + (result == R_THROTTLE and 1.5 or 3)
            if bucket.minRate then
                bucket.rate = math.max(bucket.minRate, bucket.rate / 2)
                bucket.successes = 0
            end
            ns.Debug("throttled (%d), waiting", result)
        elseif result == R_LOCKDOWN then
            pausedUntil = now + LOCKDOWN_CHECK
            ns.Debug("addon messages are locked down, pausing")
        elseif result == R_NOT_IN_GUILD and message.channel == "GUILD" then
            DropChannel("GUILD")
        elseif result == R_OFFLINE and message.target then
            local target = message.target
            Comm.DropTarget(target)
            ns.Fire("TargetOffline", target)
        else
            ns.Debug("message dropped, result %s", tostring(result))
            Finish(lane, index, message, false)
        end
    end

    local function Tick()
        local now = GetTime()
        local elapsed = now - (lastTick or now)
        lastTick = now
        for _, bucket in pairs(buckets) do
            bucket.tokens = math.min(bucket.cap, bucket.tokens + bucket.rate * elapsed)
        end
        if QueueEmpty() then
            ticker:Hide()
            lastTick = nil
            return
        end
        if now < pausedUntil then
            return
        end
        if InLockdown() then
            pausedUntil = now + LOCKDOWN_CHECK
            return
        end
        -- One chunk per frame at most: the first message, by lane, whose channel
        -- has a token and that is not waiting out a throttle answer.
        for _, lane in ipairs(LANES) do
            for index, message in ipairs(queue[lane]) do
                if buckets[message.channel].tokens >= 1 and (message.retryAt or 0) <= now then
                    SendChunk(lane, index, message, now)
                    return
                end
            end
        end
    end

    ticker:SetScript("OnUpdate", Tick)

    -- Queues payload (a packed string) for channel "GUILD" or "WHISPER" (with
    -- target). onDone(sent) runs once the last chunk went out, or the message
    -- was dropped. Returns false when the message is too big to send.
    function Comm.Send(payload, channel, target, lane, onDone)
        local body, compressed = Compress(payload)
        body = ToBase64(body)
        local parts = math.max(ceil(#body / CHUNK), 1)
        if parts > MAX_PARTS then
            ns.Debug("message too large (%d bytes)", #body)
            return false
        end
        local id = nextMessageID
        nextMessageID = (nextMessageID + 1) % 4096
        local header = PROTOCOL .. (compressed and "z" or "p") .. Pack.Digit(floor(id / 64)) .. Pack.Digit(id % 64)
        local chunks = {}
        for part = 0, parts - 1 do
            chunks[part + 1] = header .. Pack.Digit(part) .. Pack.Digit(parts - 1) .. body:sub(part * CHUNK + 1, (part + 1) * CHUNK)
        end
        table.insert(queue[lane or "bulk"], { chunks = chunks, next = 1, channel = channel, target = target, onDone = onDone })
        ticker:Show()
        return true
    end

    -- Receiving ------------------------------------------------------------------------

    local pending = {}      -- [sender] = { [id] = { parts, got, last, compressed, time, bytes } }
    local seenMessages = {} -- ["sender|id"] = time, to drop repeats
    local cleanupTicker
    local newerProtocolNoticed = false

    local function CleanUp()
        local now = GetTime()
        local anything = false
        for sender, messages in pairs(pending) do
            for id, message in pairs(messages) do
                if now - message.time > REASSEMBLY_TIMEOUT then
                    messages[id] = nil
                    ns.Debug("incomplete message from %s dropped", sender)
                else
                    anything = true
                end
            end
            if next(messages) == nil then
                pending[sender] = nil
            end
        end
        for key, time in pairs(seenMessages) do
            if now - time > DUPLICATE_WINDOW then
                seenMessages[key] = nil
            else
                anything = true
            end
        end
        if not anything and cleanupTicker then
            cleanupTicker:Cancel()
            cleanupTicker = nil
        end
    end

    local function EnsureCleanup()
        if not cleanupTicker then
            cleanupTicker = C_Timer.NewTicker(10, CleanUp)
        end
    end

    local function Deliver(sender, channel, compressed, body, protocol)
        local raw = FromBase64(body)
        if raw and compressed then
            raw = Decompress(raw)
        end
        if not raw or raw == "" then
            ns.Debug("unreadable message from %s", sender)
            return
        end
        if Comm.handler then
            local ok, err = pcall(Comm.handler, raw, sender, channel, protocol)
            if not ok then
                ns.Debug("bad message from %s: %s", sender, tostring(err))
            end
        end
    end

    local function OnChunk(text, channel, sender)
        local protocol = text:sub(1, 1)
        if protocol ~= PROTOCOL and not LEGACY[protocol] then
            if not newerProtocolNoticed and protocol > PROTOCOL then
                newerProtocolNoticed = true
                ns.Print(L["a guild member uses a newer version of %s that this one cannot talk to. Please update."], ns.TITLE)
            end
            return
        end
        if #text < HEADER then
            return
        end
        local flag = text:sub(2, 2)
        local high, low = Pack.DigitValue(text:sub(3, 3)), Pack.DigitValue(text:sub(4, 4))
        local part, last = Pack.DigitValue(text:sub(5, 5)), Pack.DigitValue(text:sub(6, 6))
        if (flag ~= "z" and flag ~= "p") or not (high and low and part and last) or part > last then
            return
        end
        local id = high * 64 + low
        local seenKey = sender .. "|" .. id
        local seenAt = seenMessages[seenKey]
        if seenAt and GetTime() - seenAt < DUPLICATE_WINDOW then
            return
        end
        local data = text:sub(HEADER + 1)
        if last == 0 then
            seenMessages[seenKey] = GetTime()
            EnsureCleanup()
            C_Timer.After(0, function()
                Deliver(sender, channel, flag == "z", data, protocol)
            end)
            return
        end

        local messages = pending[sender]
        if not messages then
            messages = {}
            pending[sender] = messages
        end
        local message = messages[id]
        if not message then
            local count, bytes = 0, 0
            for _, other in pairs(messages) do
                count = count + 1
                bytes = bytes + other.bytes
            end
            if count >= MAX_PENDING_PER_SENDER or bytes > MAX_PENDING_BYTES then
                return
            end
            message = { parts = {}, got = 0, last = last, compressed = flag == "z", bytes = 0, protocol = protocol }
            messages[id] = message
            EnsureCleanup()
        end
        if message.last ~= last or message.parts[part + 1] then
            return
        end
        message.parts[part + 1] = data
        message.got = message.got + 1
        message.bytes = message.bytes + #data
        message.time = GetTime()
        if message.got == last + 1 then
            messages[id] = nil
            seenMessages[seenKey] = GetTime()
            local body = table.concat(message.parts)
            C_Timer.After(0, function()
                Deliver(sender, channel, message.compressed, body, message.protocol)
            end)
        end
    end

    -- Hides "No player named 'X' is currently playing." for names we just
    -- whispered an addon message to.
    local function FilterOffline(_, _, message, ...)
        message = ns.Plain(message)
        if type(message) ~= "string" or not Comm.offlinePattern then
            return false
        end
        local name = message:match(Comm.offlinePattern)
        local whisperedAt = name and recentWhispers[name]
        if whisperedAt and GetTime() - whisperedAt < 10 then
            return true
        end
        return false
    end

    function Comm.Init()
        for prefix in pairs(ns.LISTEN) do
            local result = ns.Try(C_ChatInfo.RegisterAddonMessagePrefix, prefix)
            ns.Debug("prefix %s registered: %s", prefix, tostring(result))
        end

        if type(ERR_CHAT_PLAYER_NOT_FOUND_S) == "string" then
            local pattern = ERR_CHAT_PLAYER_NOT_FOUND_S:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)")
            Comm.offlinePattern = "^" .. pattern .. "$"
            local addFilter = ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter or ChatFrame_AddMessageEventFilter
            if addFilter then
                addFilter("CHAT_MSG_SYSTEM", FilterOffline)
            end
        end

        local events = CreateFrame("Frame")
        ns.RegisterEvents(events, "CHAT_MSG_ADDON")
        events:SetScript("OnEvent", function(_, _, prefix, text, channel, sender)
            prefix = ns.Plain(prefix)
            if not ns.LISTEN[prefix] then
                return
            end
            text, channel, sender = ns.Plain(text), ns.Plain(channel), ns.Plain(sender)
            if type(text) ~= "string" or type(sender) ~= "string" then
                return
            end
            -- The sender exactly as the server gives it: it is also the only form
            -- a whisper reaches. (WoW Forever gives "Name Surname", with no realm,
            -- and refuses whispers to "Name Surname-Realm".)
            local from = sender
            if ns.IsMe(from) then
                -- Our own GUILD messages come back to us.
                return
            end
            -- Anyone can whisper on our prefix: only guild members are heard,
            -- before anything is buffered or decompressed.
            if not ns.Roster.IsKnownSender(from) then
                return
            end
            OnChunk(text, channel, from)
        end)
    end
    return Comm
end
