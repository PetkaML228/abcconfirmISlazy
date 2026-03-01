--[[
    ╔══════════════════════════════════════════════╗
    ║   TDS: Reanimated — Macro System v3.0.0     ║
    ║   Rayfield UI | Record | Playback | Auto    ║
    ╠══════════════════════════════════════════════╣
    ║   Основан на Strategies-X (адаптация)       ║
    ║   Для TDS: Reanimated (старая версия TDS)   ║
    ╚══════════════════════════════════════════════╝
    
    Структура:
    1. Инициализация сервисов и переменных
    2. Утилиты (файлы, таймеры, волны)
    3. Recorder — запись действий игрока
    4. Playback — воспроизведение макроса
    5. AutoFarm — авто-продажа ферм
    6. Rayfield UI — интерфейс
]]

-- ═══════════════════════════════════════════════
--  СЕКЦИЯ 1: СЕРВИСЫ И ИНИЦИАЛИЗАЦИЯ
-- ═══════════════════════════════════════════════

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

-- ═══════════════════════════════════════════════
--  СЕКЦИЯ 2: RAYFIELD UI ЗАГРУЗКА
-- ═══════════════════════════════════════════════

local Rayfield = loadstring(game:HttpGet(
    "https://sirius.menu/rayfield"
))()

-- ═══════════════════════════════════════════════
--  СЕКЦИЯ 3: КОНСТАНТЫ И КОНФИГУРАЦИЯ
-- ═══════════════════════════════════════════════

local CONFIG = {
    Version       = "3.0.0",
    MacroFolder   = "TDS_Macros",        -- папка для сохранения макросов
    TimeoutTower  = 45,                   -- сек. ожидания башни при воспроизведении
    TimeoutWave   = 600,                  -- сек. ожидания волны
    PollInterval  = 0.1,                  -- интервал проверки состояния
    ActionDelay   = 0.15,                 -- задержка между действиями
    AutoSellDelay = 2,                    -- интервал проверки авто-продажи
}

-- ═══════════════════════════════════════════════
--  СЕКЦИЯ 4: ФАЙЛОВАЯ СИСТЕМА
-- ═══════════════════════════════════════════════

--[[
    FileManager — обёртка над файловыми функциями эксплоита.
    Все макросы хранятся в папке TDS_Macros/ как .lua файлы.
]]
local FileManager = {}

function FileManager.Init()
    if not isfolder(CONFIG.MacroFolder) then
        makefolder(CONFIG.MacroFolder)
    end
end

function FileManager.GetPath(name)
    -- Добавляем .lua если нет расширения
    if not name:match("%.%w+$") then
        name = name .. ".lua"
    end
    return CONFIG.MacroFolder .. "/" .. name
end

function FileManager.Write(name, content)
    writefile(FileManager.GetPath(name), content)
end

function FileManager.Append(name, line)
    appendfile(FileManager.GetPath(name), line .. "\n")
end

function FileManager.Read(name)
    local path = FileManager.GetPath(name)
    if isfile(path) then
        return readfile(path)
    end
    return nil
end

function FileManager.Exists(name)
    return isfile(FileManager.GetPath(name))
end

function FileManager.Delete(name)
    local path = FileManager.GetPath(name)
    if isfile(path) then
        delfile(path)
        return true
    end
    return false
end

function FileManager.List()
    local files = {}
    if not isfolder(CONFIG.MacroFolder) then return files end
    
    for _, fullPath in ipairs(listfiles(CONFIG.MacroFolder)) do
        local name = fullPath:match("[/\\]([^/\\]+)$")
        if name then
            table.insert(files, name)
        end
    end
    
    table.sort(files)
    return files
end

FileManager.Init()

-- ═══════════════════════════════════════════════
--  СЕКЦИЯ 5: ИГРОВЫЕ ССЫЛКИ И УТИЛИТЫ
-- ═══════════════════════════════════════════════

--[[
    GameBridge — мост между скриптом и игрой.
    Обеспечивает доступ к RemoteFunction, State, Troops.
    
    Структура игры (TDS: Reanimated):
    - ReplicatedStorage
      ├── RemoteFunctions
      │   └── Troops (RemoteFunction) — основной RF для действий с башнями
      ├── State
      │   ├── Wave (IntValue) — текущая волна
      │   └── Timer (NumberValue) — таймер волны
      └── Client
          └── Modules
              └── Game
                  └── Interface
                      └── Elements
                          └── Upgrade
                              ├── upgradeHandler (ModuleScript)
                              └── upgradeGui (ModuleScript)
    
    - Workspace
      └── <MapName>
          └── Troops (Folder) — размещённые башни
    
    Формат вызова RemoteFunction:
      RF:InvokeServer("Troops", Action, Arg3, Arg4)
      
    Действия (Action):
      "Place"   — args[3]=TowerName, args[4]=CFrame
      "Upgrade" — args[4]={Troop=Instance}
      "Sell"    — args[4]={Troop=Instance}
      "Target"  — args[4]={Troop=Instance, Priority=string}
]]

local GameBridge = {
    RemoteFunction = nil,    -- RemoteFunction "Troops"
    StateWave      = nil,    -- IntValue волны
    StateTimer     = nil,    -- NumberValue таймера
    UpgradeHandler = nil,    -- upgradeHandler модуль (для синхронизации GUI)
    TroopsFolder   = nil,    -- Folder с башнями в workspace
    _initialized   = false,
}

-- Получение RemoteFunction
function GameBridge.GetRF()
    if GameBridge.RemoteFunction then
        return GameBridge.RemoteFunction
    end
    
    local remoteFunctions = ReplicatedStorage:FindFirstChild("RemoteFunctions")
    if not remoteFunctions then
        remoteFunctions = ReplicatedStorage:WaitForChild("RemoteFunctions", 15)
    end
    
    if remoteFunctions then
        GameBridge.RemoteFunction = remoteFunctions:FindFirstChild("Troops")
        if not GameBridge.RemoteFunction then
            GameBridge.RemoteFunction = remoteFunctions:WaitForChild("Troops", 10)
        end
    end
    
    if not GameBridge.RemoteFunction then
        warn("[GameBridge] RemoteFunction 'Troops' не найдена!")
    end
    
    return GameBridge.RemoteFunction
end

