-- ================================================================
--  TDS: REANIMATED — MACRO SCRIPT
--  Версия: 2.1.0
--  Исправлено: ошибка при выборе сложности во время записи
--  Исправлено: чтение лоадаута через GUI хотбара
--  Добавлено:  запись и воспроизведение выбора сложности
-- ================================================================
--
--  КАРТА СЛОЖНОСТЕЙ (внутренние названия игры):
--    Easy   → "Easy"
--    Molten → "Normal"
--    Hard   → "Hard"
--    Fallen → "Insane"
--
--  ЛОАДАУТ читается из:
--    PlayerGui.GameGui.Hotbar.Troops[1-5].Icon.ViewportFrame.WorldModel
--
--  ОШИБКА ИСПРАВЛЕНА:
--    hookmetamethod теперь НЕ оборачивает "Difficulty" в корутину.
--    Вызов сложности выполняется нормально, запись идёт асинхронно.
-- ================================================================

-- ════════════════════════════════════════════════════════════════
--  СЕРВИСЫ
-- ════════════════════════════════════════════════════════════════

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local VirtualUser       = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer

-- ════════════════════════════════════════════════════════════════
--  ПОДКЛЮЧЕНИЕ К ИГРЕ
-- ════════════════════════════════════════════════════════════════

if not game:IsLoaded() then game.Loaded:Wait() end

local RemoteFunction = ReplicatedStorage:WaitForChild("RemoteFunction", 15)
local RemoteEvent    = ReplicatedStorage:WaitForChild("RemoteEvent",    15)

local State   = ReplicatedStorage:WaitForChild("State", 15)
local RSWave  = State:WaitForChild("Wave",       10)  -- IntValue
local RSTimer = State:WaitForChild("Timer",      10)
      RSTimer = RSTimer:WaitForChild("Time",     10)  -- IntValue (секунды)
local RSDiff  = State:WaitForChild("Difficulty", 10)  -- StringValue
local RSMap   = State:WaitForChild("Map",        10)  -- StringValue
local RSMode  = State:WaitForChild("Mode",       10)  -- StringValue

if not RemoteFunction then
    error("[TDS Macro] RemoteFunction не найдена!")
end

-- ════════════════════════════════════════════════════════════════
--  RAYFIELD UI
-- ════════════════════════════════════════════════════════════════

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield", true))()

local Window = Rayfield:CreateWindow({
    Name                   = "TDS: Reanimated  |  Macro",
    LoadingTitle           = "Загрузка...",
    LoadingSubtitle        = "TDS: Reanimated Macro v2.1",
    Theme                  = "Default",
    DisableRayfieldPrompts = false,
    DisableBuildWarnings   = true,
    ConfigurationSaving    = {
        Enabled    = true,
        FolderName = "TDSReanimatedMacro",
        FileName   = "Config",
    },
    KeySystem = false,
})

local function Notify(title, text, duration)
    Rayfield:Notify({ Title=title, Content=text, Duration=duration or 3 })
end

-- ════════════════════════════════════════════════════════════════
--  ФАЙЛОВАЯ СИСТЕМА
-- ════════════════════════════════════════════════════════════════

local FOLDER = "TDSReanimated"
local STRATS = FOLDER .. "/Strats"

if not isfolder(FOLDER) then makefolder(FOLDER) end
if not isfolder(STRATS) then makefolder(STRATS) end

local function FileWrite(name, text)
    writefile(STRATS.."/"..name..".txt", tostring(text).."\n")
end
local function FileAppend(name, text)
    local path = STRATS.."/"..name..".txt"
    if isfile(path) then
        appendfile(path, tostring(text).."\n")
    else
        FileWrite(name, text)
    end
end
local function FileRead(name)
    local path = STRATS.."/"..name..".txt"
    if isfile(path) then return readfile(path) end
    return nil
end
local function GetAllStrats()
    local result = {}
    for _, path in ipairs(listfiles(STRATS)) do
        local name = path:match("([^/\\]+)%.txt$")
        if name then table.insert(result, name) end
    end
    return result
end

-- ════════════════════════════════════════════════════════════════
--  ТАЙМЕР И ВОЛНА
-- ════════════════════════════════════════════════════════════════

local function GetWave()
    return RSWave and RSWave.Value or 0
end

local function ConvertTimer(totalSec)
    return math.floor(totalSec / 60), totalSec % 60
end

local function TotalSec(min, sec)
    return (min * 60) + math.ceil(sec)
end

-- Субсекундная точность между тиками таймера
local SecondMili = 0
RSTimer.Changed:Connect(function()
    SecondMili = 0
    for i = 1, 9 do
        task.wait(0.09)
        SecondMili += 0.1
    end
end)

