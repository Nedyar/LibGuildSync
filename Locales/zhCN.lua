-- 简体中文.
local _, ns = ...

ns.RegisterLocale("zhCN", function(L)
    L["a moment"] = "片刻"
    L["a guild member uses a newer version of %s that this one cannot talk to. Please update."] = "有公会成员使用了更新版本的 %s，当前版本无法与之通信。请更新插件。"
    L["a newer version of %s (%s) is in use in your guild."] = "你的公会中有人在使用更新版本的 %s（%s）。"
    L["sync finished: %d |4record:records; received from %s."] = "同步完成：收到 %d 条记录，来自 %s。"
    L["you are not in a guild (or the guild has not loaded yet)."] = "你不在公会中（或公会尚未加载）。"
    L["a sync is already running."] = "同步已在进行中。"
    L["nobody online has data you are missing."] = "在线的人中没有你缺少的数据。"
    L["asking the guild for missing data..."] = "正在向公会索取缺少的数据……"
    L["waiting for offers"] = "等待响应"
    L["receiving from %s (%d |4record:records; so far)"] = "正在接收 %s 的数据（目前 %d 条记录）"
    L["sending to %d |4member:members;"] = "正在发送给 %d 名成员"
    L["%d |4message:messages; queued (%d |4part:parts;)"] = "%d 条消息排队中（%d 段）"
    L["paused: addon messages are blocked here"] = "已暂停：此处禁止插件消息"
    L["idle"] = "空闲"
end)