-- Получение State (Wave, Timer)
function GameBridge.GetState()
    if GameBridge.StateWave then return end
    
    local state = ReplicatedStorage:FindFirstChild("State")
    if not state then
        state = ReplicatedStorage:WaitForChild("State", 15)
    end
    
    if state then
        GameBridge.StateWave  = state:FindFirstChild("Wave")
        GameBridge.StateTimer = state:FindFirstChild("Timer")
    end
end

-- Получение upgradeHandler для синхронизации GUI
function GameBridge.GetUpgradeHandler()
    if GameBridge.UpgradeHandler then
        return GameBridge.UpgradeHandler
    end
    
    local ok, handler = pcall(function()
        return require(
            ReplicatedStorage
                .Client.Modules.Game.Interface
                .Elements.Upgrade.upgradeHandler
        )
    end)
    
    if ok and handler then
        GameBridge.UpgradeHandler = handler
    end
    
    return GameBridge.UpgradeHandler
end

--[[
    SyncGUI — синхронизирует GUI после Place/Upgrade.
    
    Проблема: upgradeGui:398 "attempt to index nil with 'Clone'"
    Причина: hookmetamethod оборачивает InvokeServer в корутину,
             GUI-модуль upgradeGui ожидает синхронный результат
             и пытается обновить интерфейс, но контекст уже другой.
    Решение: вызываем upgradeHandler:selectTroop(troop) после действия,
             что инициализирует GUI корректно.
]]
function GameBridge.SyncGUI(troop)
    if not troop then return end
    
    local handler = GameBridge.GetUpgradeHandler()
    if handler then
        pcall(function()
            handler:selectTroop(troop)
        end)
    end
end

-- Поиск папки Troops в workspace (внутри карты)
function GameBridge.FindTroopsFolder()
    if GameBridge.TroopsFolder and GameBridge.TroopsFolder.Parent then
        return GameBridge.TroopsFolder
    end
    
    -- Ищем во всех дочерних объектах workspace
    for _, child in ipairs(workspace:GetChildren()) do
        if child:IsA("Model") or child:IsA("Folder") then
            local troops = child:FindFirstChild("Troops")
            if troops then
                GameBridge.TroopsFolder = troops
                return troops
            end
        end
    end
    
    return nil
end

-- ═══════════════════════════════════════════════
--  СЕКЦИЯ 6: СИСТЕМА ТАЙМЕРОВ И ВОЛН
-- ═══════════════════════════════════════════════

--[[
    WaveTimer — отслеживает текущую волну и время.
    
    Волна берётся из двух источников (по приоритету):
    1. GUI: PlayerGui.ReactGameTopGameDisplay.Frame.wave.container.value (TextLabel)
    2. State: ReplicatedStorage.State.Wave (IntValue)
    
    GUI обновляется клиентским скриптом и может отличаться
    от IntValue по таймингу. Приоритет GUI — как в оригинале Strategies-X.
]]
local WaveTimer = {}

-- Получение текущей волны
function WaveTimer.GetWave()
    -- Источник 1: GUI (приоритет)
    local guiOk, guiWave = pcall(function()
        local display = PlayerGui:FindFirstChild("ReactGameTopGameDisplay")
        if not display then return nil end
        
        local frame = display:FindFirstChild("Frame")
        if not frame then return nil end
        
        local waveFrame = frame:FindFirstChild("wave")
        if not waveFrame then return nil end
        
        local container = waveFrame:FindFirstChild("container")
        if not container then return nil end
        
        local valueLabel = container:FindFirstChild("value")
        if valueLabel and valueLabel:IsA("TextLabel") then
            return tonumber(valueLabel.Text)
        end
        
        return nil
    end)
    
    if guiOk and guiWave and guiWave > 0 then
        return guiWave
    end
    
    -- Источник 2: IntValue (fallback)
    GameBridge.GetState()
    if GameBridge.StateWave then
        local v = GameBridge.StateWave.Value
        if typeof(v) == "number" then
            return math.floor(v)
        end
    end
    
    return 0
end

-- Получение таймера в секундах
function WaveTimer.GetSeconds()
    GameBridge.GetState()
    if GameBridge.StateTimer then
        local v = GameBridge.StateTimer.Value
        if typeof(v) == "number" then return v end
        if typeof(v) == "string" then return tonumber(v) or 0 end
    end
    return 0
end

-- Проверка: идёт ли подготовка (true) или волна (false)
function WaveTimer.IsIntermission()
    local result = true
    
    pcall(function()
        local state = ReplicatedStorage:FindFirstChild("State")
        if not state then return end
        
        -- Ищем различные возможные названия
        local check = state:FindFirstChild("TimerCheck")
                   or state:FindFirstChild("Intermission")
                   or state:FindFirstChild("Preparing")
                   or state:FindFirstChild("IsIntermission")
        
        if check then
            result = (check.Value == true)
        end
    end)
    
    return result
end

--[[
    GetTimerData — возвращает полные данные таймера для записи.
    Формат: {wave, minutes, seconds, timerCheck}
    
    wave       — номер текущей волны
    minutes    — полные минуты таймера
    seconds    — оставшиеся секунды
    timerCheck — "true" если подготовка, "false" если волна
]]
function WaveTimer.GetTimerData()
    local wave    = WaveTimer.GetWave()
    local rawSecs = WaveTimer.GetSeconds()
    local mins    = math.floor(rawSecs / 60)
    local secs    = rawSecs - (mins * 60)
    local tc      = tostring(WaveTimer.IsIntermission())
    
    return {wave, mins, secs, tc}
end

-- ═══════════════════════════════════════════════
--  СЕКЦИЯ 7: RECORDER — ЗАПИСЬ МАКРОСА
-- ═══════════════════════════════════════════════

--[[
    Recorder — перехватывает вызовы InvokeServer к RemoteFunction "Troops"
    и записывает действия игрока в файл.
    
    Формат записи:
      TDS:Place("TowerName", x, y, z, wave, min, sec, "tc", rx, ry, rz)
      TDS:Upgrade(id, wave, min, sec, "tc")
      TDS:Sell(id, wave, min, sec, "tc")
      TDS:Target(id, "priority", wave, min, sec, "tc")
    
    Как работает перехват:
    - hookmetamethod перехватывает __namecall
    - Фильтрует только InvokeServer к GameRF (Troops)
    - Оборачивает в корутину для получения результата
    - Записывает действие в файл
    - Вызывает SyncGUI для предотвращения ошибки Clone
]]
local Recorder = {
    Active     = false,
    FileName   = "",
    TowerCount = 0,
    Towers     = {},     -- [id] = {Name, Instance}
    _hooked    = false,  -- hook создаётся один раз
}