-- TimerCheck = true когда мы внутри волны
local TimerCheck = false
RSTimer.Changed:Connect(function(val)
    if val == 5 then
        TimerCheck = true
    elseif val and val > 5 then
        TimerCheck = false
    end
end)

local function GetTimer()
    local min, sec = ConvertTimer(RSTimer.Value)
    return { GetWave(), min, sec + SecondMili, tostring(TimerCheck) }
end

local function TimePrecise(sec)
    return (sec - math.floor(sec) - 0.13) + 0.5
end

-- ════════════════════════════════════════════════════════════════
--  ОЖИДАНИЕ ВОЛНЫ + МОМЕНТА
-- ════════════════════════════════════════════════════════════════

local RestartCount = 0

local function TimeWaveWait(wave, min, sec)
    local startCount = RestartCount

    repeat
        task.wait()
        if RestartCount ~= startCount then return false end
    until GetWave() >= wave

    if RSTimer.Value - TotalSec(min, sec) < -1 then
        return true
    end

    repeat
        task.wait()
        if RestartCount ~= startCount then return false end
    until RSTimer.Value - TotalSec(min, sec) <= 1

    if sec > 0 then
        task.wait(TimePrecise(sec))
    end

    return true
end

-- ════════════════════════════════════════════════════════════════
--  ТАБЛИЦА БАШЕН
-- ════════════════════════════════════════════════════════════════

local TowersContained = {}
TowersContained.Index = 0

local function WaitForTower(id)
    local skip = false
    task.delay(45, function() skip = true end)

    if not TowersContained[id] then
        repeat task.wait() until TowersContained[id] or skip
    end
    if TowersContained[id] and not TowersContained[id].Placed then
        repeat task.wait()
        until (TowersContained[id] and TowersContained[id].Placed) or skip
    end

    if skip then
        warn("[TDS Macro] Башня ID:"..id.." не найдена за 45 сек")
        return false
    end
    return true
end

-- ════════════════════════════════════════════════════════════════
--  СОСТОЯНИЕ МАКРОСА
-- ════════════════════════════════════════════════════════════════

local MacroState = {
    IsRecording = false,
    IsPlaying   = false,
    AutoSkip    = false,
    AutoSell    = true,
    AntiAFK     = true,
}

-- ════════════════════════════════════════════════════════════════
--  АНТИ-АФК
-- ════════════════════════════════════════════════════════════════

LocalPlayer.Idled:Connect(function()
    if MacroState.AntiAFK then
        VirtualUser:ClickButton2(Vector2.new())
        VirtualUser:Button2Down(Vector2.new(), Workspace.CurrentCamera.CFrame)
        task.wait(0.5)
        VirtualUser:Button2Up(Vector2.new(), Workspace.CurrentCamera.CFrame)
    end
end)

-- ════════════════════════════════════════════════════════════════
-- ══════════════════════════════════════════════════════════════
--
--                        RECORDER
--
-- ══════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════

local RecFileName = nil
local TowerCount  = 0

-- ─── ЛОАДАУТ — читаем из GUI хотбара ─────────────────────────
--
--  Путь: PlayerGui.GameGui.Hotbar.Troops[1..5]
--               .Icon.ViewportFrame.WorldModel."ИмяБашни"
--
-- Берём имя первого дочернего объекта внутри WorldModel —
-- это и есть название башни (Model с именем башни).

local RecordedTroops = {}

local function FetchLoadout()
    table.clear(RecordedTroops)

    local ok, hotbar = pcall(function()
        return LocalPlayer.PlayerGui
            :WaitForChild("GameGui",  5)
            :WaitForChild("Hotbar",   5)
            :WaitForChild("Troops",   5)
    end)

    if not ok or not hotbar then
        warn("[Recorder] Hotbar.Troops не найден — лоадаут будет пустым")
        return
    end

    -- Слоты 1..5
    for slot = 1, 5 do
        local frame = hotbar:FindFirstChild(tostring(slot))
        if not frame then continue end

        local worldModel = frame
            :FindFirstChild("Icon")
            and frame.Icon:FindFirstChild("ViewportFrame")
            and frame.Icon.ViewportFrame:FindFirstChild("WorldModel")

        if not worldModel then continue end

        -- Первый дочерний объект WorldModel = модель башни
        local towerModel = worldModel:FindFirstChildWhichIsA("Model")
        if towerModel and towerModel.Name ~= "" then
            table.insert(RecordedTroops, towerModel.Name)
            print(string.format("[Recorder] Слот %d → %s", slot, towerModel.Name))
        end
    end

    if #RecordedTroops == 0 then
        warn("[Recorder] Лоадаут пустой — убедись что башни экипированы")
    else
        print("[Recorder] Лоадаут: " .. table.concat(RecordedTroops, ", "))
    end
