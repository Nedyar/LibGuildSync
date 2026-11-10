-- 한국어.
local _, ns = ...

ns.RegisterLocale("koKR", function(L)
    L["a moment"] = "잠시"
    L["a guild member uses a newer version of %s that this one cannot talk to. Please update."] = "어떤 길드원이 이 버전과 통신할 수 없는 새 버전의 %s를 사용하고 있습니다. 애드온을 업데이트하세요."
    L["a newer version of %s (%s) is in use in your guild."] = "길드에서 새 버전의 %s(%s)를 사용하고 있습니다."
    L["sync finished: %d |4record:records; received from %s."] = "동기화 완료: 기록 %d개 받음 (보낸 사람: %s)."
    L["you are not in a guild (or the guild has not loaded yet)."] = "길드에 속해 있지 않습니다 (또는 길드 정보를 아직 불러오지 않았습니다)."
    L["a sync is already running."] = "이미 동기화가 진행 중입니다."
    L["nobody online has data you are missing."] = "접속 중인 길드원 중 빠진 데이터를 가진 사람이 없습니다."
    L["asking the guild for missing data..."] = "빠진 데이터를 길드에 요청하는 중..."
    L["waiting for offers"] = "응답 기다리는 중"
    L["receiving from %s (%d |4record:records; so far)"] = "%s에게서 받는 중 (지금까지 기록 %d개)"
    L["sending to %d |4member:members;"] = "길드원 %d명에게 보내는 중"
    L["%d |4message:messages; queued (%d |4part:parts;)"] = "대기 중인 메시지 %d개 (조각 %d개)"
    L["paused: addon messages are blocked here"] = "일시 중지: 여기서는 애드온 메시지가 차단됩니다"
    L["idle"] = "대기"
end)