-- Форматирование таймера для записи
-- Формат: wave, min, sec, "tc"  (tc всегда в кавычках!)
local function FormatTimer(timerData)
    return string.format(
        '%d, %d, %.4f, "%s"',
        timerData[1], timerData[2], timerData[3], timerData[4]
    )
end

-- ═════ Генераторы записей для каждого действия ═════

local ActionGenerators = {}

--[[
    Place — размещение башни.
    args[3] = имя башни (string)
    args[4] = CFrame позиции
    result  = Instance (размещённая башня) или nil при ошибке
]]
ActionGenerators.Place = function(args, timerData, result)
    -- Проверяем что сервер вернул Instance
    if typeof(result) ~= "Instance" then
        warn("[Recorder] Place: сервер вернул не Instance, тип: " .. typeof(result))
        return
    end
    
    local towerName = args[3]
    if typeof(towerName) ~= "string" then
        warn("[Recorder] Place: args[3] не строка")
        return
    end
    
    local cframe = args[4]
    if typeof(cframe) ~= "CFrame" then
        warn("[Recorder] Place: args[4] не CFrame")
        return
    end
    
    -- Увеличиваем счётчик и присваиваем ID
    Recorder.TowerCount = Recorder.TowerCount + 1
    local id = Recorder.TowerCount
    
    -- Переименовываем Instance для отслеживания
    result.Name = tostring(id)
    
    -- Сохраняем в таблицу
    Recorder.Towers[id] = {
        Name     = towerName,
        Instance = result,
    }
    
    -- ★ Синхронизация GUI (FIX ошибки Clone)
    GameBridge.SyncGUI(result)
    
    -- Извлекаем позицию и вращение
    local pos = cframe.Position
    local rx, ry, rz = cframe:ToEulerAnglesYXZ()
    
    -- Записываем в файл
    local timerStr = FormatTimer(timerData)
    FileManager.Append(Recorder.FileName, string.format(
        'TDS:Place("%s", %.4f, %.4f, %.4f, %s, %.6f, %.6f, %.6f)',
        towerName, pos.X, pos.Y, pos.Z, timerStr, rx, ry, rz
    ))
    
    print(string.format("[Recorder] Place %-14s ID:%-3d Wave:%d", towerName, id, timerData[1]))
end

--[[
    Upgrade — улучшение башни.
    args[4] = {Troop = Instance}
    result  = true при успехе
]]
ActionGenerators.Upgrade = function(args, timerData, result)
    local data = args[4]
    if typeof(data) ~= "table" or not data.Troop then
        warn("[Recorder] Upgrade: args[4] не содержит Troop")
        return
    end
    
    local troop = data.Troop
    if typeof(troop) ~= "Instance" then
        warn("[Recorder] Upgrade: Troop не Instance")
        return
    end
    
    local id = tonumber(troop.Name)
    if not id then
        warn("[Recorder] Upgrade: имя башни не число: " .. tostring(troop.Name))
        return
    end
    
    if result ~= true then
        warn("[Recorder] Upgrade FAILED для ID:" .. id)
        return
    end
    
    -- ★ Синхронизация GUI
    GameBridge.SyncGUI(troop)
    
    local timerStr = FormatTimer(timerData)
    FileManager.Append(Recorder.FileName, string.format(
        'TDS:Upgrade(%d, %s)', id, timerStr
    ))
    
    print(string.format("[Recorder] Upgrade ID:%-3d Wave:%d", id, timerData[1]))
end

--[[
    Sell — продажа башни.
    args[4] = {Troop = Instance}
]]
ActionGenerators.Sell = function(args, timerData, result)
    local data = args[4]
    if typeof(data) ~= "table" or not data.Troop then return end
    
    local troop = data.Troop
    if typeof(troop) ~= "Instance" then return end
    
    local id = tonumber(troop.Name)
    if not id then return end
    
    local timerStr = FormatTimer(timerData)
    FileManager.Append(Recorder.FileName, string.format(
        'TDS:Sell(%d, %s)', id, timerStr
    ))
    
    print(string.format("[Recorder] Sell   ID:%-3d Wave:%d", id, timerData[1]))
end

--[[
    Target — изменение приоритета цели.
    args[4] = {Troop = Instance, Priority = string}
]]
ActionGenerators.Target = function(args, timerData, result)
    local data = args[4]
    if typeof(data) ~= "table" or not data.Troop then return end
    
    local troop = data.Troop
    if typeof(troop) ~= "Instance" then return end
    
    local id = tonumber(troop.Name)
    if not id then return end
    
    local priority = data.Priority or data.Setting or "First"
    
    local timerStr = FormatTimer(timerData)
    FileManager.Append(Recorder.FileName, string.format(
        'TDS:Target(%d, "%s", %s)', id, tostring(priority), timerStr
    ))
    
    print(string.format("[Recorder] Target ID:%-3d → %s Wave:%d", id, tostring(priority), timerData[1]))
end

-- Маппинг действий (включая альтернативные названия)
local ActionMap = {
    Place        = ActionGenerators.Place,
    Upgrade      = ActionGenerators.Upgrade,
    Sell         = ActionGenerators.Sell,
    Target       = ActionGenerators.Target,
    SetTarget    = ActionGenerators.Target,
    ChangeTarget = ActionGenerators.Target,
}

-- ═════ Управление записью ═════

function Recorder:Start(fileName)
    if self.Active then
        warn("[Recorder] Уже идёт запись!")
        return false, "Запись уже идёт"
    end
    
    -- Проверяем доступность RF
    local rf = GameBridge.GetRF()
    if not rf then
        return false, "RemoteFunction не найдена"
    end
    
    -- Инициализация
    self.FileName   = fileName
    self.TowerCount = 0
    self.Towers     = {}
    self.Active     = true
    
    -- Создаём файл с заголовком
    FileManager.Write(fileName,
        "-- TDS: Reanimated Macro v" .. CONFIG.Version .. "\n" ..
        "-- Recorded: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n" ..
        "-- Player: " .. LocalPlayer.Name .. "\n\n"
    )
    
    -- Устанавливаем hook (один раз за сессию)
    if not self._hooked then
        self._hooked = true
        self:_installHook()
    end
    
    print("[Recorder] ▶ Запись начата → " .. fileName)
    return true, "Запись начата"