end

-- ─── Запись заголовка файла ───────────────────────────────────

local function WriteHeader()
    local mapName  = RSMap  and RSMap.Value  or "Unknown"
    local modeName = RSMode and RSMode.Value or "Survival"

    local lines = {}
    table.insert(lines, 'getgenv().StratCreditsAuthor = ""')
    table.insert(lines,
        'local TDS = loadstring(game:HttpGet(' ..
        '"https://raw.githubusercontent.com/Sigmanic/Strategies-X/main/TDS/MainSource.lua"' ..
        ', true))()')
    table.insert(lines, string.format('TDS:Map("%s", true, "%s")', mapName, modeName))

    if #RecordedTroops > 0 then
        local troopsStr = '"' .. table.concat(RecordedTroops, '", "') .. '"'
        table.insert(lines, string.format('TDS:Loadout({%s})', troopsStr))
    else
        table.insert(lines, '-- TDS:Loadout({}) -- лоадаут не был прочитан')
    end

    FileWrite(RecFileName, table.concat(lines, "\n"))
    print("[Recorder] Заголовок записан | Карта: "..mapName.." | Режим: "..modeName)
end

-- ════════════════════════════════════════════════════════════════
--  ГЕНЕРАТОРЫ СТРОК ДЕЙСТВИЙ
-- ════════════════════════════════════════════════════════════════

local Gen = {}

-- ─── Place ────────────────────────────────────────────────────
Gen.Place = function(Args, Timer, RemoteResult)
    -- Args = { "Troops", "Place", "TowerName", {Position=V3, Rotation=CF} }
    if typeof(RemoteResult) ~= "Instance" then
        warn("[Recorder] Place: RF вернул не Instance — пропускаю")
        return
    end

    local towerName    = Args[3]
    local pos          = Args[4].Position
    local rot          = Args[4].Rotation
    local rx, ry, rz   = rot:ToEulerAnglesYXZ()

    TowerCount      += 1
    RemoteResult.Name = TowerCount
    TowersContained[TowerCount] = {
        TowerName = towerName,
        Instance  = RemoteResult,
        Placed    = true,
    }
    TowersContained.Index = TowerCount

    local ts = table.concat(Timer, ", ")
    FileAppend(RecFileName, string.format(
        'TDS:Place("%s", %s, %s, %s, %s, %s, %s, %s)',
        towerName, pos.X, pos.Y, pos.Z, ts, rx, ry, rz))

    print(string.format("[Recorder] Place  %-12s ID:%-3d Wave:%d",
        towerName, TowerCount, Timer[1]))
end

-- ─── Upgrade ──────────────────────────────────────────────────
Gen.Upgrade = function(Args, Timer, RemoteResult)
    -- Args = { "Troops", "Upgrade", "Set", {Troop=instance} }
    local troop = Args[4] and Args[4].Troop
    if not troop then
        warn("[Recorder] Upgrade: нет Troop в аргументах")
        return
    end
    local id = tonumber(troop.Name)
    if not id then
        warn("[Recorder] Upgrade: Instance не имеет числового имени")
        return
    end
    if RemoteResult ~= true then
        warn("[Recorder] Upgrade FAILED ID:"..id)
        return
    end

    local ts = table.concat(Timer, ", ")
    FileAppend(RecFileName, string.format('TDS:Upgrade(%d, %s)', id, ts))
    print(string.format("[Recorder] Upgrade ID:%-3d Wave:%d", id, Timer[1]))
end

-- ─── Sell ─────────────────────────────────────────────────────
Gen.Sell = function(Args, Timer, RemoteResult)
    -- Args = { "Troops", "Sell", {Troop=instance} }
    local troop = Args[3] and Args[3].Troop
    if not troop then
        warn("[Recorder] Sell: нет Troop в аргументах")
        return
    end
    local id = tonumber(troop.Name)
    if not id then
        warn("[Recorder] Sell: Instance не имеет числового имени")
        return
    end

    local ts = table.concat(Timer, ", ")
    FileAppend(RecFileName, string.format('TDS:Sell(%d, %s)', id, ts))
    print(string.format("[Recorder] Sell   ID:%-3d Wave:%d", id, Timer[1]))
end

-- ─── Skip ─────────────────────────────────────────────────────
Gen.Skip = function(Args, Timer)
    -- Args = { "Waves", "Skip" }
    local ts = table.concat(Timer, ", ")
    FileAppend(RecFileName, string.format('TDS:Skip(%s)', ts))
    print(string.format("[Recorder] Skip  Wave:%d", Timer[1]))
end

