--[[
    TDS: Reanimated — Macro v2.2.0 (Fixed)
    Функции: запись / воспроизведение / авто‑продажа ферм
    Fixes:
      1. upgradeGui:398 Clone error — добавлен pcall + selectTroop
      2. Place pattern mismatch — tc записывается в кавычках
      3. GetWave() — приоритет GUI‑текст, fallback на IntValue
      4. Отладочный вывод нераспознанных строк
]]

-------------------------------------------------
--  СЕРВИСЫ
-------------------------------------------------
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local HttpService        = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

-------------------------------------------------
--  КОНСТАНТЫ / НАСТРОЙКИ
-------------------------------------------------
local VERSION        = "2.2.0-fix"
local MACRO_FOLDER   = "TDS_Macros"
local TIMEOUT_TOWER  = 45          -- секунд ожидания башни
local TIMEOUT_WAVE   = 300         -- секунд ожидания волны
local POLL_INTERVAL  = 0.15        -- шаг polling‑а

-------------------------------------------------
--  УТИЛИТЫ ФАЙЛОВ
-------------------------------------------------
if not isfolder(MACRO_FOLDER) then makefolder(MACRO_FOLDER) end

local function FilePath(name)
    return MACRO_FOLDER .. "/" .. name
end

local function FileWrite(name, text)
    writefile(FilePath(name), text)
end

local function FileAppend(name, text)
    appendfile(FilePath(name), text .. "\n")
end

local function FileRead(name)
    return readfile(FilePath(name))
end

local function FileExists(name)
    return isfile(FilePath(name))
end

local function FileList()
    local out = {}
    for _, v in ipairs(listfiles(MACRO_FOLDER)) do
        local n = v:match("[/\\]([^/\\]+)$")
        if n then table.insert(out, n) end
    end
    return out
end

-------------------------------------------------
--  ИГРОВЫЕ ССЫЛКИ (ленивая инициализация)
-------------------------------------------------
local GameRF        -- RemoteFunction "Troops"
local RSWave        -- IntValue  State.Wave
local RSTimer       -- NumberValue State.Timer  (или StringValue)
local TroopsFolder  -- Workspace.<map>.Troops

local function EnsureRemote()
    if GameRF then return GameRF end
    GameRF = ReplicatedStorage:WaitForChild("RemoteFunctions", 10)
               and ReplicatedStorage.RemoteFunctions:WaitForChild("Troops", 10)
    assert(GameRF, "[Macro] RemoteFunction 'Troops' не найдена")
    return GameRF
end

local function EnsureState()
    if RSWave then return end
    local state = ReplicatedStorage:WaitForChild("State", 15)
    if state then
        RSWave  = state:FindFirstChild("Wave")
        RSTimer = state:FindFirstChild("Timer")
    end
end

local function FindTroopsFolder()
    if TroopsFolder and TroopsFolder.Parent then return TroopsFolder end
    for _, obj in ipairs(workspace:GetChildren()) do
        if obj:IsA("Folder") or obj:IsA("Model") then
            local t = obj:FindFirstChild("Troops")
            if t then TroopsFolder = t; return t end
        end
    end
    return nil
end

-------------------------------------------------
--  ПОЛУЧЕНИЕ ВОЛНЫ (GUI → fallback IntValue)
-------------------------------------------------
local function GetWave()
    -- Приоритет: GUI текст (как в оригинале Sigmanic)
    pcall(function()
        local gui = LocalPlayer.PlayerGui:FindFirstChild("ReactGameTopGameDisplay")
        if gui then
            local frame = gui:FindFirstChild("Frame")
            if frame then
                local wave = frame:FindFirstChild("wave")
                if wave then
                    local container = wave:FindFirstChild("container")
                    if container then
                        local val = container:FindFirstChild("value")
                        if val and val:IsA("TextLabel") then
                            local n = tonumber(val.Text)
                            if n then return n end
                        end
                    end
                end
            end
        end
    end)

    -- Fallback: IntValue
    EnsureState()
    if RSWave then
        local v = RSWave.Value
        if typeof(v) == "number" then return math.floor(v) end
    end
    return 0
end

-- Правильная версия GetWave с возвратом через переменную (pcall не возвращает из функции)
local function GetWave()
    local result = 0

    -- Приоритет: GUI текст
    local ok, guiWave = pcall(function()
        local gui = LocalPlayer.PlayerGui:FindFirstChild("ReactGameTopGameDisplay")
        if not gui then return nil end
        local frame = gui:FindFirstChild("Frame")
        if not frame then return nil end
        local wave = frame:FindFirstChild("wave")
        if not wave then return nil end
        local container = wave:FindFirstChild("container")
        if not container then return nil end
        local val = container:FindFirstChild("value")
        if val and val:IsA("TextLabel") then
            return tonumber(val.Text)
        end
        return nil
    end)

    if ok and guiWave then
        return guiWave
    end

    -- Fallback: IntValue
    EnsureState()
    if RSWave then
        local v = RSWave.Value
        if typeof(v) == "number" then return math.floor(v) end
    end

    return 0
