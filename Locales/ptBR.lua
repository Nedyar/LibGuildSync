-- Português (Brasil). ptPT clients use these texts too (see Locales.lua).
local _, ns = ...

ns.RegisterLocale("ptBR", function(L)
    L["a moment"] = "um momento"
    L["a guild member uses a newer version of %s that this one cannot talk to. Please update."] = "um membro da guilda usa uma versão mais nova do %s com a qual esta não consegue se comunicar. Atualize o addon."
    L["a newer version of %s (%s) is in use in your guild."] = "uma versão mais nova do %s (%s) está em uso na sua guilda."
    L["sync finished: %d |4record:records; received from %s."] = "sincronização concluída: %d |4registro recebido:registros recebidos; de %s."
    L["you are not in a guild (or the guild has not loaded yet)."] = "você não está em uma guilda (ou a guilda ainda não foi carregada)."
    L["a sync is already running."] = "já há uma sincronização em andamento."
    L["nobody online has data you are missing."] = "ninguém conectado tem dados que faltam para você."
    L["asking the guild for missing data..."] = "pedindo à guilda os dados que faltam..."
    L["waiting for offers"] = "aguardando ofertas"
    L["receiving from %s (%d |4record:records; so far)"] = "recebendo de %s (%d |4registro:registros; até agora)"
    L["sending to %d |4member:members;"] = "enviando para %d |4membro:membros;"
    L["%d |4message:messages; queued (%d |4part:parts;)"] = "%d |4mensagem:mensagens; na fila (%d |4parte:partes;)"
    L["paused: addon messages are blocked here"] = "em pausa: as mensagens de addons estão bloqueadas aqui"
    L["idle"] = "ociosa"
end)
