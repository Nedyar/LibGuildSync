-- lua5.1 Tests/run.lua <LibGuildSync folder> <tests folder> [test names...]
-- The library's tests run on Sync Fixture, a minimal addon built on it.
LIB_PATH = arg[1]
ADDON_PATH = arg[1] .. "/Tests/SyncFixture"
ADDON_NAME = "SyncFixture"
local TESTS = arg[2]
local H = dofile(TESTS .. "/harness.lua")

local names = { select(3, unpack(arg)) }
if #names == 0 then
    names = { "unit", "sync" }
end
for _, name in ipairs(names) do
    local chunk = assert(loadfile(TESTS .. "/test_" .. name .. ".lua"))
    local ok, err = xpcall(function()
        chunk(H)
    end, debug.traceback)
    if not ok then
        H.failures = H.failures + 1
        print("CRASH in " .. name .. ": " .. tostring(err))
    end
end
print(("\n%d passed, %d failed"):format(H.passes, H.failures))
os.exit(H.failures == 0 and 0 or 1)
