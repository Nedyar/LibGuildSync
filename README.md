# LibGuildSync

Shared code for guild addons on WoW Forever (the `_forever_` client,
1.60.x). It does nothing on its own; install it because an addon you use
needs it (the CurseForge app does it for you).

What it gives each addon:

- **Hidden addon messages** on the addon's own prefix and protocol:
  compressed when that helps, split into chunks, queued under the server's
  limits and paused while messaging is locked down (boss encounters, Mythic+
  runs, PvP matches). Messages of older protocols the addon still reads
  reach it with their protocol.
- **The guild roster**, read once for every addon: members by GUID, their
  names as WoW Forever gives them (with spaces, without a realm), rank,
  note, level, who is online and when the others were last online.
- **A saved database of the members' records**, one per addon: each member
  owns their record and stamps every change with a time, so every client
  keeps the newest copy (then the most complete one) and all end up with
  the same. Records are saved packed (Base64), and members gone from the
  guild for a month are dropped.
- **The sync**: members announce their own changes to the guild, and a
  member who logs in compares digests with whoever is online and gets what
  they lack. When everybody agrees, logging in costs a single message.
- **Texts in every client language** for the sync's messages, in the
  language each addon shows its own.

## For addon authors

Depend on it in the TOC (`## Dependencies: LibGuildSync`), then attach the
addon's namespace when its files load:

```lua
local ADDON_NAME, ns = ...
ns.ADDON_NAME = ADDON_NAME

LibGuildSync.Attach(ns, {
    title = "My Guild Addon",         -- in the messages the player sees
    tag = "MGA",                      -- in the debug log
    prefix = "MyGuildAddon",          -- at most 16 characters
    trialPrefix = "MyGuildAddonDev",  -- used while trial is true
    trial = false,
    protocol = "1",                   -- one character, in every chunk
    legacy = nil,                     -- older protocols still read: { ["0"] = true }
    savedVariable = "MyGuildAddonDB",
})
```

`Attach` fills the namespace with:

| Field | What it is |
|---|---|
| `ns.Comm` | The addon's messages: `Send(payload, "GUILD" or "WHISPER", target, lane, onDone)`, `QueueSize()`, `IsPaused()` |
| `ns.Data` | The addon's database (see below) |
| `ns.Sync` | The addon's sync: `SendHello(manual)`, `Describe()`; replace `OwnReady()` |
| `ns.Roster` | The shared roster: `guildKey`, `members[guid]` (`n`, `c`, `l`, `rk`, `ri`, `nt`, `on`, `lo`), `ready`, `total`, `NameOf`, `GUIDOfSender`, `IsKnownGUID`, `IsOnline` |
| `ns.Pack` | `Writer`, `Reader`, `WriteList`, `ReadList`, `Hash`, `ToBase64`, `FromBase64`... and `RecordString` |
| `ns.Print`, `ns.Debug`, `ns.Try`, `ns.On`, `ns.Fire`, `ns.Debounce`, `ns.Ago` | The addon's own helpers |
| `ns.Plain`, `ns.Number`, `ns.Same`, `ns.CanRead`, `ns.Now`, `ns.IsMe`... | Shared helpers |
| `ns.TITLE`, `ns.VERSION`, `ns.VERSION_NUM`, `ns.PREFIX`, `ns.PROTOCOL`, `ns.TRIAL` | From the configuration and the TOC |

Then the addon describes its records, which hold `t` (time of the last
change), `av` (addon version), `n` (name) and `rl` (realm) plus its own
fields:

- `ns.Pack.WriteRecord(writer, guid, record)` and
  `ns.Pack.ReadRecord(reader, protocol)` (returns guid, record). Prefix the
  record with its length (`writer:Str(body)`) so later fields are skipped by
  older readers.
- `ns.Data.CleanRecord(record, now)`: a checked copy, or nil. Start from
  `ns.Data.CleanBase(record, now)`.