end

function Recorder:Stop()
    if not self.Active then return end
    
    self.Active = false
    FileManager.Append(self.FileName, "\n-- End of macro | Towers: " .. self.TowerCount)
    
    print("[Recorder] ■ Запись остановлена | Башен: " .. self.TowerCount)
end

--[[
    _installHook — устанавливает перехват __namecall.
    
    Как это работает:
    1. hookmetamethod заменяет метод __namecall у всех объектов game
    2. Фильтруем: только InvokeServer, только наш RF, только при активной записи
    3. Оборачиваем в корутину:
       - Получаем timerData ДО вызова (фиксируем момент действия)
       - Вызываем оригинальный InvokeServer
       - Получаем результат
       - Записываем действие
       - Возвращаем результат игровому коду
    4. SyncGUI предотвращает ошибку upgradeGui Clone
]]
function Recorder:_installHook()
    local rf = GameBridge.GetRF()
    if not rf then
        warn("[Recorder] Не удалось установить hook: RF не найдена")
        return
    end
    
    local originalNamecall
    originalNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self2, ...)
        local method = getnamecallmethod()
        
        -- Фильтр 1: только InvokeServer
        if method ~= "InvokeServer" then
            return originalNamecall(self2, ...)
        end
        
        -- Фильтр 2: только наш RemoteFunction
        if self2 ~= rf then
            return originalNamecall(self2, ...)
        end
        
        -- Фильтр 3: только при активной записи
        if not Recorder.Active then
            return originalNamecall(self2, ...)
        end
        
        local packedArgs = {...}
        local category   = packedArgs[1]  -- "Troops"
        local action     = packedArgs[2]  -- "Place"/"Upgrade"/etc.
        
        -- Фильтр 4: только категория "Troops"
        if category ~= "Troops" then
            return originalNamecall(self2, ...)
        end
        
        -- Фильтр 5: только известные действия
        local handler = ActionMap[action]
        if not handler then
            return originalNamecall(self2, ...)
        end
        
        -- ═══ Корутинный перехват ═══
        -- Сохраняем текущий поток, чтобы вернуть результат
        local callerThread = coroutine.running()
        
        coroutine.wrap(function(capturedArgs)
            -- Фиксируем таймер ДО вызова сервера
            local timerData = WaveTimer.GetTimerData()
            
            -- Вызываем оригинальный InvokeServer
            local result = originalNamecall(self2, table.unpack(capturedArgs))
            
            -- Записываем действие (безопасно)
            local recordOk, recordErr = pcall(function()
                handler(capturedArgs, timerData, result)
            end)
            
            if not recordOk then
                warn("[Recorder] Ошибка записи " .. action .. ": " .. tostring(recordErr))
            end
            
            -- Возвращаем результат вызывающему коду
            coroutine.resume(callerThread, result)
        end)({...})
        
        -- Ждём результат из корутины
        return coroutine.yield()
    end))
    
    print("[Recorder] Hook установлен на __namecall")
end

-- ═══════════════════════════════════════════════
--  СЕКЦИЯ 8: ПАРСЕР МАКРО-ФАЙЛОВ
-- ═══════════════════════════════════════════════

--[[
    MacroParser — разбирает .lua файл макроса в список команд.
    
    Поддерживаемые форматы:
      TDS:Place("Name", x, y, z, wave, min, sec, "tc", rx, ry, rz)
      TDS:Place("Name", x, y, z, wave, min, sec, tc, rx, ry, rz)  -- tc без кавычек тоже работает
      TDS:Upgrade(id, wave, min, sec, "tc")
      TDS:Sell(id, wave, min, sec, "tc")
      TDS:Target(id, "priority", wave, min, sec, "tc")
    
    Паттерн для tc: "?([^",%)]+)"?
    Это позволяет матчить и "true" и true
]]
local MacroParser = {}

-- Числовой паттерн (включая научную нотацию и отрицательные)
local NUM = "([-%.%deE]+)"
-- Паттерн для timerCheck (с кавычками и без)
local TC  = '"?([^",%)]+)"?'

