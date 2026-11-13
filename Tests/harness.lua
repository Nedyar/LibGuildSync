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
H.ReadToc = ReadToc

-- What each client loads: the library, then the addon under test (a client
-- made with options.addons loads those instead, such as an older release).
H.ADDONS = { ReadToc(H.LIB, "LibGuildSync"), ReadToc(H.ADDON, assert(ADDON_NAME, "set ADDON_NAME")) }
H.MAIN = H.ADDONS[2]
H.NAME = H.MAIN.name
-- The addon under test's files.
H.FILES = H.MAIN.files

-- A released version of the addon under test (its git tag, such as
-- "v0.1.0"), extracted from the addon's repository into its Tests/out, for
-- tests that mix versions in one guild: H.ReadToc of it, or nil when git or
-- tar cannot give it (the test is then skipped).
function H.Release(tag)
    local folder = ("%s/Tests/out/%s/%s"):format(H.ADDON, tag, H.NAME)
    local function Exists()
        local file = io.open(folder .. "/" .. H.NAME .. ".toc")
        if file then
            file:close()
            return true
        end
        return false
    end
    if not Exists() then
        os.execute(('git -C "%s" archive --prefix=out/%s/%s/ %s | tar -x -f - -C "%s/Tests"'):format(H.ADDON, tag, H.NAME, tag, H.ADDON))
    end
    return Exists() and ReadToc(folder, H.NAME) or nil
end

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
        recipeSkill = {}, -- recipe ID -> profession skill line (World:OpenProfession)
        itemSlots = {},   -- [itemID] = "INVTYPE_..." (C_Item.GetItemInfoInstant)
        reagents = {},    -- [recipeID] = { { itemID, quantity }... } (else 2 x item 2447)
        noItem = {},      -- [recipeID] = true when it makes no item (an enchantment)
        unloaded = {},    -- [itemID] = true while no client has loaded the item (see "Items" in MakeEnv)
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
    SetTextColor SetVertexColor SetNumeric ClearFocus SetHorizTile SetVertTile AddMaskTexture IsTruncated
    SetFillToInterior]]):gmatch("%a+") do
    H.NoOpMethods[name] = true
end

-- Regions that Blizzard's templates give a frame, by template.
H.TemplateRegions = {
    CircularGiantItemButtonTemplate = { Icon = "Texture", IconBorder = "Texture", Count = "FontString" },
    -- A top tab's art, not selected and selected (of its TabTextures).
    PanelTopTabButtonTemplate = { Middle = "Texture", MiddleActive = "Texture" },
    InputBoxInstructionsTemplate = { Instructions = "FontString" },
    InputScrollFrameTemplate = { EditBox = "EditBox", CharCount = "FontString" },
    LargeSideTabButtonTemplate = { Background = "Texture", Icon = "Texture", SelectedTexture = "Texture" },
    RightSideTabTemplate = { Icon = "Texture", IconOverlay = "Texture" },
}