-- ─── Target ───────────────────────────────────────────────────
Gen.Target = function(Args, Timer, RemoteResult)
    -- Args = { "Troops", "Target", "Set", {Troop=instance, Target="First"} }
    local troop      = Args[4] and Args[4].Troop
    local targetType = Args[4] and Args[4].Target or "First"
    if not troop then return end
    local id = tonumber(troop.Name)
    if not id then return end
    if RemoteResult ~= true then
        warn("[Recorder] Target FAILED ID:"..id)
        return
    end

    local ts = table.concat(Timer, ", ")
    FileAppend(RecFileName, string.format(
        'TDS:Target(%d, "%s", %s)', id, targetType, ts))
    print(string.format("[Recorder] Target ID:%-3d → %-10s Wave:%d",
        id, targetType, Timer[1]))
end

-- ─── Difficulty ───────────────────────────────────────────────
--
--  ВАЖНО: эта функция вызывается АСИНХРОННО (task.spawn),
--  НЕ через корутину — именно это исправляет ошибку.
--  Запись идёт параллельно, не блокируя игровой вызов.
--
Gen.Difficulty = function(Args, Timer)
    -- Args = { "Difficulty", "Vote", "Normal", false }
    local diffName = Args[3]  -- "Easy" / "Normal" / "Hard" / "Insane"
    if not diffName then return end

    -- Человекочитаемое название для лога
    local readableNames = {
        Easy   = "Easy",
        Normal = "Molten",
        Hard   = "Hard",
        Insane = "Fallen",
    }

    FileAppend(RecFileName, string.format('TDS:Mode("%s")', diffName))
    print(string.format("[Recorder] Difficulty → %s (%s)",
        diffName, readableNames[diffName] or diffName))
end

-- ════════════════════════════════════════════════════════════════
--  hookmetamethod — ЯДРО RECORDER
-- ════════════════════════════════════════════════════════════════
--
--  Логика перехвата:
--
--  ┌─────────────────────────────────────────────────────────┐
--  │ Вызов "Troops" / "Waves"                                │
--  │   → Оборачиваем в корутину                              │
--  │   → Выполняем RF, получаем результат                    │
--  │   → Записываем действие с результатом                   │
--  │   → Возвращаем результат игре                           │
--  ├─────────────────────────────────────────────────────────┤
--  │ Вызов "Difficulty"                                      │
--  │   → НЕ оборачиваем в корутину (это ломало игру!)        │
--  │   → Выполняем RF нормально через OldNamecall            │
--  │   → Записываем асинхронно в task.spawn                  │
--  │   → Игровой модуль Difficulties работает без ошибок     │
--  ├─────────────────────────────────────────────────────────┤
--  │ Все остальные вызовы                                    │
--  │   → Пропускаем без изменений (OldNamecall)              │
--  └─────────────────────────────────────────────────────────┘

-- Вызовы, которые используют корутину (нужен результат RF)
local CoroutineActions = {
    Place   = Gen.Place,
    Upgrade = Gen.Upgrade,
    Sell    = Gen.Sell,
    Target  = Gen.Target,
}

local OldNamecall
OldNamecall = hookmetamethod(game, "__namecall", function(...)
    local self = (...)
    local args = { select(2, ...) }

    -- Работаем только с RemoteFunction во время записи
    if self.Name ~= "RemoteFunction"
    or getnamecallmethod() ~= "InvokeServer"
    or not MacroState.IsRecording
    then
        return OldNamecall(...)
    end

    local category = args[1]  -- "Troops" / "Waves" / "Difficulty" / ...
    local action   = args[2]  -- "Place" / "Upgrade" / "Sell" / "Skip" / "Vote" / ...

    -- ── "Difficulty" "Vote" — асинхронная запись, НЕ корутина ──
    if category == "Difficulty" and action == "Vote" then
        -- Снимаем таймер ДО вызова (точный момент)
        local timer = GetTimer()
        -- Записываем асинхронно — не мешаем игровому коду
        task.spawn(Gen.Difficulty, args, timer)
        -- Выполняем оригинальный вызов без изменений
        return OldNamecall(...)
    end

    -- ── "Waves" "Skip" — пропуск волны ──
    if category == "Waves" and action == "Skip" then
        local thread = coroutine.running()
        coroutine.wrap(function(a)
            local timer    = GetTimer()
            local result   = self:InvokeServer(table.unpack(a))
            Gen.Skip(a, timer)
            coroutine.resume(thread, result)
        end)(args)
        return coroutine.yield()
    end

    -- ── "Troops" — размещение, апгрейд, продажа, цель ──
    if category == "Troops" and CoroutineActions[action] then
        local thread = coroutine.running()
        coroutine.wrap(function(a)
            local timer  = GetTimer()
            local result = self:InvokeServer(table.unpack(a))
            CoroutineActions[action](a, timer, result)
            coroutine.resume(thread, result)
        end)(args)
        return coroutine.yield()
    end

    -- ── Всё остальное — пропускаем без изменений ──
    return OldNamecall(...)
end)

