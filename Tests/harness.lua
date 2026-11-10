-- Test harness for LibGuildSync and the guild addons built on it: a fake
-- world with a virtual clock, a guild roster and a server that delivers
-- addon messages between clients. Each client loads the real files of
-- LibGuildSync and then of the addon under test into its own environment,
-- as the game loads an addon after the addons it depends on.
--
-- Set ADDON_PATH and ADDON_NAME (the addon under test: its folder and its
-- name) and LIB_PATH (LibGuildSync's folder) before loading this file.
local H = {}

H.ADDON = assert(ADDON_PATH, "set ADDON_PATH")
H.LIB = assert(LIB_PATH, "set LIB_PATH")

-- An addon's TOC fields and files, in the TOC's order.
local function ReadToc(path, name)
    local addon = { name = name, path = path, files = {}, fields = {}, saved = {} }
    for line in io.lines(path .. "/" .. name .. ".toc") do
        line = line:gsub("\r$", "")
        local field, value = line:match("^## ([%w%-]+): (.*)$")
        if field then
            addon.fields[field] = value
        elseif line ~= "" and not line:find("^#") then
            addon.files[#addon.files + 1] = (line:gsub("\\", "/"))
        end
    end
    for variable in (addon.fields.SavedVariables or ""):gmatch("[%w_]+") do
        addon.saved[#addon.saved + 1] = variable
    end
    return addon
end

-- What each client loads: the library, then the addon under test.
H.ADDONS = { ReadToc(H.LIB, "LibGuildSync"), ReadToc(H.ADDON, assert(ADDON_NAME, "set ADDON_NAME")) }
H.MAIN = H.ADDONS[2]
H.NAME = H.MAIN.name
-- The addon under test's files.
H.FILES = H.MAIN.files

-- Assertions ------------------------------------------------------------------

H.passes, H.failures = 0, 0

function H.check(condition, message)
    if condition then
        H.passes = H.passes + 1
    else
        H.failures = H.failures + 1
        print("  FAIL: " .. message)
    end
    return condition
end

function H.eq(actual, expected, message)
    return H.check(actual == expected, ("%s (got %s, expected %s)"):format(message, tostring(actual), tostring(expected)))
end

function H.section(name)
    print("== " .. name)
end

function H.DeepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[H.DeepCopy(k)] = H.DeepCopy(v)
    end
    return copy
end

function H.SameList(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

-- Independent Base64 (to cross-check the addon's own) -----------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function Enc64(s)
    local out = {}
    for i = 1, #s, 3 do
        local chunk = s:sub(i, i + 2)
        local bits = ""
        for j = 1, #chunk do
            local b = chunk:byte(j)
            for k = 7, 0, -1 do
                bits = bits .. (math.floor(b / 2 ^ k) % 2)
            end
        end
        while #bits % 6 ~= 0 do
            bits = bits .. "0"
        end
        for j = 1, #bits, 6 do
            out[#out + 1] = B64:sub(tonumber(bits:sub(j, j + 5), 2) + 1, tonumber(bits:sub(j, j + 5), 2) + 1)
        end
        out[#out + 1] = ("="):rep(3 - #chunk)
    end
    return table.concat(out)
end
local function Dec64(s)
    s = s:gsub("=", "")
    local bits = ""
    for i = 1, #s do
        local v = B64:find(s:sub(i, i), 1, true) - 1
        for k = 5, 0, -1 do
            bits = bits .. (math.floor(v / 2 ^ k) % 2)
        end
    end
    local out = {}
    for i = 1, #bits - 7, 8 do
        out[#out + 1] = string.char(tonumber(bits:sub(i, i + 7), 2))
    end
    return table.concat(out)
end
H.Enc64, H.Dec64 = Enc64, Dec64

-- World -------------------------------------------------------------------------

local World = {}
World.__index = World

function H.NewWorld(options)
    options = options or {}
    math.randomseed(options.seed or 1)
    local world = setmetatable({
        now = 0,
        base = 1760000000,
        timers = {},
        seq = 0,
        clients = {},
        roster = {},
        guildName = "Test Guild",
        realm = "TestRealm",
        errors = {},
        dict = {},
        lastDelivery = {},
        jitter = options.jitter or 0.15,
        senderFormat = options.senderFormat or "full",
        -- WoW Forever's roster gives names without a realm; "full" adds it.
        rosterNames = options.rosterNames or "short",
        guildRealm = options.guildRealm or "TestRealm",
        realmIDs = { TestRealm = 1 },
        encoding = options.encoding or "native", -- "native" or "none"
        compress = options.compress ~= false,
        whisperLimit = options.whisperLimit,
        communities = options.communities,
        strictWhispers = options.strictWhispers,
        systemShown = {},
        log = {},
        stats = { sent = 0, guild = 0, whisper = 0, throttled = 0, types = {} },
    }, World)
    return world
end

function World:Schedule(delay, fn, owner)
    self.seq = self.seq + 1
    local timer = { at = self.now + math.max(delay or 0, 0), seq = self.seq, fn = fn, owner = owner }
    self.timers[#self.timers + 1] = timer
    return timer
end

function World:Protect(label, fn, ...)
    local args, n = { ... }, select("#", ...)
    local ok, err = xpcall(function()
        return fn(unpack(args, 1, n))
    end, debug.traceback)
    if not ok then
        self.errors[#self.errors + 1] = label .. ": " .. tostring(err)
    end
end

function World:Step(dt)
    self.now = self.now + dt
    local due, keep = {}, {}
    for _, timer in ipairs(self.timers) do
        if not timer.cancelled then
            if timer.at <= self.now + 1e-9 then
                due[#due + 1] = timer
            else
                keep[#keep + 1] = timer
            end
        end
    end
    self.timers = keep
    table.sort(due, function(a, b)
        if a.at ~= b.at then
            return a.at < b.at
        end
        return a.seq < b.seq
    end)
    for _, timer in ipairs(due) do
        if not timer.cancelled then
            self:Protect("timer", timer.fn)
        end
    end
    for _, client in ipairs(self.clients) do
        if client.loggedIn then
            for frame in pairs(client.updateFrames) do
                if frame._shown and frame._scripts.OnUpdate then
                    self:Protect(client.name .. " OnUpdate", frame._scripts.OnUpdate, frame, dt)
                end
            end
        end
    end
end

function World:RunFor(seconds, dt)
    dt = dt or 0.05
    local stop = self.now + seconds
    while self.now < stop - 1e-9 do
        self:Step(dt)
    end
end

-- Runs until done() is true (checked every second) or the time runs out.
function World:RunUntil(done, maxSeconds)
    local stop = self.now + maxSeconds
    while self.now < stop do
        self:RunFor(1)
        if done() then
            return true
        end
    end
    return false
end

-- Fake frames ---------------------------------------------------------------------

local function NewObject(client, objectType)
    local object = { _scripts = {}, _shown = true, _type = objectType, _client = client, _points = {} }
    return setmetatable(object, {
        __index = function(self, key)
            local method = H.FrameMethods[key]
            if method then
                return method
            end
            -- Other widget methods do nothing; like a real frame, any other
            -- key is nil.
            if H.NoOpMethods[key] then
                return H.NoOp
            end
            return nil
        end,
    })
end

H.NewObject = NewObject

H.NoOp = function()
    return nil
end
H.NoOpMethods = {}
for name in ([[AddLine ClearAllPoints EnableMouse HighlightText RegisterForClicks RegisterForDrag SetAllPoints
    SetAutoFocus SetClampedToScreen SetColorTexture SetDesaturated SetElementExtent SetFocus
    SetFontObject SetFrameStrata SetHeight SetHighlightTexture SetItemByID SetJustifyH SetMinMaxValues
    SetMovable SetMultiLine SetOwner SetPortraitToAsset SetScrollChild SetHitRectInsets
    SetSize SetSpacing SetSpellByID SetStatusBarColor SetStatusBarTexture SetTexCoord SetTexture SetTitle
    SetToplevel SetValue SetWidth SetWordWrap StartMoving StopMovingOrSizing SetMaxLetters SetMaxBytes
    SetDataProvider SetElementInitializer SetElementExtentCalculator SetFrameLevel SetAtlas SetBlendMode
    SetTextColor SetVertexColor SetNumeric ClearFocus SetTextInsets SetHorizTile SetVertTile]]):gmatch("%a+") do
    H.NoOpMethods[name] = true
end

-- Regions that Blizzard's templates give a frame, by template.
H.TemplateRegions = {
    RightSideTabTemplate = { Icon = "Texture", IconOverlay = "Texture" },
}

H.FrameMethods = {
    RegisterEvent = function(self, event)
        local client = self._client
        client.eventFrames[event] = client.eventFrames[event] or {}
        client.eventFrames[event][self] = true
    end,
    UnregisterEvent = function(self, event)
        local frames = self._client.eventFrames[event]
        if frames then
            frames[self] = nil
        end
    end,
    SetScript = function(self, name, fn)
        self._scripts[name] = fn
        if name == "OnUpdate" then
            self._client.updateFrames[self] = true
        end
    end,
    HookScript = function(self, name, fn)
        local old = self._scripts[name]
        self._scripts[name] = function(...)
            if old then
                old(...)
            end
            fn(...)
        end
    end,
    GetScript = function(self, name)
        return self._scripts[name]
    end,
    Show = function(self)
        self._shown = true
    end,
    Hide = function(self)
        self._shown = false
    end,
    SetShown = function(self, shown)
        self._shown = shown and true or false
    end,
    IsShown = function(self)
        return self._shown
    end,
    IsVisible = function(self)
        return self._shown
    end,
    CreateTexture = function(self)
        return NewObject(self._client, "Texture")
    end,
    CreateFontString = function(self)
        return NewObject(self._client, "FontString")
    end,
    GetName = function(self)
        return self._name
    end,
    GetText = function(self)
        return self._text
    end,
    SetText = function(self, text)
        self._text = text
    end,
    -- About 6 pixels per character.
    GetTextWidth = function(self)
        return 6 * #(self._text or "")
    end,
    GetStringWidth = function(self)
        return 6 * #(self._text or "")
    end,
    -- Frames have no size in the tests.
    GetWidth = function()
        return 0
    end,
    GetHeight = function()
        return 0
    end,
    SetScale = function(self, scale)
        self._scale = scale
    end,
    -- The last anchor set, and the enabled, checked and alpha states, for
    -- the tests to check.
    SetPoint = function(self, ...)
        self._point = { ... }
    end,
    SetEnabled = function(self, enabled)
        self._enabled = enabled and true or false
    end,
    IsEnabled = function(self)
        return self._enabled ~= false
    end,
    SetChecked = function(self, checked)
        self._checked = checked and true or false
    end,
    GetChecked = function(self)
        return self._checked == true
    end,
    SetAlpha = function(self, alpha)
        self._alpha = alpha
    end,
    GetAlpha = function(self)
        return self._alpha or 1
    end,
    SetID = function(self, id)
        self._id = id
    end,
    GetID = function(self)
        return self._id or 0
    end,
    SetMotionScriptsWhileDisabled = function(self, on)
        self._motionWhileDisabled = on and true or false
    end,
    -- Clicks in the tests land where they are aimed.
    IsMouseOver = function()
        return true
    end,
}

-- Blizzard's menus (Blizzard_Menu), as a dropdown builds them: the entries
-- its generator makes, in order.
function H.NewMenuDescription()
    local description = { entries = {} }
    function description:CreateRadio(text, isSelected, setSelected, data)
        local entry = { kind = "radio", text = text, isSelected = isSelected, setSelected = setSelected, data = data }
        self.entries[#self.entries + 1] = entry
        return entry
    end
    function description:CreateCheckbox(text, isSelected, setSelected, data)
        local entry = { kind = "checkbox", text = text, isSelected = isSelected, setSelected = setSelected, data = data }
        self.entries[#self.entries + 1] = entry
        return entry
    end
    return description
end

-- A dropdown's menu (WowStyle1DropdownTemplate): SetupMenu builds it right
-- away, GenerateMenu again; the text is the selected radio's.
H.FrameMethods.SetupMenu = function(self, generator)
    self._menuGenerator = generator
    self:GenerateMenu()
end
H.FrameMethods.GenerateMenu = function(self)
    local root = H.NewMenuDescription()
    self._menuGenerator(self, root)
    self._menu = root.entries
    self._text = nil
    for _, entry in ipairs(root.entries) do
        if entry.kind == "radio" and entry.isSelected(entry.data) then
            self._text = entry.text
        end
    end
end

-- A stand-in for Blizzard's guild window (CommunitiesFrame): its side tabs,
-- the communities list, the chat, and its display mode.
H.BLIZZARD_TABS = { "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab", "GuildPreferredPlaySettingsTab" }

function H.FakeCommunities(client)
    local frame = H.NewObject(client, "Frame")
    for _, key in ipairs(H.BLIZZARD_TABS) do
        frame[key] = H.NewObject(client, "CheckButton")
    end
    frame.GuildBenefitsTab:Hide()
    frame.GuildPreferredPlaySettingsTab:Hide()
    rawset(frame, "UpdateCommunitiesTabs", function() end)
    frame.CommunitiesList = H.NewObject(client, "Frame")
    frame.Chat = H.NewObject(client, "Frame")
    frame.Chat.ScrollBar = H.NewObject(client, "EventFrame")
    -- Pieces of the views, which an addon's panel makes invisible.
    frame.MemberList = H.NewObject(client, "Frame")
    frame.GuildDetailsFrame = H.NewObject(client, "Frame")
    frame.displayMode = "Roster"
    frame.RosterTab:SetChecked(true)
    -- Like the game's, setting the same view again does nothing.
    rawset(frame, "SetDisplayMode", function(self, mode)
        if self.displayMode == mode then
            return
        end
        self.displayMode = mode
        for _, key in ipairs(H.BLIZZARD_TABS) do
            self[key]:SetChecked(key == mode .. "Tab")
        end
    end)
    return frame
end

-- Clients -------------------------------------------------------------------------

function World:RealmID(realm)
    if not self.realmIDs[realm] then
        local count = 0
        for _ in pairs(self.realmIDs) do
            count = count + 1
        end
        self.realmIDs[realm] = count + 1
    end
    return self.realmIDs[realm]
end

H.CLASS_FILES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", nil, "SHAMAN", "MAGE", "WARLOCK", nil, "DRUID" }
-- options.realm: the character's realm (members of a guild can be on several).
-- In the roster: level, classID, rank, rankIndex, note.
function World:NewClient(name, options)
    options = options or {}
    local realm = options.realm or self.realm
    local client = {
        world = self,
        name = name,
        realm = realm,
        key = name .. "-" .. realm,
        guid = ("Player-%d-%08X"):format(self:RealmID(realm), #self.roster + 1),
        locale = options.locale or "enUS",
        level = options.level or 60,
        classID = options.classID or 3,
        eventFrames = {},
        updateFrames = {},
        printed = {},
        filters = {},
        bucket = { tokens = 10, last = 0 },
        inGuild = true,
        lockdown = false,
        saved = options.saved, -- the account's saved variables: { [variable] = value }
        globals = options.globals, -- set in the client's environment before its addons load
        -- What the character holds: containers by bag ID, as { size = slots,
        -- [slot] = { itemID, count, link } }; the bank tabs (6 to 14) can be
        -- read only while the bank is open (World:OpenBank).
        containers = options.containers or {},
        money = options.money or 0,
        bankTabs = options.bankTabs or { 6 },
        maxBankTabs = options.maxBankTabs or 4,
        -- The bag (item ID) in each bag slot (1 to 5) and each bank bag slot.
        bagItems = options.bagItems or {},
        bankBags = options.bankBags or {},
        inbox = {},
    }
    self.clients[#self.clients + 1] = client
    self.roster[#self.roster + 1] = {
        key = client.key, short = name, class = H.CLASS_FILES[client.classID], guid = client.guid, client = client,
        rank = options.rank or "Member", rankIndex = options.rankIndex or 3, note = options.note or "",
    }
    return client
end

-- A guild member who never logs in with the addon. options: class, level,
-- rank, rankIndex, note, offline = { years, months, days, hours }.
function World:AddMember(name, realm, options)
    options = options or {}
    realm = realm or self.realm
    local key = name .. "-" .. realm
    local guid = ("Player-%d-%08X"):format(self:RealmID(realm), #self.roster + 1)
    self.roster[#self.roster + 1] = {
        key = key, short = name, class = options.class or "WARRIOR", guid = guid, level = options.level,
        rank = options.rank or "Member", rankIndex = options.rankIndex or 3, note = options.note or "",
        offline = options.offline or { 0, 0, 2, 5 },
    }
    return key, guid
end

function World:RemoveMember(key)
    for i, member in ipairs(self.roster) do
        if member.key == key then
            table.remove(self.roster, i)
            return
        end
    end
end

function World:FindClient(target)
    for _, client in ipairs(self.clients) do
        if client.key == target or client.name == target then
            return client
        end
    end
end

function World:FireEvent(client, event, ...)
    local frames = client.eventFrames[event]
    if not frames then
        return
    end
    local list = {}
    for frame in pairs(frames) do
        list[#list + 1] = frame
    end
    for _, frame in ipairs(list) do
        if frame._scripts.OnEvent then
            self:Protect(client.name .. " " .. event, frame._scripts.OnEvent, frame, event, ...)
        end
    end
end

function World:RosterChanged(except)
    for _, other in ipairs(self.clients) do
        if other.loggedIn and other ~= except then
            self:Schedule(0.3, function()
                self:FireEvent(other, "GUILD_ROSTER_UPDATE", true)
            end, other)
        end
    end
end

function World:OnlineCount()
    local count = 0
    for _, member in ipairs(self.roster) do
        if member.client and member.client.loggedIn then
            count = count + 1
        end
    end
    return count
end

function World:LoadFile(client, addon, ns, path)
    local chunk, err = loadfile(addon.path .. "/" .. path)
    if not chunk then
        -- Like the game: an error for this file, and loading goes on.
        self.errors[#self.errors + 1] = client.name .. ": error loading " .. addon.name .. "/" .. path .. ": " .. tostring(err)
        return
    end
    setfenv(chunk, client.env)
    self:Protect(client.name .. " load " .. addon.name .. "/" .. path, chunk, addon.name, ns)
end

-- Each addon loads its files, then its saved variables (client.saved,
-- unless options.brokenSavedVariables is set: the data was lost), then
-- gets ADDON_LOADED. client.ns is the addon under test's namespace.
function World:Login(client, options)
    options = options or {}
    client.env = self:MakeEnv(client)
    -- Globals the test sets for this client before its addons load.
    for key, value in pairs(client.globals or {}) do
        client.env[key] = value
    end
    client.namespaces = {}
    client.eventFrames, client.updateFrames, client.printed = {}, {}, {}
    client.loggedIn = true
    for _, addon in ipairs(H.ADDONS) do
        local ns = {}
        client.namespaces[addon.name] = ns
        for _, path in ipairs(addon.files) do
            self:LoadFile(client, addon, ns, path)
        end
        for _, variable in ipairs(addon.saved) do
            if client.saved and client.saved[variable] ~= nil and not options.brokenSavedVariables then
                client.env[variable] = H.DeepCopy(client.saved[variable])
            end
        end
        self:FireEvent(client, "ADDON_LOADED", addon.name)
    end
    client.ns = client.namespaces[H.NAME]
    self:FireEvent(client, "PLAYER_LOGIN")
    self:FireEvent(client, "PLAYER_ENTERING_WORLD", true, false)
    self:RosterChanged(client)
end

function World:Logout(client)
    self:FireEvent(client, "PLAYER_LOGOUT")
    client.saved = {}
    for _, addon in ipairs(H.ADDONS) do
        for _, variable in ipairs(addon.saved) do
            client.saved[variable] = H.DeepCopy(client.env[variable])
        end
    end
    client.loggedIn = false
    for _, timer in ipairs(self.timers) do
        if timer.owner == client then
            timer.cancelled = true
        end
    end
    self:RosterChanged(client)
end

-- Bags, bank and money ------------------------------------------------------------------

-- Changes what a client's bags (or bank tabs) hold: container bag gets the
-- slots given ({ [slot] = { itemID, count, link }... }, size = slots), and
-- the game says the bags changed.
function World:SetContainer(client, bag, container)
    client.containers[bag] = container
    if client.loggedIn then
        self:FireEvent(client, "BAG_UPDATE", bag)
        self:FireEvent(client, "BAG_UPDATE_DELAYED")
    end
end

function World:SetMoney(client, copper)
    client.money = copper
    if client.loggedIn then
        self:FireEvent(client, "PLAYER_MONEY")
    end
end

-- At the banker: the bank tabs can be read until World:CloseBank.
function World:OpenBank(client)
    client.atBank = true
    self:FireEvent(client, "BANKFRAME_OPENED")
end

function World:CloseBank(client)
    self:FireEvent(client, "BANKFRAME_CLOSED")
    client.atBank = false
end

-- At a guild vault, as on WoW Forever: the window opens through the player
-- interactions (no GUILDBANKFRAME_OPENED, no money event). The money is
-- known from the start, or only after delay seconds.
H.GUILD_BANKER, H.BANKER = 10, 8

function World:OpenGuildBank(client, copper, delay)
    if delay then
        self:Schedule(delay, function()
            client.guildBankMoney = copper
        end, client)
    else
        client.guildBankMoney = copper
    end
    self:FireEvent(client, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", H.GUILD_BANKER)
end

function World:CloseGuildBank(client)
    self:FireEvent(client, "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", H.GUILD_BANKER)
end

-- Trade and mail ------------------------------------------------------------------------

-- A trade between two clients, each putting in items ({ { itemID, count }...
-- by slot }), with the game's events. options.cancel: it is cancelled.
function World:Trade(a, b, aItems, bItems, options)
    a.trade = { partner = b, mine = aItems or {}, theirs = bItems or {} }
    b.trade = { partner = a, mine = bItems or {}, theirs = aItems or {} }
    for _, client in ipairs({ a, b }) do
        self:FireEvent(client, "TRADE_SHOW")
        for slot in pairs(client.trade.mine) do
            self:FireEvent(client, "TRADE_PLAYER_ITEM_CHANGED", slot)
        end
        self:FireEvent(client, "TRADE_ACCEPT_UPDATE", 1, 0)
    end
    -- Like the game: the window empties and closes, then the trade is
    -- told complete.
    for _, client in ipairs({ a, b }) do
        client.trade = nil
        self:FireEvent(client, "TRADE_CLOSED")
        self:FireEvent(client, "TRADE_CLOSED")
        if options and options.cancel then
            self:FireEvent(client, "UI_INFO_MESSAGE", 227, "Trade cancelled.")
        else
            self:FireEvent(client, "UI_INFO_MESSAGE", 226, "Trade complete.")
        end
    end
end

-- Mail from a client to a name as typed, with items ({ { itemID, count }...
-- by slot }). options.fail: the game refuses to send it.
function World:Mail(from, toName, items, options)
    from.sendMail = items
    self:FireEvent(from, "MAIL_SEND_INFO_UPDATE")
    from.env.SendMail(toName, "Subject", "")
    if options and options.fail then
        self:FireEvent(from, "MAIL_FAILED")
    else
        self:FireEvent(from, "MAIL_SEND_SUCCESS")
    end
    from.sendMail = nil
end

-- The server -------------------------------------------------------------------------

function World:Send(client, prefix, text, channel, target)
    if type(text) ~= "string" or #text > 255 or text:find("\0", 1, true) then
        self.errors[#self.errors + 1] = client.name .. ": invalid addon message (" .. tostring(text and #text) .. " bytes)"
        return 2
    end
    if client.lockdown then
        return 11
    end
    if channel == "GUILD" and not client.inGuild then
        return 10
    end
    local bucket = client.bucket
    bucket.tokens = math.min(10, bucket.tokens + (self.now - bucket.last))
    bucket.last = self.now
    if channel == "GUILD" then
        if bucket.tokens < 1 then
            self.stats.throttled = self.stats.throttled + 1
            return 3
        end
        bucket.tokens = bucket.tokens - 1
    end
    -- Optionally whispers are throttled too (cap messages, rate per second).
    local limit = self.whisperLimit
    if channel == "WHISPER" and limit then
        local whisper = client.whisperBucket or { tokens = limit.cap, last = self.now }
        client.whisperBucket = whisper
        whisper.tokens = math.min(limit.cap, whisper.tokens + (self.now - whisper.last) * limit.rate)
        whisper.last = self.now
        if whisper.tokens < 1 then
            self.stats.throttled = self.stats.throttled + 1
            return 3
        end
        whisper.tokens = whisper.tokens - 1
    end
    local recipients = {}
    if channel == "GUILD" then
        for _, other in ipairs(self.clients) do
            if other.loggedIn and other.inGuild then
                recipients[#recipients + 1] = other
            end
        end
        self.stats.guild = self.stats.guild + 1
    elseif channel == "WHISPER" then
        local other = self:FindClient(target)
        if self.strictWhispers and other and target ~= other.name then
            -- Like WoW Forever: only "Name Surname" reaches a player; the send
            -- still "succeeds" and the server answers with a system line.
            self:Schedule(0.1, function()
                self:SystemMessage(client, ("No player named '%s' is currently playing."):format(target))
            end, client)
            return 0
        end
        if not other or not other.loggedIn then
            return 12
        end
        recipients[1] = other
        self.stats.whisper = self.stats.whisper + 1
    else
        return 4
    end
    self.stats.sent = self.stats.sent + 1
    self.log[#self.log + 1] = { time = self.now, from = client.name, channel = channel, target = target, text = text }
    local sender = self.senderFormat == "full" and client.key or client.name
    for _, other in ipairs(recipients) do
        local pair = client.name .. ">" .. other.name
        local at = math.max(self.now + 0.05 + math.random() * self.jitter, (self.lastDelivery[pair] or 0) + 0.001)
        self.lastDelivery[pair] = at
        self:Schedule(at - self.now, function()
            if other.loggedIn then
                self:FireEvent(other, "CHAT_MSG_ADDON", prefix, text, channel, sender, other.name)
            end
        end, other)
    end
    return 0
end

-- A system line in the chat, unless one of the client's chat filters hides it.
function World:SystemMessage(client, text)
    local filter = client.filters.CHAT_MSG_SYSTEM
    if filter and filter(nil, "CHAT_MSG_SYSTEM", text) then
        return
    end
    self.systemShown[#self.systemShown + 1] = client.name .. ": " .. text
end

-- Decodes a logged chunk's message type when it is a single-part message.
function World:CountTypes(since)
    local counts = {}
    for _, entry in ipairs(self.log) do
        if entry.time >= (since or 0) then
            counts[entry.channel] = (counts[entry.channel] or 0) + 1
        end
    end
    return counts
end

-- API stubs ------------------------------------------------------------------------

function World:MakeEnv(client)
    local world = self
    local api = {}
    local env = setmetatable({}, {
        __index = function(_, key)
            local value = api[key]
            if value ~= nil then
                return value
            end
            return _G[key]
        end,
    })

    api.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring((select(i, ...)))
        end
        client.printed[#client.printed + 1] = table.concat(parts, " ")
    end
    api.date = os.date
    api.geterrorhandler = function()
        return function(err)
            world.errors[#world.errors + 1] = client.name .. ": " .. tostring(err) .. "\n" .. debug.traceback()
        end
    end
    api.wipe = function(t)
        for k in pairs(t) do
            t[k] = nil
        end
        return t
    end
    api.tContains = function(t, value)
        for _, v in pairs(t) do
            if v == value then
                return true
            end
        end
        return false
    end
    api.tinsert = table.insert
    api.strtrim = function(s)
        return (s:match("^%s*(.-)%s*$"))
    end
    api.hooksecurefunc = function() end
    api.GetTime = function()
        return world.now
    end
    api.GetServerTime = function()
        return math.floor(world.base + world.now)
    end
    api.C_Timer = {
        After = function(delay, fn)
            world:Schedule(delay, fn, client)
        end,
        NewTimer = function(delay, fn)
            local handle = {}
            handle.timer = world:Schedule(delay, function()
                fn(handle)
            end, client)
            handle.Cancel = function(self)
                self.timer.cancelled = true
            end
            return handle
        end,
        NewTicker = function(delay, fn, iterations)
            local handle = { count = 0 }
            local function Tick()
                if handle.cancelled then
                    return
                end
                handle.count = handle.count + 1
                fn(handle)
                if not handle.cancelled and (not iterations or handle.count < iterations) then
                    handle.timer = world:Schedule(delay, Tick, client)
                end
            end
            handle.timer = world:Schedule(delay, Tick, client)
            handle.Cancel = function(self)
                self.cancelled = true
                self.timer.cancelled = true
            end
            return handle
        end,
    }
    api.CreateFrame = function(objectType, name, parent, template)
        local frame = NewObject(client, objectType)
        frame._name = name
        frame._parent = parent
        frame._template = template
        for key, kind in pairs(H.TemplateRegions[template] or {}) do
            rawset(frame, key, NewObject(client, kind))
        end
        client.created = client.created or {}
        client.created[#client.created + 1] = frame
        if name then
            env[name] = frame
        end
        return frame
    end
    api.C_AddOns = {
        GetAddOnMetadata = function(name, field)
            for _, addon in ipairs(H.ADDONS) do
                if addon.name == name then
                    return addon.fields[field]
                end
            end
        end,
    }
    api.GetLocale = function()
        return client.locale
    end
    api.Enum = {
        SendAddonMessageResult = { Success = 0, InvalidMessage = 2, AddonMessageThrottle = 3, ChannelThrottle = 8, NotInGuild = 10, AddOnMessageLockdown = 11, TargetOffline = 12 },
        CompressionMethod = { Deflate = 0, Zlib = 1, Gzip = 2 },
        ClubType = { BattleNet = 0, Character = 1, Guild = 2, Other = 3 },
    }
    api.C_ChatInfo = {
        RegisterAddonMessagePrefix = function()
            return 0
        end,
        IsAddonMessagePrefixRegistered = function()
            return true
        end,
        InChatMessagingLockdown = function()
            return client.lockdown
        end,
        AreOutgoingAddonChatMessagesRestricted = function()
            return false
        end,
        SendAddonMessage = function(prefix, text, channel, target)
            return world:Send(client, prefix, text, channel, target)
        end,
    }
    if world.encoding == "native" then
        api.C_EncodingUtil = {
            EncodeBase64 = Enc64,
            DecodeBase64 = Dec64,
        }
        if world.compress then
            -- An invertible stand-in: a short token for each distinct input.
            api.C_EncodingUtil.CompressString = function(text)
                local token = world.dict[text]
                if not token then
                    world.dictCount = (world.dictCount or 0) + 1
                    token = "Z" .. world.dictCount .. "\0"
                    world.dict[text] = token
                    world.dict[token] = text
                end
                return token
            end
            api.C_EncodingUtil.DecompressString = function(token)
                return assert(world.dict[token], "unknown compressed data")
            end
        end
    end
    -- Like WoW Forever: a two-part name comes back in two values.
    api.UnitName = function()
        local first, last = client.name:match("^(%S+)%s+(.+)$")
        if first then
            return first, last
        end
        return client.name
    end
    api.UnitGUID = function()
        return client.guid
    end
    api.GetRealmName = function()
        return "Test Realm"
    end
    api.GetNormalizedRealmName = function()
        return client.realm
    end
    api.IsInGuild = function()
        return client.inGuild
    end
    api.GetGuildInfo = function()
        if client.inGuild then
            return world.guildName, "Member", 1, world.guildRealm ~= client.realm and world.guildRealm or nil
        end
    end
    api.GetNumGuildMembers = function()
        local online = world:OnlineCount()
        return #world.roster, online, online
    end
    api.GetGuildRosterInfo = function(index)
        local member = world.roster[index]
        if not member then
            return nil
        end
        local online = member.client and member.client.loggedIn or false
        local name = world.rosterNames == "full" and member.key or member.short
        local level = member.client and member.client.level or member.level or 60
        return name, member.rank, member.rankIndex, level, "Class", "Zone", member.note, "officer only", online, 0,
            member.class, 0, 0, false, false, 0, member.guid
    end
    api.GetGuildRosterLastOnline = function(index)
        local member = world.roster[index]
        if not member or (member.client and member.client.loggedIn) then
            return nil
        end
        local offline = member.offline or { 0, 0, 0, 1 }
        return offline[1], offline[2], offline[3], offline[4]
    end
    api.C_GuildInfo = {
        GuildRoster = function()
            world:Schedule(0.2, function()
                world:FireEvent(client, "GUILD_ROSTER_UPDATE", false)
            end, client)
        end,
    }
    api.C_Item = {
        GetItemIconByID = function()
            return 3
        end,
        GetItemQualityByID = function()
            return 1
        end,
        RequestLoadItemDataByID = function() end,
    }
    api.Ambiguate = function(name)
        return (name:gsub("%-[^%-]+$", ""))
    end
    -- Blizzard's SecondsToTime (Blizzard_SharedXML\TimeUtil.lua) with
    -- English unit names. Limited to one term, it only uses a unit from 1.5
    -- of it.
    api.SecondsToTime = function(seconds, noSeconds, notAbbreviated, maxCount, roundUp)
        seconds = roundUp and math.ceil(seconds) or math.floor(seconds)
        maxCount = maxCount or 2
        local threshold = maxCount > 1 and 1.0 or 1.5
        local parts = {}
        for _, unit in ipairs({ { 86400, " Days" }, { 3600, " Hours" }, { 60, " Minutes" } }) do
            local size, name = unit[1], unit[2]
            if #parts < maxCount and seconds >= size * threshold then
                local last = #parts + 1 == maxCount
                parts[#parts + 1] = (last and roundUp and math.ceil(seconds / size) or math.floor(seconds / size)) .. name
                seconds = seconds % size
            end
        end
        if #parts < maxCount and seconds > 0 and not noSeconds then
            parts[#parts + 1] = seconds .. " Seconds"
        end
        return table.concat(parts, " ")
    end
    api.InCombatLockdown = function()
        return false
    end
    api.IsInInstance = function()
        return false
    end
    api.EventUtil = {
        ContinueOnAddOnLoaded = function() end,
    }
    api.ChatFrameUtil = {
        AddMessageEventFilter = function(event, fn)
            client.filters[event] = fn
        end,
        InsertLink = function() end,
    }
    -- UI stubs.
    api.hooksecurefunc = function(a, b, c)
        local target, name, hook
        if type(a) == "table" then
            target, name, hook = a, b, c
        else
            target, name, hook = env, a, b
        end
        local original = target[name]
        rawset(target, name, function(...)
            local results = { original(...) }
            hook(...)
            return unpack(results)
        end)
    end
    api.CreateDataProvider = function(elements)
        return { elements = elements }
    end
    api.CreateScrollBoxListLinearView = function()
        local view = NewObject(client, "View")
        rawset(view, "SetElementInitializer", function(self, template, init)
            self.init = init
        end)
        return view
    end
    api.ScrollUtil = {
        InitScrollBoxListWithScrollBar = function(scrollBox, _, view)
            rawset(scrollBox, "_view", view)
            rawset(scrollBox, "SetDataProvider", function(self, provider)
                self._provider = provider
            end)
        end,
        AddAcquiredFrameCallback = function(scrollBox, callback, owner)
            rawset(scrollBox, "_acquired", function(frame)
                callback(owner, frame)
            end)
        end,
    }
    api.ScrollBoxConstants = { RetainScrollPosition = true }
    api.PanelTemplates_SetNumTabs = function() end
    api.PanelTemplates_UpdateTabs = function() end
    api.PanelTemplates_TabResize = function() end
    api.Item = {
        CreateFromItemID = function()
            return { ContinueOnItemLoad = function(_, callback) callback() end }
        end,
    }
    api.IsModifiedClick = function()
        return client.shiftDown == true
    end
    api.PlaySound = function() end
    api.SOUNDKIT = {}
    api.GameTooltip = NewObject(client, "GameTooltip")
    api.GameTooltip_Hide = function() end
    api.RETRIEVING_ITEM_INFO = "Retrieving item information"
    api.NORMAL_FONT_COLOR = { GetRGB = function() return 1, 0.82, 0 end }
    api.GREEN_FONT_COLOR = { GetRGB = function() return 0, 1, 0 end }
    api.C_Item.GetItemInfoInstant = function(itemID)
        return itemID, "Trade Goods", "Elixir", "", 1, 7, 2
    end
    api.C_Item.GetItemQualityColor = function()
        return 1, 1, 1, "ffffffff"
    end
    api.C_Item.GetItemNameByID = function(itemID)
        return "Item" .. itemID
    end
    api.C_Item.GetItemInfo = function(itemID)
        return "Item" .. itemID, "|cffffffff|Hitem:" .. itemID .. "|h[Item]|h|r"
    end
    api.ChatFrameUtil.InsertLink = function(link)
        client.linked = link
    end
    if world.communities then
        api.CommunitiesFrame = world.communities(client)
        api.COMMUNITIES_FRAME_DISPLAY_MODES = { ROSTER = { "MemberList" }, GUILD_INFO = { "GuildDetailsFrame" } }
        api.EventUtil.ContinueOnAddOnLoaded = function(_, callback)
            callback()
        end
    end
    api.PanelTemplates_SetTab = function(frame, id)
        frame.selectedTab = id
    end
    api.CANCEL, api.DELETE = "Cancel", "Delete"
    api.ITEM_QUALITY_COLORS = {}
    for quality = 0, 7 do
        api.ITEM_QUALITY_COLORS[quality] = { r = 1, g = 1, b = 1 }
    end

    -- Bags, bank and money (see World:NewClient and World:OpenBank).
    api.NUM_TOTAL_EQUIPPED_BAG_SLOTS, api.ITEM_INVENTORY_BANK_BAG_OFFSET, api.NUM_CHARACTER_BANK_SLOTS = 5, 5, 9
    api.NUM_BAG_SLOTS, api.NUM_REAGENTBAG_SLOTS = 4, 1
    api.BACKPACK_CONTAINER = 0
    api.Enum.BankType = { Character = 0, Guild = 1, Account = 2 }
    api.Enum.BagIndex = { Characterbanktab = -2, Keyring = -1, Backpack = 0, ReagentBag = 5, CharacterBankTab_1 = 6 }
    api.Enum.PlayerInteractionType = { Banker = 8, GuildBanker = 10, CharacterBanker = 67, AccountBanker = 68 }
    local function ContainerItemLink(item)
        return item[3] or ("|cffffffff|Hitem:%d::::::::60:::::|h[Item%d]|h|r"):format(item[1], item[1])
    end
    local function Container(bag)
        if (bag >= 6 or bag == -2) and not client.atBank then
            return nil
        end
        if bag == -2 then
            -- The bags in the bank bag slots, by slot.
            local holder = { size = client.maxBankTabs }
            for index, bagID in pairs(client.bankBags) do
                holder[index] = { bagID, 1, ("|cffffffff|Hitem:%d::::::::60:::::|h[Bag%d]|h|r"):format(bagID, bagID) }
            end
            return holder
        end
        return client.containers[bag]
    end
    api.C_Container = {
        GetContainerNumSlots = function(bag)
            local container = Container(bag)
            return container and container.size or 0
        end,
        GetContainerItemInfo = function(bag, slot)
            local container = Container(bag)
            local item = container and container[slot]
            if not item then
                return nil
            end
            return { itemID = item[1], stackCount = item[2], hyperlink = ContainerItemLink(item), iconFileID = 7, quality = 2 }
        end,
        ContainerIDToInventoryID = function(bag)
            return 100 + bag
        end,
    }
    api.C_Bank = {
        FetchPurchasedBankTabData = function()
            local tabs = {}
            for i, id in ipairs(client.bankTabs) do
                tabs[i] = { ID = id, bankType = 0, name = "Tab " .. i }
            end
            return tabs
        end,
        FetchMaxNumBankTabs = function()
            return client.maxBankTabs
        end,
    }
    api.GetMoney = function()
        return client.money
    end
    api.GetGuildBankMoney = function()
        return client.guildBankMoney or 0
    end

    -- Trade and mail, driven by World:Trade and World:Mail.
    api.ERR_TRADE_COMPLETE = "Trade complete."
    api.ATTACHMENTS_MAX_SEND = 12
    local function ItemLink(item)
        return item and ("|cffffffff|Hitem:%d::::::::|h[Item%d]|h|r"):format(item[1], item[1]) or nil
    end
    local unitGUID, unitName = api.UnitGUID, api.UnitName
    -- "NPC" is whoever we trade with.
    api.UnitGUID = function(unit)
        if unit == "NPC" then
            return client.trade and client.trade.partner.guid
        end
        return unitGUID(unit)
    end
    api.UnitName = function(unit)
        if unit == "NPC" then
            return client.trade and client.trade.partner.name
        end
        return unitName(unit)
    end
    local function TradeSlot(side, slot)
        return client.trade and client.trade[side][slot] or nil
    end
    api.GetTradePlayerItemInfo = function(slot)
        local item = TradeSlot("mine", slot)
        if item then
            return "Item" .. item[1], 3, item[2], 1, nil, false
        end
    end
    api.GetTradePlayerItemLink = function(slot)
        return ItemLink(TradeSlot("mine", slot))
    end
    api.GetSendMailItem = function(slot)
        local item = client.sendMail and client.sendMail[slot]
        if item then
            return "Item" .. item[1], item[1], 3, item[2], 1, true
        end
    end
    api.GetSendMailItemLink = function(slot)
        return ItemLink(client.sendMail and client.sendMail[slot])
    end
    -- The world delivers it (World:Mail).
    api.SendMail = function() end
    api._G = env
    api.ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
    api.YES, api.NO, api.NONE = "Yes", "No", "None"
    api.UISpecialFrames = {}
    api.SlashCmdList = {}
    api.UIParent = NewObject(client, "Frame")
    api.debugprofilestop = function()
        return os.clock() * 1000
    end
    api.ReloadUI = function()
        client.reloaded = true
    end
    api.ChatFontNormal = {}

    -- The bags in the bag slots, inventory slots 100 + bag (C_Container.ContainerIDToInventoryID).
    api.GetInventoryItemLink = function(_, slot)
        local bag = client.bagItems[slot - 100]
        return bag and ("|cffffffff|Hitem:%d::::::::60:::::|h[Bag%d]|h|r"):format(bag, bag) or nil
    end
    -- Items are "loaded" once requested, as from the server.
    api.C_Item.RequestLoadItemDataByID = function(itemID)
        world.itemsLoaded = world.itemsLoaded or {}
        world.itemsLoaded[client.name .. ":" .. itemID] = true
    end
    api.C_Item.GetItemInfo = function(item)
        local itemID = tonumber(tostring(item):match("item:(%d+)") or item)
        if not (world.itemsLoaded and world.itemsLoaded[client.name .. ":" .. tostring(itemID)]) then
            return nil
        end
        return "Item " .. itemID, "|cffa335ee|Hitem:" .. itemID .. "|h[Item]|h|r", 4
    end
    api.C_Item.GetItemNameByID = function()
        return nil
    end
    api.C_Item.GetItemQualityByID = function()
        return nil
    end
    -- Stacks of 20, but for the items given in world.maxStacks.
    api.C_Item.GetItemMaxStackSizeByID = function(itemID)
        return world.maxStacks and world.maxStacks[itemID] or 20
    end

    return env
end

return H