- `ns.Data.STATS` numbers from `ns.Data.Stats(record)`: how complete a copy
  is, compared in order when two copies have the same time.
- Optionally `ns.Data.CarryMissing(kept, other)` and
  `ns.Data.AdoptOwn(own, record)` (what a kept copy takes from another,
  true when it took anything), `ns.Data.NewOwnRecord()`,
  `ns.Data.SanitizeExtra(clean, saved)`, `ns.Data.PackExtra(db)` and
  `ns.Data.OnPrune(guild, present, now)`.

At `ADDON_LOADED` call `ns.Data.Load()`, at `PLAYER_LOGIN`
`LibGuildSync.Start(ns)`, and at `PLAYER_LOGOUT`
`ns.Data.PackForSave(ns.db)`. Change the player's own record through
`ns.Data.GetOwnRecord(true)` and `ns.Data.TouchOwn(record, kind)`, which
announces it (`kind`, optional, is a short text of the addon's own that
says what changed). Events reach the addon through `ns.On`: `GuildChanged`,
`RosterUpdated`, `DataChanged`, `RecordChanged`, `OwnChanged`,
`TargetOffline`.

### Going further (0.2.0 and later)

- **Quick changes**: `ns.Sync.QUICK_KINDS[kind] = true` announces changes
  of that kind within seconds instead of once things are quiet.
- **Shorter messages**: `ns.Sync.WriteOwnChange(record, state, pending)`
  returns a message for the changes waiting (`pending[kind] = true`;
  `state.sentT` is the time of the record last announced), started with
  `ns.Sync.Begin(type)`, or nil to send the whole record.
- **Message types of its own**: `ns.Sync.handlers[type] =
  function(reader, sender, guildKey, protocol)`, `type` being one byte
  other than `UHOMQRE`.
- **Older protocols**: members on a protocol in `legacy` are heard only for
  the types in `ns.Sync.LEGACY_TYPES` (the record announcements, `U`, by
  default); nobody answers their hellos, which come in a protocol they
  could not read the answers of.
- **Test messages**: with `probe = "0"` (a protocol character of their own)
  in the configuration, `ns.Comm.SendProbe(text, channel, target)` sends one
  at once and returns what the server answered, and
  `ns.Comm.probeHandler(text, channel, sender)` gets them, ours included.
- **A saved form of its own**, for an addon that saved its records another
  way before it used the library: `ns.Data.UpgradeSaved(db)` (an older form
  brought up to date before it is checked), `ns.Data.SaveRecord(guid,
  record)` and `ns.Data.LoadRecord(saved, key)` (returns guid, record).
- `ns.Roster.OnlineCount()`: how many members are online.

## Tests

The tests run outside the game with Lua 5.1, from the library's folder:

```
lua5.1 Tests\run.lua . Tests
```

They load the library and Sync Fixture (`Tests/SyncFixture`, a minimal
addon built on it) into simulated clients that talk through a simulated
server. The harness (`Tests/harness.lua`) is shared: each guild addon's
tests load it from the `LibGuildSync` folder next to theirs. It simulates
what those addons read from the game (the roster, professions, talents,
gear, bags, bank, trades and mail), and `H.Release(tag)` extracts an
addon's earlier release from its git tag, so a test can put members on
that release in the same guild as members on the current code.

## Releasing

Once the library has a CurseForge project with this repository's webhook,
CurseForge packages every tagged commit pushed here.

1. Raise `## Version` in `LibGuildSync.toc` and add that version's entry at
   the top of `CHANGELOG.md`. The tests check that both match. Keep every
   change backward compatible: addons released against an older version
   must keep working with the newer one.
2. Commit, tag the commit `v<version>` and push the tag.
3. CurseForge builds the zip as `.pkgmeta` says: the `LibGuildSync` folder
   without the tests.

## License

MIT. See [LICENSE](LICENSE).
