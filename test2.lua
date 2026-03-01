--[[
    TDS: Reanimated — Macro v2.3.0
    Rayfield UI + Запись / Воспроизведение / Авто-продажа ферм
    Fixes:
      1. upgradeGui Clone error — pcall + selectTroop
      2. Place pattern mismatch — tc в кавычках + гибкий парсер
      3. GetWave() — GUI приоритет
      4. continue → правильная структура if/elseif
      5. Rayfield UI
]]

-------------------------------------------------
--  СЕРВИСЫ
-------------------------------------------------
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

-------------------------------------------------
--  RAYFIELD UI
-------------------------------------------------
local Rayfield = loadstring(game:HttpGet(
    "https://sirius.menu/rayfield"
))()

-------------------------------------------------
--  КОНСТАНТЫ
-------------------------------------------------
local VERSION       = "2.3.0"
local MACRO_FOLDER  = "TDS_Macros"
local TIMEOUT_TOWER = 45
local TIMEOUT_WAVE  = 300
local POLL_INTERVAL = 0.15

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
--  ИГРОВЫЕ ССЫЛКИ
-------------------------------------------------
local GameRF       = nil
local RSWave       = nil
local RSTimer      = nil
local TroopsFolder = nil

local function EnsureRemote()
    if GameRF then return GameRF end
    local rf = ReplicatedStorage:WaitForChild("RemoteFunctions", 10)
    if rf then
        GameRF = rf:WaitForChild("Troops", 10)
    end
    if not GameRF then
        warn("[Macro] RemoteFunction 'Troops' не найдена")
    end
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
            if t then
                TroopsFolder = t
                return t
            end
        end
    end
    return nil
end

-------------------------------------------------
--  ПОЛУЧЕНИЕ ВОЛНЫ (GUI → fallback IntValue)
-------------------------------------------------
local function GetWave()
    local result = 0

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

    EnsureState()
    if RSWave then
        local v = RSWave.Value
        if typeof(v) == "number" then return math.floor(v) end
    end

    return result
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

local function GetTimer()
    local wave = GetWave()
    local raw  = GetTimerSeconds()
    local mins = math.floor(raw / 60)
    local secs = raw - mins * 60

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
--  upgradeHandler для синхронизации GUI
-------------------------------------------------
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

-------------------------------------------------
--  ЗАПИСЬ (RECORDER)
-------------------------------------------------
local Recorder = {}
Recorder.Active     = false
Recorder.FileName   = ""
Recorder.TowerCount = 0
Recorder.Towers     = {}
Recorder.Hooked     = false

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

    Recorder.TowerCount = Recorder.TowerCount + 1
    local id = Recorder.TowerCount
    result.Name = tostring(id)

    Recorder.Towers[id] = {
        TowerName = towerName,
        Instance  = result,
    }

    SyncGUI(result)

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
    Place        = Gen.Place,
    Upgrade      = Gen.Upgrade,
    Sell         = Gen.Sell,
    Target       = Gen.Target,
    SetTarget    = Gen.Target,
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

    if not self.Hooked then
        self.Hooked = true

        local oldHook
        oldHook = hookmetamethod(game, "__namecall", newcclosure(function(self2, ...)
            local method = getnamecallmethod()

            if method ~= "InvokeServer" then
                return oldHook(self2, ...)
            end

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

            local thread = coroutine.running()
            coroutine.wrap(function(a)
                local timer  = GetTimer()
                local result = oldHook(self2, table.unpack(a))

                pcall(function()
                    handler(a, timer, result)
                end)

                coroutine.resume(thread, result)
            end)({...})

            return coroutine.yield()
        end))
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
--  ВОСПРОИЗВЕДЕНИЕ (PLAYBACK)
-------------------------------------------------
local Playback = {}
Playback.Active     = false
Playback.Paused     = false
Playback.Towers     = {}
Playback.TowerCount = 0

local function WaitForWave(targetWave)
    local t0 = tick()
    while Playback.Active do
        local cur = GetWave()
        if cur >= targetWave then return true end
        if tick() - t0 > TIMEOUT_WAVE then
            warn("[Playback] Таймаут ожидания волны " .. targetWave .. " (текущая " .. cur .. ")")
            return false
        end
        while Playback.Paused and Playback.Active do
            task.wait(0.25)
        end
        task.wait(POLL_INTERVAL)
    end
    return false