-- The size that Blizzard's templates give a frame, by template ({ width,
-- height }); any other frame has no size (0).
H.TemplateSizes = {
    LargeSideTabButtonTemplate = { 0, 55 },
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
    -- Frames have no size in the tests, but what a template gives them
    -- (H.TemplateSizes).
    GetWidth = function(self)
        return self._width or 0
    end,
    GetHeight = function(self)
        return self._height or 0
    end,
    GetFrameLevel = function()
        return 1
    end,
    CreateMaskTexture = function(self)
        return NewObject(self._client, "MaskTexture")
    end,
    -- An edit box's text insets, for the tests to check.
    SetTextInsets = function(self, left, right, top, bottom)
        self._insets = { left, right, top, bottom }
    end,
    -- As the game: a scale must be above 0.
    SetScale = function(self, scale)
        if type(scale) ~= "number" or scale <= 0 then
            error("Frame:SetScale(): Scale must be > 0", 2)
        end
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
-- its generator makes, in order. A button's own entries (its submenu) are
-- in its .entries. An entry made disabled has enabled = false.
function H.NewMenuDescription()
    local description = { entries = {} }
    local function Add(entry)
        function entry:SetTitleAndTextTooltip(title, tooltip)
            self.tooltipTitle, self.tooltip = title, tooltip
        end
        function entry:SetEnabled(enabled)
            self.enabled = enabled
        end
        description.entries[#description.entries + 1] = entry
        return entry
    end
    function description:CreateRadio(text, isSelected, setSelected, data)
        return Add({ kind = "radio", text = text, isSelected = isSelected, setSelected = setSelected, data = data })
    end
    function description:CreateCheckbox(text, isSelected, setSelected, data)
        return Add({ kind = "checkbox", text = text, isSelected = isSelected, setSelected = setSelected, data = data })
    end
    function description:CreateButton(text, callback, data)
        local entry = H.NewMenuDescription()
        entry.kind, entry.text, entry.callback, entry.data = "button", text, callback, data
        return Add(entry)
    end
    return description
end

-- The entries of a dropdown's menu, as the game builds it when it opens.
function H.MenuOf(dropdown)
    local root = H.NewMenuDescription()
    dropdown._menuGenerator(dropdown, root)
    return root.entries
end

-- A dropdown's menu (WowStyle1DropdownTemplate): SetupMenu builds it right
-- away, GenerateMenu again. A menu of radios shows the selected one's text;
-- another (a filter dropdown's) keeps the dropdown's own.
H.FrameMethods.SetupMenu = function(self, generator)
    self._menuGenerator = generator
    self:GenerateMenu()
end
H.FrameMethods.GenerateMenu = function(self)
    local root = H.NewMenuDescription()
    self._menuGenerator(self, root)
    self._menu = root.entries
    local radios, selected = false, nil
    for _, entry in ipairs(root.entries) do
        if entry.kind == "radio" then
            radios = true
            if entry.isSelected(entry.data) then
                selected = entry.text
            end
        end
    end
    if radios then
        self._text = selected
    end
end

-- A filter dropdown (WowDropdownFilterBehaviorMixin): its reset button shows
-- while the filters are not the default ones.
H.FrameMethods.SetDefaultCallback = function(self, callback)
    self._default = callback
end
H.FrameMethods.SetIsDefaultCallback = function(self, callback)
    self._isDefault = callback
end
H.FrameMethods.ValidateResetState = function(self)
    self._resetShown = not self._isDefault()
end

-- Blizzard's side tabs of the guild window.
H.BLIZZARD_TABS = { "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab", "GuildPreferredPlaySettingsTab" }

-- The member list (CommunitiesMemberListMixin) of the guild window, in its
-- expanded display (the Roster tab): a row for every roster member (when
-- the client logs in) and a column display with six headers.
local function FakeMemberList(client)
    local list = H.NewObject(client, "Frame")
    list.expandedDisplay = true
    rawset(list, "GetSelectedClubInfo", function()
        return { clubType = 2 }
    end)
    rawset(list, "GetGuildColumnIndex", function()
        return list.guildColumnIndex
    end)
    rawset(list, "RefreshLayout", function() end)
    list.ColumnDisplay = H.NewObject(client, "Frame")
    local headers = {}
    for i = 1, 6 do
        local header = H.NewObject(client, "Button")
        rawset(header, "GetID", function()
            return i
        end)
        rawset(header, "SetPoint", function(self, ...)
            self._lastPoint = { ... }
        end)
        headers[i] = header
    end
    list.ColumnDisplay.columnHeaders = {
        EnumerateActive = function()
            local i = 0
            return function()
                i = i + 1
                return headers[i]
            end
        end,
    }
    list.headers = headers
    list.columnInfo = { {}, {}, {}, {}, {}, {} }
    local rows = {}
    for _, member in ipairs(client.world.roster) do
        local row = H.NewObject(client, "Button")
        row.expanded = true
        row.isInvitation = false
        row.memberInfo = { guid = member.guid, name = member.short }
        rawset(row, "GetMemberInfo", function(self)
            return self.memberInfo
        end)
        rawset(row, "RefreshExpandedColumns", function() end)
        row.ProfessionHeader = H.NewObject(client, "Frame")
        row.ProfessionHeader:Hide()
        row.FactionButton = H.NewObject(client, "Button")
        row.FactionButton:Hide()
        row.Rank = H.NewObject(client, "FontString")
        row.Note = H.NewObject(client, "FontString")
        -- Where the Note column ends, for the tests to check.
        rawset(row.Note, "SetPoint", function(self, point, relative)
            self._right = relative
        end)
        rows[#rows + 1] = row
    end
    list.rows = rows
    list.ScrollBox = H.NewObject(client, "Frame")
    rawset(list.ScrollBox, "ForEachFrame", function(_, fn)
        for _, row in ipairs(rows) do
            fn(row)
        end
    end)
    return list
end

-- A stand-in for Blizzard's guild window (CommunitiesFrame): its side tabs
-- (as for a guild without benefits), the communities list, the chat, its
-- display mode, and the member list.
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
    frame.MemberList = FakeMemberList(client)
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
H.CLASS_NAMES = { "Warrior", "Paladin", "Hunter", "Rogue", "Priest", nil, "Shaman", "Mage", "Warlock", nil, "Druid" }
H.RACES = { [1] = { "Human", "Human" }, [2] = { "Orc", "Orc" }, [3] = { "Dwarf", "Dwarf" }, [4] = { "NightElf", "Night Elf" } }

-- A fake class talent tree (C_Traits): three tabs, nodes on a grid of 600
-- units between columns and 600 between rows, like Blizzard's.
H.TREE = {
    id = 773,
    tabs = { { groupID = 11, name = "Beast Mastery" }, { groupID = 12, name = "Marksmanship" }, { groupID = 13, name = "Survival" } },
    -- id, tab, column, row, max rank; each tab starts 3000 units further right.
    nodes = {
        { 101, 1, 1, 1, 5 }, { 102, 1, 2, 1, 5 }, { 103, 1, 1, 2, 2 }, { 104, 1, 3, 2, 3 }, { 105, 1, 2, 3, 1 },
        { 201, 2, 2, 1, 5 }, { 202, 2, 3, 1, 5 }, { 203, 2, 1, 2, 3 }, { 204, 2, 2, 3, 1 }, { 205, 2, 4, 4, 5 },
        { 301, 3, 1, 1, 5 }, { 302, 3, 3, 1, 5 }, { 303, 3, 2, 2, 3 },
    },
    -- a hidden node of another spec, which must be left out
    hidden = { 999, 1, 1, 1, 1 },
}

function H.NodePosition(node)
    return (node[2] - 1) * 3000 + (node[3] - 1) * 600 + 1200, (node[4] - 1) * 600 + 1500
end

-- options.realm: the character's realm (members of a guild can be on several).
-- The character: level, classID, raceID, sex, faction, itemLevel (average),
-- gear = { [slot] = { link, il } }, talents = { active, groups = { [group]
-- = { [nodeID] = rank } }, unspent, staged }, professions = list in
-- GetProfessions order of { sl = skillLine, r = rank, m = max, spell =
-- spellID, hasRecipes = bool }. In the roster: rank, rankIndex, note.
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
        raceID = options.raceID or 4,
        sex = options.sex or 3,
        faction = options.faction or "Alliance",
        itemLevel = options.itemLevel,
        gear = options.gear or {},
        talents = options.talents,
        professions = options.professions or {},
        eventFrames = {},
        updateFrames = {},
        printed = {},
        filters = {},
        bucket = { tokens = 10, last = 0 },
        inGuild = true,
        lockdown = false,
        saved = options.saved, -- the account's saved variables: { [variable] = value }
        globals = options.globals, -- set in the client's environment before its addons load
        -- The addons it loads, in order (H.ReadToc of each): H.ADDONS unless
        -- given, such as an older release of the addon under test.
        addons = options.addons or H.ADDONS,
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
        -- Mail received (World:Mail, World:TakeMail): { { from = name, items
        -- = { { itemID, count } or false (taken)... }, money = copper }... }.
        -- What is taken goes to client.bags ({ [itemID] = count }, what
        -- C_Item.GetItemCount counts) and client.money; while client.bagsFull
        -- is set the game refuses items.
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
    for _, addon in ipairs(client.addons) do
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
    for _, addon in ipairs(client.addons) do
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

-- Professions ----------------------------------------------------------------------------

-- Opens a profession window on the client: all = every recipe of the
-- profession, learned = the ones the character knows.
function World:OpenProfession(client, skillLine, all, learned, linked)
    local set = {}
    for _, id in ipairs(learned) do
        set[id] = true
        self.recipeSkill[id] = skillLine
    end
    for _, id in ipairs(all) do
        self.recipeSkill[id] = skillLine
    end
    client.session = { sl = skillLine, all = all, learned = set, linked = linked }
    self:FireEvent(client, "TRADE_SKILL_SHOW")
    self:FireEvent(client, "TRADE_SKILL_LIST_UPDATE")
end

function World:CloseProfession(client)
    client.session = nil
    self:FireEvent(client, "TRADE_SKILL_CLOSE")
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

-- The guild vault's own log, kept by the server: world.vault.tabs (each
-- { name, viewable, log = { { kind, name, itemID, count, tab1, tab2, at }... } })
-- and world.vault.money ({ { kind, name, amount, at }... }), oldest first,
-- at being the server's time (World:ServerTime). A client reads them after
-- QueryGuildBankLog, like the game: the last H.VAULT_LOG_SIZE of each,
-- with how long ago in years, months, days and hours. (Tests may move the
-- server's time on by raising world.base.)
H.VAULT_LOG_SIZE = 25

-- What GetServerTime gives every client.
function World:ServerTime()
    return math.floor(self.base + self.now)
end

function World:Vault()
    self.vault = self.vault or { tabs = {}, money = {} }
    return self.vault
end

function World:VaultTab(name, viewable)
    local tabs = self:Vault().tabs
    tabs[#tabs + 1] = { name = name, viewable = viewable ~= false, log = {} }
    return #tabs
end

-- kind: "deposit", "withdraw", "repair"... as GetGuildBankMoneyTransaction
-- gives it.
function World:VaultMoney(kind, name, amount)
    local money = self:Vault().money
    money[#money + 1] = { kind = kind, name = name, amount = amount, at = self:ServerTime() }
end

-- kind: "deposit", "withdraw" or "move" (to tab2).
function World:VaultItem(tab, kind, name, itemID, count, tab2)
    local log = self:Vault().tabs[tab].log
    log[#log + 1] = { kind = kind, name = name, itemID = itemID, count = count, tab1 = kind == "move" and tab or nil, tab2 = tab2,
        at = self:ServerTime() }
end

-- Trade and mail ------------------------------------------------------------------------

-- A trade between two clients, each putting in items ({ { itemID, count }...
-- by slot }), with the game's events. options.cancel: it is cancelled;
-- options.aMoney, options.bMoney: the copper each side puts in.
function World:Trade(a, b, aItems, bItems, options)
    options = options or {}
    a.trade = { partner = b, mine = aItems or {}, theirs = bItems or {}, myMoney = options.aMoney, theirMoney = options.bMoney }
    b.trade = { partner = a, mine = bItems or {}, theirs = aItems or {}, myMoney = options.bMoney, theirMoney = options.aMoney }
    for _, client in ipairs({ a, b }) do
        self:FireEvent(client, "TRADE_SHOW")
        if client.trade.myMoney or client.trade.theirMoney then
            self:FireEvent(client, "TRADE_MONEY_CHANGED")
        end
        for slot in pairs(client.trade.mine) do
            self:FireEvent(client, "TRADE_PLAYER_ITEM_CHANGED", slot)
        end
        for slot in pairs(client.trade.theirs) do
            self:FireEvent(client, "TRADE_TARGET_ITEM_CHANGED", slot)
        end
        self:FireEvent(client, "TRADE_ACCEPT_UPDATE", 1, 0)
    end
    -- Like the game: the window empties and closes, then the trade is
    -- told complete.
    for _, client in ipairs({ a, b }) do
        client.trade = nil
        self:FireEvent(client, "TRADE_CLOSED")
        self:FireEvent(client, "TRADE_CLOSED")
        if options.cancel then
            self:FireEvent(client, "UI_INFO_MESSAGE", 227, "Trade cancelled.")
        else
            self:FireEvent(client, "UI_INFO_MESSAGE", 226, "Trade complete.")
        end
    end
end

-- Mail from a client to a name as typed, with items ({ { itemID, count }...
-- by slot }). options.fail: the game refuses to send it; options.money:
-- the copper it carries; options.cod: the copper its recipient pays to
-- take its items. Sent, it lands in the inbox of the client of that name,
-- if there is one (World:TakeMail).
function World:Mail(from, toName, items, options)
    options = options or {}
    from.sendMail, from.sendMoney, from.sendCOD = items, options.money, options.cod
    self:FireEvent(from, "MAIL_SEND_INFO_UPDATE")
    from.env.SendMail(toName, "Subject", "")
    if options.fail then
        self:FireEvent(from, "MAIL_FAILED")
    else
        self:FireEvent(from, "MAIL_SEND_SUCCESS")
        local to = self:FindClient(toName)
        if to then
            -- The attachments, in the order of their slots.
            local copy = {}
            for slot = 1, 12 do
                local item = items[slot]
                if item then
                    copy[#copy + 1] = { item[1], item[2] }
                end
            end
            to.inbox[#to.inbox + 1] = { from = from.name, items = copy, money = options.money, cod = options.cod }
        end
    end
    from.sendMail, from.sendMoney, from.sendCOD = nil, nil, nil
end

-- Takes the items of a mail of the client's inbox: one slot, the money
-- ("money"), or all of it; then runs the world a second for the server's
-- answer.
function World:TakeMail(client, index, slot)
    if slot == "money" then
        client.env.TakeInboxMoney(index)
    elseif slot then
        client.env.TakeInboxItem(index, slot)
    else
        client.env.AutoLootMailItem(index)
    end
    self:RunFor(1)
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
        local size = H.TemplateSizes[template]
        if size then
            frame._width, frame._height = size[1], size[2]
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
            for _, addon in ipairs(client.addons) do
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
        SpellBookSpellBank = { Player = 0, Pet = 1 },
        ClubType = { BattleNet = 0, Character = 1, Guild = 2, Other = 3 },
        CraftingReagentType = { Modifying = 0, Basic = 1 },
        Profession = { FirstAid = 0, Blacksmithing = 1, Leatherworking = 2, Alchemy = 3, Herbalism = 4, Cooking = 5, Mining = 6,
            Tailoring = 7, Engineering = 8, Enchanting = 9, Fishing = 10, Skinning = 11 },
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
    -- Professions (see World:NewClient and World:OpenProfession).
    api.GetProfessions = function()
        local result = {}
        for i = 1, 7 do
            result[i] = client.professions[i] and i or nil
        end
        return unpack(result, 1, 7)
    end
    api.GetProfessionInfo = function(index)
        local prof = client.professions[index]
        return "Prof" .. prof.sl, 1000 + index, prof.r, prof.m, 2, index * 10, prof.sl, 0, 0, 0, "Prof" .. prof.sl
    end
    api.IsPlayerSpell = function(spellID)
        return client.knownSpells ~= nil and client.knownSpells[spellID] == true
    end
    api.C_SpellBook = {
        GetSpellBookItemInfo = function(slot)
            for index = 1, 7 do
                local prof = client.professions[index]
                if prof and index * 10 + 1 == slot then
                    return { spellID = prof.spell, actionID = prof.spell }
                end
            end
            return {}
        end,
    }
    local function SessionFlag()
        return client.session ~= nil and client.session.linked == true
    end
    api.C_TradeSkillUI = {
        CanTradeSkillShowCraftingUI = function(spellID)
            for index = 1, 7 do
                local prof = client.professions[index]
                if prof and prof.spell == spellID then
                    return prof.hasRecipes
                end
            end
            return false
        end,
        IsTradeSkillReady = function()
            return client.session ~= nil
        end,
        IsDataSourceChanging = function()
            return false
        end,
        IsTradeSkillLinked = SessionFlag,
        IsTradeSkillGuild = function()
            return false
        end,
        IsTradeSkillGuildMember = function()
            return false
        end,
        IsNPCCrafting = function()
            return false
        end,
        GetChildProfessionInfo = function()
            return { professionID = client.session and client.session.sl or 0 }
        end,
        GetBaseProfessionInfo = function()
            return { professionID = client.session and client.session.sl or 0 }
        end,
        GetAllRecipeIDs = function()
            if client.noAllRecipeIDs then
                return nil
            end
            return client.session and client.session.all or {}
        end,
        GetFilteredRecipeIDs = function()
            return client.session and (client.session.filtered or client.session.all) or {}
        end,
        GetRecipeInfo = function(id)
            -- Away from a profession window the game gives category 0.
            return { name = "Recipe " .. id, learned = client.session ~= nil and client.session.learned[id] == true, categoryID = client.session and 5 or 0, isDummyRecipe = false }
        end,
        GetCategoryInfo = function()
            return { name = "Category", uiOrder = 1 }
        end,
        GetProfessionInfoByRecipeID = function(id)
            return { professionID = world.recipeSkill[id] or 0 }
        end,
        GetTradeSkillLineForRecipe = function(id)
            return world.recipeSkill[id]
        end,
        GetTradeSkillDisplayName = function(skillLine)
            return "Skill" .. skillLine
        end,
        GetTradeSkillTexture = function()
            return 1
        end,
        -- Which profession a skill line is (Enum.Profession), for the real IDs.
        GetProfessionInfoBySkillLineID = function(skillLine)
            local kinds = { [164] = 1, [165] = 2, [171] = 3, [182] = 4, [185] = 5, [186] = 6, [197] = 7, [202] = 8, [333] = 9, [356] = 10, [393] = 11 }
            return { profession = kinds[skillLine] }
        end,
        IsGuildTradeSkillsEnabled = function()
            return false
        end,
        -- Recipe N makes item 100000 + N (none for world.noItem's), from
        -- world.reagents' reagents or else 2 of item 2447.
        GetRecipeSchematic = function(recipeID)
            local slots = {}
            for i, reagent in ipairs(world.reagents[recipeID] or { { 2447, 2 } }) do
                slots[i] = { reagents = { { itemID = reagent[1] } }, quantityRequired = reagent[2], reagentType = 1 }
            end
            return {
                name = "Recipe " .. recipeID, icon = 4, outputItemID = world.noItem[recipeID] and 0 or recipeID + 100000,
                quantityMin = 1, quantityMax = recipeID % 2 + 1, reagentSlotSchematics = slots,
            }
        end,
        GetRecipeDescription = function(recipeID)
            return "Makes the item of recipe " .. recipeID .. "."
        end,
        GetRecipeRequirements = function()
            return {}
        end,
    }
    api.C_Spell = {
        GetSpellName = function(id)
            return "Spell" .. id
        end,
        GetSpellTexture = function()
            return 2
        end,
        GetSpellLink = function()
            return nil
        end,
        RequestLoadSpellData = function() end,
    }
    -- More of C_Item under "Items" below.
    api.C_Item = {
        GetItemIconByID = function()
            return 3
        end,
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
            -- The element scrolled to, for the tests to check. As in the game,
            -- an offset that is not a number fails (it is added to).
            rawset(scrollBox, "ScrollToElementDataByPredicate", function(self, predicate, alignment, offset, noInterpolation)
                if offset ~= nil and type(offset) ~= "number" then
                    error("attempt to perform arithmetic on local 'offset' (a " .. type(offset) .. " value)", 2)
                end
                self._scrolledTo = nil
                for _, element in ipairs(self._provider and self._provider.elements or {}) do
                    if predicate(element) then
                        self._scrolledTo = element
                        return
                    end
                end
            end)
        end,
        AddAcquiredFrameCallback = function(scrollBox, callback, owner)
            rawset(scrollBox, "_acquired", function(frame)
                callback(owner, frame)
            end)
        end,
    }
    -- As the game defines them (ScrollBoxConstants in Blizzard_SharedXML).
    api.ScrollBoxConstants = { RetainScrollPosition = true, DiscardScrollPosition = false, NoScrollInterpolation = true,
        AlignBegin = 0, AlignCenter = 0.5, AlignEnd = 1, AlignNearest = -1 }
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
    -- The tooltip keeps what it shows since its last SetOwner: _lines, the
    -- title first, a double line as "left | right".
    local tooltip = NewObject(client, "GameTooltip")
    tooltip._lines = {}
    tooltip.SetOwner = function(self)
        self._text, self._lines = nil, {}
    end
    tooltip.SetText = function(self, text)
        self._text, self._lines = text, { text }
    end
    tooltip.AddLine = function(self, text)
        table.insert(self._lines, text)
    end
    tooltip.AddDoubleLine = function(self, left, right)
        table.insert(self._lines, tostring(left) .. " | " .. tostring(right))
    end
    api.GameTooltip = tooltip
    api.GameTooltip_Hide = function() end
    api.RETRIEVING_ITEM_INFO = "Retrieving item information"
    api.NORMAL_FONT_COLOR = { GetRGB = function() return 1, 0.82, 0 end }
    -- The game's confirmation dialog: client.confirm keeps what it asks
    -- (text, text_arg1, callback...); a test accepts by calling its callback.
    api.StaticPopup_ShowCustomGenericConfirmation = function(data)
        client.confirm = data
    end
    -- The game's settings panel (Options > AddOns): client.settings keeps the
    -- categories registered ({ frame, name, subcategories, registered }).
    api.SettingsPanel = NewObject(client, "Frame")
    api.SettingsPanel:Hide()
    local function Category(frame, name)
        return { frame = frame, name = name, subcategories = {}, GetID = function() return name end }
    end
    api.Settings = {
        RegisterCanvasLayoutCategory = function(frame, name)
            local category = Category(frame, name)
            client.settings = client.settings or {}
            client.settings[#client.settings + 1] = category
            return category
        end,
        RegisterCanvasLayoutSubcategory = function(parent, frame, name)
            local category = Category(frame, name)
            parent.subcategories[#parent.subcategories + 1] = category
            return category
        end,
        RegisterAddOnCategory = function(category)
            category.registered = true
        end,
        OpenToCategory = function(id)
            client.openedSettings = id
            api.SettingsPanel:Show()
        end,
    }
    api.GREEN_FONT_COLOR = { GetRGB = function() return 0, 1, 0 end }
    api.C_Texture = {
        GetAtlasInfo = function()
            return { width = 128, height = 1020, file = 5, leftTexCoord = 0, rightTexCoord = 1, topTexCoord = 0, bottomTexCoord = 1 }
        end,
    }
    -- The game's link handling, to check that nothing asks for links.
    client.itemRefs = {}
    api.SetItemRef = function(link)
        client.itemRefs[#client.itemRefs + 1] = link
    end
    -- Always known, loaded or not: the equip slot is world.itemSlots'.
    api.C_Item.GetItemInfoInstant = function(itemID)
        return itemID, "Trade Goods", "Elixir", world.itemSlots[itemID] or "", 1, 7, 2
    end
    api.C_Item.GetItemQualityColor = function()
        return 1, 1, 1, "ffffffff"
    end
    -- What the bags hold: client.bags, plus the stacks in the bag containers
    -- (0 to 5), as the game counts them.
    api.C_Item.GetItemCount = function(itemID)
        local count = client.bags and client.bags[itemID] or 0
        for bag = 0, 5 do
            for slot, item in pairs(client.containers[bag] or {}) do
                if type(slot) == "number" and item[1] == itemID then
                    count = count + item[2]
                end
            end
        end
        return count
    end
    api.INVTYPE_CHEST, api.INVTYPE_ROBE, api.INVTYPE_FEET, api.INVTYPE_HEAD = "Chest", "Chest", "Feet", "Head"
    api.MenuResponse = { Open = 1, Refresh = 2, Close = 3, CloseAll = 4 }
    -- What the client linked in chat, and whom it opened a whisper to.
    api.ChatFrameUtil.InsertLink = function(link)
        client.linked = link
    end
    api.ChatFrameUtil.SendTell = function(name)
        client.whispered = name
    end
    -- The game opens its profession window on one of our recipes.
    api.ProfessionsUtil = {
        OpenProfessionFrameToRecipe = function(recipeID)
            client.openedRecipe = recipeID
            return true
        end,
    }
    -- The micro menu's Guild & Communities button, always there.
    api.GuildMicroButton = H.NewObject(client, "Button")
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
            return { itemID = item[1], stackCount = item[2], hyperlink = ContainerItemLink(item), iconFileID = 7, quality = 2,
                isLocked = item.locked == true }
        end,
        ContainerIDToInventoryID = function(bag)
            return 100 + bag
        end,
    }

    -- The cursor and moving items, as the game does it: a stack picked up
    -- (or split off) stays in its slot, locked, until it is put down: in an
    -- empty slot, onto a stack of the same item (as much as fits, the rest
    -- staying where it was), back where it was, or, a whole stack, into the
    -- mail being written. Put down in a slot, the move is the server's: the
    -- slots look as they were until it answers (world.moveDelay seconds,
    -- 0.4 by default), and their locks may clear before that
    -- (world.unlockDelay, 0.2 by default; ITEM_LOCK_CHANGED). The server
    -- refuses a move its slots no longer allow. client.moves counts the
    -- moves.
    local cursor -- { bag, slot, count }
    local function MaxStack(itemID)
        return world.maxStacks and world.maxStacks[itemID] or 20
    end
    -- The stack on the cursor put down on bag, slot (target: the stack there).
    local function Ask(bag, slot, target)
        local from, count = { bag = cursor.bag, slot = cursor.slot }, cursor.count
        local source = Container(from.bag)[from.slot]
        cursor = nil
        client.moves = (client.moves or 0) + 1
        if target then
            target.locked = true
        end
        local unlocked, moved = false, nil
        world:Schedule(world.unlockDelay or 0.2, function()
            unlocked = true
            for _, item in ipairs({ source, target or false, moved or false }) do
                if item then
                    item.locked = nil
                end
            end
            world:FireEvent(client, "ITEM_LOCK_CHANGED", from.bag, from.slot)
            world:FireEvent(client, "ITEM_LOCK_CHANGED", bag, slot)
        end, client)
        world:Schedule(world.moveDelay or 0.4, function()
            local fromContainer, toContainer = Container(from.bag), Container(bag)
            if not fromContainer or not toContainer or fromContainer[from.slot] ~= source or source[2] < count
                    or toContainer[slot] ~= target then
                return
            end
            if target then
                count = math.min(count, MaxStack(target[1]) - target[2])
                target[2] = target[2] + count
                moved = target
            else
                -- A whole stack is the same item (its GUID) in another slot;
                -- a part split off is a new one.
                moved = { source[1], count, source[3], locked = not unlocked or nil, guid = count == source[2] and source.guid or nil }
                toContainer[slot] = moved
            end
            source[2] = source[2] - count
            if source[2] <= 0 then
                fromContainer[from.slot] = nil
            end
            world:FireEvent(client, "BAG_UPDATE_DELAYED")
        end, client)
    end
    api.C_Container.PickupContainerItem = function(bag, slot)
        local container = Container(bag)
        if not container or slot < 1 or slot > (container.size or 0) then
            return
        end
        local item = container[slot]
        if not cursor then
            if item and not item.locked then
                cursor = { bag = bag, slot = slot, count = item[2] }
                item.locked = true
            end
            return
        end
        local source = Container(cursor.bag)[cursor.slot]
        if not source then
            cursor = nil
        elseif bag == cursor.bag and slot == cursor.slot then
            source.locked, cursor = nil, nil
        elseif not item or (item[1] == source[1] and item[3] == source[3] and not item.locked) then
            Ask(bag, slot, item)
        end
    end
    api.C_Container.SplitContainerItem = function(bag, slot, count)
        local container = Container(bag)
        local item = container and container[slot]
        if cursor or not item or item.locked or count < 1 or count >= item[2] then
            return
        end
        cursor = { bag = bag, slot = slot, count = count }
        item.locked = true
    end
    -- Each item of the containers has a GUID, given the first time it is
    -- asked for (see ItemLocation below).
    api.C_Item.GetItemGUID = function(location)
        local container = location and location.bag and Container(location.bag)
        local item = container and container[location.slot]
        if not item then
            return nil
        end
        if not item.guid then
            world.itemGUIDs = (world.itemGUIDs or 0) + 1
            item.guid = ("Item-1-0-%016X"):format(world.itemGUIDs)
        end
        return item.guid
    end
    api.C_Container.GetContainerNumFreeSlots = function(bag)
        local container = Container(bag)
        local free = 0
        for slot = 1, container and container.size or 0 do
            if not container[slot] then
                free = free + 1
            end
        end
        return free, 0
    end
    api.CursorHasItem = function()
        return cursor ~= nil
    end
    api.ClearCursor = function()
        if cursor then
            local source = Container(cursor.bag)[cursor.slot]
            if source then
                source.locked = nil
            end
            cursor = nil
        end
    end
    -- The stack on the cursor goes into the mail: into the slot given, or
    -- the first free one. Not part of one, split off: it stays on the cursor.
    api.ClickSendMailItemButton = function(index)
        local bag, slot = cursor and cursor.bag, cursor and cursor.slot
        local source = cursor and Container(bag)[slot]
        if not source or cursor.count < source[2] then
            return
        end
        client.sendMail = client.sendMail or {}
        if not index then
            for i = 1, api.ATTACHMENTS_MAX_SEND do
                if not client.sendMail[i] then
                    index = i
                    break
                end
            end
        end
        if not index or client.sendMail[index] then
            return
        end
        client.sendMail[index] = { source[1], source[2], source[3] }
        Container(bag)[slot] = nil
        cursor = nil
        client.moves = (client.moves or 0) + 1
        world:Schedule(0.1, function()
            world:FireEvent(client, "MAIL_SEND_INFO_UPDATE")
        end, client)
    end
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
    -- Money moved at the vault: the server answers a moment later, with the
    -- money moved (if there is enough) and the vault's money log written.
    local function MoveVaultMoney(sign, copper)
        world:Schedule(0.2, function()
            local vault, money = client.guildBankMoney or 0, client.money or 0
            if copper <= 0 or (sign > 0 and vault < copper) or (sign < 0 and money < copper) then
                return
            end
            client.guildBankMoney, client.money = vault - sign * copper, money + sign * copper
            world:VaultMoney(sign > 0 and "withdraw" or "deposit", client.name, copper)
            world:FireEvent(client, "PLAYER_MONEY")
            world:FireEvent(client, "GUILDBANK_UPDATE_MONEY")
        end, client)
    end
    api.WithdrawGuildBankMoney = function(copper)
        MoveVaultMoney(1, copper)
    end
    api.DepositGuildBankMoney = function(copper)
        MoveVaultMoney(-1, copper)
    end

    -- The guild vault's log (World:VaultTab, World:VaultMoney,
    -- World:VaultItem): known to a client once asked for.
    api.MAX_GUILDBANK_TABS = 8
    local vaultAsked = {}
    local function VaultLog(tab)
        local vault = world.vault or { tabs = {}, money = {} }
        if tab == api.MAX_GUILDBANK_TABS + 1 then
            return vault.money
        end
        return vault.tabs[tab] and vault.tabs[tab].log or {}
    end
    -- The last ones, and how long ago as years, months, days and hours.
    local function VaultEntry(tab, index)
        if not vaultAsked[tab] then
            return nil
        end
        local log = VaultLog(tab)
        local entry = log[math.max(#log - H.VAULT_LOG_SIZE, 0) + index]
        if not entry then
            return nil
        end
        local hours = math.floor((world:ServerTime() - entry.at) / 3600)
        local years = math.floor(hours / 8760)
        hours = hours - years * 8760
        local months = math.floor(hours / 720)
        hours = hours - months * 720
        local days = math.floor(hours / 24)
        return entry, years, months, days, hours - days * 24
    end
    api.QueryGuildBankLog = function(tab)
        world:Schedule(0.2, function()
            vaultAsked[tab] = true
            world:FireEvent(client, "GUILDBANKLOG_UPDATE")
        end, client)
    end
    api.GetNumGuildBankTabs = function()
        return world.vault and #world.vault.tabs or 0
    end
    api.GetGuildBankTabInfo = function(tab)
        local info = world.vault and world.vault.tabs[tab]
        if info then
            return info.name, 133784, info.viewable, true, -1, -1, false
        end
    end
    api.GetNumGuildBankTransactions = function(tab)
        return vaultAsked[tab] and math.min(#VaultLog(tab), H.VAULT_LOG_SIZE) or 0
    end
    api.GetGuildBankTransaction = function(tab, index)
        local entry, years, months, days, hours = VaultEntry(tab, index)
        if entry then
            local link = ("|cffffffff|Hitem:%d::::::::|h[Item%d]|h|r"):format(entry.itemID, entry.itemID)
            return entry.kind, entry.name, link, entry.count, entry.tab1, entry.tab2, years, months, days, hours
        end
    end
    api.GetNumGuildBankMoneyTransactions = function()
        local tab = api.MAX_GUILDBANK_TABS + 1
        return vaultAsked[tab] and math.min(#VaultLog(tab), H.VAULT_LOG_SIZE) or 0
    end
    api.GetGuildBankMoneyTransaction = function(index)
        local entry, years, months, days, hours = VaultEntry(api.MAX_GUILDBANK_TABS + 1, index)
        if entry then
            return entry.kind, entry.name, entry.amount, years, months, days, hours
        end
    end

    -- Trade and mail, driven by World:Trade, World:Mail and World:TakeMail.
    api.ERR_TRADE_COMPLETE = "Trade complete."
    api.ERR_INV_FULL = "Inventory is full."
    api.ATTACHMENTS_MAX_SEND, api.ATTACHMENTS_MAX_RECEIVE = 12, 16
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
    api.GetTradeTargetItemInfo = function(slot)
        local item = TradeSlot("theirs", slot)
        if item then
            return "Item" .. item[1], 3, item[2], 1, true, nil
        end
    end
    api.GetTradeTargetItemLink = function(slot)
        return ItemLink(TradeSlot("theirs", slot))
    end
    api.GetPlayerTradeMoney = function()
        return client.trade and client.trade.myMoney or 0
    end
    api.GetTargetTradeMoney = function()
        return client.trade and client.trade.theirMoney or 0
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
    api.GetSendMailMoney = function()
        return client.sendMoney or 0
    end
    api.GetSendMailCOD = function()
        return client.sendCOD or 0
    end
    -- What sending the mail costs, as the game counts it: the postage (30
    -- copper per item attached, 30 with none) and the money it carries
    -- (seen in game: a mail with 1 copper costs 31).
    api.GetSendMailPrice = function()
        local count = 0
        for _ in pairs(client.sendMail or {}) do
            count = count + 1
        end
        return 30 * math.max(count, 1) + (client.sendMoney or 0)
    end
    -- The world delivers it (World:Mail).
    api.SendMail = function() end
    api.GetInboxNumItems = function()
        return #client.inbox
    end
    api.GetInboxHeaderInfo = function(index)
        local mail = client.inbox[index]
        if mail then
            return nil, nil, mail.from, "Subject", mail.money or 0, mail.cod or 0, 30, #mail.items, false, mail.returned == true,
                false, true, false
        end
    end
    local function MailItem(index, slot)
        local mail = client.inbox[index]
        return mail and mail.items[slot] or nil
    end
    api.GetInboxItem = function(index, slot)
        local item = MailItem(index, slot)
        if item then
            return "Item" .. item[1], item[1], 3, item[2], 1, true
        end
    end
    api.GetInboxItemLink = function(index, slot)
        return ItemLink(MailItem(index, slot))
    end
    -- The server answers a moment later: the items go to the bags (or the
    -- bags are full), and a mail left empty is deleted. Taking an item pays
    -- the mail's cash on delivery.
    -- what: "item" (one slot), "money" or "all".
    local function Take(index, slot, what)
        local mail = client.inbox[index]
        if not mail then
            return
        end
        world:Schedule(0.1, function()
            if what ~= "money" then
                if client.bagsFull then
                    world:FireEvent(client, "UI_ERROR_MESSAGE", 2, api.ERR_INV_FULL)
                    return
                end
                if (mail.cod or 0) > 0 then
                    client.money = (client.money or 0) - mail.cod
                    mail.cod = 0
                end
                for i = slot or 1, slot or #mail.items do
                    local item = mail.items[i]
                    if item then
                        client.bags = client.bags or {}
                        client.bags[item[1]] = (client.bags[item[1]] or 0) + item[2]
                        mail.items[i] = false
                    end
                end
            end
            if what ~= "item" then
                client.money = (client.money or 0) + (mail.money or 0)
                mail.money = 0
            end
            local left = (mail.money or 0) > 0
            for _, item in ipairs(mail.items) do
                left = left or item ~= false
            end
            if not left then
                for i, other in ipairs(client.inbox) do
                    if other == mail then
                        table.remove(client.inbox, i)
                        break
                    end
                end
            end
            world:FireEvent(client, "MAIL_INBOX_UPDATE")
        end, client)
    end
    api.TakeInboxItem = function(index, slot)
        Take(index, slot, "item")
    end
    api.TakeInboxMoney = function(index)
        Take(index, nil, "money")
    end
    api.AutoLootMailItem = function(index)
        Take(index, nil, "all")
    end
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

    -- The character ------------------------------------------------------------
    api.UnitLevel = function()
        return client.level
    end
    api.UnitClass = function()
        return H.CLASS_NAMES[client.classID], H.CLASS_FILES[client.classID], client.classID
    end
    api.UnitRace = function()
        local race = H.RACES[client.raceID]
        return race[2], race[1], client.raceID
    end
    api.UnitSex = function()
        return client.sex
    end
    api.UnitFactionGroup = function()
        return client.faction, client.faction
    end
    api.C_CreatureInfo = {
        GetClassInfo = function(classID)
            local file = H.CLASS_FILES[classID]
            if not file then
                return nil
            end
            return { className = (client.locale == "esES" and "Clase " or "") .. H.CLASS_NAMES[classID], classFile = file, classID = classID }
        end,
        GetRaceInfo = function(raceID)
            local race = H.RACES[raceID]
            return race and { raceName = race[2], clientFileString = race[1], raceID = raceID } or nil
        end,
    }
    api.GetAverageItemLevel = function()
        local itemLevel = client.itemLevel or 0
        return itemLevel + 1, itemLevel, itemLevel
    end
    api.INVSLOT_FIRST_EQUIPPED, api.INVSLOT_LAST_EQUIPPED = 1, 19
    -- The equipped items by slot (1 to 19); the bags in the bag slots are
    -- inventory slots 100 + bag (C_Container.ContainerIDToInventoryID).
    api.GetInventoryItemLink = function(_, slot)
        if slot >= 100 then
            local bag = client.bagItems[slot - 100]
            return bag and ("|cffffffff|Hitem:%d::::::::60:::::|h[Bag%d]|h|r"):format(bag, bag) or nil
        end
        local item = client.gear[slot]
        return item and item.link or nil
    end
    api.ItemLocation = {
        CreateFromEquipmentSlot = function(_, slot)
            return { slot = slot }
        end,
        CreateFromBagAndSlot = function(_, bag, slot)
            return { bag = bag, slot = slot }
        end,
    }
    api.C_Item.GetCurrentItemLevel = function(location)
        local item = client.gear[location.slot]
        return item and item.il or nil
    end

    -- Talents (see H.TREE) -----------------------------------------------------------
    local tree = H.TREE
    local function NodeByID(nodeID)
        for _, node in ipairs(tree.nodes) do
            if node[1] == nodeID then
                return node
            end
        end
        if nodeID == tree.hidden[1] then
            return tree.hidden
        end
    end
    local function ConfigOf(group)
        return client.talents and client.talents.groups[group] and (500 + group) or nil
    end
    local function RanksOf(configID)
        return client.talents and client.talents.groups[configID - 500] or {}
    end
    api.GetNumSpecGroups = function()
        local count = 0
        for _ in pairs(client.talents and client.talents.groups or {}) do
            count = count + 1
        end
        return math.max(count, 1)
    end
    api.C_SpecializationInfo = {
        GetActiveSpecGroup = function()
            return client.talents and client.talents.active or 1
        end,
        GetCombatConfigIDForSpecGroup = function(group)
            return ConfigOf(group)
        end,
    }
    api.C_ClassTalents = {
        GetActiveConfigID = function()
            return ConfigOf(client.talents and client.talents.active or 1)
        end,
    }
    api.Enum.TraitNodeType = { Single = 0, Tiered = 1, Selection = 2, SubTreeSelection = 3 }
    api.C_Traits = {
        GetConfigInfo = function(configID)
            return { ID = configID, name = "Config " .. configID, treeIDs = { tree.id } }
        end,
        ConfigHasStagedChanges = function()
            return client.talents ~= nil and client.talents.staged == true
        end,
        GetTreeNodes = function()
            local ids = {}
            for _, node in ipairs(tree.nodes) do
                ids[#ids + 1] = node[1]
            end
            ids[#ids + 1] = tree.hidden[1]
            return ids
        end,
        GetNodeInfo = function(configID, nodeID)
            local node = NodeByID(nodeID)
            if not node then
                return { ID = 0 }
            end
            local rank = RanksOf(configID)[nodeID] or 0
            local x, y = H.NodePosition(node)
            return {
                ID = nodeID, isVisible = node ~= tree.hidden, type = 0, posX = x, posY = y, maxRanks = node[5],
                activeRank = rank, ranksPurchased = rank, currentRank = rank, groupIDs = { 1, tree.tabs[node[2]].groupID },
                entryIDs = { nodeID * 10 }, activeEntry = { entryID = nodeID * 10, rank = rank },
            }
        end,
        GetEntryInfo = function(_, entryID)
            return { definitionID = entryID + 1, maxRanks = 5 }
        end,
        GetDefinitionInfo = function(definitionID)
            return { spellID = 40000 + (definitionID - 1) / 10 }
        end,
        GetGroupDisplayInfoByTreeID = function()
            local list = {}
            for i, tab in ipairs(tree.tabs) do
                list[i] = { groupID = tab.groupID, treeID = tree.id, displayName = tab.name, icon = i, orderIndex = i }
            end
            return list
        end,
        GetGroupCurrencyInfo = function(configID, groupIDs)
            local list = {}
            for _, groupID in ipairs(groupIDs) do
                local spent = 0
                for nodeID, rank in pairs(RanksOf(configID)) do
                    local node = NodeByID(nodeID)
                    if node and tree.tabs[node[2]].groupID == groupID then
                        spent = spent + rank
                    end
                end
                list[#list + 1] = { traitNodeGroupID = groupID, currencyInfos = { { spent = spent, quantity = 0 } } }
            end
            return list
        end,
        GetTreeCurrencyInfo = function()
            return { { quantity = client.talents and client.talents.unspent or 0, spent = 0 } }
        end,
    }

    -- Items --------------------------------------------------------------------
    -- A client has an item loaded, as a game that has seen it, but for those
    -- it cannot have seen yet:
    -- * the items in world.unloaded, which no client has;
    -- * the items only other characters carry (their gear and containers),
    --   which it knows of only from addon data.
    -- C_Item.RequestLoadItemDataByID loads such an item half a second later,
    -- with ITEM_DATA_LOAD_RESULT. Loaded, an item is an epic (quality 4),
    -- named "Item <ID>" by C_Item.GetItemInfo and "Item<ID>" by
    -- C_Item.GetItemNameByID (each form is the one some addon's tests read).
    client.itemsLoaded = client.itemsLoaded or {} -- [itemID] = true once requested
    local function Carries(character, itemID)
        for _, item in pairs(character.gear) do
            if tonumber(tostring(item.link):match("item:(%d+)")) == itemID then
                return true
            end
        end
        for _, container in pairs(character.containers) do
            for _, item in pairs(container) do
                if type(item) == "table" and item[1] == itemID then
                    return true
                end
            end
        end
        return false
    end
    local function ItemLoaded(itemID)
        if world.unloaded[itemID] then
            return false
        end
        if client.itemsLoaded[itemID] or Carries(client, itemID) then
            return true
        end
        for _, other in ipairs(world.clients) do
            if other ~= client and Carries(other, itemID) then
                return false
            end
        end
        return true
    end
    local function ItemID(item)
        return tonumber(tostring(item):match("item:(%d+)") or item)
    end
    api.C_Item.RequestLoadItemDataByID = function(itemID)
        itemID = ItemID(itemID)
        if itemID and not ItemLoaded(itemID) then
            world:Schedule(0.5, function()
                world.unloaded[itemID] = nil
                client.itemsLoaded[itemID] = true
                world:FireEvent(client, "ITEM_DATA_LOAD_RESULT", itemID, true)
            end, client)
        end
    end
    api.C_Item.GetItemInfo = function(item)
        local itemID = ItemID(item)
        if not itemID or not ItemLoaded(itemID) then
            return nil
        end
        return "Item " .. itemID, "|cffa335ee|Hitem:" .. itemID .. "|h[Item]|h|r", 4
    end
    api.C_Item.GetItemNameByID = function(itemID)
        itemID = ItemID(itemID)
        return itemID and ItemLoaded(itemID) and "Item" .. itemID or nil
    end
    api.C_Item.GetItemQualityByID = function(itemID)
        itemID = ItemID(itemID)
        return itemID and ItemLoaded(itemID) and 4 or nil
    end
    -- Stacks of 20, but for the items given in world.maxStacks.
    api.C_Item.GetItemMaxStackSizeByID = function(itemID)
        return world.maxStacks and world.maxStacks[itemID] or 20
    end

    return env
end

-- JSON reading (independent of the addon's writer) -----------------------------------

local NULL = setmetatable({}, { __tostring = function() return "null" end })
H.NULL = NULL

-- Decodes JSON text strictly; raises on anything invalid. Objects become
-- tables with their keys in _order; null becomes H.NULL.
function H.DecodeJSON(text)
    local pos = 1
    local function Fail(message)
        error(("JSON error at %d: %s (near %q)"):format(pos, message, text:sub(pos, pos + 20)), 0)
    end
    local function Skip()
        pos = text:find("[^ \t\r\n]", pos) or #text + 1
    end
    local Value
    local function Codepoint(code)
        if code < 0x80 then
            return string.char(code)
        elseif code < 0x800 then
            return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
        elseif code < 0x10000 then
            return string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
        end
        return string.char(0xF0 + math.floor(code / 262144), 0x80 + math.floor(code / 4096) % 64, 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
    end
    local function String()
        pos = pos + 1
        local out = {}
        while true do
            local c = text:sub(pos, pos)
            if c == "" then
                Fail("unterminated string")
            elseif c == '"' then
                pos = pos + 1
                return table.concat(out)
            elseif c == "\\" then
                local e = text:sub(pos + 1, pos + 1)
                local simple = ({ ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" })[e]
                if simple then
                    out[#out + 1] = simple
                    pos = pos + 2
                elseif e == "u" then
                    local hex = text:sub(pos + 2, pos + 5)
                    if not hex:find("^%x%x%x%x$") then
                        Fail("bad \\u escape")
                    end
                    out[#out + 1] = Codepoint(tonumber(hex, 16))
                    pos = pos + 6
                else
                    Fail("bad escape")
                end
            elseif c:byte() < 32 then
                Fail("control character in string")
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
    end
    function Value()
        Skip()
        local c = text:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local object = { _order = {} }
            Skip()
            if text:sub(pos, pos) == "}" then
                pos = pos + 1
                return object
            end
            while true do
                Skip()
                if text:sub(pos, pos) ~= '"' then
                    Fail("expected a key")
                end
                local key = String()
                Skip()
                if text:sub(pos, pos) ~= ":" then
                    Fail("expected ':'")
                end
                pos = pos + 1
                if object[key] ~= nil then
                    Fail("duplicate key " .. key)
                end
                object[key] = Value()
                object._order[#object._order + 1] = key
                Skip()
                local d = text:sub(pos, pos)
                pos = pos + 1
                if d == "}" then
                    return object
                elseif d ~= "," then
                    Fail("expected ',' or '}'")
                end
            end
        elseif c == "[" then
            pos = pos + 1
            local array = {}
            Skip()
            if text:sub(pos, pos) == "]" then
                pos = pos + 1
                return array
            end
            while true do
                array[#array + 1] = Value()
                Skip()
                local d = text:sub(pos, pos)
                pos = pos + 1
                if d == "]" then
                    return array
                elseif d ~= "," then
                    Fail("expected ',' or ']'")
                end
            end
        elseif c == '"' then
            return String()
        elseif text:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif text:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif text:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return NULL
        else
            local number = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
            if not number or number == "" or number == "-" then
                Fail("unexpected character")
            end
            pos = pos + #number
            return tonumber(number) or Fail("bad number")
        end
    end
    local value = Value()
    Skip()
    if pos <= #text then
        Fail("text after the value")
    end
    return value
end

-- Saved variables files ---------------------------------------------------------------

-- A string as a Lua literal. style "wow" escapes like the game's writer
-- (backslash, quote, \n, \r, other control bytes as \ddd); "q" uses Lua's %q.
function H.LuaString(text, style)
    if style == "q" then
        return ("%q"):format(text)
    end
    return '"' .. text:gsub('[%c"\\]', function(c)
        local named = ({ ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r" })[c]
        return named or ("\\%03d"):format(c:byte())
    end) .. '"'
end

local function Serialize(value, indent, style, out)
    local kind = type(value)
    if kind == "string" then
        out[#out + 1] = H.LuaString(value, style)
    elseif kind == "number" or kind == "boolean" then
        out[#out + 1] = tostring(value)
    elseif kind == "table" then
        out[#out + 1] = "{\n"
        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
            if type(a) ~= type(b) then
                return type(a) < type(b)
            end
            return a < b
        end)
        for _, key in ipairs(keys) do
            out[#out + 1] = indent .. "\t[" .. (type(key) == "string" and H.LuaString(key, style) or tostring(key)) .. "] = "
            Serialize(value[key], indent .. "\t", style, out)
            out[#out + 1] = ",\n"
        end
        out[#out + 1] = indent .. "}"
    else
        out[#out + 1] = "nil"
    end
end

-- Writes variables { { name, value }, ... } the way the client writes a
-- saved variables file.
function H.WriteSavedVariables(path, variables, style)
    local out = {}
    for _, variable in ipairs(variables) do
        out[#out + 1] = "\n" .. variable[1] .. " = "
        Serialize(variable[2], "", style, out)
        out[#out + 1] = "\n"
    end
    local file = assert(io.open(path, "wb"))
    file:write(table.concat(out))
    file:close()
end

return H
