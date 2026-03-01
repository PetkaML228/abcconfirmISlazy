-- ================================================================
--  TDS: REANIMATED — MACRO SCRIPT
--  Версия: 2.4.0
--
--  ИСПРАВЛЕНО v2.3:
--  • instance.Name больше НЕ меняется на числовой ID
--    → Устранена ошибка upgradeGui Line 398 "attempt to index nil with Clone"
--    → upgradeGui ищет иконку по имени башни ("Cowboy" etc) — теперь не ломается
--  • ID башни хранится через instance:SetAttribute("MacroID", id)
--    → Атрибут невидим для игровых скриптов, не влияет на GUI
--  • Upgrade / Sell / Target читают ID через GetAttribute("MacroID")
--
--  ИСПРАВЛЕНО v2.2:
--  • Убраны ВСЕ корутины из hookmetamethod
--    → Ошибки Placement Line 352 и upgradeGui Line 398 устранены
--  • Башни обнаруживаются через ChildAdded (не зависим от RF result)
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
local RSWave  = State:WaitForChild("Wave",       10)
local RSTimer = State:WaitForChild("Timer",      10)
      RSTimer = RSTimer:WaitForChild("Time",     10)
local RSDiff  = State:WaitForChild("Difficulty", 10)
local RSMap   = State:WaitForChild("Map",        10)
local RSMode  = State:WaitForChild("Mode",       10)

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
    LoadingSubtitle        = "TDS: Reanimated Macro v2.4",
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

local SecondMili = 0
RSTimer.Changed:Connect(function()
    SecondMili = 0
    for i = 1, 9 do
        task.wait(0.09)
        SecondMili += 0.1
    end
end)