function MacroParser.Parse(content)
    local commands = {}
    local lineNum  = 0
    
    for line in content:gmatch("[^\r\n]+") do
        lineNum = lineNum + 1
        local trimmed = line:match("^%s*(.-)%s*$")
        
        -- Пропуск пустых строк и комментариев
        if trimmed == "" or trimmed:sub(1, 2) == "--" then
            -- skip
            
        elseif trimmed:find("^TDS:Place") then
            -- Place: TDS:Place("Name", x, y, z, wave, min, sec, "tc", rx, ry, rz)
            local nm, x, y, z, wv, mn, sc, tc, rx, ry, rz = trimmed:match(
                'TDS:Place%(' ..
                '"([^"]+)",%s*' ..                           -- towerName
                NUM .. ',%s*' .. NUM .. ',%s*' .. NUM .. ',%s*' ..  -- x, y, z
                '(%d+),%s*(%d+),%s*' .. NUM .. ',%s*' ..     -- wave, min, sec
                TC .. ',%s*' ..                               -- timerCheck
                NUM .. ',%s*' .. NUM .. ',%s*' .. NUM ..      -- rx, ry, rz
                '%)'
            )
            
            if nm then
                table.insert(commands, {
                    Type  = "Place",
                    Args  = {
                        nm,
                        tonumber(x), tonumber(y), tonumber(z),
                        tonumber(wv), tonumber(mn), tonumber(sc),
                        tc,
                        tonumber(rx), tonumber(ry), tonumber(rz),
                    },
                    Wave  = tonumber(wv),
                    Line  = lineNum,
                })
            else
                warn("[Parser] Строка " .. lineNum .. ": Place не распознан: " .. trimmed)
            end
            
        elseif trimmed:find("^TDS:Upgrade") then
            -- Upgrade: TDS:Upgrade(id, wave, min, sec, "tc")
            local id, wv, mn, sc, tc = trimmed:match(
                'TDS:Upgrade%(' ..
                '(%d+),%s*' ..
                '(%d+),%s*(%d+),%s*' .. NUM .. ',%s*' ..
                TC ..
                '%)'
            )
            
            if id then
                table.insert(commands, {
                    Type = "Upgrade",
                    Args = {tonumber(id), tonumber(wv), tonumber(mn), tonumber(sc), tc},
                    Wave = tonumber(wv),
                    Line = lineNum,
                })
            else
                warn("[Parser] Строка " .. lineNum .. ": Upgrade не распознан: " .. trimmed)
            end
            
        elseif trimmed:find("^TDS:Sell") then
            -- Sell: TDS:Sell(id, wave, min, sec, "tc")
            local id, wv, mn, sc, tc = trimmed:match(
                'TDS:Sell%(' ..
                '(%d+),%s*' ..
                '(%d+),%s*(%d+),%s*' .. NUM .. ',%s*' ..
                TC ..
                '%)'
            )
            
            if id then
                table.insert(commands, {
                    Type = "Sell",
                    Args = {tonumber(id), tonumber(wv), tonumber(mn), tonumber(sc), tc},
                    Wave = tonumber(wv),
                    Line = lineNum,
                })
            else
                warn("[Parser] Строка " .. lineNum .. ": Sell не распознан: " .. trimmed)
            end
            
        elseif trimmed:find("^TDS:Target") then
            -- Target: TDS:Target(id, "priority", wave, min, sec, "tc")
            local id, pr, wv, mn, sc, tc = trimmed:match(
                'TDS:Target%(' ..
                '(%d+),%s*' ..
                '"([^"]*)",%s*' ..
                '(%d+),%s*(%d+),%s*' .. NUM .. ',%s*' ..
                TC ..
                '%)'
            )
            
            if id then
                table.insert(commands, {
                    Type = "Target",
                    Args = {tonumber(id), pr, tonumber(wv), tonumber(mn), tonumber(sc), tc},
                    Wave = tonumber(wv),
                    Line = lineNum,
                })
            else
                warn("[Parser] Строка " .. lineNum .. ": Target не распознан: " .. trimmed)
            end
            
        else
            warn("[Parser] Строка " .. lineNum .. ": нераспознано: " .. trimmed)
        end
    end
    
    print("[Parser] Распознано команд: " .. #commands)
    return commands
end

-- ═══════════════════════════════════════════════
--  СЕКЦИЯ 9: PLAYBACK — ВОСПРОИЗВЕДЕНИЕ МАКРОСА
-- ═══════════════════════════════════════════════

--[[
    Playback — воспроизводит записанный макрос.
    
    Как работает:
    1. Парсит файл в список команд
    2. Последовательно выполняет каждую команду
    3. Перед каждым действием ждёт нужную волну
    4. Place создаёт башню и сохраняет Instance по ID
    5. Upgrade/Sell/Target ждут появления башни по ID
    
    Проблема из оригинального бага:
    "Башня ID:1 не найдена за 45 секунд"
    
    Причина: tc записывался без кавычек (true вместо "true"),
    парсер не мог распарсить строку Place → TowersContained пуст →
    все Upgrade/Sell ждали несуществующую башню.
    
    Решение: FormatTimer всегда оборачивает tc в кавычки,
    парсер принимает оба варианта через паттерн "?([^",%)]+)"?
]]
local Playback = {
    Active     = false,
    Paused     = false,
    Towers     = {},      -- [id] = Instance
    TowerCount = 0,
    Progress   = 0,       -- текущая команда
    Total      = 0,       -- всего команд
    StatusCallback = nil,  -- callback для обновления UI
}

-- Обновление статуса в UI
function Playback:_setStatus(text)
    if self.StatusCallback then
        pcall(function()
            self.StatusCallback(text)
        end)
    end
    print("[Playback] " .. text)
end

-- Ожидание нужной волны
function Playback:_waitForWave(targetWave)
    local startTime = tick()
    
    while self.Active do
        -- Проверка паузы
        while self.Paused and self.Active do
            task.wait(0.25)
        end
        
        if not self.Active then return false end
        
        local currentWave = WaveTimer.GetWave()
        if currentWave >= targetWave then
            return true
        end
        
        -- Таймаут
        if tick() - startTime > CONFIG.TimeoutWave then
            warn("[Playback] Таймаут ожидания волны " .. targetWave ..
                 " (текущая: " .. currentWave .. ")")
            return false
        end
        
        task.wait(CONFIG.PollInterval)
    end
    
    return false
end

-- Ожидание башни по ID
function Playback:_waitForTower(id)
    if self.Towers[id] then
        return self.Towers[id]
    end
    
    local startTime = tick()
    
    while self.Active do
        if self.Towers[id] then
            return self.Towers[id]
        end
        
        if tick() - startTime > CONFIG.TimeoutTower then
            warn("[Playback] Башня ID:" .. id .. " не найдена за " ..
                 CONFIG.TimeoutTower .. " секунд")
            return nil
        end
        
        task.wait(CONFIG.PollInterval)
    end
    
    return nil
end

-- ═════ Действия воспроизведения ═════

local PlaybackActions = {}

function PlaybackActions.Place(pb, towerName, x, y, z, wave, min, sec, tc, rx, ry, rz)
    rx = rx or 0
    ry = ry or 0
    rz = rz or 0
    
    pb:_setStatus(string.format("Ожидание волны %d для Place '%s'...", wave, towerName))
    
    if not pb:_waitForWave(wave) then return end
    
    local rf = GameBridge.GetRF()
    if not rf then
        warn("[Playback] RF недоступен для Place")
        return
    end
    
    local cf = CFrame.new(x, y, z) * CFrame.fromEulerAnglesYXZ(rx, ry, rz)
    
    pb:_setStatus(string.format("Place '%s' (%.0f, %.0f, %.0f)", towerName, x, y, z))
    
    local ok, result = pcall(function()
        return rf:InvokeServer("Troops", "Place", towerName, cf)
    end)
    
    if ok and typeof(result) == "Instance" then
        pb.TowerCount = pb.TowerCount + 1
        local id = pb.TowerCount
        result.Name = tostring(id)
        pb.Towers[id] = result
        
        GameBridge.SyncGUI(result)
        
        pb:_setStatus(string.format("✓ Placed '%s' ID:%d", towerName, id))
    else
        warn("[Playback] ✗ Place failed: " .. tostring(result))
    end
end

