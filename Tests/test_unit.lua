local H = ...

-- A single client gives access to the library and to Sync Fixture.
local world = H.NewWorld({ seed = 1 })
local solo = world:NewClient("Solo Name")
world:Login(solo)
world:RunFor(30)
local ns = solo.ns
local Lib = solo.env.LibGuildSync
local Pack, Data = ns.Pack, ns.Data
local now = ns.Now()

H.section("Loading")
H.eq(#world.errors, 0, "no errors while loading and starting")
for _, err in ipairs(world.errors) do
    print("   " .. err)
end
H.check(Lib ~= nil and Lib.VERSION ~= "0.0.0", "the library is loaded, with its version")

H.section("Attaching")
H.eq(ns.TITLE, "Sync Fixture", "the addon's title")
H.eq(ns.VERSION, "1.2.3", "its version, from its TOC")
H.eq(ns.VERSION_NUM, 10203, "as a number")
H.eq(ns.PREFIX, "SyncFixture", "its prefix")
H.check(ns.LISTEN.SyncFixture and not ns.TRIAL, "heard on its prefix, not in trial")
H.eq(ns.PROTOCOL, "3", "its protocol")
H.check(ns.Roster == Lib.Roster, "the roster is shared")
H.check(ns.Comm ~= nil and ns.Data ~= nil and ns.Sync ~= nil, "its own messages, data and sync")
H.eq(ns.playerName, "Solo Name", "the player's name")
H.check(ns.IsMe("Solo Name") and ns.IsMe("Solo Name-TestRealm") and not ns.IsMe("Other Name"), "messages from ourselves are told apart")
H.eq(Lib.VersionString(Lib.VersionNumber("2.10.3")), "2.10.3", "versions as numbers and back")
H.eq(Lib.VersionNumber("nonsense"), 0, "a bad version is 0")

H.section("Pack: numbers and texts")
for _, value in ipairs({ 0, 1, 127, 128, 255, 16383, 16384, 2 ^ 21, 1306126, 2 ^ 31, 2 ^ 40, 2 ^ 53 - 1 }) do
    local writer = Pack.Writer()
    writer:UInt(value)
    local reader = Pack.Reader(writer:Result())
    H.eq(reader:UInt(), value, "uint round trip " .. value)
    H.check(reader:AtEnd(), "uint fully read " .. value)
end
for _, value in ipairs({ 0, 1, -1, 63, -64, 64, 1000000, -1000000, 2 ^ 40, -(2 ^ 40) }) do
    local writer = Pack.Writer()
    writer:Int(value)
    H.eq(Pack.Reader(writer:Result()):Int(), value, "int round trip " .. value)
end
H.check(not pcall(function() Pack.Writer():UInt(-1) end), "negative uint refused")
H.check(not pcall(function() Pack.Reader(""):UInt() end), "truncated number refused")
H.check(not pcall(function() Pack.Reader(("\128"):rep(9)):UInt() end), "overlong number refused")
H.check(not pcall(function() Pack.Reader("\5ab"):Str() end), "truncated text refused")
H.check(not pcall(function() Pack.Reader("\100" .. ("x"):rep(100)):Str() end), "text over the limit refused")
local list = Pack.Writer()
Pack.WriteList(list, { 3, 10, 1306126 })
H.check(H.SameList(Pack.ReadList(Pack.Reader(list:Result())), { 3, 10, 1306126 }), "ID list round trip")
H.check(not pcall(Pack.ReadList, Pack.Reader(list:Result()), 2), "an ID list over the limit refused")
for _, text in ipairs({ "", "a", "ab", "abc", "\0\255\128", ("xyz"):rep(50) }) do
    H.eq(Pack.FromBase64(Pack.ToBase64(text)), text, "Base64 round trip of " .. #text .. " bytes")
end
H.eq(Pack.FromBase64("abc"), nil, "Base64 of a wrong length refused")
H.eq(Pack.FromBase64("a=bc"), nil, "Base64 padding in the middle refused")
H.eq(Pack.Hash("abc"), Pack.Hash("abc"), "hashing is stable")
H.check(Pack.Hash("abc") ~= Pack.Hash("abd"), "and tells texts apart")

H.section("Data: checking records")
local GUID, OTHER = "Player-1-0000000A", "Player-1-0000000B"
local record = { n = "Solo Name", rl = "TestRealm", t = now, av = 100, v = "note", k = { 1, 2, 3 } }
local key, back = Pack.ReadRecord(Pack.Reader(Pack.RecordString(GUID, record)), "3")
H.eq(key, GUID, "the addon's records pack, through ns.Pack")
H.check(ns.Same(back, record), "and read back")
H.check(Data.CleanRecord(record) ~= nil, "a good record passes")
H.eq(Data.CleanBase({ t = now + 3600 }, now), nil, "a record from the future is refused")
H.eq(Data.CleanBase({ t = 1000 }, now), nil, "and one from before 2020")
H.eq(Data.CleanBase({ t = now, n = "Evil|cffff0000Name" }, now).n, "Evilcffff0000Name", "escape sequences are stripped from names")
H.check(Data.IsShareable({ t = now }) and not Data.IsShareable({ t = 0 }), "records never stamped are not shared")

H.section("Data: merging")
local guild = { members = {} }
Data.MergeRecord(guild, OTHER, { t = now - 100, v = "a", k = { 5 } }, false)
H.check(not Data.MergeRecord(guild, OTHER, { t = now - 200, v = "old" }, false), "an older copy loses")
Data.MergeRecord(guild, OTHER, { t = now - 50, v = "b" }, true)
H.eq(guild.members[OTHER].v, "b", "a newer copy wins")
H.check(guild.members[OTHER].k ~= nil, "it keeps what only the older copy knew (Data.CarryMissing)")
guild.members[OTHER].k = nil
H.check(Data.MergeRecord(guild, OTHER, { t = now - 50, v = "b", k = { 1, 2 } }, false), "at the same time, the more complete copy wins")
H.check(not Data.MergeRecord(guild, OTHER, { t = now - 50, v = "b", k = { 1 } }, false), "comparing every stat in order")
H.check(Data.CompareVersions(5, { 1, 2 }, 5, { 1, 1 }) > 0 and Data.CompareVersions(6, { 0, 0 }, 5, { 1, 9 }) > 0,
    "time first, then the stats")

H.section("Data: saved form")
local savedGuild = Data.GetGuild("Test Guild", true)
savedGuild.members[GUID] = Data.CleanRecord(record)
local packed = H.DeepCopy(ns.db)
Data.PackForSave(packed)
H.eq(type(packed.guilds["Test Guild"].members[GUID].b), "string", "records are saved packed")
local loaded = Data.Sanitize(packed)
H.check(ns.Same(loaded.guilds["Test Guild"].members[GUID].k, record.k), "and come back")
local garbage = H.DeepCopy(packed)
garbage.guilds["Test Guild"].members[GUID] = { b = "!!!" }
garbage.guilds["Test Guild"].members["Player-1-0000000F"] = packed.guilds["Test Guild"].members[GUID]
loaded = Data.Sanitize(garbage)
H.check(loaded.guilds["Test Guild"].members[GUID] == nil, "an unreadable saved record is dropped")
H.check(loaded.guilds["Test Guild"].members["Player-1-0000000F"] == nil, "a record saved under another GUID is dropped")
H.check(next(Data.Sanitize("nonsense").guilds) == nil, "a broken database starts empty")
H.check(solo.env.SyncFixtureDB == ns.db, "the addon's saved variable is its database")
local twice = H.DeepCopy(ns.db)
Data.PackForSave(twice)
local first = twice.guilds["Test Guild"].members[GUID].b
Data.PackForSave(twice)
H.eq(twice.guilds["Test Guild"].members[GUID].b, first, "packing twice changes nothing")

-- An addon that saved its records its own way before it used the library.
Data.UpgradeSaved = function(db)
    -- Its first form knew guilds as "Name-Realm".
    if db.schema == 0 then
        db.guilds = { ["Test Guild"] = db.guilds["Test Guild-Old Realm"] }
    end
end
Data.SaveRecord = function(guid, saved)
    return { v = saved.v, t = saved.t, list = table.concat(saved.k or {}, ","), seen = saved.seen }
end
Data.LoadRecord = function(saved, key)
    local list = {}
    for id in tostring(saved.list or ""):gmatch("%d+") do
        list[#list + 1] = tonumber(id)
    end
    return key, { v = saved.v, t = saved.t, k = list, seen = saved.seen }
end
local own = H.DeepCopy(ns.db)
Data.PackForSave(own)
H.eq(own.guilds["Test Guild"].members[GUID].list, "1,2,3", "an addon may save records its own way")
loaded = Data.Sanitize(own)
H.check(ns.Same(loaded.guilds["Test Guild"].members[GUID].k, { 1, 2, 3 }), "and read them back")
own.schema, own.guilds = 0, { ["Test Guild-Old Realm"] = own.guilds["Test Guild"] }
loaded = Data.Sanitize(own)
H.check(loaded.guilds["Test Guild"] ~= nil and loaded.guilds["Test Guild"].members[GUID] ~= nil, "an older saved form is upgraded first")
Data.UpgradeSaved, Data.SaveRecord, Data.LoadRecord = nil, nil, nil

H.section("Roster")
H.eq(ns.Roster.OnlineCount(), 1, "members online")

H.section("Own record")
local own = Data.GetOwnRecord(false)
H.check(own ~= nil and Data.IsShareable(own), "the fixture's record is stamped once the guild is known")
H.eq(own and own.av, 10203, "with the addon's version")
H.eq(own and own.n, "Solo Name", "the character's name")
H.eq(own and own.rl, "TestRealm", "and realm")

H.section("Texts")
H.eq(Lib.TextsFor(ns)["idle"], "idle", "the library's texts, in the addon's language")
ns.LOCALE = "esES"
H.check(Lib.TextsFor(ns)["idle"] ~= "idle", "they follow the addon's language")
ns.LOCALE = "enUS"
H.eq(ns.Ago(now - 10), "a moment", "Ago, with the library's texts")

H.section("Locales")
local function ReadFile(path)
    local handle = io.open(path, "rb")
    if not handle then
        return nil
    end
    local text = handle:read("*a")
    handle:close()
    return text
end
local codeKeys = {}
for _, file in ipairs(H.ADDONS[1].files) do
    if not file:find("^Locales/") then
        for k in ReadFile(H.LIB .. "/" .. file):gmatch('L%["(.-)"%]') do
            codeKeys[k] = true
        end
    end
end
local function Specifiers(text)
    local found = {}
    for spec in text:gmatch("%%[%d%.]*[sdf]") do
        found[#found + 1] = spec
    end
    return table.concat(found, " ")
end
for _, locale in ipairs({ "deDE", "esES", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }) do
    local texts = {}
    local chunk = assert(loadfile(H.LIB .. "/Locales/" .. locale .. ".lua"))
    setfenv(chunk, setmetatable({}, { __index = _G }))
    chunk("LibGuildSync", { RegisterLocale = function(_, fill) fill(texts) end })
    local missing, extra, badSpecs = {}, {}, {}
    for k in pairs(codeKeys) do
        if texts[k] == nil then
            missing[#missing + 1] = k
        end
    end
    for k, v in pairs(texts) do
        if not codeKeys[k] then
            extra[#extra + 1] = k
        elseif Specifiers(k) ~= Specifiers(v) then
            badSpecs[#badSpecs + 1] = k
        end
    end
    H.check(#missing == 0, locale .. " has every text" .. (#missing > 0 and (": missing " .. table.concat(missing, " | ")) or ""))
    H.check(#extra == 0, locale .. " has no unused text" .. (#extra > 0 and (": " .. table.concat(extra, " | ")) or ""))
    H.check(#badSpecs == 0, locale .. " keeps the format specifiers" .. (#badSpecs > 0 and (": " .. table.concat(badSpecs, " | ")) or ""))
end

H.section("Release files")
local toc = ReadFile(H.LIB .. "/LibGuildSync.toc")
local changelog = ReadFile(H.LIB .. "/CHANGELOG.md")
local tocVersion = toc:match("## Version: ([%d%.]+)")
H.check(changelog ~= nil and changelog:match("## ([%d%.]+)") == tocVersion, "the TOC version is the changelog's newest")
local pkgmeta = ReadFile(H.LIB .. "/.pkgmeta")
H.check(pkgmeta ~= nil and pkgmeta:find("package%-as: LibGuildSync") ~= nil, ".pkgmeta packages the folder as LibGuildSync")
H.check(pkgmeta ~= nil and pkgmeta:find("\n    %- Tests\n") ~= nil, ".pkgmeta leaves the tests out of the package")
H.check(not toc:find("## SavedVariables", 1, true), "the library saves nothing of its own")
for _, file in ipairs(H.ADDONS[1].files) do
    H.check(ReadFile(H.LIB .. "/" .. file) ~= nil, "the TOC's file exists: " .. file)
end