end

local function TimeWaveWait(wave, min, sec, tc)
    if not WaitForWave(wave) then return false end
    return true
end

local function WaitForTower(id)
    if Playback.Towers[id] then return Playback.Towers[id] end
    local t0 = tick()
    while Playback.Active do
        if Playback.Towers[id] then return Playback.Towers[id] end
        if tick() - t0 > TIMEOUT_TOWER then
            warn("[Playback] Башня ID:" .. id .. " не найдена за " .. TIMEOUT_TOWER .. " секунд")
            return nil
        end
        task.wait(POLL_INTERVAL)
    end
    return nil
end

local TDS = {}

function TDS.Place(towerName, x, y, z, wave, min, sec, tc, rx, ry, rz)
    rx = rx or 0
    ry = ry or 0
    rz = rz or 0

    if not TimeWaveWait(wave, min, sec, tc) then return end

    EnsureRemote()
    if not GameRF then
        warn("[Playback] GameRF недоступен")
        return
    end

    local cf = CFrame.new(x, y, z) * CFrame.fromEulerAnglesYXZ(rx, ry, rz)

    print(string.format("[Playback] Place %-14s at (%.1f, %.1f, %.1f) Wave:%d", towerName, x, y, z, wave))

    local ok, result = pcall(function()
        return GameRF:InvokeServer("Troops", "Place", towerName, cf)
    end)

    if ok and typeof(result) == "Instance" then
        Playback.TowerCount = Playback.TowerCount + 1
        local id = Playback.TowerCount
        result.Name = tostring(id)
        Playback.Towers[id] = result
        print(string.format("[Playback] ✓ Placed ID:%d", id))
        SyncGUI(result)
    else
        warn("[Playback] ✗ Place failed: " .. tostring(result))
    end
end

function TDS.Upgrade(id, wave, min, sec, tc)
    if not TimeWaveWait(wave, min, sec, tc) then return end

    local troop = WaitForTower(id)
    if not troop then return end

    EnsureRemote()
    if not GameRF then return end

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

function TDS.Sell(id, wave, min, sec, tc)
    if not TimeWaveWait(wave, min, sec, tc) then return end

    local troop = WaitForTower(id)
    if not troop then return end

    EnsureRemote()
    if not GameRF then return end

    print(string.format("[Playback] Sell ID:%d Wave:%d", id, wave))

    local ok, result = pcall(function()
        return GameRF:InvokeServer("Troops", "Sell", nil, {Troop = troop})
    end)

    if ok then
        Playback.Towers[id] = nil
        print(string.format("[Playback] ✓ Sold ID:%d", id))
    else
        warn("[Playback] ✗ Sell failed ID:" .. id)
    end
end

