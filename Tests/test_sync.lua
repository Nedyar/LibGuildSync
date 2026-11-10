local H = ...

local function Errors(world, label)
    H.eq(#world.errors, 0, "no errors: " .. label)
    for _, err in ipairs(world.errors) do
        print("   " .. err)
    end
    world.errors = {}
end

local function RecordOf(client, other)
    local guild = client.ns.Data.GetGuild("Test Guild")
    return guild and guild.members[other.guid]
end

local function Printed(client, text, since)
    for i = (since or 0) + 1, #client.printed do
        if client.printed[i]:find(text, 1, true) then
            return true
        end
    end
    return false
end

H.section("Sync: two members online")
local world = H.NewWorld({ seed = 7, senderFormat = "short", strictWhispers = true })
local alice = world:NewClient("Alice Smith")
local bob = world:NewClient("Bob Jones")
local carol = world:NewClient("Carol White")
world:AddMember("Dan Brown", nil, { class = "PRIEST", level = 42 })
world:Login(alice)
world:RunFor(5)
alice.ns.SetOwn("Alice's note", { 4, 8, 15 })
world:Login(bob)
world:RunFor(120)
Errors(world, "two members online")
H.check(RecordOf(bob, alice) ~= nil and RecordOf(bob, alice).v == "Alice's note", "Bob has Alice's record")
H.check(RecordOf(bob, alice) and H.SameList(RecordOf(bob, alice).k, { 4, 8, 15 }), "with her list")
H.check(RecordOf(alice, bob) ~= nil, "Alice has Bob's")

H.section("Sync: a member logs in later")
world:Logout(bob)
world:RunFor(10)
world:Login(carol)
world:RunUntil(function()
    return RecordOf(carol, bob) ~= nil and RecordOf(carol, alice) ~= nil
end, 180)
Errors(world, "later login")
H.check(RecordOf(carol, bob) ~= nil, "Carol gets Bob's record from Alice, though Bob is offline")
H.check(RecordOf(carol, bob) and not RecordOf(carol, bob).fh, "marked as relayed")

H.section("Sync: changes are announced")
local before = RecordOf(carol, alice).t
alice.ns.SetOwn("Changed", { 4, 8, 15, 16 })
world:RunFor(150)
Errors(world, "a change")
H.check(RecordOf(carol, alice).t > before and RecordOf(carol, alice).v == "Changed", "Carol gets Alice's newer record")
local sent = world.stats.guild
world:RunFor(600)
H.check(world.stats.guild - sent <= 2, "quiet when nothing changes (" .. (world.stats.guild - sent) .. " guild messages in 10 min)")

H.section("Sync: saved data")
world:Logout(carol)
world:RunFor(5)
H.eq(type(carol.saved.SyncFixtureDB.guilds["Test Guild"].members[alice.guid].b), "string", "records are saved packed")
world:Login(carol)
world:RunFor(5)
H.check(RecordOf(carol, alice) ~= nil and RecordOf(carol, alice).v == "Changed", "records come back after logging in again")
Errors(world, "saved data")

-- A member whose saved data was lost gets back what only the guild still has.
world:Logout(alice)
world:RunFor(5)
world:Login(alice, { brokenSavedVariables = true })
world:RunUntil(function()
    local own = alice.ns.Data.GetOwnRecord(false)
    return own and own.k ~= nil
end, 240)
local own = alice.ns.Data.GetOwnRecord(false)
H.check(own and H.SameList(own.k, { 4, 8, 15, 16 }), "a lost list comes back from the guild (Data.AdoptOwn)")
Errors(world, "lost data")

H.section("Sync: members who leave")
world:Login(bob)
world:RunFor(60)
world:Logout(bob)
world:RemoveMember(bob.key)
world:RosterChanged()
world:RunFor(150)
H.check(carol.ns.Data.GetGuild("Test Guild").members[bob.guid] ~= nil, "Bob's record stays for a while, in case the roster read was partial")
H.check(not carol.ns.Roster.IsKnownGUID(bob.guid), "but he is no longer in the roster")
Errors(world, "a member leaves")

H.section("Sync: manual sync")
local printed = #carol.printed
carol.ns.Sync.SendHello(true)
world:RunFor(30)
H.check(Printed(carol, "asking the guild", printed), "manual sync says it is asking")
H.check(Printed(carol, "nobody online has data you are missing", printed) or Printed(carol, "sync finished", printed), "and how it ended")
H.check(type(carol.ns.Sync.Describe()) == "string", "and describes itself")
Errors(world, "manual sync")

H.section("Versions and protocols")
-- A member on an older protocol the addon still reads.
local old = world:NewClient("Olaf Older", { globals = { SYNC_FIXTURE_PROTOCOL = "2" } })
world:Login(old)
world:RunFor(5)
old.ns.SetOwn("From protocol 2")
world:RunFor(150)
H.check(RecordOf(carol, old) ~= nil and RecordOf(carol, old).v == "From protocol 2", "records of an older protocol are read")
H.check(Printed(old, "a guild member uses a newer version of Sync Fixture that this one cannot talk to"),
    "a member on the older protocol is told to update")
Errors(world, "older protocol")
-- A newer version in the guild.
printed = #carol.printed
alice.ns.VERSION_NUM = 10300
alice.ns.SetOwn("From 1.3.0", { 1 })
world:RunFor(150)
H.check(Printed(carol, "a newer version of Sync Fixture (1.3.0) is in use in your guild", printed), "a newer version in the guild is noticed")
-- Another language for the library's texts.
local hans = world:NewClient("Hans Meyer", { globals = { SYNC_FIXTURE_LOCALE = "deDE" } })
world:Login(hans)
world:RunFor(150)
printed = #hans.printed
hans.ns.Sync.SendHello(true)
world:RunFor(30)
H.check(not Printed(hans, "asking the guild", printed) and #hans.printed > printed, "the sync's messages come in the addon's language")
Errors(world, "versions")
