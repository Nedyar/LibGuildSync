-- Locales: the library's texts (the sync's messages, mostly) in the
-- language of each addon that shows them.
--
-- The English text is the key, so the code reads in English and any text a
-- language file lacks shows in English. Each language file registers its
-- texts with ns.RegisterLocale; esMX starts from esES and would only
-- override what differs (nothing yet, so it has no file). An addon may show
-- its texts in another language than the client's ("/<addon> language"), so
-- the library keeps a table per language (ns.Texts) and each addon reads the
-- one of its own language (LibGuildSync.TextsFor). Texts that name the addon
-- take its title as a %s.
--
-- Every client language is translated. The client has no Japanese; enGB
-- uses the English texts and ptPT the Brazilian Portuguese ones. Counts use
-- the game's plural markup, "%d |4record:records;" (Russian has three
-- forms: "|4one:few:many;").
local _, ns = ...

local CLIENT_LOCALE = ({ enGB = "enUS", ptPT = "ptBR" })[GetLocale()] or GetLocale()
local CHAINS = { esMX = { "esES", "esMX" } }
local fills, tables = {}, {}

ns.CLIENT_LOCALE = CLIENT_LOCALE

function ns.RegisterLocale(code, fill)
    fills[code] = fill
end

-- The texts in a language (code nil: the client's).
function ns.Texts(code)
    code = code or CLIENT_LOCALE
    local texts = tables[code]
    if not texts then
        texts = setmetatable({}, {
            __index = function(_, key)
                return key
            end,
        })
        for _, part in ipairs(CHAINS[code] or { code }) do
            if fills[part] then
                fills[part](texts)
            end
        end
        tables[code] = texts
    end
    return texts
end