function TDS.Target(id, priority, wave, min, sec, tc)
    if not TimeWaveWait(wave, min, sec, tc) then return end

    local troop = WaitForTower(id)
    if not troop then return end

    EnsureRemote()
    if not GameRF then return end

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
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed == "" or trimmed:sub(1, 2) == "--" then
            -- пропуск комментариев и пустых строк

        elseif trimmed:find("TDS:Place") then
            local nm, x, y, z, wv, mn, sc, tc, rx, ry, rz = trimmed:match(
                'TDS:Place%("([^"]+)",%s*' ..
                '([-%.%deE]+),%s*([-%.%deE]+),%s*([-%.%deE]+),%s*' ..
                '(%d+),%s*(%d+),%s*([-%.%deE]+),%s*"?([^",%)]+)"?,%s*' ..
                '([-%.%deE]+),%s*([-%.%deE]+),%s*([-%.%deE]+)%)'
            )
            if nm then
                table.insert(commands, {
                    type = "Place",
                    args = {
                        nm,
                        tonumber(x), tonumber(y), tonumber(z),
                        tonumber(wv), tonumber(mn), tonumber(sc), tc,
                        tonumber(rx), tonumber(ry), tonumber(rz)
                    },
                    wave  = tonumber(wv),
                    order = #commands + 1,
                })
            else
                warn("[Parser] Place не распознан: " .. trimmed)
            end

        elseif trimmed:find("TDS:Upgrade") then
            local uid, uwv, umn, usc, utc = trimmed:match(
                'TDS:Upgrade%((%d+),%s*(%d+),%s*(%d+),%s*([-%.%deE]+),%s*"?([^",%)]+)"?%)'
            )
            if uid then
                table.insert(commands, {
                    type = "Upgrade",
                    args = {tonumber(uid), tonumber(uwv), tonumber(umn), tonumber(usc), utc},
                    wave  = tonumber(uwv),
                    order = #commands + 1,
                })
            else
                warn("[Parser] Upgrade не распознан: " .. trimmed)
            end

        elseif trimmed:find("TDS:Sell") then
            local sid, swv, smn, ssc, stc = trimmed:match(
                'TDS:Sell%((%d+),%s*(%d+),%s*(%d+),%s*([-%.%deE]+),%s*"?([^",%)]+)"?%)'
            )
            if sid then
                table.insert(commands, {
                    type = "Sell",
                    args = {tonumber(sid), tonumber(swv), tonumber(smn), tonumber(ssc), stc},
                    wave  = tonumber(swv),
                    order = #commands + 1,
                })
            else
                warn("[Parser] Sell не распознан: " .. trimmed)
            end

        elseif trimmed:find("TDS:Target") then
            local tid, tpr, twv, tmn, tsc, ttc = trimmed:match(
                'TDS:Target%((%d+),%s*"([^"]*)",%s*(%d+),%s*(%d+),%s*([-%.%deE]+),%s*"?([^",%)]+)"?%)'
            )
            if tid then
                table.insert(commands, {
                    type = "Target",
                    args = {tonumber(tid), tpr, tonumber(twv), tonumber(tmn), tonumber(tsc), ttc},
                    wave  = tonumber(twv),
                    order = #commands + 1,
                })
            else
                warn("[Parser] Target не распознан: " .. trimmed)
            end

        else
            warn("[Parser] Нераспознанная строка: " .. trimmed)
        end
    end

    print("[Parser] Команд распознано: " .. #commands)
    return commands
end

-------------------------------------------------
--  ЗАПУСК ВОСПРОИЗВЕДЕНИЯ
-------------------------------------------------
function Playback:Start(fileName)
    if self.Active then
        warn("[Playback] Уже воспроизводится!")
        return false
    end

    if not FileExists(fileName) then
        warn("[Playback] Файл не найден: " .. fileName)
        return false
    end

    local content  = FileRead(fileName)
    local commands = ParseMacro(content)

    if #commands == 0 then
        warn("[Playback] Нет команд в файле!")
        return false
    end

    self.Active     = true
    self.Paused     = false
    self.Towers     = {}
    self.TowerCount = 0

    print("[Playback] ▶ Старт: " .. fileName .. " (" .. #commands .. " команд)")

    task.spawn(function()
        for i, cmd in ipairs(commands) do
            if not self.Active then
                print("[Playback] ■ Остановлено на команде " .. i)
                break
            end

            while self.Paused and self.Active do
                task.wait(0.25)
            end

            local fn = TDS[cmd.type]
            if fn then
                local ok, err = pcall(function()
                    fn(table.unpack(cmd.args))
                end)
                if not ok then
                    warn("[Playback] Ошибка команда " .. i .. " (" .. cmd.type .. "): " .. tostring(err))
                end
            else
                warn("[Playback] Неизвестный тип: " .. cmd.type)
            end

            task.wait(0.1)
        end

        self.Active = false
        print("[Playback] ✓ Воспроизведение завершено")
    end)

    return true
end

function Playback:Stop()
    self.Active = false
    self.Paused = false
    print("[Playback] ■ Остановка")
end

function Playback:TogglePause()
    self.Paused = not self.Paused
    print("[Playback] " .. (self.Paused and "⏸ Пауза" or "▶ Продолжение"))
    return self.Paused
end

-------------------------------------------------
--  АВТО-ПРОДАЖА ФЕРМ
-------------------------------------------------
local AutoSellFarm = {}
AutoSellFarm.Active = false

function AutoSellFarm:Start()
    if self.Active then return end
    self.Active = true

    task.spawn(function()
        EnsureRemote()

        while self.Active do
            pcall(function()
                local troops = FindTroopsFolder()
                if not troops then return end

                for _, troop in ipairs(troops:GetChildren()) do
                    if not self.Active then break end

                    local owner = troop:FindFirstChild("Owner")
                    if not owner then
                        -- skip
                    else
                        local ownerVal = owner.Value
                        local isOurs = false

                        if typeof(ownerVal) == "Instance" and ownerVal == LocalPlayer then
                            isOurs = true
                        elseif typeof(ownerVal) == "string" and ownerVal == LocalPlayer.Name then
                            isOurs = true
                        elseif typeof(ownerVal) == "number" and ownerVal == LocalPlayer.UserId then
                            isOurs = true
                        end

                        if isOurs then
                            local towerName = troop.Name:lower()
                            local isFarm = towerName:find("farm") ~= nil

                            local config = troop:FindFirstChild("Config")
                                        or troop:FindFirstChild("Configuration")
                            if config then
                                local tType = config:FindFirstChild("Type")
                                          or config:FindFirstChild("TowerType")
                                if tType and tostring(tType.Value):lower():find("farm") then
                                    isFarm = true
                                end
                            end

                            if isFarm then
                                local level    = troop:FindFirstChild("Level")
                                local maxLevel = troop:FindFirstChild("MaxLevel")
                                if level and maxLevel and level.Value >= maxLevel.Value then
                                    pcall(function()
                                        GameRF:InvokeServer("Troops", "Sell", nil, {Troop = troop})
                                    end)
                                    print("[AutoSell] Продана ферма: " .. troop.Name)
                                end
                            end
                        end
                    end
                end
            end)

            task.wait(2)
        end
    end)

    print("[AutoSell] ▶ Включена")
end

function AutoSellFarm:Stop()
    self.Active = false
    print("[AutoSell] ■ Выключена")
end

-------------------------------------------------
--  RAYFIELD ИНТЕРФЕЙС
-------------------------------------------------
local Window = Rayfield:CreateWindow({
    Name            = "TDS Macro v" .. VERSION,
    LoadingTitle    = "TDS: Reanimated Macro",
    LoadingSubtitle = "by You | v" .. VERSION,
    ConfigurationSaving = {
        Enabled  = false,
        FileName = "TDSMacroConfig",
    },
    KeySystem    = false,
})

-- ===================== ВКЛАДКА: ЗАПИСЬ =====================
local TabRecord = Window:CreateTab("🔴 Запись", "circle")

local RecFileNameInput = ""

TabRecord:CreateInput({
    Name            = "Имя файла",
    PlaceholderText = "Введите имя макроса...",
    RemoveTextAfterFocusLost = false,
    Callback = function(text)
        RecFileNameInput = text
    end,
})

local RecStatusLabel = TabRecord:CreateLabel("Статус: Ожидание")

TabRecord:CreateButton({
    Name     = "▶ Начать запись",
    Callback = function()
        local name = RecFileNameInput
        if name == "" then
            RecStatusLabel:Set("❌ Введите имя файла!")
            return
        end
        if not name:match("%.lua$") and not name:match("%.txt$") then
            name = name .. ".lua"
        end
        if Recorder:Start(name) then
            RecStatusLabel:Set("🔴 Запись: " .. name)
        else
            RecStatusLabel:Set("❌ Не удалось начать запись")
        end
    end,
})

TabRecord:CreateButton({
    Name     = "⬛ Остановить запись",
    Callback = function()
        Recorder:Stop()
        RecStatusLabel:Set("⬛ Запись остановлена | Башен: " .. Recorder.TowerCount)
    end,
})

-- ===================== ВКЛАДКА: ВОСПРОИЗВЕДЕНИЕ =====================
local TabPlay = Window:CreateTab("▶ Воспроизведение", "play")

local PlayFileNameInput = ""

TabPlay:CreateInput({
    Name            = "Имя файла",
    PlaceholderText = "Введите имя макроса...",
    RemoveTextAfterFocusLost = false,
    Callback = function(text)
        PlayFileNameInput = text
    end,
})

local PlayStatusLabel = TabPlay:CreateLabel("Статус: Ожидание")

-- Выпадающий список файлов
local fileListForDropdown = FileList()
if #fileListForDropdown == 0 then
    fileListForDropdown = {"Нет файлов"}
end

local FileDropdown = TabPlay:CreateDropdown({
    Name    = "Выбрать макрос",
    Options = fileListForDropdown,
    CurrentOption = {},
    MultipleOptions = false,
    Callback = function(options)
        if options and options[1] and options[1] ~= "Нет файлов" then
            PlayFileNameInput = options[1]
            PlayStatusLabel:Set("Выбран: " .. options[1])
        end
    end,
})

TabPlay:CreateButton({
    Name     = "🔄 Обновить список файлов",
    Callback = function()
        local newList = FileList()
        if #newList == 0 then
            newList = {"Нет файлов"}
        end
        FileDropdown:Set(newList)
        PlayStatusLabel:Set("Список обновлён (" .. #newList .. " файлов)")
    end,
})

TabPlay:CreateButton({
    Name     = "▶ Воспроизвести",
    Callback = function()
        local name = PlayFileNameInput
        if name == "" or name == "Нет файлов" then
            PlayStatusLabel:Set("❌ Выберите или введите имя файла!")
            return
        end
        if Playback:Start(name) then
            PlayStatusLabel:Set("▶ Воспроизведение: " .. name)
        else
            PlayStatusLabel:Set("❌ Не удалось начать воспроизведение")
        end
    end,
})

TabPlay:CreateButton({
    Name     = "⏸ Пауза / Продолжить",
    Callback = function()
        local paused = Playback:TogglePause()
        PlayStatusLabel:Set(paused and "⏸ Пауза" or "▶ Продолжение воспроизведения")
    end,
})

TabPlay:CreateButton({
    Name     = "⬛ Остановить",
    Callback = function()
        Playback:Stop()
        PlayStatusLabel:Set("⬛ Воспроизведение остановлено")
    end,
})

-- ===================== ВКЛАДКА: АВТО-ФУНКЦИИ =====================
local TabAuto = Window:CreateTab("🔧 Авто-функции", "settings")

local AutoSellLabel = TabAuto:CreateLabel("Авто-продажа ферм: ВЫКЛ")

TabAuto:CreateToggle({
    Name          = "Авто-продажа ферм (макс. уровень)",
    CurrentValue  = false,
    Flag          = "AutoSellFarmToggle",
    Callback = function(value)
        if value then
            AutoSellFarm:Start()
            AutoSellLabel:Set("Авто-продажа ферм: ВКЛ ✅")
        else
            AutoSellFarm:Stop()
            AutoSellLabel:Set("Авто-продажа ферм: ВЫКЛ ❌")
        end
    end,
})

-- ===================== ВКЛАДКА: ИНФОРМАЦИЯ =====================
local TabInfo = Window:CreateTab("ℹ Инфо", "info")

TabInfo:CreateLabel("TDS: Reanimated Macro v" .. VERSION)
TabInfo:CreateLabel("Папка макросов: " .. MACRO_FOLDER)

TabInfo:CreateParagraph({
    Title   = "Как использовать",
    Content = "1. Зайдите в лобби и выберите карту\n" ..
              "2. Откройте вкладку 'Запись' и начните запись\n" ..
              "3. Играйте — ставьте/прокачивайте/продавайте башни\n" ..
              "4. Остановите запись\n" ..
              "5. В следующей игре откройте 'Воспроизведение'\n" ..
              "6. Выберите файл и нажмите 'Воспроизвести'\n\n" ..
              "Горячие клавиши:\n" ..
              "F9 — показать/скрыть интерфейс",
})

TabInfo:CreateButton({
    Name     = "📂 Показать файлы в консоли",
    Callback = function()
        local files = FileList()
        print("=== Макро-файлы ===")
        for i, f in ipairs(files) do
            print(i .. ". " .. f)
        end
        print("===================")
    end,
})

-------------------------------------------------
--  ГОТОВО
-------------------------------------------------
print(string.format("[TDS Macro v%s] ✓ Загружен успешно", VERSION))
