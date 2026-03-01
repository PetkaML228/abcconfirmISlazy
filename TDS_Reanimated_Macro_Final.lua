-- ================================================================
--  TDS: REANIMATED — MACRO SCRIPT
--  Версия: 2.0.0 (Финальная)
--  Режимы: Recorder (запись) + Playback (воспроизведение)
--  UI: Rayfield
--
--  ПОДТВЕРЖДЁННЫЕ ПУТИ:
--  RF:  ReplicatedStorage.RemoteFunction
--  RE:  ReplicatedStorage.RemoteEvent
--  Wave:       ReplicatedStorage.State.Wave (IntValue)
--  Timer:      ReplicatedStorage.State.Timer.Time (IntValue)
--  Difficulty: ReplicatedStorage.State.Difficulty (StringValue)
--  Map:        ReplicatedStorage.State.Map (StringValue)
--  Mode:       ReplicatedStorage.State.Mode (StringValue)
--  Towers:     Workspace.Towers
--  Owner:      Tower.Owner (ObjectValue, .Value = Player object)
--  FarmType:   Tower.Type (StringValue, .Value == "Farm")
--  Cash:       LocalPlayer.Cash (IntValue)
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

-- Ждём загрузки игры
if not game:IsLoaded() then game.Loaded:Wait() end

-- RemoteFunction — главный канал всех действий
local RemoteFunction = ReplicatedStorage:WaitForChild("RemoteFunction", 15)
local RemoteEvent    = ReplicatedStorage:WaitForChild("RemoteEvent", 15)

-- Состояние игры
local State      = ReplicatedStorage:WaitForChild("State", 15)
local RSWave     = State:WaitForChild("Wave", 10)       -- IntValue
local RSTimer    = State:WaitForChild("Timer", 10)
       RSTimer   = RSTimer:WaitForChild("Time", 10)     -- IntValue (секунды)
local RSDiff     = State:WaitForChild("Difficulty", 10) -- StringValue
local RSMap      = State:WaitForChild("Map", 10)        -- StringValue
local RSMode     = State:WaitForChild("Mode", 10)       -- StringValue

-- Проверка подключения
if not RemoteFunction then
    error("[TDS Macro] ОШИБКА: RemoteFunction не найдена в ReplicatedStorage!")
end

-- ════════════════════════════════════════════════════════════════
--  RAYFIELD UI
-- ════════════════════════════════════════════════════════════════

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield", true))()