function PlaybackActions.Upgrade(pb, id, wave, min, sec, tc)
    pb:_setStatus(string.format("Ожидание волны %d для Upgrade ID:%d...", wave, id))
    
    if not pb:_waitForWave(wave) then return end
    
    local troop = pb:_waitForTower(id)
    if not troop then return end
    
    local rf = GameBridge.GetRF()
    if not rf then return end
    
    pb:_setStatus(string.format("Upgrade ID:%d", id))
    
    local ok, result = pcall(function()
        return rf:InvokeServer("Troops", "Upgrade", nil, {Troop = troop})
    end)
    
    if ok and result == true then
        GameBridge.SyncGUI(troop)
        pb:_setStatus(string.format("✓ Upgraded ID:%d", id))
    else
        warn("[Playback] ✗ Upgrade failed ID:" .. id .. " — " .. tostring(result))
    end
end

function PlaybackActions.Sell(pb, id, wave, min, sec, tc)
    pb:_setStatus(string.format("Ожидание волны %d для Sell ID:%d...", wave, id))
    
    if not pb:_waitForWave(wave) then return end
    
    local troop = pb:_waitForTower(id)
    if not troop then return end
    
    local rf = GameBridge.GetRF()
    if not rf then return end
    
    pb:_setStatus(string.format("Sell ID:%d", id))
    
    local ok, result = pcall(function()
        return rf:InvokeServer("Troops", "Sell", nil, {Troop = troop})
    end)
    
    if ok then
        pb.Towers[id] = nil
        pb:_setStatus(string.format("✓ Sold ID:%d", id))
    else
        warn("[Playback] ✗ Sell failed ID:" .. id)
    end
end

function PlaybackActions.Target(pb, id, priority, wave, min, sec, tc)
    pb:_setStatus(string.format("Ожидание волны %d для Target ID:%d...", wave, id))
    
    if not pb:_waitForWave(wave) then return end
    
    local troop = pb:_waitForTower(id)
    if not troop then return end
    
    local rf = GameBridge.GetRF()
    if not rf then return end
    
    pb:_setStatus(string.format("Target ID:%d → %s", id, priority))
    
    pcall(function()
        rf:InvokeServer("Troops", "Target", nil, {
            Troop    = troop,
            Priority = priority,
        })
    end)
    
    pb:_setStatus(string.format("✓ Target ID:%d → %s", id, priority))
end

-- ═════ Управление воспроизведением ═════