-- ─── Авто-пропуск волн во время записи ───────────────────────

RSWave.Changed:Connect(function(newWave)
    if not MacroState.AutoSkip or newWave == 0 then return end
    if not MacroState.IsRecording and not MacroState.IsPlaying then return end
    task.wait(1)
    pcall(function()
        RemoteFunction:InvokeServer("Waves", "Skip")
    end)
    print("[Macro] AutoSkip → волна "..newWave)
end)

-- ─── Авто-продажа ферм (последняя волна) ─────────────────────

local LAST_WAVES = {
    Easy=25, Casual=30, Intermediate=30,
    Molten=35, Fallen=40, Hardcore=50,
    -- Внутренние названия TDS: Reanimated
    Normal=35, Hard=40, Insane=40,
}

RSWave.Changed:Connect(function(wave)
    if not MacroState.AutoSell then return end
    -- Определяем последнюю волну по текущей сложности
    local diff     = RSDiff.Value
    local lastWave = LAST_WAVES[diff]
    if not lastWave or wave ~= lastWave then return end

    task.wait(0.5)
    local towers = Workspace:FindFirstChild("Towers")
    if not towers then return end

    local count = 0
    for _, tower in ipairs(towers:GetChildren()) do
        local ownerVal = tower:FindFirstChild("Owner")  -- ObjectValue
        local typeVal  = tower:FindFirstChild("Type")   -- StringValue

        if  ownerVal and ownerVal.Value == LocalPlayer
        and typeVal  and typeVal.Value  == "Farm"
        then
            pcall(function()
                RemoteFunction:InvokeServer("Troops", "Sell", {Troop = tower})
            end)
            count += 1
            task.wait(0.05)
        end
    end

    if count > 0 then
        print("[Macro] AutoSell: продано ферм: "..count)
        Notify("AutoSell", "Продано ферм: "..count, 4)
    end
end)

-- ─── Старт / Стоп записи ─────────────────────────────────────

local function StartRecording()
    if MacroState.IsPlaying then
        Notify("Ошибка", "Сначала остановите воспроизведение!", 3)
        return
    end

    -- Сброс
    TowerCount = 0
    table.clear(TowersContained)
    TowersContained.Index = 0
    table.clear(RecordedTroops)

    RecFileName            = LocalPlayer.Name .. "'s strat"
    MacroState.IsRecording = true

    -- Читаем лоадаут из GUI
    FetchLoadout()
    -- Пишем заголовок в файл
    WriteHeader()

    print("[Recorder] ▶ Запись начата → "..RecFileName)
    Notify("▶ Запись начата", "Файл: "..RecFileName, 4)
end

local function StopRecording()
    if not MacroState.IsRecording then
        Notify("Запись не активна", "Нажми ▶ Начать запись", 3)
        return
    end
    MacroState.IsRecording = false
    print("[Recorder] ■ Запись остановлена → "..(RecFileName or "?"))
    Notify("■ Остановлено", "Сохранено: "..(RecFileName or "?"), 4)
end

-- ════════════════════════════════════════════════════════════════
-- ══════════════════════════════════════════════════════════════
--
--                        PLAYBACK
--
-- ══════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════

-- ─── Парсер файла стратегии ───────────────────────────────────

