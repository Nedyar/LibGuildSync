-- Русский. Counts take three forms: "|4one:few:many;".
local _, ns = ...

ns.RegisterLocale("ruRU", function(L)
    L["a moment"] = "мгновение"
    L["a guild member uses a newer version of %s that this one cannot talk to. Please update."] = "член гильдии использует более новую версию %s, с которой эта версия не может обмениваться данными. Обновите модификацию."
    L["a newer version of %s (%s) is in use in your guild."] = "в вашей гильдии используется более новая версия %s (%s)."
    L["sync finished: %d |4record:records; received from %s."] = "синхронизация завершена: получено %d |4запись:записи:записей; от %s."
    L["you are not in a guild (or the guild has not loaded yet)."] = "вы не состоите в гильдии (или гильдия еще не загрузилась)."
    L["a sync is already running."] = "синхронизация уже идет."
    L["nobody online has data you are missing."] = "ни у кого в сети нет данных, которых не хватает вам."
    L["asking the guild for missing data..."] = "запрос недостающих данных у гильдии..."
    L["waiting for offers"] = "ожидание предложений"
    L["receiving from %s (%d |4record:records; so far)"] = "получение от %s (пока %d |4запись:записи:записей;)"
    L["sending to %d |4member:members;"] = "отправка %d |4участнику:участникам:участникам;"
    L["%d |4message:messages; queued (%d |4part:parts;)"] = "%d |4сообщение:сообщения:сообщений; в очереди (%d |4часть:части:частей;)"
    L["paused: addon messages are blocked here"] = "пауза: здесь сообщения модификаций заблокированы"
    L["idle"] = "неактивна"
end)
