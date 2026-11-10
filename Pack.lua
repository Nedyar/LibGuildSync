-- Pack.lua: the compact binary form messages and records travel in (LEB128
-- numbers, length-prefixed texts, sorted ID lists), Base64 and hashing.
-- Plain Lua with no game API, so it can be tested outside the game. Each
-- addon's ns.Pack inherits these and adds its own records (see Core.lua).
local Lib = LibGuildSync

local Pack = {}
Lib.Pack = Pack

local byte, char, floor, sub = string.byte, string.char, math.floor, string.sub
local concat = table.concat

-- The longest text a reader takes unless told otherwise, and the longest ID
-- list.
Pack.LIMITS = {
    text = 64,
    list = 5000,
}

local TWO_32 = 4294967296
local TWO_53 = 9007199254740992

-- Writer ---------------------------------------------------------------------

local Writer = {}
Writer.__index = Writer

function Pack.Writer()
    return setmetatable({ n = 0 }, Writer)
end

function Writer:Byte(value)
    self.n = self.n + 1
    self[self.n] = char(value)
end

-- Unsigned integers take 7 bits per byte (LEB128): 1 byte below 128, 2
-- below 16384, 3 below about two million (item IDs, for one).
function Writer:UInt(value)
    value = floor(value)
    if value < 0 or value >= TWO_53 then
        error("number out of range: " .. tostring(value), 2)
    end
    while value >= 128 do
        self:Byte(value % 128 + 128)
        value = floor(value / 128)
    end
    self:Byte(value)
end

-- Signed integers: 0, -1, 1, -2... become 0, 1, 2, 3...
function Writer:Int(value)
    value = floor(value)
    self:UInt(value >= 0 and value * 2 or -value * 2 - 1)
end

function Writer:Str(text)
    self:UInt(#text)
    self:Raw(text)
end

-- Appends bytes that are already packed.
function Writer:Raw(text)
    self.n = self.n + 1
    self[self.n] = text
end

function Writer:Size()
    local size = 0
    for i = 1, self.n do
        size = size + #self[i]
    end
    return size
end

function Writer:Result()
    return concat(self, "", 1, self.n)
end

-- Reader ---------------------------------------------------------------------

-- Every read raises on malformed input; callers read under pcall.
local Reader = {}
Reader.__index = Reader

function Pack.Reader(text)
    return setmetatable({ s = text, pos = 1, len = #text }, Reader)
end

function Reader:Byte()
    local value = byte(self.s, self.pos)
    if not value or self.pos > self.len then
        error("truncated message", 0)
    end
    self.pos = self.pos + 1
    return value
end

function Reader:UInt()
    local value, scale = 0, 1
    for _ = 1, 8 do
        local b = self:Byte()
        if b < 128 then
            return value + b * scale
        end
        value = value + (b - 128) * scale
        scale = scale * 128
    end
    error("malformed number", 0)
end

function Reader:Int()
    local value = self:UInt()
    if value % 2 == 0 then
        return value / 2
    end
    return -(value + 1) / 2
end

function Reader:Str(maxLength)
    local length = self:UInt()
    if length > (maxLength or Pack.LIMITS.text) then
        error("text too long", 0)
    end
    if self.pos + length - 1 > self.len then
        error("truncated message", 0)
    end
    local text = sub(self.s, self.pos, self.pos + length - 1)
    self.pos = self.pos + length
    return text
end

-- A reader over the next length bytes, which this reader skips.
function Reader:Sub(length)
    if self.pos + length - 1 > self.len then
        error("truncated message", 0)
    end
    local inner = Pack.Reader(sub(self.s, self.pos, self.pos + length - 1))
    self.pos = self.pos + length
    return inner
end

function Reader:AtEnd()
    return self.pos > self.len
end

-- ID lists -------------------------------------------------------------------

-- A sorted list of distinct IDs (recipes, for one), stored as the gaps
-- between them: most gaps fit in one byte even where the IDs need three.
function Pack.WriteList(writer, list)
    writer:UInt(#list)
    local previous = 0
    for i = 1, #list do
        writer:UInt(list[i] - previous)
        previous = list[i]
    end
end

function Pack.ReadList(reader, max)
    local count = reader:UInt()
    if count > (max or Pack.LIMITS.list) then
        error("too many IDs", 0)
    end
    local list, previous = {}, 0
    for i = 1, count do
        local gap = reader:UInt()
        if gap == 0 then
            error("ID list not sorted", 0)
        end
        previous = previous + gap
        list[i] = previous
    end
    return list
end

-- Hashing --------------------------------------------------------------------

-- djb2, kept to 32 bits. Exact with Lua's doubles, so no bit library is needed.
function Pack.Hash(text, seed)
    local hash = seed or 5381
    for i = 1, #text do
        hash = (hash * 33 + byte(text, i)) % TWO_32
    end
    return hash
end

function Pack.AddHash(a, b)
    return (a + b) % TWO_32
end

-- Base64 ---------------------------------------------------------------------

-- The client's C_EncodingUtil does this natively; this version is the
-- fallback, and the digits are reused for the message headers.
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DIGIT, VALUE = {}, {}
for i = 1, 64 do
    local c = sub(ALPHABET, i, i)
    DIGIT[i - 1] = c
    VALUE[c] = i - 1
end

-- A single Base64 digit: 0..63 <-> one character.
function Pack.Digit(value)
    return DIGIT[value]
end

function Pack.DigitValue(c)
    return VALUE[c]
end

function Pack.ToBase64(text)
    local out = {}
    for i = 1, #text, 3 do
        local a, b, c = byte(text, i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        out[#out + 1] = DIGIT[floor(n / 262144)] .. DIGIT[floor(n / 4096) % 64]
            .. (b and DIGIT[floor(n / 64) % 64] or "=") .. (c and DIGIT[n % 64] or "=")
    end
    return concat(out)
end

function Pack.FromBase64(text)
    if #text % 4 ~= 0 then
        return nil
    end
    local out = {}
    for i = 1, #text, 4 do
        local c1, c2, c3, c4 = sub(text, i, i), sub(text, i + 1, i + 1), sub(text, i + 2, i + 2), sub(text, i + 3, i + 3)
        local v1, v2 = VALUE[c1], VALUE[c2]
        local v3, v4 = VALUE[c3], VALUE[c4]
        if not v1 or not v2 or (not v3 and c3 ~= "=") or (not v4 and c4 ~= "=") then
            return nil
        end
        -- Padding only at the very end, and "x=y" is never valid.
        if (not v4 and i + 3 < #text) or (not v3 and v4) then
            return nil
        end
        local n = v1 * 262144 + v2 * 4096 + (v3 or 0) * 64 + (v4 or 0)
        out[#out + 1] = char(floor(n / 65536))
        if v3 then
            out[#out + 1] = char(floor(n / 256) % 256)
        end
        if v4 then
            out[#out + 1] = char(n % 256)
        end
    end
    return concat(out)
end