end

-------------------------------------------------
--  ПОЛУЧЕНИЕ ТАЙМЕРА
-------------------------------------------------
local function GetTimerSeconds()
    EnsureState()
    if RSTimer then
        local v = RSTimer.Value
        if typeof(v) == "number" then return v end
        if typeof(v) == "string" then return tonumber(v) or 0 end
    end
    return 0
end

-------------------------------------------------
--  ПОЛУЧЕНИЕ {wave, minutes, seconds, timerCheck}
-------------------------------------------------
local function GetTimer()
    local wave = GetWave()
    local raw  = GetTimerSeconds()
    local mins = math.floor(raw / 60)
    local secs = raw - mins * 60
    -- timerCheck: true если таймер (подготовка), false если волна идёт
    -- Определяем по наличию активных мобов или по значению State
    local timerCheck = true
    pcall(function()
        local state = ReplicatedStorage:FindFirstChild("State")
        if state then
            local tc = state:FindFirstChild("TimerCheck")
                    or state:FindFirstChild("Intermission")
                    or state:FindFirstChild("Preparing")
            if tc then
                timerCheck = tc.Value and true or false
            end
        end
    end)
    return {wave, mins, secs, tostring(timerCheck)}
end

-------------------------------------------------
--  ЗАПИСЬ (RECORDER)
-------------------------------------------------
local Recorder = {}
Recorder.Active      = false
Recorder.FileName    = ""
Recorder.TowerCount  = 0
Recorder.Towers      = {}   -- [id] = {TowerName, Instance, ...}
Recorder.HookCleanup = nil

-- upgradeHandler для синхронизации GUI
local upgradeHandler = nil
pcall(function()
    upgradeHandler = require(
        ReplicatedStorage.Client.Modules.Game.Interface.Elements.Upgrade.upgradeHandler
    )
end)

local function SyncGUI(troop)
    if upgradeHandler and troop then
        pcall(function()
            upgradeHandler:selectTroop(troop)
        end)
    end
end

--  Генераторы строк для каждого action
local Gen = {}

Gen.Place = function(args, timer, result)
    if typeof(result) ~= "Instance" then
        warn("[Recorder] Place: RF вернул не Instance — пропуск")
        return
    end

    local towerName = args[3]
    local cframe    = args[4]
    if typeof(cframe) ~= "CFrame" then
        warn("[Recorder] Place: args[4] не CFrame — пропуск")
        return
    end

    local pos = cframe.Position
    local rx, ry, rz = cframe:ToEulerAnglesYXZ()

    Recorder.TowerCount += 1
    local id = Recorder.TowerCount
    result.Name = tostring(id)

    Recorder.Towers[id] = {
        TowerName = towerName,
        Instance  = result,
    }

    -- Синхронизация GUI ★ FIX проблемы 1
    SyncGUI(result)

    -- timer[4] оборачиваем в кавычки ★ FIX проблемы 2
    local ts = string.format('%d, %d, %.4f, "%s"', timer[1], timer[2], timer[3], timer[4])
    FileAppend(Recorder.FileName, string.format(
        'TDS:Place("%s", %.4f, %.4f, %.4f, %s, %.6f, %.6f, %.6f)',
        towerName, pos.X, pos.Y, pos.Z, ts, rx, ry, rz
    ))

    print(string.format("[Recorder] Place %-14s ID:%-3d Wave:%d", towerName, id, timer[1]))
end

Gen.Upgrade = function(args, timer, result)
    local troopData = args[4]
    if typeof(troopData) ~= "table" then
        warn("[Recorder] Upgrade: args[4] не таблица")
        return
    end

    local troop = troopData.Troop
    if not troop or typeof(troop) ~= "Instance" then
        warn("[Recorder] Upgrade: нет Troop Instance")
        return
    end

    local id = tonumber(troop.Name)
    if not id then
        warn("[Recorder] Upgrade: имя трупа не число: " .. tostring(troop.Name))
        return
    end

    if result ~= true then
        warn("[Recorder] Upgrade FAILED ID:" .. id)
        return
    end

    -- Синхронизация GUI ★ FIX проблемы 1
    SyncGUI(troop)

    local ts = string.format('%d, %d, %.4f, "%s"', timer[1], timer[2], timer[3], timer[4])
    FileAppend(Recorder.FileName, string.format('TDS:Upgrade(%d, %s)', id, ts))

    print(string.format("[Recorder] Upgrade ID:%-3d Wave:%d", id, timer[1]))
