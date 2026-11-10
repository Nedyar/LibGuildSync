-- Français.
local _, ns = ...

ns.RegisterLocale("frFR", function(L)
    L["a moment"] = "un instant"
    L["a guild member uses a newer version of %s that this one cannot talk to. Please update."] = "un membre de la guilde utilise une version plus récente de %s avec laquelle celle-ci ne peut pas communiquer. Veuillez mettre à jour l'add-on."
    L["a newer version of %s (%s) is in use in your guild."] = "une version plus récente de %s (%s) est utilisée dans votre guilde."
    L["sync finished: %d |4record:records; received from %s."] = "synchronisation terminée : %d |4fiche reçue:fiches reçues; de %s."
    L["you are not in a guild (or the guild has not loaded yet)."] = "vous n'êtes pas dans une guilde (ou la guilde n'est pas encore chargée)."
    L["a sync is already running."] = "une synchronisation est déjà en cours."
    L["nobody online has data you are missing."] = "personne en ligne n'a de données qui vous manquent."
    L["asking the guild for missing data..."] = "demande des données manquantes à la guilde..."
    L["waiting for offers"] = "en attente d'offres"
    L["receiving from %s (%d |4record:records; so far)"] = "réception depuis %s (%d |4fiche:fiches; jusqu'ici)"
    L["sending to %d |4member:members;"] = "envoi à %d |4membre:membres;"
    L["%d |4message:messages; queued (%d |4part:parts;)"] = "%d |4message:messages; en file d'attente (%d |4partie:parties;)"
    L["paused: addon messages are blocked here"] = "en pause : les messages d'add-on sont bloqués ici"
    L["idle"] = "inactive"
end)