local function ParseFile(filename)
    local content = FileRead(filename)
    if not content then
        warn("[Playback] Файл не найден: "..filename)
        return nil
    end

    local commands = {}

    for line in content:gmatch("[^\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line == "" or line:sub(1,2) == "--" then continue end

        -- TDS:Place("Name", x,y,z, wave,min,sec,tc, rx,ry,rz)
        local nm,x,y,z,wv,mn,sc,tc,rx,ry,rz = line:match(
            'TDS:Place%("([^"]+)",%s*'..
            '([-%.%d]+),%s*([-%.%d]+),%s*([-%.%d]+),%s*'..
            '(%d+),%s*(%d+),%s*([-%.%d]+),%s*"([^"]*)",%s*'..
            '([-%.%d]+),%s*([-%.%d]+),%s*([-%.%d]+)%)')
        if nm then
            table.insert(commands,{
                Action="Place", TowerName=nm,
                X=tonumber(x), Y=tonumber(y), Z=tonumber(z),
                Wave=tonumber(wv), Min=tonumber(mn), Sec=tonumber(sc),
                RotX=tonumber(rx), RotY=tonumber(ry), RotZ=tonumber(rz),
            })
            continue
        end

        -- TDS:Upgrade(id, wave, min, sec, tc)
        local uid,uwv,umn,usc = line:match(
            'TDS:Upgrade%((%d+),%s*(%d+),%s*(%d+),%s*([-%.%d]+)')
        if uid then
            table.insert(commands,{
                Action="Upgrade", Id=tonumber(uid),
                Wave=tonumber(uwv), Min=tonumber(umn), Sec=tonumber(usc),
            })
            continue
        end

        -- TDS:Sell(id, wave, min, sec, tc)
        local sid,swv,smn,ssc = line:match(
            'TDS:Sell%((%d+),%s*(%d+),%s*(%d+),%s*([-%.%d]+)')
        if sid then
            table.insert(commands,{
                Action="Sell", Id=tonumber(sid),
                Wave=tonumber(swv), Min=tonumber(smn), Sec=tonumber(ssc),
            })
            continue
        end

        -- TDS:Skip(wave, min, sec, tc)
        local kwv,kmn,ksc = line:match(
            'TDS:Skip%((%d+),%s*(%d+),%s*([-%.%d]+)')
        if kwv then
            table.insert(commands,{
                Action="Skip",
                Wave=tonumber(kwv), Min=tonumber(kmn), Sec=tonumber(ksc),
            })
            continue
        end

        -- TDS:Target(id, "type", wave, min, sec, tc)
        local tid,ttype,twv,tmn,tsc = line:match(
            'TDS:Target%((%d+),%s*"([^"]+)",%s*(%d+),%s*(%d+),%s*([-%.%d]+)')
        if tid then
            table.insert(commands,{
                Action="Target", Id=tonumber(tid), TargetType=ttype,
                Wave=tonumber(twv), Min=tonumber(tmn), Sec=tonumber(tsc),
            })
            continue
        end

        -- TDS:Mode("Normal") — выбор сложности
        local mname = line:match('TDS:Mode%("([^"]+)"')
        if mname then
            table.insert(commands,{ Action="Mode", DiffName=mname })
            continue
        end
    end

    print(string.format("[Playback] Распарсено: %d команд из '%s'",
        #commands, filename))
    return commands
end

-- ─── Исполнители действий ────────────────────────────────────

local Play = {}

Play.Place = function(cmd)
    local ok = TimeWaveWait(cmd.Wave, cmd.Min, cmd.Sec)
    if not ok then return end

    local pos = Vector3.new(cmd.X, cmd.Y, cmd.Z)
    local rot = CFrame.fromEulerAnglesYXZ(cmd.RotX, cmd.RotY, cmd.RotZ)

    local placed
    local success = pcall(function()
        placed = RemoteFunction:InvokeServer("Troops", "Place", cmd.TowerName, {
            Position = pos,
            Rotation = rot,
        })
    end)

    if success and typeof(placed) == "Instance" then
        TowersContained.Index += 1
        local id = TowersContained.Index
        placed.Name = id
        TowersContained[id] = { TowerName=cmd.TowerName, Instance=placed, Placed=true }
        print(string.format("[Playback] Place  %-12s ID:%-3d Wave:%d",
            cmd.TowerName, id, cmd.Wave))
    else
        warn(string.format("[Playback] Place FAILED: %s Wave:%d", cmd.TowerName, cmd.Wave))
    end
end

Play.Upgrade = function(cmd)
    if not WaitForTower(cmd.Id) then return end
    local ok = TimeWaveWait(cmd.Wave, cmd.Min, cmd.Sec)
    if not ok then return end

    local tower = TowersContained[cmd.Id]
    if not tower or not tower.Instance then
        warn("[Playback] Upgrade: нет Instance ID:"..cmd.Id)
        return
    end
    pcall(function()
        RemoteFunction:InvokeServer("Troops", "Upgrade", "Set", {
            Troop = tower.Instance
        })
    end)
    print(string.format("[Playback] Upgrade ID:%-3d Wave:%d", cmd.Id, cmd.Wave))
end

Play.Sell = function(cmd)
    if not WaitForTower(cmd.Id) then return end
    local ok = TimeWaveWait(cmd.Wave, cmd.Min, cmd.Sec)
    if not ok then return end

    local tower = TowersContained[cmd.Id]
    if not tower or not tower.Instance then
        warn("[Playback] Sell: нет Instance ID:"..cmd.Id)
        return
    end
    pcall(function()
        RemoteFunction:InvokeServer("Troops", "Sell", { Troop = tower.Instance })
    end)
    print(string.format("[Playback] Sell   ID:%-3d Wave:%d", cmd.Id, cmd.Wave))
end

Play.Skip = function(cmd)
    local ok = TimeWaveWait(cmd.Wave, cmd.Min, cmd.Sec)
    if not ok then return end
    pcall(function()
        RemoteFunction:InvokeServer("Waves", "Skip")
    end)
    print(string.format("[Playback] Skip  Wave:%d", cmd.Wave))
end

Play.Target = function(cmd)
    if not WaitForTower(cmd.Id) then return end
    local ok = TimeWaveWait(cmd.Wave, cmd.Min, cmd.Sec)
    if not ok then return end

    local tower = TowersContained[cmd.Id]
    if not tower or not tower.Instance then return end
    pcall(function()
        RemoteFunction:InvokeServer("Troops", "Target", "Set", {
            Troop  = tower.Instance,
            Target = cmd.TargetType,
        })
    end)
    print(string.format("[Playback] Target ID:%-3d → %-10s Wave:%d",
        cmd.Id, cmd.TargetType, cmd.Wave))
end

-- Выбор сложности — выполняется при загрузке карты (волна 0)
Play.Mode = function(cmd)
    task.wait(0.5)
    pcall(function()
        RemoteFunction:InvokeServer("Difficulty", "Vote", cmd.DiffName, false)
    end)

    local readableNames = {
        Easy="Easy", Normal="Molten", Hard="Hard", Insane="Fallen"
    }
    print(string.format("[Playback] Mode → %s (%s)",
        cmd.DiffName, readableNames[cmd.DiffName] or cmd.DiffName))
end

-- ─── Запуск / Остановка воспроизведения ──────────────────────

local PlayThread = nil

local function StartPlayback(filename)
    if MacroState.IsRecording then
        Notify("Ошибка", "Сначала остановите запись!", 3)
        return
    end
    if MacroState.IsPlaying then
        Notify("Ошибка", "Воспроизведение уже запущено!", 3)
        return
    end

    local commands = ParseFile(filename)
    if not commands or #commands == 0 then
        Notify("Ошибка", "Файл пустой или не найден!", 4)
        return
    end

    table.clear(TowersContained)
    TowersContained.Index = 0
    RestartCount  += 1
    MacroState.IsPlaying = true

    Notify("▶ Воспроизведение",
        string.format("%d команд | '%s'", #commands, filename), 5)
    print(string.format("[Playback] ▶ Старт: '%s' (%d команд)",
        filename, #commands))

    PlayThread = task.spawn(function()
        for i, cmd in ipairs(commands) do
            if not MacroState.IsPlaying then
                print("[Playback] ■ Прервано на команде #"..i)
                return
            end
            local fn = Play[cmd.Action]
            if fn then
                task.spawn(fn, cmd)  -- параллельный запуск
            else
                warn("[Playback] Неизвестная команда: "..tostring(cmd.Action))
            end
            task.wait()
        end

        task.wait(10)
        MacroState.IsPlaying = false
        print("[Playback] ✔ Завершено")
        Notify("✔ Готово", "Воспроизведение завершено!", 5)
    end)
end

local function StopPlayback()
    if not MacroState.IsPlaying then
        Notify("Не активно", "Воспроизведение не запущено", 3)
        return
    end
    MacroState.IsPlaying = false
    RestartCount += 1
    if PlayThread then
        task.cancel(PlayThread)
        PlayThread = nil
    end
    print("[Playback] ■ Остановлено")
    Notify("■ Остановлено", "Прервано", 3)
end

-- ════════════════════════════════════════════════════════════════
-- ══════════════════════════════════════════════════════════════
--
--                       RAYFIELD UI
--
-- ══════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════

-- ─── ВКЛАДКА 1: ЗАПИСЬ ───────────────────────────────────────

local TabRec = Window:CreateTab("⏺  Запись", "circle")

TabRec:CreateSection("Управление")

TabRec:CreateButton({
    Name     = "▶  Начать запись",
    Callback = StartRecording,
})
TabRec:CreateButton({
    Name     = "■  Остановить запись",
    Callback = StopRecording,
})

TabRec:CreateSection("Настройки")

TabRec:CreateToggle({
    Name         = "Авто-пропуск волн",
    CurrentValue = false,
    Flag         = "AutoSkip",
    Callback     = function(v) MacroState.AutoSkip = v end,
})
TabRec:CreateToggle({
    Name         = "Авто-продажа ферм (последняя волна)",
    CurrentValue = true,
    Flag         = "AutoSell",
    Callback     = function(v) MacroState.AutoSell = v end,
})

TabRec:CreateSection("Путь сохранения")
TabRec:CreateLabel("Папка: "..STRATS)
TabRec:CreateLabel("Файл:  ИмяИгрока's strat.txt")
TabRec:CreateLabel("Лоадаут читается из Hotbar автоматически")

-- ─── ВКЛАДКА 2: ВОСПРОИЗВЕДЕНИЕ ──────────────────────────────

local TabPlay = Window:CreateTab("▶  Воспроизведение", "play")

local SelectedFile = LocalPlayer.Name.."'s strat"

TabPlay:CreateSection("Файл стратегии")
TabPlay:CreateInput({
    Name                     = "Имя файла (без .txt)",
    PlaceholderText          = LocalPlayer.Name.."'s strat",
    RemoveTextAfterFocusLost = false,
    Callback = function(text)
        if text ~= "" then SelectedFile = text end
    end,
})

TabPlay:CreateSection("Управление")
TabPlay:CreateButton({
    Name     = "▶  Запустить",
    Callback = function() StartPlayback(SelectedFile) end,
})
TabPlay:CreateButton({
    Name     = "■  Остановить",
    Callback = StopPlayback,
})

TabPlay:CreateSection("Файлы")
TabPlay:CreateButton({
    Name     = "📋  Список файлов (F9)",
    Callback = function()
        local files = GetAllStrats()
        print("════ Стратегии ("..#files..") ════")
        for i,f in ipairs(files) do
            print(string.format("  [%d] %s", i, f))
        end
        print("══════════════════════════")
        Notify("Список", "Найдено: "..#files.." | Смотри F9", 4)
    end,
})
TabPlay:CreateButton({
    Name     = "🗑  Удалить выбранный файл",
    Callback = function()
        local path = STRATS.."/"..SelectedFile..".txt"
        if isfile(path) then
            delfile(path)
            Notify("Удалено", SelectedFile, 3)
        else
            Notify("Ошибка", "Файл не найден: "..SelectedFile, 3)
        end
    end,
})

-- ─── ВКЛАДКА 3: НАСТРОЙКИ ────────────────────────────────────

local TabCfg = Window:CreateTab("⚙  Настройки", "settings")

TabCfg:CreateSection("Общие")
TabCfg:CreateToggle({
    Name         = "Анти-АФК",
    CurrentValue = true,
    Flag         = "AntiAFK",
    Callback     = function(v) MacroState.AntiAFK = v end,
})

TabCfg:CreateSection("Подключение")
TabCfg:CreateLabel("RF: "..(RemoteFunction and "✔ "..RemoteFunction:GetFullName() or "✘ НЕ НАЙДЕНА"))
TabCfg:CreateLabel("RE: "..(RemoteEvent    and "✔ "..RemoteEvent:GetFullName()    or "✘ НЕ НАЙДЕНА"))

TabCfg:CreateSection("Карта сложностей")
TabCfg:CreateLabel("Easy   → 'Easy'")
TabCfg:CreateLabel("Molten → 'Normal'")
TabCfg:CreateLabel("Hard   → 'Hard'")
TabCfg:CreateLabel("Fallen → 'Insane'")

TabCfg:CreateSection("Диагностика")
TabCfg:CreateButton({
    Name     = "📊  Статус → консоль (F9)",
    Callback = function()
        print("════ TDS Macro v2.1 ════")
        print("IsRecording: "..tostring(MacroState.IsRecording))
        print("IsPlaying:   "..tostring(MacroState.IsPlaying))
        print("AutoSkip:    "..tostring(MacroState.AutoSkip))
        print("AutoSell:    "..tostring(MacroState.AutoSell))
        print("Wave:        "..GetWave())
        print("Timer:       "..RSTimer.Value.."s")
        print("Map:         "..(RSMap.Value or "?"))
        print("Difficulty:  "..(RSDiff.Value or "?"))
        print("Mode:        "..(RSMode.Value or "?"))
        print("Towers ID:   "..TowersContained.Index)
        print("RecFile:     "..(RecFileName or "—"))
        print("SelFile:     "..SelectedFile)
        print("Loadout:     "..table.concat(RecordedTroops, ", "))
        print("════════════════════════")
        Notify("Статус", "Смотри консоль F9", 3)
    end,
})

TabCfg:CreateSection("Версия")
TabCfg:CreateLabel("TDS: Reanimated Macro  v2.1.0")

-- ════════════════════════════════════════════════════════════════
--  ЗАГРУЗКА КОНФИГА + ФИНАЛЬНЫЙ ЛОГ
-- ════════════════════════════════════════════════════════════════

Rayfield:LoadConfiguration()

print("══════════════════════════════════════════")
print("  TDS: Reanimated Macro  v2.1.0  загружен")
print("  RF: "..(RemoteFunction and "✔ OK" or "✘ НЕ НАЙДЕНА"))
print("  Папка: "..STRATS)
print("══════════════════════════════════════════")

Notify("TDS: Reanimated Macro v2.1",
    "RF: "..(RemoteFunction and "✔ OK" or "⚠ Проверь RF"), 6)