end

Gen.Sell = function(args, timer, result)
    local troopData = args[4]
    if typeof(troopData) ~= "table" then return end
    local troop = troopData.Troop
    if not troop or typeof(troop) ~= "Instance" then return end
    local id = tonumber(troop.Name)
    if not id then return end

    local ts = string.format('%d, %d, %.4f, "%s"', timer[1], timer[2], timer[3], timer[4])
    FileAppend(Recorder.FileName, string.format('TDS:Sell(%d, %s)', id, ts))

    print(string.format("[Recorder] Sell   ID:%-3d Wave:%d", id, timer[1]))
end

Gen.Target = function(args, timer, result)
    local troopData = args[4]
    if typeof(troopData) ~= "table" then return end
    local troop = troopData.Troop
    if not troop or typeof(troop) ~= "Instance" then return end
    local id = tonumber(troop.Name)
    if not id then return end

    local priority = troopData.Priority or troopData.Setting or "Unknown"

    local ts = string.format('%d, %d, %.4f, "%s"', timer[1], timer[2], timer[3], timer[4])
    FileAppend(Recorder.FileName, string.format('TDS:Target(%d, "%s", %s)', id, tostring(priority), ts))

    print(string.format("[Recorder] Target ID:%-3d → %s Wave:%d", id, tostring(priority), timer[1]))
end

local CoroutineActions = {
    Place   = Gen.Place,
    Upgrade = Gen.Upgrade,
    Sell    = Gen.Sell,
    Target  = Gen.Target,
    SetTarget   = Gen.Target,
    ChangeTarget = Gen.Target,
}

function Recorder:Start(fileName)
    if self.Active then
        warn("[Recorder] Уже записывается!")
        return false
    end

    self.FileName   = fileName
    self.TowerCount = 0
    self.Towers     = {}
    self.Active     = true

    FileWrite(fileName, "-- TDS Macro v" .. VERSION .. "\n")
    FileAppend(fileName, "-- Recorded: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")

    EnsureRemote()

    -- Hook InvokeServer
    local oldHook
    oldHook = hookmetamethod(game, "__namecall", newcclosure(function(self2, ...)
        local method = getnamecallmethod()
        if method ~= "InvokeServer" then
            return oldHook(self2, ...)
        end

        -- Только наш RemoteFunction
        if self2 ~= GameRF then
            return oldHook(self2, ...)
        end

        if not Recorder.Active then
            return oldHook(self2, ...)
        end

        local args = {...}
        local category = args[1]
        local action   = args[2]

        if category ~= "Troops" then
            return oldHook(self2, ...)
        end

        local handler = CoroutineActions[action]
        if not handler then
            return oldHook(self2, ...)
        end

        -- Выполняем в корутине, чтобы получить результат И записать
        local thread = coroutine.running()
        coroutine.wrap(function(a)
            local timer  = GetTimer()
            local result = oldHook(self2, table.unpack(a))

            -- Запись — безопасно
            pcall(function()
                handler(a, timer, result)
            end)

            coroutine.resume(thread, result)
        end)({...})

        return coroutine.yield()
    end))

    self.HookCleanup = function()
        -- hookmetamethod нельзя "снять" напрямую,
        -- но мы деактивируем через Recorder.Active = false
    end

    print("[Recorder] ▶ Запись начата → " .. fileName)
    return true
end

function Recorder:Stop()
    if not self.Active then return end
    self.Active = false
    FileAppend(self.FileName, "\n-- End of macro")
    print("[Recorder] ■ Запись остановлена. Towers: " .. self.TowerCount)
end

-------------------------------------------------
--  ВОСПРОИЗВЕДЕНИЕ (PLAYER)
-------------------------------------------------
local Player = {}
Player.Active      = false
Player.Paused      = false
Player.Towers      = {}    -- [id] = Instance
Player.TowerCount  = 0

--  Ожидание волны
local function WaitForWave(targetWave)
    local t0 = tick()
    while Player.Active do
        local cur = GetWave()
        if cur >= targetWave then return true end
        if tick() - t0 > TIMEOUT_WAVE then
            warn("[Playback] Таймаут ожидания волны " .. targetWave .. " (текущая " .. cur .. ")")
            return false
        end
        task.wait(POLL_INTERVAL)
    end
    return false
end