local TimerCheck = false
RSTimer.Changed:Connect(function(val)
    if val == 5 then TimerCheck = true
    elseif val and val > 5 then TimerCheck = false
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

    if sec > 0 then task.wait(TimePrecise(sec)) end

    return true
end

-- ════════════════════════════════════════════════════════════════
--  ТАБЛИЦА БАШЕН
-- ════════════════════════════════════════════════════════════════

local TowersContained = {}
TowersContained.Index = 0

-- Ждёт пока башня с ID появится и будет помечена Placed=true
local function WaitForTower(id)
    local skip = false
    task.delay(30, function() skip = true end)

    if not TowersContained[id] then
        repeat task.wait() until TowersContained[id] or skip
    end
    if TowersContained[id] and not TowersContained[id].Placed then
        repeat task.wait()
        until (TowersContained[id] and TowersContained[id].Placed) or skip
    end

    if skip or not (TowersContained[id] and TowersContained[id].Placed) then
        warn("[TDS Macro] Башня ID:"..id.." не найдена за 30 сек")
        return false
    end
    return true
end

-- ════════════════════════════════════════════════════════════════
--  ОПРЕДЕЛЕНИЕ БАШНИ ЧЕРЕЗ ChildAdded
-- ════════════════════════════════════════════════════════════════
--
--  Вместо того чтобы полагаться на возвращаемое значение RF
--  (которое в TDS:Reanimated может быть не Instance),
--  мы слушаем появление нового объекта в Workspace.Towers.
--
--  Логика:
--  1. Запоминаем имена ВСЕХ башен в Towers ДО вызова RF
--  2. После вызова RF ждём новый дочерний объект
--  3. Убеждаемся что Owner == LocalPlayer
--  4. Назначаем ID и регистрируем в TowersContained

-- Ожидает появления НОВОЙ башни LocalPlayer в Workspace.Towers
-- callback(instance) вызывается когда башня найдена
-- Возвращает функцию-отмену
-- Структура башни в Workspace.Towers:
--   .Name       = скин башни (например "Default") — НЕ используем как ID
--   .Owner      = ObjectValue, .Value = объект Player
--   .Type       = StringValue, .Value = название башни ("Cowboy" etc)
--   .Upgrade    = IntValue,    .Value = текущий уровень
--   .Class      = StringValue, .Value = "ground" / "cliff"

local function WatchForNewTower(callback, timeoutSec)
    timeoutSec = timeoutSec or 10
    local TowersFolder = Workspace:WaitForChild("Towers", 5)
    if not TowersFolder then
        warn("[TDS Macro] Workspace.Towers не найдена!")
        return function() end
    end

    local done = false
    local conn

    conn = TowersFolder.ChildAdded:Connect(function(child)
        if done then return end

        -- Ждём репликации дочерних объектов (Owner может появиться чуть позже)
        task.wait(0.2)

        local ownerVal = child:FindFirstChild("Owner")
        if not ownerVal then
            -- Ждём ещё немного если Owner ещё не реплицировался
            task.wait(0.3)
            ownerVal = child:FindFirstChild("Owner")
        end

        if ownerVal and ownerVal.Value == LocalPlayer then
            done = true
            conn:Disconnect()
            callback(child)
        end
    end)

    -- Таймаут
    task.delay(timeoutSec, function()
        if not done then
            done = true
            conn:Disconnect()
            warn("[TDS Macro] WatchForNewTower: таймаут "..timeoutSec.."с")
        end
    end)

    return function()
        done = true
        conn:Disconnect()
    end
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

-- ─── Лоадаут из GUI хотбара ───────────────────────────────────

local RecordedTroops = {}

local function FetchLoadout()
    table.clear(RecordedTroops)

    local ok, hotbar = pcall(function()
        return LocalPlayer.PlayerGui
            :WaitForChild("GameGui", 5)
            :WaitForChild("Hotbar",  5)
            :WaitForChild("Troops",  5)
    end)

    if not ok or not hotbar then
        warn("[Recorder] Hotbar.Troops не найден")
        return
    end

    for slot = 1, 5 do
        local frame = hotbar:FindFirstChild(tostring(slot))
        if not frame then continue end

        local icon       = frame:FindFirstChild("Icon")
        local viewport   = icon and icon:FindFirstChild("ViewportFrame")
        local worldModel = viewport and viewport:FindFirstChild("WorldModel")
        if not worldModel then continue end

        local model = worldModel:FindFirstChildWhichIsA("Model")
        if model and model.Name ~= "" then
            table.insert(RecordedTroops, model.Name)
            print(string.format("[Recorder] Слот %d → %s", slot, model.Name))
        end
    end

    print("[Recorder] Лоадаут: " .. (#RecordedTroops > 0
        and table.concat(RecordedTroops, ", ")
        or  "пустой"))
end

-- ─── Запись заголовка ─────────────────────────────────────────

local function WriteHeader()
    local mapName  = RSMap  and RSMap.Value  or "Unknown"
    local modeName = RSMode and RSMode.Value or "Survival"
    local lines    = {}

    table.insert(lines, 'getgenv().StratCreditsAuthor = ""')
    table.insert(lines,
        'local TDS = loadstring(game:HttpGet(' ..
        '"https://raw.githubusercontent.com/Sigmanic/Strategies-X/main/TDS/MainSource.lua"' ..
        ', true))()')
    table.insert(lines, string.format('TDS:Map("%s", true, "%s")', mapName, modeName))
    -- Лоадаут записывается автоматически при первой постановке башни через TDS:Place
    -- Ручное указание не требуется

    FileWrite(RecFileName, table.concat(lines, "\n"))
    print("[Recorder] Заголовок → Карта:"..mapName.." Режим:"..modeName)
end

-- ════════════════════════════════════════════════════════════════
--  hookmetamethod — ЯДРО RECORDER
--
--  ВАЖНО: здесь НУЛЬ корутин.
--  Все записи происходят через task.spawn (асинхронно).
--  OldNamecall(...) всегда вызывается без изменений.
--  Это гарантирует что внутренние модули игры работают штатно.
-- ════════════════════════════════════════════════════════════════

local OldNamecall
OldNamecall = hookmetamethod(game, "__namecall", function(...)
    local self = (...)
    local args = { select(2, ...) }

    -- Фильтр: только RF, только во время записи
    if  self.Name ~= "RemoteFunction"
    or  getnamecallmethod() ~= "InvokeServer"
    or  not MacroState.IsRecording
    then
        return OldNamecall(...)
    end

    local category = args[1]
    local action   = args[2]

    -- ── "Troops" "Place" ──────────────────────────────────────
    --  Снимаем данные ДО вызова, башню ищем через ChildAdded ПОСЛЕ.
    if category == "Troops" and action == "Place" then
        local timer     = GetTimer()
        local towerName = args[3]                   -- "Cowboy" и т.д.
        local posArg    = args[4] and args[4].Position  -- Vector3
        local rotArg    = args[4] and args[4].Rotation  -- CFrame

        -- Асинхронно ждём появления башни в Workspace.Towers
        task.spawn(function()
            WatchForNewTower(function(instance)
                TowerCount += 1
                -- Имя башни берём из Type.Value (надёжнее чем из аргумента)
                -- instance.Name = скин ("Default"), нам не нужен
                local actualName = instance:FindFirstChild("Type")
                    and instance.Type.Value
                    or towerName  -- запасной вариант из аргумента RF

                -- НЕ меняем instance.Name — это ломает upgradeGui игры!
                instance:SetAttribute("MacroID", TowerCount)
                TowersContained[TowerCount] = {
                    TowerName = actualName,
                    Instance  = instance,
                    Placed    = true,
                }
                TowersContained.Index = TowerCount

                -- Позицию берём из аргументов (точнее чем из instance)
                local pos = posArg or (
                    instance.PrimaryPart and instance.PrimaryPart.Position
                    or Vector3.new(0, 0, 0))

                local rx, ry, rz = 0, 0, 0
                if rotArg then
                    rx, ry, rz = rotArg:ToEulerAnglesYXZ()
                elseif instance.PrimaryPart then
                    rx, ry, rz = instance.PrimaryPart.CFrame:ToEulerAnglesYXZ()
                end

                local ts = table.concat(timer, ", ")
                FileAppend(RecFileName, string.format(
                    'TDS:Place("%s", %s, %s, %s, %s, %s, %s, %s)',
                    actualName,
                    pos.X, pos.Y, pos.Z,
                    ts, rx, ry, rz))

                print(string.format("[Recorder] Place  %-12s  ID:%-3d  Wave:%d  (скин: %s)",
                    actualName, TowerCount, timer[1], instance.Name))
            end, 10)
        end)

        -- Выполняем RF как обычно — без изменений
        return OldNamecall(...)
    end

    -- ── "Troops" "Upgrade" ────────────────────────────────────
    --  ID башни берём из атрибута MacroID (SetAttribute при Place).
    if category == "Troops" and action == "Upgrade" then
        local timer = GetTimer()
        local troop = args[4] and args[4].Troop

        task.spawn(function()
            if not troop then
                warn("[Recorder] Upgrade: нет Troop в аргументах")
                return
            end
            local id = troop:GetAttribute("MacroID")
            if not id then
                warn("[Recorder] Upgrade: башня не имеет атрибута MacroID"
                    .." (Name='"..tostring(troop.Name).."')")
                return
            end
            local ts = table.concat(timer, ", ")
            FileAppend(RecFileName, string.format('TDS:Upgrade(%d, %s)', id, ts))
            print(string.format("[Recorder] Upgrade  ID:%-3d  Wave:%d", id, timer[1]))
        end)

        return OldNamecall(...)
    end

    -- ── "Troops" "Sell" ───────────────────────────────────────
    if category == "Troops" and action == "Sell" then
        local timer = GetTimer()
        local troop = args[3] and args[3].Troop

        task.spawn(function()
            if not troop then return end
            local id = troop:GetAttribute("MacroID")
            if not id then
                warn("[Recorder] Sell: башня не имеет атрибута MacroID")
                return
            end
            local ts = table.concat(timer, ", ")
            FileAppend(RecFileName, string.format('TDS:Sell(%d, %s)', id, ts))
            print(string.format("[Recorder] Sell     ID:%-3d  Wave:%d", id, timer[1]))
        end)

        return OldNamecall(...)
    end

    -- ── "Troops" "Target" "Set" ───────────────────────────────
    if category == "Troops" and action == "Target" then
        local timer      = GetTimer()
        local troop      = args[4] and args[4].Troop
        local targetType = args[4] and args[4].Target or "First"

        task.spawn(function()
            if not troop then return end
            local id = troop:GetAttribute("MacroID")
            if not id then return end
            local ts = table.concat(timer, ", ")
            FileAppend(RecFileName, string.format(
                'TDS:Target(%d, "%s", %s)', id, targetType, ts))
            print(string.format("[Recorder] Target   ID:%-3d → %-10s  Wave:%d",
                id, targetType, timer[1]))
        end)

        return OldNamecall(...)
    end

    -- ── "Waves" "Skip" ────────────────────────────────────────
    if category == "Waves" and action == "Skip" then
        local timer = GetTimer()
        task.spawn(function()
            local ts = table.concat(timer, ", ")
            FileAppend(RecFileName, string.format('TDS:Skip(%s)', ts))
            print(string.format("[Recorder] Skip  Wave:%d", timer[1]))
        end)
        return OldNamecall(...)
    end

    -- ── "Difficulty" "Vote" ───────────────────────────────────
    if category == "Difficulty" and action == "Vote" then
        local timer    = GetTimer()
        local diffName = args[3]
        task.spawn(function()
            if not diffName then return end
            FileAppend(RecFileName, string.format('TDS:Mode("%s")', diffName))
            print("[Recorder] Difficulty → " .. diffName)
        end)
        return OldNamecall(...)
    end

    -- ── Всё остальное — без изменений ─────────────────────────
    return OldNamecall(...)
end)

-- ─── Авто-пропуск волн ───────────────────────────────────────

RSWave.Changed:Connect(function(newWave)
    if not MacroState.AutoSkip or newWave == 0 then return end
    if not MacroState.IsRecording and not MacroState.IsPlaying then return end
    task.wait(1)
    pcall(function()
        RemoteFunction:InvokeServer("Waves", "Skip")
    end)
    print("[Macro] AutoSkip → волна "..newWave)
end)

-- ─── Авто-продажа ферм ───────────────────────────────────────

local LAST_WAVES = {
    Easy=25, Normal=35, Hard=40, Insane=40,
    Casual=30, Intermediate=30, Molten=35, Fallen=40, Hardcore=50,
}

RSWave.Changed:Connect(function(wave)
    if not MacroState.AutoSell then return end
    local lastWave = LAST_WAVES[RSDiff.Value]
    if not lastWave or wave ~= lastWave then return end

    task.wait(0.5)
    local towers = Workspace:FindFirstChild("Towers")
    if not towers then return end

    -- ВАЖНО: Type.Value = название башни ("Cowboy", "Farmer" etc)
    -- Фермы в TDS: Reanimated обычно называются "Farmer", "EconomistV2" etc
    -- Список ферм — уточни и добавь сюда названия из своей игры
    local FARM_NAMES = {
        ["Farmer"]       = true,
        ["EconomistV2"]  = true,
        ["Economist"]    = true,
        ["Farm"]         = true,
        ["CashFactory"]  = true,
    }

    local count = 0
    for _, tower in ipairs(towers:GetChildren()) do
        local ownerVal = tower:FindFirstChild("Owner")  -- ObjectValue
        local typeVal  = tower:FindFirstChild("Type")   -- StringValue = название башни

        if  ownerVal and ownerVal.Value == LocalPlayer
        and typeVal  and FARM_NAMES[typeVal.Value]
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

    TowerCount = 0
    table.clear(TowersContained)
    TowersContained.Index = 0
    table.clear(RecordedTroops)

    RecFileName            = LocalPlayer.Name.."'s strat"
    MacroState.IsRecording = true

    FetchLoadout()
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

-- ─── Парсер файла ────────────────────────────────────────────

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

        -- TDS:Mode("Normal")
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

-- Place: стреляем RF, ждём ChildAdded в Workspace.Towers
Play.Place = function(cmd)
    local ok = TimeWaveWait(cmd.Wave, cmd.Min, cmd.Sec)
    if not ok then return end

    local pos = Vector3.new(cmd.X, cmd.Y, cmd.Z)
    local rot = CFrame.fromEulerAnglesYXZ(cmd.RotX, cmd.RotY, cmd.RotZ)

    -- Заранее резервируем ID чтобы Upgrade/Sell не ждали вечно
    TowersContained.Index += 1
    local expectedId = TowersContained.Index
    TowersContained[expectedId] = { TowerName=cmd.TowerName, Instance=nil, Placed=false }

    -- Слушаем появление башни в Workspace.Towers
    WatchForNewTower(function(instance)
        -- НЕ меняем instance.Name — используем атрибут
        instance:SetAttribute("MacroID", expectedId)
        TowersContained[expectedId].Instance = instance
        TowersContained[expectedId].Placed   = true
        print(string.format("[Playback] Place  %-12s  ID:%-3d  Wave:%d",
            cmd.TowerName, expectedId, cmd.Wave))
    end, 15)

    -- Стреляем RF
    pcall(function()
        RemoteFunction:InvokeServer("Troops", "Place", cmd.TowerName, {
            Position = pos,
            Rotation = rot,
        })
    end)
end

-- Upgrade: ждём башню по ID, затем RF
Play.Upgrade = function(cmd)
    if not WaitForTower(cmd.Id) then return end

    local ok = TimeWaveWait(cmd.Wave, cmd.Min, cmd.Sec)
    if not ok then return end

    local tower = TowersContained[cmd.Id]
    if not tower or not tower.Instance then
        warn("[Playback] Upgrade: нет Instance для ID:"..cmd.Id)
        return
    end

    pcall(function()
        RemoteFunction:InvokeServer("Troops", "Upgrade", "Set", {
            Troop = tower.Instance
        })
    end)
    print(string.format("[Playback] Upgrade  ID:%-3d  Wave:%d", cmd.Id, cmd.Wave))
end

-- Sell: ждём башню по ID, затем RF
Play.Sell = function(cmd)
    if not WaitForTower(cmd.Id) then return end

    local ok = TimeWaveWait(cmd.Wave, cmd.Min, cmd.Sec)
    if not ok then return end

    local tower = TowersContained[cmd.Id]
    if not tower or not tower.Instance then
        warn("[Playback] Sell: нет Instance для ID:"..cmd.Id)
        return
    end

    pcall(function()
        RemoteFunction:InvokeServer("Troops", "Sell", {
            Troop = tower.Instance
        })
    end)
    print(string.format("[Playback] Sell     ID:%-3d  Wave:%d", cmd.Id, cmd.Wave))
end

-- Skip: ждём момента, затем RF
Play.Skip = function(cmd)
    local ok = TimeWaveWait(cmd.Wave, cmd.Min, cmd.Sec)
    if not ok then return end
    pcall(function()
        RemoteFunction:InvokeServer("Waves", "Skip")
    end)
    print(string.format("[Playback] Skip  Wave:%d", cmd.Wave))
end

-- Target: ждём башню, затем RF
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
    print(string.format("[Playback] Target   ID:%-3d → %-10s  Wave:%d",
        cmd.Id, cmd.TargetType, cmd.Wave))
end

-- Mode: голосуем за сложность
Play.Mode = function(cmd)
    task.wait(0.5)
    pcall(function()
        RemoteFunction:InvokeServer("Difficulty", "Vote", cmd.DiffName, false)
    end)
    print("[Playback] Mode → "..cmd.DiffName)
end

-- ─── Запуск / Остановка воспроизведения ──────────────────────

local PlayThread = nil

local function StartPlayback(filename)
    if MacroState.IsRecording then
        Notify("Ошибка", "Сначала остановите запись!", 3); return
    end
    if MacroState.IsPlaying then
        Notify("Ошибка", "Уже запущено!", 3); return
    end

    local commands = ParseFile(filename)
    if not commands or #commands == 0 then
        Notify("Ошибка", "Файл пустой или не найден: "..filename, 4); return
    end

    table.clear(TowersContained)
    TowersContained.Index = 0
    RestartCount  += 1
    MacroState.IsPlaying = true

    Notify("▶ Воспроизведение",
        string.format("%d команд | '%s'", #commands, filename), 5)
    print(string.format("[Playback] ▶ Старт: '%s' (%d команд)", filename, #commands))

    PlayThread = task.spawn(function()
        for i, cmd in ipairs(commands) do
            if not MacroState.IsPlaying then
                print("[Playback] ■ Прервано на команде #"..i); return
            end
            local fn = Play[cmd.Action]
            if fn then
                task.spawn(fn, cmd)
            else
                warn("[Playback] Неизвестная команда: "..tostring(cmd.Action))
            end
            task.wait()
        end

        task.wait(15)
        MacroState.IsPlaying = false
        print("[Playback] ✔ Завершено")
        Notify("✔ Готово", "Воспроизведение завершено!", 5)
    end)
end

local function StopPlayback()
    if not MacroState.IsPlaying then
        Notify("Не активно", "Воспроизведение не запущено", 3); return
    end
    MacroState.IsPlaying = false
    RestartCount += 1
    if PlayThread then task.cancel(PlayThread); PlayThread = nil end
    print("[Playback] ■ Остановлено")
    Notify("■ Остановлено", "Прервано", 3)
end

-- ════════════════════════════════════════════════════════════════
--                       RAYFIELD UI
-- ════════════════════════════════════════════════════════════════

-- ─── ВКЛАДКА 1: ЗАПИСЬ ───────────────────────────────────────

local TabRec = Window:CreateTab("⏺  Запись", "circle")

TabRec:CreateSection("Управление")
TabRec:CreateButton({ Name="▶  Начать запись",    Callback=StartRecording })
TabRec:CreateButton({ Name="■  Остановить запись", Callback=StopRecording  })

TabRec:CreateSection("Настройки")
TabRec:CreateToggle({
    Name="Авто-пропуск волн", CurrentValue=false, Flag="AutoSkip",
    Callback=function(v) MacroState.AutoSkip=v end,
})
TabRec:CreateToggle({
    Name="Авто-продажа ферм (последняя волна)", CurrentValue=true, Flag="AutoSell",
    Callback=function(v) MacroState.AutoSell=v end,
})

TabRec:CreateSection("Путь сохранения")
TabRec:CreateLabel("Папка: "..STRATS)
TabRec:CreateLabel("Файл:  ИмяИгрока's strat.txt")

-- ─── ВКЛАДКА 2: ВОСПРОИЗВЕДЕНИЕ ──────────────────────────────

local TabPlay = Window:CreateTab("▶  Воспроизведение", "play")

local SelectedFile = LocalPlayer.Name.."'s strat"

TabPlay:CreateSection("Файл стратегии")
TabPlay:CreateInput({
    Name="Имя файла (без .txt)",
    PlaceholderText=LocalPlayer.Name.."'s strat",
    RemoveTextAfterFocusLost=false,
    Callback=function(t) if t~="" then SelectedFile=t end end,
})

TabPlay:CreateSection("Управление")
TabPlay:CreateButton({ Name="▶  Запустить", Callback=function() StartPlayback(SelectedFile) end })
TabPlay:CreateButton({ Name="■  Остановить", Callback=StopPlayback })

TabPlay:CreateSection("Файлы")
TabPlay:CreateButton({
    Name="📋  Список файлов (F9)",
    Callback=function()
        local files = GetAllStrats()
        print("════ Стратегии ("..#files..") ════")
        for i,f in ipairs(files) do print(string.format("  [%d] %s", i, f)) end
        print("══════════════════════════")
        Notify("Список", "Найдено: "..#files.." | F9", 4)
    end,
})
TabPlay:CreateButton({
    Name="🗑  Удалить выбранный файл",
    Callback=function()
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
    Name="Анти-АФК", CurrentValue=true, Flag="AntiAFK",
    Callback=function(v) MacroState.AntiAFK=v end,
})

TabCfg:CreateSection("Подключение")
TabCfg:CreateLabel("RF: "..(RemoteFunction
    and "✔ "..RemoteFunction:GetFullName() or "✘ НЕ НАЙДЕНА"))

TabCfg:CreateSection("Карта сложностей")
TabCfg:CreateLabel("Easy   → 'Easy'")
TabCfg:CreateLabel("Molten → 'Normal'")
TabCfg:CreateLabel("Hard   → 'Hard'")
TabCfg:CreateLabel("Fallen → 'Insane'")

TabCfg:CreateSection("Диагностика")
TabCfg:CreateButton({
    Name="📊  Статус → консоль (F9)",
    Callback=function()
        print("════ TDS Macro v2.4 ════")
        print("IsRecording: "..tostring(MacroState.IsRecording))
        print("IsPlaying:   "..tostring(MacroState.IsPlaying))
        print("AutoSkip:    "..tostring(MacroState.AutoSkip))
        print("Wave:        "..GetWave())
        print("Timer:       "..RSTimer.Value.."s")
        print("Map:         "..(RSMap.Value or "?"))
        print("Difficulty:  "..(RSDiff.Value or "?"))
        print("Towers:      "..TowersContained.Index)
        print("RecFile:     "..(RecFileName or "—"))
        print("SelFile:     "..SelectedFile)
        print("Loadout:     "..table.concat(RecordedTroops, ", "))
        print("════════════════════════")
        Notify("Статус", "Смотри консоль F9", 3)
    end,
})

TabCfg:CreateButton({
    Name="🗼  Список башен в Workspace.Towers (F9)",
    Callback=function()
        local towers = Workspace:FindFirstChild("Towers")
        if not towers then
            print("[Debug] Workspace.Towers не найдена!")
            Notify("Ошибка", "Workspace.Towers не найдена", 3)
            return
        end
        print("════ Workspace.Towers ("..#towers:GetChildren()..") ════")
        for i, t in ipairs(towers:GetChildren()) do
            local owner   = t:FindFirstChild("Owner")
            local ttype   = t:FindFirstChild("Type")
            local upgrade = t:FindFirstChild("Upgrade")
            local macroId = t:GetAttribute("MacroID")
            local isMe    = owner and owner.Value == LocalPlayer
            print(string.format(
                "  [%d] Скин:%-10s  Тип:%-12s  Lvl:%s  МОЯ:%s  MacroID:%s",
                i,
                tostring(t.Name),
                ttype   and tostring(ttype.Value)   or "?",
                upgrade and tostring(upgrade.Value) or "?",
                tostring(isMe),
                tostring(macroId)
            ))
        end
        print("═══════════════════════════════════════")
        Notify("Towers", #towers:GetChildren().." башен | F9", 3)
    end,
})

TabCfg:CreateSection("Версия")
TabCfg:CreateLabel("TDS: Reanimated Macro  v2.4.0")

-- ════════════════════════════════════════════════════════════════
--  ФИНАЛ
-- ════════════════════════════════════════════════════════════════

Rayfield:LoadConfiguration()

print("══════════════════════════════════════════")
print("  TDS: Reanimated Macro  v2.4.0  загружен")
print("  RF: "..(RemoteFunction and "✔ OK" or "✘ НЕ НАЙДЕНА"))
print("══════════════════════════════════════════")

Notify("TDS: Reanimated Macro v2.4",
    "RF: "..(RemoteFunction and "✔ OK" or "⚠ Проверь RF"), 6)
