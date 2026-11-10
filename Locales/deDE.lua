-- Deutsch.
local _, ns = ...

ns.RegisterLocale("deDE", function(L)
    L["a moment"] = "wenige Sekunden"
    L["a guild member uses a newer version of %s that this one cannot talk to. Please update."] = "ein Gildenmitglied nutzt eine neuere Version von %s, mit der diese nicht kommunizieren kann. Bitte aktualisiere das Addon."
    L["a newer version of %s (%s) is in use in your guild."] = "in deiner Gilde wird eine neuere Version von %s (%s) verwendet."
    L["sync finished: %d |4record:records; received from %s."] = "Synchronisierung abgeschlossen: %d |4Eintrag:Einträge; von %s erhalten."
    L["you are not in a guild (or the guild has not loaded yet)."] = "du bist in keiner Gilde (oder die Gilde ist noch nicht geladen)."
    L["a sync is already running."] = "es läuft bereits eine Synchronisierung."
    L["nobody online has data you are missing."] = "niemand, der online ist, hat Daten, die dir fehlen."
    L["asking the guild for missing data..."] = "frage die Gilde nach fehlenden Daten..."
    L["waiting for offers"] = "warte auf Angebote"
    L["receiving from %s (%d |4record:records; so far)"] = "empfange von %s (bisher %d |4Eintrag:Einträge;)"
    L["sending to %d |4member:members;"] = "sende an %d |4Mitglied:Mitglieder;"
    L["%d |4message:messages; queued (%d |4part:parts;)"] = "%d |4Nachricht:Nachrichten; in der Warteschlange (%d |4Teil:Teile;)"
    L["paused: addon messages are blocked here"] = "pausiert: Addon-Nachrichten sind hier gesperrt"
    L["idle"] = "inaktiv"
end)