local Window = Rayfield:CreateWindow({
    Name                   = "TDS: Reanimated  |  Macro",
    LoadingTitle           = "Загрузка...",
    LoadingSubtitle        = "TDS: Reanimated Macro v2.0",
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

-- Уведомление-хелпер
local function Notify(title, text, duration)
    Rayfield:Notify({ Title = title, Content = text, Duration = duration or 3 })
end

-- ════════════════════════════════════════════════════════════════
--  ФАЙЛОВАЯ СИСТЕМА
-- ════════════════════════════════════════════════════════════════

local FOLDER = "TDSReanimated"
local STRATS = FOLDER .. "/Strats"

if not isfolder(FOLDER)  then makefolder(FOLDER)  end
if not isfolder(STRATS)  then makefolder(STRATS)   end

-- Записать новый файл
local function FileWrite(name, text)
    writefile(STRATS .. "/" .. name .. ".txt", tostring(text) .. "\n")
end

-- Дописать строку в конец файла
local function FileAppend(name, text)
    local path = STRATS .. "/" .. name .. ".txt"
    if isfile(path) then
        appendfile(path, tostring(text) .. "\n")
    else
        FileWrite(name, text)
    end
end

-- Прочитать файл
local function FileRead(name)
    local path = STRATS .. "/" .. name .. ".txt"
    if isfile(path) then return readfile(path) end
    return nil
end

-- Список всех файлов стратегий
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

-- Получить текущую волну
local function GetWave()
    return RSWave and RSWave.Value or 0
end

-- Конвертировать секунды → минуты, секунды
local function ConvertTimer(totalSec)
    return math.floor(totalSec / 60), totalSec % 60
end

-- Обратно
local function TotalSec(min, sec)
    return (min * 60) + math.ceil(sec)
end

-- Субсекундная точность (0.0 — 0.9 между тиками)
local SecondMili = 0
RSTimer.Changed:Connect(function()
    SecondMili = 0
    for i = 1, 9 do
        task.wait(0.09)
        SecondMili += 0.1
    end
end)

-- Флаг "мы внутри волны" (таймер ≤ 5 = между волнами)
local TimerCheck = false
RSTimer.Changed:Connect(function(val)
    if val == 5 then
        TimerCheck = true
    elseif val and val > 5 then
        TimerCheck = false
    end
end)

-- Получить полный снимок времени для записи
local function GetTimer()
    local min, sec = ConvertTimer(RSTimer.Value)
    return { GetWave(), min, sec + SecondMili, tostring(TimerCheck) }
end

-- Точность ожидания тика
local function TimePrecise(sec)
    return (sec - math.floor(sec) - 0.13) + 0.5
end

-- ════════════════════════════════════════════════════════════════
--  ОЖИДАНИЕ ВОЛНЫ + МОМЕНТА ВРЕМЕНИ
-- ════════════════════════════════════════════════════════════════

-- Счётчик перезапусков (прерывает ожидание при стопе)
local RestartCount = 0

local function TimeWaveWait(wave, min, sec)
    local startCount = RestartCount

    -- Ждём нужной волны
    repeat
        task.wait()
        if RestartCount ~= startCount then return false end
    until GetWave() >= wave

    -- Если таймер уже прошёл нужный момент — выполняем сразу
    if RSTimer.Value - TotalSec(min, sec) < -1 then
        return true
    end

    -- Ждём нужного тика таймера
    repeat
        task.wait()
        if RestartCount ~= startCount then return false end
    until RSTimer.Value - TotalSec(min, sec) <= 1

    -- Субсекундная пауза для точности
    if sec > 0 then
        task.wait(TimePrecise(sec))
    end

    return true
end

-- ════════════════════════════════════════════════════════════════
--  ТАБЛИЦА БАШЕН (по ID)
-- ════════════════════════════════════════════════════════════════
-- Каждая размещённая башня получает числовой ID (1, 2, 3...)
-- Апгрейд/продажа используют этот ID для поиска Instance

local TowersContained = {}
TowersContained.Index = 0

-- Ждёт пока башня с нужным ID появится и будет размещена
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
        warn("[TDS Macro] Башня ID:" .. id .. " не найдена за 45 сек")
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
    AutoSkip    = false,   -- авто-пропуск волн
    AutoSell    = true,    -- авто-продажа ферм на последней волне
    AntiAFK     = true,    -- анти-АФК
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

local RecFileName = nil  -- имя текущего файла записи
local TowerCount  = 0    -- счётчик ID башен

-- ─── Лоадаут ─────────────────────────────────────────────────

local RecordedTroops        = {}
local RecordedTroopsGolden  = {}

local function FetchLoadout()
    local ok, result = pcall(function()
        return RemoteFunction:InvokeServer("Session", "Search", "Inventory.Troops")
    end)
    if ok and type(result) == "table" then
        for name, info in next, result do
            if info.Equipped then
                table.insert(RecordedTroops, name)
                if info.GoldenPerks then
                    table.insert(RecordedTroopsGolden, name)
                end
            end
        end
        print("[Recorder] Лоадаут загружен: " .. table.concat(RecordedTroops, ", "))
    else
        -- Если API не работает — читаем из GUI
        warn("[Recorder] Session>Search недоступен, попытка через GUI...")
        local hotbar = LocalPlayer.PlayerGui:FindFirstChild("GameGui")
        if hotbar then
            local hotbarFrame = hotbar:FindFirstChild("Hotbar")
            if hotbarFrame then
                for _, slot in ipairs(hotbarFrame:GetChildren()) do
                    local nameLabel = slot:FindFirstChild("Name") or slot:FindFirstChild("TowerName")
                    if nameLabel and nameLabel.Value and nameLabel.Value ~= "" then
                        table.insert(RecordedTroops, nameLabel.Value)
                    end
                end
            end
        end
        if #RecordedTroops == 0 then
            warn("[Recorder] Лоадаут не найден — заголовок будет без башен")
        end
    end
end

-- ─── Запись заголовка файла ───────────────────────────────────

local function WriteHeader()
    local mapName  = RSMap  and RSMap.Value  or "Unknown"
    local modeName = RSMode and RSMode.Value or "Survival"

    local lines = {}

    -- Строка авторства
    table.insert(lines, 'getgenv().StratCreditsAuthor = ""')

    -- Основные строки стратегии
    table.insert(lines, 'local TDS = loadstring(game:HttpGet("' ..
        'https://raw.githubusercontent.com/Sigmanic/Strategies-X/main/TDS/MainSource.lua' ..
        '", true))()')

    table.insert(lines, string.format('TDS:Map("%s", true, "%s")', mapName, modeName))

    -- Лоадаут
    local troopsStr = '"' .. table.concat(RecordedTroops, '", "') .. '"'
    if #RecordedTroopsGolden > 0 then
        local goldenStr = '"' .. table.concat(RecordedTroopsGolden, '", "') .. '"'
        table.insert(lines, string.format(
            'TDS:Loadout({%s, ["Golden"] = {%s}})', troopsStr, goldenStr))
    else
        table.insert(lines, string.format('TDS:Loadout({%s})', troopsStr))
    end

    FileWrite(RecFileName, table.concat(lines, "\n"))
    print("[Recorder] Заголовок записан → Карта: " .. mapName .. " | Режим: " .. modeName)
end

-- ─── Генераторы строк действий ───────────────────────────────
-- Каждая функция пишет одну строку в файл стратегии

local Gen = {}

-- TDS:Place("TowerName", X, Y, Z, wave, min, sec, timerCheck, rotX, rotY, rotZ)
Gen.Place = function(Args, Timer, RemoteResult)
    -- В TDS:Reanimated: Args = {"Troops","Place","TowerName",{Position=...,Rotation=...}}
    if typeof(RemoteResult) ~= "Instance" then
        warn("[Recorder] Place вернул не Instance — башня не записана")
        return
    end

    local towerName = Args[3]                    -- строка, 3-й аргумент
    local pos       = Args[4].Position           -- Vector3
    local rot       = Args[4].Rotation           -- CFrame
    local rx, ry, rz = rot:ToEulerAnglesYXZ()

    -- Присваиваем ID
    TowerCount += 1
    RemoteResult.Name = TowerCount               -- переименовываем Instance
    TowersContained[TowerCount] = {
        TowerName = towerName,
        Instance  = RemoteResult,
        Position  = pos,
        Placed    = true,
    }
    TowersContained.Index = TowerCount

    local ts = table.concat(Timer, ", ")
    FileAppend(RecFileName, string.format(
        'TDS:Place("%s", %s, %s, %s, %s, %s, %s, %s)',
        towerName,
        pos.X, pos.Y, pos.Z,
        ts,
        rx, ry, rz
    ))
    print(string.format("[Recorder] Place %-12s  ID:%-3d  Wave:%d",
        towerName, TowerCount, Timer[1]))
end

-- TDS:Upgrade(id, wave, min, sec, timerCheck, path)
Gen.Upgrade = function(Args, Timer, RemoteResult)
    -- Args = {"Troops","Upgrade","Set",{Troop=instance}}
    local troopInstance = Args[4].Troop
    local id = tonumber(troopInstance.Name)
    if not id then
        warn("[Recorder] Upgrade: Instance не имеет числового имени — апгрейд не записан")
        return
    end
    if RemoteResult ~= true then
        warn("[Recorder] Upgrade FAILED ID:" .. id)
        return
    end

    local ts = table.concat(Timer, ", ")
    -- Path не передаётся в этой версии TDS, ставим 1 по умолчанию
    FileAppend(RecFileName, string.format('TDS:Upgrade(%d, %s)', id, ts))
    print(string.format("[Recorder] Upgrade ID:%-3d  Wave:%d", id, Timer[1]))
end

-- TDS:Sell(id, wave, min, sec, timerCheck)
Gen.Sell = function(Args, Timer, RemoteResult)
    -- Args = {"Troops","Sell",{Troop=instance}}
    local troopInstance = Args[3].Troop
    local id = tonumber(troopInstance.Name)
    if not id then
        warn("[Recorder] Sell: Instance не имеет числового имени — продажа не записана")
        return
    end
    -- В оригинале проверка: если башня ещё есть в мире — продажа не прошла
    if troopInstance and troopInstance.Parent and
       troopInstance:FindFirstChild("HumanoidRootPart") then
        warn("[Recorder] Sell FAILED (башня всё ещё существует) ID:" .. id)
        return
    end

    local ts = table.concat(Timer, ", ")
    FileAppend(RecFileName, string.format('TDS:Sell(%d, %s)', id, ts))
    print(string.format("[Recorder] Sell   ID:%-3d  Wave:%d", id, Timer[1]))
end

-- TDS:Skip(wave, min, sec, timerCheck)
Gen.Skip = function(Args, Timer)
    local ts = table.concat(Timer, ", ")
    FileAppend(RecFileName, string.format('TDS:Skip(%s)', ts))
    print(string.format("[Recorder] Skip  Wave:%d", Timer[1]))
end

-- TDS:Target(id, "TargetType", wave, min, sec, timerCheck)
Gen.Target = function(Args, Timer, RemoteResult)
    -- Args = {"Troops","Target","Set",{Troop=instance, Target="First"/"Last"/"Strongest"}}
    local troopInstance = Args[4].Troop
    local targetType    = Args[4].Target or "First"
    local id = tonumber(troopInstance.Name)
    if not id then
        warn("[Recorder] Target: Instance не имеет числового имени")
        return
    end
    if RemoteResult ~= true then
        warn("[Recorder] Target FAILED ID:" .. id)
        return
    end

    local ts = table.concat(Timer, ", ")
    FileAppend(RecFileName, string.format('TDS:Target(%d, "%s", %s)', id, targetType, ts))
    print(string.format("[Recorder] Target ID:%-3d → %-12s  Wave:%d", id, targetType, Timer[1]))
end

-- ─── hookmetamethod — ЯДРО RECORDER ──────────────────────────
-- Перехватывает ВСЕ вызовы RemoteFunction:InvokeServer во время записи

-- Маппинг: 2-й аргумент RF → функция-генератор
local ActionMap = {
    Place   = Gen.Place,
    Upgrade = Gen.Upgrade,
    Sell    = Gen.Sell,
    Skip    = Gen.Skip,
    Target  = Gen.Target,
}

local OldNamecall
OldNamecall = hookmetamethod(game, "__namecall", function(...)
    local self = (...)
    local args = { select(2, ...) }

    if  getnamecallmethod() == "InvokeServer"
    and self.Name == "RemoteFunction"
    and MacroState.IsRecording
    then
        -- Запускаем в корутине чтобы не блокировать поток игры
        local thread = coroutine.running()
        coroutine.wrap(function(a)
            local timer    = GetTimer()
            local rfResult = self:InvokeServer(table.unpack(a))
            local action   = a[2]  -- "Place" / "Upgrade" / "Sell" / "Waves" / "Target"

            -- Для Skip: первый аргумент "Waves", второй "Skip"
            if a[1] == "Waves" and a[2] == "Skip" then
                Gen.Skip(a, timer)
            elseif ActionMap[action] then
                ActionMap[action](a, timer, rfResult)
            end

            coroutine.resume(thread, rfResult)
        end)(args)
        return coroutine.yield()
    end

    return OldNamecall(...)
end)

-- ─── Авто-пропуск волн ────────────────────────────────────────

-- Слушаем изменение волны — если AutoSkip включён, голосуем
RSWave.Changed:Connect(function(newWave)
    if not MacroState.AutoSkip then return end
    if newWave == 0 then return end
    -- Небольшая задержка — ждём появления кнопки Skip
    task.wait(1)
    pcall(function()
        RemoteFunction:InvokeServer("Waves", "Skip")
        print("[Recorder] AutoSkip → волна " .. newWave)
    end)
end)

-- ─── Авто-продажа ферм на последней волне ─────────────────────

local LAST_WAVES = {
    Easy=25, Casual=30, Intermediate=30, Molten=35, Fallen=40, Hardcore=50
}

RSWave.Changed:Connect(function(wave)
    if not MacroState.AutoSell then return end
    local lastWave = LAST_WAVES[RSDiff.Value]
    if not lastWave or wave ~= lastWave then return end

    task.wait(0.5)
    local soldCount = 0
    local towers = Workspace:FindFirstChild("Towers")
    if not towers then return end

    for _, tower in ipairs(towers:GetChildren()) do
        -- Owner: ObjectValue, .Value = Player объект
        local ownerVal = tower:FindFirstChild("Owner")
        -- Type: StringValue, .Value == "Farm"
        local typeVal  = tower:FindFirstChild("Type")

        if ownerVal and ownerVal.Value == LocalPlayer
        and typeVal  and typeVal.Value  == "Farm" then
            pcall(function()
                RemoteFunction:InvokeServer("Troops", "Sell", {["Troop"] = tower})
            end)
            soldCount += 1
            task.wait(0.05)
        end
    end

    if soldCount > 0 then
        print("[Macro] AutoSell: продано ферм: " .. soldCount)
        Notify("AutoSell", "Продано ферм: " .. soldCount, 4)
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
    table.clear(RecordedTroopsGolden)

    RecFileName = LocalPlayer.Name .. "'s strat"
    MacroState.IsRecording = true

    FetchLoadout()
    WriteHeader()

    print("[Recorder] ▶ Запись началась → " .. RecFileName)
    Notify("▶ Запись", "Файл: " .. RecFileName, 4)
end

local function StopRecording()
    if not MacroState.IsRecording then
        Notify("Запись не активна", "Нажмите ▶ Начать запись", 3)
        return
    end
    MacroState.IsRecording = false
    print("[Recorder] ■ Запись остановлена → " .. (RecFileName or "?"))
    Notify("■ Запись остановлена", "Сохранено: " .. (RecFileName or "?"), 4)
end

-- ════════════════════════════════════════════════════════════════
-- ══════════════════════════════════════════════════════════════
--
--                        PLAYBACK
--
-- ══════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════

-- ─── Парсер файла стратегии ───────────────────────────────────
-- Читает .txt файл и возвращает список команд в виде таблиц

local function ParseFile(filename)
    local content = FileRead(filename)
    if not content then
        warn("[Playback] Файл не найден: " .. filename)
        return nil
    end

    local commands = {}

    for line in content:gmatch("[^\n]+") do
        line = line:match("^%s*(.-)%s*$")  -- убираем пробелы
        if line == "" then continue end

        -- TDS:Place("Name", x,y,z, wave,min,sec,tc, rx,ry,rz)
        local nm,x,y,z,wv,mn,sc,tc,rx,ry,rz = line:match(
            'TDS:Place%("([^"]+)",%s*'..
            '([-%.%d]+),%s*([-%.%d]+),%s*([-%.%d]+),%s*'..
            '(%d+),%s*(%d+),%s*([-%.%d]+),%s*"([^"]*)",%s*'..
            '([-%.%d]+),%s*([-%.%d]+),%s*([-%.%d]+)%)')
        if nm then
            table.insert(commands,{
                Action="Place",
                TowerName=nm,
                X=tonumber(x),Y=tonumber(y),Z=tonumber(z),
                Wave=tonumber(wv),Min=tonumber(mn),Sec=tonumber(sc),
                RotX=tonumber(rx),RotY=tonumber(ry),RotZ=tonumber(rz),
            })
            continue
        end

        -- TDS:Upgrade(id, wave, min, sec, tc)
        local uid,uwv,umn,usc = line:match(
            'TDS:Upgrade%((%d+),%s*(%d+),%s*(%d+),%s*([-%.%d]+)')
        if uid then
            table.insert(commands,{
                Action="Upgrade",
                Id=tonumber(uid),
                Wave=tonumber(uwv),Min=tonumber(umn),Sec=tonumber(usc),
            })
            continue
        end

        -- TDS:Sell(id, wave, min, sec, tc)
        local sid,swv,smn,ssc = line:match(
            'TDS:Sell%((%d+),%s*(%d+),%s*(%d+),%s*([-%.%d]+)')
        if sid then
            table.insert(commands,{
                Action="Sell",
                Id=tonumber(sid),
                Wave=tonumber(swv),Min=tonumber(smn),Sec=tonumber(ssc),
            })
            continue
        end

        -- TDS:Skip(wave, min, sec, tc)
        local kwv,kmn,ksc = line:match(
            'TDS:Skip%((%d+),%s*(%d+),%s*([-%.%d]+)')
        if kwv then
            table.insert(commands,{
                Action="Skip",
                Wave=tonumber(kwv),Min=tonumber(kmn),Sec=tonumber(ksc),
            })
            continue
        end

        -- TDS:Target(id, "type", wave, min, sec, tc)
        local tid,ttype,twv,tmn,tsc = line:match(
            'TDS:Target%((%d+),%s*"([^"]+)",%s*(%d+),%s*(%d+),%s*([-%.%d]+)')
        if tid then
            table.insert(commands,{
                Action="Target",
                Id=tonumber(tid),TargetType=ttype,
                Wave=tonumber(twv),Min=tonumber(tmn),Sec=tonumber(tsc),
            })
            continue
        end
    end

    print(string.format("[Playback] Распарсено команд: %d  из  '%s'",
        #commands, filename))
    return commands
end

-- ─── Исполнители действий ────────────────────────────────────

local Play = {}

-- Разместить башню
Play.Place = function(cmd)
    local ok = TimeWaveWait(cmd.Wave, cmd.Min, cmd.Sec)
    if not ok then return end

    local pos = Vector3.new(cmd.X, cmd.Y, cmd.Z)
    local rot = CFrame.fromEulerAnglesYXZ(cmd.RotX, cmd.RotY, cmd.RotZ)

    -- TDS:Reanimated Place: "Troops","Place","TowerName",{Position,Rotation}
    local placed, err = nil, nil
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
        TowersContained[id] = {
            TowerName = cmd.TowerName,
            Instance  = placed,
            Placed    = true,
        }
        print(string.format("[Playback] Place %-12s  ID:%-3d  Wave:%d",
            cmd.TowerName, id, cmd.Wave))
    else
        warn(string.format("[Playback] Place FAILED: %s  Wave:%d",
            cmd.TowerName, cmd.Wave))
    end
end

-- Улучшить башню
Play.Upgrade = function(cmd)
    if not WaitForTower(cmd.Id) then return end

    local ok = TimeWaveWait(cmd.Wave, cmd.Min, cmd.Sec)
    if not ok then return end

    local tower = TowersContained[cmd.Id]
    if not tower or not tower.Instance then
        warn("[Playback] Upgrade: нет Instance для ID " .. cmd.Id)
        return
    end

    pcall(function()
        RemoteFunction:InvokeServer("Troops", "Upgrade", "Set", {
            Troop = tower.Instance,
        })
    end)
    print(string.format("[Playback] Upgrade ID:%-3d  Wave:%d", cmd.Id, cmd.Wave))
end

-- Продать башню
Play.Sell = function(cmd)
    if not WaitForTower(cmd.Id) then return end

    local ok = TimeWaveWait(cmd.Wave, cmd.Min, cmd.Sec)
    if not ok then return end

    local tower = TowersContained[cmd.Id]
    if not tower or not tower.Instance then
        warn("[Playback] Sell: нет Instance для ID " .. cmd.Id)
        return
    end

    pcall(function()
        RemoteFunction:InvokeServer("Troops", "Sell", {
            Troop = tower.Instance,
        })
    end)
    print(string.format("[Playback] Sell   ID:%-3d  Wave:%d", cmd.Id, cmd.Wave))
end

-- Пропустить волну
Play.Skip = function(cmd)
    local ok = TimeWaveWait(cmd.Wave, cmd.Min, cmd.Sec)
    if not ok then return end

    pcall(function()
        RemoteFunction:InvokeServer("Waves", "Skip")
    end)
    print(string.format("[Playback] Skip  Wave:%d", cmd.Wave))
end

-- Сменить цель башни
Play.Target = function(cmd)
    if not WaitForTower(cmd.Id) then return end

    local ok = TimeWaveWait(cmd.Wave, cmd.Min, cmd.Sec)
    if not ok then return end

    local tower = TowersContained[cmd.Id]
    if not tower or not tower.Instance then
        warn("[Playback] Target: нет Instance для ID " .. cmd.Id)
        return
    end

    pcall(function()
        RemoteFunction:InvokeServer("Troops", "Target", "Set", {
            Troop  = tower.Instance,
            Target = cmd.TargetType,
        })
    end)
    print(string.format("[Playback] Target ID:%-3d → %-10s  Wave:%d",
        cmd.Id, cmd.TargetType, cmd.Wave))
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
        Notify("Ошибка", "Файл пустой или не найден: " .. filename, 4)
        return
    end

    -- Сброс состояния башен
    table.clear(TowersContained)
    TowersContained.Index = 0
    RestartCount += 1
    MacroState.IsPlaying = true

    Notify("▶ Воспроизведение", string.format(
        "Запущено %d команд | '%s'", #commands, filename), 5)
    print(string.format("[Playback] ▶ Старт: '%s'  (%d команд)",
        filename, #commands))

    PlayThread = task.spawn(function()
        -- Каждая команда запускается параллельно (как в оригинале MainSource)
        for i, cmd in ipairs(commands) do
            if not MacroState.IsPlaying then
                print("[Playback] ■ Прервано на команде #" .. i)
                return
            end

            local fn = Play[cmd.Action]
            if fn then
                task.spawn(fn, cmd)     -- параллельный запуск
            else
                warn("[Playback] Неизвестная команда: " .. tostring(cmd.Action))
            end

            task.wait()  -- уступаем поток
        end

        -- Ждём завершения всех параллельных потоков (пауза)
        task.wait(10)
        MacroState.IsPlaying = false
        print("[Playback] ✔ Все команды выданы")
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
    Notify("■ Остановлено", "Воспроизведение прервано", 3)
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

TabRec:CreateSection("Настройки записи")

TabRec:CreateToggle({
    Name         = "Авто-пропуск волн (AutoSkip)",
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

TabRec:CreateSection("Где сохраняется файл")
TabRec:CreateLabel("Папка:  " .. STRATS)
TabRec:CreateLabel("Имя:    ИмяИгрока's strat.txt")

-- ─── ВКЛАДКА 2: ВОСПРОИЗВЕДЕНИЕ ──────────────────────────────

local TabPlay = Window:CreateTab("▶  Воспроизведение", "play")

TabPlay:CreateSection("Файл стратегии")

-- Имя файла по умолчанию = записанная стратегия игрока
local SelectedFile = LocalPlayer.Name .. "'s strat"

TabPlay:CreateInput({
    Name                     = "Имя файла (без .txt)",
    PlaceholderText          = LocalPlayer.Name .. "'s strat",
    RemoveTextAfterFocusLost = false,
    Callback = function(text)
        if text ~= "" then
            SelectedFile = text
            print("[UI] Выбран файл: " .. text)
        end
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

TabPlay:CreateSection("Сохранённые стратегии")

TabPlay:CreateButton({
    Name     = "📋  Список файлов → консоль (F9)",
    Callback = function()
        local files = GetAllStrats()
        print("════ Сохранённые стратегии (" .. #files .. ") ════")
        for i, f in ipairs(files) do
            print(string.format("  [%d]  %s", i, f))
        end
        print("═══════════════════════════════════════")
        Notify("Список файлов", "Найдено: " .. #files .. " | Открой F9", 4)
    end,
})

TabPlay:CreateButton({
    Name     = "🗑  Удалить выбранный файл",
    Callback = function()
        local path = STRATS .. "/" .. SelectedFile .. ".txt"
        if isfile(path) then
            delfile(path)
            Notify("Удалено", SelectedFile, 3)
            print("[UI] Удалён файл: " .. SelectedFile)
        else
            Notify("Ошибка", "Файл не найден: " .. SelectedFile, 3)
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

TabCfg:CreateSection("Статус подключения")

local rfStatus = RemoteFunction and "✔  " .. RemoteFunction:GetFullName() or "✘  НЕ НАЙДЕНА"
local reStatus = RemoteEvent    and "✔  " .. RemoteEvent:GetFullName()    or "✘  НЕ НАЙДЕНА"

TabCfg:CreateLabel("RF:  " .. rfStatus)
TabCfg:CreateLabel("RE:  " .. reStatus)
TabCfg:CreateLabel("Wave:   RS.State.Wave")
TabCfg:CreateLabel("Timer:  RS.State.Timer.Time")
TabCfg:CreateLabel("Owner:  Tower.Owner (ObjectValue)")
TabCfg:CreateLabel("Farm:   Tower.Type == 'Farm'")

TabCfg:CreateSection("Диагностика")

TabCfg:CreateButton({
    Name     = "📊  Статус → консоль (F9)",
    Callback = function()
        print("════ TDS Macro Status ════")
        print("IsRecording: " .. tostring(MacroState.IsRecording))
        print("IsPlaying:   " .. tostring(MacroState.IsPlaying))
        print("AutoSkip:    " .. tostring(MacroState.AutoSkip))
        print("AutoSell:    " .. tostring(MacroState.AutoSell))
        print("Wave:        " .. GetWave())
        print("Timer:       " .. RSTimer.Value .. "s")
        print("Map:         " .. (RSMap.Value or "?"))
        print("Difficulty:  " .. (RSDiff.Value or "?"))
        print("Mode:        " .. (RSMode.Value or "?"))
        print("TowersCount: " .. TowersContained.Index)
        print("RecFile:     " .. (RecFileName or "—"))
        print("SelFile:     " .. SelectedFile)
        print("═════════════════════════")
        Notify("Статус", "Открой консоль F9", 3)
    end,
})

TabCfg:CreateButton({
    Name     = "🔍  Найти все RemoteFunction (F9)",
    Callback = function()
        print("════ RemoteFunctions в RS ════")
        for _, v in ipairs(ReplicatedStorage:GetDescendants()) do
            if v:IsA("RemoteFunction") then
                print("  " .. v:GetFullName())
            end
        end
        print("══════════════════════════════")
        Notify("RF Finder", "Результат в консоли F9", 3)
    end,
})

TabCfg:CreateSection("Версия")
TabCfg:CreateLabel("TDS: Reanimated Macro  v2.0.0")
TabCfg:CreateLabel("Адаптировано с Strategies-X")

-- ════════════════════════════════════════════════════════════════
--  ЗАВЕРШЕНИЕ ЗАГРУЗКИ
-- ════════════════════════════════════════════════════════════════

Rayfield:LoadConfiguration()

print("═══════════════════════════════════════════")
print("  TDS: Reanimated Macro  v2.0.0  загружен")
print("  RF: " .. (RemoteFunction and "✔ OK" or "✘ НЕ НАЙДЕНА"))
print("  Папка: " .. STRATS)
print("═══════════════════════════════════════════")

Notify(
    "TDS: Reanimated Macro v2.0.0",
    "RF: " .. (RemoteFunction and "✔ OK" or "⚠ Проверь подключение"),
    6
)
