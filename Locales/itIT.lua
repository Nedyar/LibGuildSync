-- Italiano.
local _, ns = ...

ns.RegisterLocale("itIT", function(L)
    L["a moment"] = "un momento"
    L["a guild member uses a newer version of %s that this one cannot talk to. Please update."] = "un membro della gilda usa una versione più recente di %s con cui questa non può comunicare. Aggiorna l'add-on."
    L["a newer version of %s (%s) is in use in your guild."] = "nella tua gilda è in uso una versione più recente di %s (%s)."
    L["sync finished: %d |4record:records; received from %s."] = "sincronizzazione completata: %d |4voce ricevuta:voci ricevute; da %s."
    L["you are not in a guild (or the guild has not loaded yet)."] = "non sei in una gilda (o la gilda non è ancora stata caricata)."
    L["a sync is already running."] = "è già in corso una sincronizzazione."
    L["nobody online has data you are missing."] = "nessuno online ha dati che ti mancano."
    L["asking the guild for missing data..."] = "richiesta dei dati mancanti alla gilda..."
    L["waiting for offers"] = "in attesa di offerte"
    L["receiving from %s (%d |4record:records; so far)"] = "ricezione da %s (finora %d |4voce:voci;)"
    L["sending to %d |4member:members;"] = "invio a %d |4membro:membri;"
    L["%d |4message:messages; queued (%d |4part:parts;)"] = "%d |4messaggio:messaggi; in coda (%d |4parte:parti;)"
    L["paused: addon messages are blocked here"] = "in pausa: qui i messaggi degli add-on sono bloccati"
    L["idle"] = "inattiva"
end)