function Playback:Start(fileName, statusCallback)
    if self.Active then
        return false, "Уже воспроизводится"
    end
    
    -- Проверяем файл
    local content = FileManager.Read(fileName)
    if not content then
        return false, "Файл не найден: " .. fileName
    end
    
    -- Парсим
    local commands = MacroParser.Parse(content)
    if #commands == 0 then
        return false, "Нет команд в файле"
    end
    
    -- Проверяем RF
    local rf = GameBridge.GetRF()
    if not rf then
        return false, "RemoteFunction не найдена"
    end
    
    -- Инициализация
    self.Active         = true
    self.Paused         = false
    self.Towers         = {}
    self.TowerCount     = 0
    self.Progress       = 0
    self.Total          = #commands
    self.StatusCallback = statusCallback
    
    self:_setStatus("▶ Старт: " .. fileName .. " (" .. #commands .. " команд)")
    
    -- Запускаем в отдельном потоке
    task.spawn(function()
        for i, cmd in ipairs(commands) do
            if not self.Active then
                self:_setStatus("■ Остановлено на команде " .. i .. "/" .. self.Total)
                break
            end
            
            -- Пауза
            while self.Paused and self.Active do
                task.wait(0.25)
            end
            
            if not self.Active then break end
            
            self.Progress = i
            
            -- Выполняем действие
            local actionFn = PlaybackActions[cmd.Type]
            if actionFn then
                local ok, err = pcall(function()
                    actionFn(self, table.unpack(cmd.Args))
                end)
                
                if not ok then
                    warn(string.format(
                        "[Playback] Ошибка cmd %d/%d (%s L:%d): %s",
                        i, self.Total, cmd.Type, cmd.Line, tostring(err)
                    ))
                end
            else
                warn("[Playback] Неизвестный тип команды: " .. tostring(cmd.Type))
            end
            
            task.wait(CONFIG.ActionDelay)
        end
        
        if self.Active then
            self:_setStatus("✓ Воспроизведение завершено (" .. self.Total .. " команд)")
        end
        
        self.Active = false
    end)
    
    return true, "Воспроизведение начато"
end

function Playback:Stop()
    if not self.Active then return end
    self.Active = false
    self.Paused = false
    self:_setStatus("■ Остановлено")
end

function Playback:TogglePause()
    if not self.Active then return false end
    self.Paused = not self.Paused
    self:_setStatus(self.Paused and "⏸ Пауза" or "▶ Продолжение")
    return self.Paused
end

function Playback:GetProgress()
    if self.Total == 0 then return 0 end
    return math.floor((self.Progress / self.Total) * 100)
end

-- ═══════════════════════════════════════════════
--  СЕКЦИЯ 10: АВТО-ПРОДАЖА ФЕРМ
-- ═══════════════════════════════════════════════

--[[
    AutoSellFarm — автоматически продаёт фермы на максимальном уровне.
    
    Логика:
    1. Каждые N секунд сканирует папку Troops в workspace
    2. Для каждой башни проверяет:
       - Принадлежит ли локальному игроку (Owner)
       - Является ли фермой (по имени)
       - Достигла ли максимального уровня
    3. Если все условия выполнены — продаёт через RF
]]
local AutoSellFarm = {
    Active    = false,
    FarmNames = {  -- имена башен-ферм (в нижнем регистре)
        "farm", "golden farm", "military base",
    },
}

function AutoSellFarm:IsFarm(name)
    local lower = name:lower()
    for _, farmName in ipairs(self.FarmNames) do
        if lower:find(farmName, 1, true) then
            return true
        end
    end
    return false
end

function AutoSellFarm:IsOurTower(troop)
    local owner = troop:FindFirstChild("Owner")
    if not owner then return false end
    
    local val = owner.Value
    
    -- Owner может быть разных типов в зависимости от реализации
    if typeof(val) == "Instance" then
        return val == LocalPlayer
    elseif typeof(val) == "string" then
        return val == LocalPlayer.Name
    elseif typeof(val) == "number" then
        return val == LocalPlayer.UserId
    end
    
    return false
end

function AutoSellFarm:IsMaxLevel(troop)
    local level    = troop:FindFirstChild("Level")
    local maxLevel = troop:FindFirstChild("MaxLevel")
    
    if level and maxLevel then
        return level.Value >= maxLevel.Value
    end
    
    return false
end

function AutoSellFarm:Start()
    if self.Active then return end
    self.Active = true
    
    task.spawn(function()
        local rf = GameBridge.GetRF()
        
        while self.Active do
            pcall(function()
                if not rf then
                    rf = GameBridge.GetRF()
                    return
                end
                
                local troopsFolder = GameBridge.FindTroopsFolder()
                if not troopsFolder then return end
                
                for _, troop in ipairs(troopsFolder:GetChildren()) do
                    if not self.Active then break end
                    
                    if self:IsOurTower(troop) 
                       and self:IsFarm(troop.Name) 
                       and self:IsMaxLevel(troop) then
                        
                        local sellOk = pcall(function()
                            rf:InvokeServer("Troops", "Sell", nil, {Troop = troop})
                        end)
                        
                        if sellOk then
                            print("[AutoSell] ✓ Продана: " .. troop.Name)
                        end
                    end
                end
            end)
            
            task.wait(CONFIG.AutoSellDelay)
        end
    end)
    
    print("[AutoSell] ▶ Включена")
end

function AutoSellFarm:Stop()
    self.Active = false
    print("[AutoSell] ■ Выключена")
end

-- ═══════════════════════════════════════════════
--  СЕКЦИЯ 11: RAYFIELD UI — ИНТЕРФЕЙС
-- ═══════════════════════════════════════════════

local Window = Rayfield:CreateWindow({
    Name              = "TDS: Reanimated Macro",
    LoadingTitle      = "TDS: Reanimated Macro",
    LoadingSubtitle   = "v" .. CONFIG.Version .. " | Загрузка...",
    ConfigurationSaving = {
        Enabled  = false,
        FileName = "TDSMacroConfig",
    },
    Discord = {
        Enabled = false,
    },
    KeySystem = false,
})

-- ═══════ ВКЛАДКА: ЗАПИСЬ ═══════

local TabRecord = Window:CreateTab("Запись", 4483362458)

local RecordFileName  = ""
local RecordStatusLbl = TabRecord:CreateLabel("⏹ Ожидание")

TabRecord:CreateInput({
    Name            = "Имя макроса",
    PlaceholderText = "Введите имя файла...",
    RemoveTextAfterFocusLost = false,
    Callback = function(text)
        RecordFileName = text
    end,
})

TabRecord:CreateButton({
    Name     = "🔴 Начать запись",
    Callback = function()
        if RecordFileName == "" then
            RecordStatusLbl:Set("❌ Введите имя файла!")
            return
        end
        
        local name = RecordFileName
        if not name:match("%.lua$") then
            name = name .. ".lua"
        end
        
        local ok, msg = Recorder:Start(name)
        if ok then
            RecordStatusLbl:Set("🔴 Запись: " .. name)
            Rayfield:Notify({
                Title   = "Запись начата",
                Content = "Файл: " .. name,
                Duration = 3,
            })
        else
            RecordStatusLbl:Set("❌ " .. msg)
        end
    end,
})

TabRecord:CreateButton({
    Name     = "⬛ Остановить запись",
    Callback = function()
        if not Recorder.Active then
            RecordStatusLbl:Set("❌ Запись не идёт")
            return
        end
        
        Recorder:Stop()
        RecordStatusLbl:Set("⬛ Остановлено | Башен: " .. Recorder.TowerCount)
        
        Rayfield:Notify({
            Title   = "Запись остановлена",
            Content = "Записано башен: " .. Recorder.TowerCount,
            Duration = 3,
        })
    end,
})

TabRecord:CreateParagraph({
    Title   = "Инструкция",
    Content = "1. Введите имя файла\n" ..
              "2. Нажмите 'Начать запись'\n" ..
              "3. Играйте — ставьте, улучшайте, продавайте башни\n" ..
              "4. Нажмите 'Остановить запись'\n" ..
              "Все действия сохранятся в файл.",
})

-- ═══════ ВКЛАДКА: ВОСПРОИЗВЕДЕНИЕ ═══════

local TabPlay = Window:CreateTab("Воспроизведение", 4483362458)

local PlayFileName  = ""
local PlayStatusLbl = TabPlay:CreateLabel("⏹ Ожидание")
local PlayProgress  = TabPlay:CreateLabel("Прогресс: —")

-- Получаем список файлов
local function GetFileOptions()
    local files = FileManager.List()
    if #files == 0 then
        return {"— Нет макросов —"}
    end
    return files
end

local PlayDropdown

PlayDropdown = TabPlay:CreateDropdown({
    Name            = "Выбрать макрос",
    Options         = GetFileOptions(),
    CurrentOption   = {},
    MultipleOptions = false,
    Callback = function(options)
        if options and options[1] and options[1] ~= "— Нет макросов —" then
            PlayFileName = options[1]
            PlayStatusLbl:Set("Выбран: " .. options[1])
        end
    end,
})

TabPlay:CreateInput({
    Name            = "Или введите имя",
    PlaceholderText = "Имя файла...",
    RemoveTextAfterFocusLost = false,
    Callback = function(text)
        if text ~= "" then
            PlayFileName = text
            if not PlayFileName:match("%.lua$") then
                PlayFileName = PlayFileName .. ".lua"
            end
            PlayStatusLbl:Set("Введено: " .. PlayFileName)
        end
    end,
})

TabPlay:CreateButton({
    Name     = "🔄 Обновить список",
    Callback = function()
        local newOptions = GetFileOptions()
        PlayDropdown:Set(newOptions)
        PlayStatusLbl:Set("Список обновлён (" .. #newOptions .. ")")
    end,
})

TabPlay:CreateButton({
    Name     = "▶ Воспроизвести",
    Callback = function()
        if PlayFileName == "" or PlayFileName == "— Нет макросов —" then
            PlayStatusLbl:Set("❌ Выберите макрос!")
            return
        end
        
        local ok, msg = Playback:Start(PlayFileName, function(statusText)
            pcall(function()
                PlayStatusLbl:Set(statusText)
                PlayProgress:Set("Прогресс: " .. Playback:GetProgress() .. "% (" ..
                                 Playback.Progress .. "/" .. Playback.Total .. ")")
            end)
        end)
        
        if ok then
            PlayStatusLbl:Set("▶ " .. PlayFileName)
            Rayfield:Notify({
                Title   = "Воспроизведение начато",
                Content = PlayFileName,
                Duration = 3,
            })
        else
            PlayStatusLbl:Set("❌ " .. msg)
        end
    end,
})

TabPlay:CreateButton({
    Name     = "⏸ Пауза / Продолжить",
    Callback = function()
        if not Playback.Active then
            PlayStatusLbl:Set("❌ Воспроизведение не идёт")
            return
        end
        
        local paused = Playback:TogglePause()
        PlayStatusLbl:Set(paused and "⏸ Пауза" or "▶ Продолжение")
    end,
})

TabPlay:CreateButton({
    Name     = "⬛ Остановить",
    Callback = function()
        Playback:Stop()
        PlayStatusLbl:Set("⬛ Остановлено")
        PlayProgress:Set("Прогресс: —")
    end,
})

-- ═══════ ВКЛАДКА: АВТО-ФУНКЦИИ ═══════

local TabAuto = Window:CreateTab("Авто-функции", 4483362458)

local AutoSellLbl = TabAuto:CreateLabel("Авто-продажа: ВЫКЛ")

TabAuto:CreateToggle({
    Name         = "Авто-продажа ферм (макс. уровень)",
    CurrentValue = false,
    Flag         = "AutoSellToggle",
    Callback = function(enabled)
        if enabled then
            AutoSellFarm:Start()
            AutoSellLbl:Set("Авто-продажа: ВКЛ ✅")
        else
            AutoSellFarm:Stop()
            AutoSellLbl:Set("Авто-продажа: ВЫКЛ ❌")
        end
    end,
})

TabAuto:CreateParagraph({
    Title   = "Как работает",
    Content = "Автоматически продаёт ваши фермы,\n" ..
              "когда они достигают максимального уровня.\n" ..
              "Проверка каждые " .. CONFIG.AutoSellDelay .. " секунд.",
})

-- ═══════ ВКЛАДКА: ФАЙЛЫ ═══════

local TabFiles = Window:CreateTab("Файлы", 4483362458)

local FilesInfoLbl = TabFiles:CreateLabel("Папка: " .. CONFIG.MacroFolder)

TabFiles:CreateButton({
    Name     = "📋 Показать все файлы",
    Callback = function()
        local files = FileManager.List()
        if #files == 0 then
            FilesInfoLbl:Set("Нет сохранённых макросов")
            return
        end
        
        print("═══ Макро-файлы ═══")
        for i, f in ipairs(files) do
            print(string.format("  %d. %s", i, f))
        end
        print("════════════════════")
        
        FilesInfoLbl:Set("Файлов: " .. #files .. " (см. консоль)")
    end,
})

local DeleteFileName = ""

TabFiles:CreateInput({
    Name            = "Удалить файл",
    PlaceholderText = "Имя файла для удаления...",
    RemoveTextAfterFocusLost = false,
    Callback = function(text)
        DeleteFileName = text
    end,
})

TabFiles:CreateButton({
    Name     = "🗑 Удалить",
    Callback = function()
        if DeleteFileName == "" then
            FilesInfoLbl:Set("❌ Введите имя файла")
            return
        end
        
        if FileManager.Delete(DeleteFileName) then
            FilesInfoLbl:Set("✓ Удалён: " .. DeleteFileName)
            -- Обновляем dropdown
            local newOptions = GetFileOptions()
            PlayDropdown:Set(newOptions)
        else
            FilesInfoLbl:Set("❌ Файл не найден: " .. DeleteFileName)
        end
    end,
})

TabFiles:CreateButton({
    Name     = "📖 Прочитать файл в консоль",
    Callback = function()
        if DeleteFileName == "" then
            FilesInfoLbl:Set("❌ Введите имя файла")
            return
        end
        
        local content = FileManager.Read(DeleteFileName)
        if content then
            print("═══ Содержимое: " .. DeleteFileName .. " ═══")
            print(content)
            print("═══════════════════════════════════════════")
            FilesInfoLbl:Set("✓ Выведено в консоль")
        else
            FilesInfoLbl:Set("❌ Файл не найден")
        end
    end,
})

-- ═══════ ВКЛАДКА: ИНФОРМАЦИЯ ═══════

local TabInfo = Window:CreateTab("Информация", 4483362458)

TabInfo:CreateParagraph({
    Title   = "TDS: Reanimated Macro v" .. CONFIG.Version,
    Content = "Макро-система для TDS: Reanimated\n" ..
              "Основана на Strategies-X\n\n" ..
              "Возможности:\n" ..
              "• Запись действий (Place/Upgrade/Sell/Target)\n" ..
              "• Воспроизведение макросов\n" ..
              "• Пауза/Стоп воспроизведения\n" ..
              "• Авто-продажа ферм\n" ..
              "• Управление файлами макросов",
})

TabInfo:CreateParagraph({
    Title   = "Формат макро-файла",
    Content = 'TDS:Place("Name", x, y, z, wave, min, sec, "tc", rx, ry, rz)\n' ..
              'TDS:Upgrade(id, wave, min, sec, "tc")\n' ..
              'TDS:Sell(id, wave, min, sec, "tc")\n' ..
              'TDS:Target(id, "priority", wave, min, sec, "tc")',
})

TabInfo:CreateLabel("Wave: " .. WaveTimer.GetWave())
TabInfo:CreateLabel("RF: " .. tostring(GameBridge.GetRF() ~= nil and "✓" or "✗"))

-- ═══════════════════════════════════════════════
--  СЕКЦИЯ 12: ФИНАЛИЗАЦИЯ
-- ═══════════════════════════════════════════════

print(string.format(
    "[TDS Macro v%s] ✓ Загружен | RF: %s | Папка: %s",
    CONFIG.Version,
    GameBridge.GetRF() and "найдена" or "НЕ НАЙДЕНА",
    CONFIG.MacroFolder
))

Rayfield:Notify({
    Title    = "TDS Macro v" .. CONFIG.Version,
    Content  = "Скрипт загружен успешно!",
    Duration = 5,
})