--  Ожидание таймера внутри волны
local function WaitForTime(targetMin, targetSec, timerCheck)
    -- timerCheck = "true" → ждём подготовку; "false" → ждём бой
    local t0 = tick()
    while Player.Active do
        local raw = GetTimerSeconds()
        local curMin = math.floor(raw / 60)
        local curSec = raw - curMin * 60

        -- Простейшая проверка: общее время <= целевого
        local curTotal    = curMin * 60 + curSec
        local targetTotal = targetMin * 60 + targetSec

        if curTotal <= targetTotal then
            return true
        end

        if tick() - t0 > TIMEOUT_WAVE then
            warn("[Playback] Таймаут ожидания таймера")
            return false
        end

        -- Пауза
        while Player.Paused and Player.Active do
            task.wait(0.25)
        end

        task.wait(POLL_INTERVAL)
    end
    return false
end

--  Комбинированное ожидание волны + таймера
local function TimeWaveWait(wave, min, sec, tc)
    if not WaitForWave(wave) then return false end
    -- После достижения волны ждём таймер (опционально)
    -- Для простоты пока ждём только волну
    -- Можно раскомментировать если нужна точность:
    -- if not WaitForTime(min, sec, tc) then return false end
    return true
end

--  Ожидание появления башни по ID
local function WaitForTower(id)
    if Player.Towers[id] then return Player.Towers[id] end
    local t0 = tick()
    while Player.Active do
        if Player.Towers[id] then return Player.Towers[id] end
        if tick() - t0 > TIMEOUT_TOWER then
            warn("[Playback] Башня ID:" .. id .. " не найдена за " .. TIMEOUT_TOWER .. " секунд")
            return nil
        end
        task.wait(POLL_INTERVAL)
    end
    return nil
end

--  Действия воспроизведения
local TDS = {}

function TDS:Place(towerName, x, y, z, wave, min, sec, tc, rx, ry, rz)
    rx = rx or 0
    ry = ry or 0
    rz = rz or 0

    if not TimeWaveWait(wave, min, sec, tc) then return end

    EnsureRemote()

    local cf = CFrame.new(x, y, z) * CFrame.fromEulerAnglesYXZ(rx, ry, rz)

    print(string.format("[Playback] Place %-14s at (%.1f, %.1f, %.1f) Wave:%d", towerName, x, y, z, wave))

    local ok, result = pcall(function()
        return GameRF:InvokeServer("Troops", "Place", towerName, cf)
    end)

    if ok and typeof(result) == "Instance" then
        Player.TowerCount += 1
        local id = Player.TowerCount
        result.Name = tostring(id)
        Player.Towers[id] = result
        print(string.format("[Playback] ✓ Placed ID:%d", id))

        -- Синхронизация GUI
        SyncGUI(result)
    else
        warn("[Playback] ✗ Place failed: " .. tostring(result))
    end
end

function TDS:Upgrade(id, wave, min, sec, tc)
    if not TimeWaveWait(wave, min, sec, tc) then return end

    local troop = WaitForTower(id)
    if not troop then return end

    EnsureRemote()

    print(string.format("[Playback] Upgrade ID:%d Wave:%d", id, wave))

    local ok, result = pcall(function()
        return GameRF:InvokeServer("Troops", "Upgrade", nil, {Troop = troop})
    end)

    if ok and result == true then
        print(string.format("[Playback] ✓ Upgraded ID:%d", id))
        SyncGUI(troop)
    else
        warn("[Playback] ✗ Upgrade failed ID:" .. id .. ": " .. tostring(result))
    end
end

function TDS:Sell(id, wave, min, sec, tc)
    if not TimeWaveWait(wave, min, sec, tc) then return end

    local troop = WaitForTower(id)
    if not troop then return end

    EnsureRemote()

    print(string.format("[Playback] Sell ID:%d Wave:%d", id, wave))

    local ok, result = pcall(function()
        return GameRF:InvokeServer("Troops", "Sell", nil, {Troop = troop})
    end)

    if ok then
        Player.Towers[id] = nil
        print(string.format("[Playback] ✓ Sold ID:%d", id))
    else
        warn("[Playback] ✗ Sell failed ID:" .. id)
    end
end

function TDS:Target(id, priority, wave, min, sec, tc)
    if not TimeWaveWait(wave, min, sec, tc) then return end

    local troop = WaitForTower(id)
    if not troop then return end

    EnsureRemote()

    print(string.format("[Playback] Target ID:%d → %s Wave:%d", id, priority, wave))

    pcall(function()
        GameRF:InvokeServer("Troops", "Target", nil, {Troop = troop, Priority = priority})
    end)
end

-------------------------------------------------
--  ПАРСЕР МАКРО-ФАЙЛА
-------------------------------------------------
local function ParseMacro(content)
    local commands = {}

    for line in content:gmatch("[^\r\n]+") do
        -- Пропускаем комментарии и пустые строки
        local 
