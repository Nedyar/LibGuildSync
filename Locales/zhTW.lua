-- 繁體中文.
local _, ns = ...

ns.RegisterLocale("zhTW", function(L)
    L["a moment"] = "片刻"
    L["a guild member uses a newer version of %s that this one cannot talk to. Please update."] = "有公會成員使用較新版本的 %s，目前版本無法與之通訊。請更新插件。"
    L["a newer version of %s (%s) is in use in your guild."] = "你的公會中有人在使用較新版本的 %s（%s）。"
    L["sync finished: %d |4record:records; received from %s."] = "同步完成：收到 %d 筆記錄，來自 %s。"
    L["you are not in a guild (or the guild has not loaded yet)."] = "你不在公會中（或公會尚未載入）。"
    L["a sync is already running."] = "同步已在進行中。"
    L["nobody online has data you are missing."] = "線上的人沒有你缺少的資料。"
    L["asking the guild for missing data..."] = "正在向公會索取缺少的資料……"
    L["waiting for offers"] = "等待回應"
    L["receiving from %s (%d |4record:records; so far)"] = "正在接收 %s 的資料（目前 %d 筆記錄）"
    L["sending to %d |4member:members;"] = "正在傳送給 %d 名成員"
    L["%d |4message:messages; queued (%d |4part:parts;)"] = "%d 則訊息排隊中（%d 段）"
    L["paused: addon messages are blocked here"] = "已暫停：此處禁止插件訊息"
    L["idle"] = "閒置"
end)
