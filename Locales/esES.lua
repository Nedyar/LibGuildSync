-- Español (EU), used for esMX too (see Locales.lua).
local _, ns = ...

ns.RegisterLocale("esES", function(L)
    L["a moment"] = "un momento"
    L["a guild member uses a newer version of %s that this one cannot talk to. Please update."] = "un miembro de la hermandad usa una versión más nueva de %s con la que esta no puede comunicarse. Actualiza el addon."
    L["a newer version of %s (%s) is in use in your guild."] = "en tu hermandad se usa una versión más nueva de %s (%s)."
    L["sync finished: %d |4record:records; received from %s."] = "sincronización terminada: %d |4registro recibido:registros recibidos; de %s."
    L["you are not in a guild (or the guild has not loaded yet)."] = "no estás en una hermandad (o la hermandad aún no se ha cargado)."
    L["a sync is already running."] = "ya hay una sincronización en curso."
    L["nobody online has data you are missing."] = "nadie conectado tiene datos que te falten."
    L["asking the guild for missing data..."] = "pidiendo a la hermandad los datos que faltan..."
    L["waiting for offers"] = "esperando ofertas"
    L["receiving from %s (%d |4record:records; so far)"] = "recibiendo de %s (%d |4registro:registros; hasta ahora)"
    L["sending to %d |4member:members;"] = "enviando a %d |4miembro:miembros;"
    L["%d |4message:messages; queued (%d |4part:parts;)"] = "%d |4mensaje:mensajes; en cola (%d |4parte:partes;)"
    L["paused: addon messages are blocked here"] = "en pausa: aquí los mensajes de addons están bloqueados"
    L["idle"] = "inactiva"
end)
