--[[
    AutoChain v4.0 — TDS: Reanimated
    Защита от вылетов при инжекте
]]

-- ═══════════════════════════════════════════════════════════════
-- ГЛОБАЛЬНЫЙ ОБРАБОТЧИК ОШИБОК
-- Перехватывает ВСЕ ошибки и выводит их через warn()
-- warn() виден даже если F9-консоль не открыта
-- ═══════════════════════════════════════════════════════════════

local function SafeInit()

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 1: СЕРВИСЫ
-- Каждый GetService обёрнут отдельно — чтобы понять КАКОЙ именно упал
-- ═══════════════════════════════════════════════════════════════

local Players, ReplicatedStorage, Workspace

do
    local ok, err

    ok, Players = pcall(game.GetService, game, "Players")
    if not ok then error("GetService Players: " .. tostring(Players)) end

    ok, ReplicatedStorage = pcall(game.GetService, game, "ReplicatedStorage")
    if not ok then error("GetService ReplicatedStorage: " .. tostring(ReplicatedStorage)) end

    ok, Workspace = pcall(game.GetService, game, "Workspace")
    if not ok then error("GetService Workspace: " .. tostring(Workspace)) end
end

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    error("LocalPlayer не найден — инжектируй после загрузки игры")
end

warn("[AutoChain] Сервисы: OK")

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 2: РЕМОУТЫ И ПАПКА БАШЕН
-- WaitForChild с таймаутом — не висим вечно если объект не существует
-- ═══════════════════════════════════════════════════════════════

local WAIT_TIMEOUT = 10  -- секунд максимум ждём каждый объект

local RemoteFunction = ReplicatedStorage:WaitForChild("RemoteFunction", WAIT_TIMEOUT)
if not RemoteFunction then
    error("RemoteFunction не найден в ReplicatedStorage за " .. WAIT_TIMEOUT .. "с")
end

local TowersFolder = Workspace:WaitForChild("Towers", WAIT_TIMEOUT)
if not TowersFolder then
    error("Workspace.Towers не найден за " .. WAIT_TIMEOUT .. "с — ты в лобби или карта не загружена?")
end

warn("[AutoChain] Ремоуты и Towers: OK")

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 3: КОНСТАНТЫ
-- ═══════════════════════════════════════════════════════════════

local BUFF_DURATION    = 10.0
local ABILITY_COOLDOWN = 1.0   -- В Reanimated КД = 34с
local ABILITY_NAME     = "Call Of Arms"
local COMMANDER_TYPE   = "Commander"
local ACTIVATION_LEAD  = 0.0

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 4: СОСТОЯНИЕ
-- ═══════════════════════════════════════════════════════════════

local State = {
    Enabled         = false,
    Commanders      = {},
    QueueIndex      = 1,
    ActivationCount = 0,
    ScheduledThread = nil,
}

local debugMode = false

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 5: ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ═══════════════════════════════════════════════════════════════

local function IsOwned(model)
    local ok, result = pcall(function()
        local o = model:FindFirstChild("Owner")
        return o and o.Value == LocalPlayer
    end)
    return ok and result
end

local function GetType(model)
    local ok, result = pcall(function()
        local t = model:FindFirstChild("Type")
        return t and t:IsA("StringValue") and t.Value or ""
    end)
    return ok and result or ""
end

local function GetLevel(model)
    local ok, result = pcall(function()
        local u = model:FindFirstChild("Upgrade")
        return u and u:IsA("IntValue") and u.Value or 0
    end)
    return ok and result or 0
end

local function DbgLog(msg)
    if debugMode then warn("[AutoChain][DBG] " .. tostring(msg)) end
end

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 6: СКАНИРОВАНИЕ
-- ═══════════════════════════════════════════════════════════════

local function ScanCommanders()
    local found = {}

    local ok, err = pcall(function()
        for _, model in ipairs(TowersFolder:GetChildren()) do
            if model:IsA("Model")
            and IsOwned(model)
            and GetType(model) == COMMANDER_TYPE
            then
                table.insert(found, {
                    model   = model,
                    name    = model.Name,
                    level   = GetLevel(model),
                    readyAt = 0,
                })
            end
        end
    end)

    if not ok then
        warn("[AutoChain][ERROR] Сканирование упало: " .. tostring(err))
    end

    table.sort(found, function(a, b) return a.level > b.level end)

    warn(string.format("[AutoChain] Найдено командиров: %d", #found))
    for i, cmd in ipairs(found) do
        warn(string.format("  [%d] %s (ур.%d)", i, cmd.name, cmd.level))
    end

    return found
end

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 7: АКТИВАЦИЯ
-- ═══════════════════════════════════════════════════════════════

local function Activate(cmd)
    if not cmd.model or not cmd.model.Parent then
        warn("[AutoChain][WARN] Командир '" .. cmd.name .. "' удалён с карты")
        return false
    end

    local ok, result = pcall(
        RemoteFunction.InvokeServer,
        RemoteFunction,
        "Troops", "Abilities", "Activate",
        { Name = ABILITY_NAME, Troop = cmd.model }
    )

    if ok then
        cmd.readyAt = os.clock() + ABILITY_COOLDOWN
        State.ActivationCount += 1
        DbgLog(string.format("✓ %s | Активаций: %d", cmd.name, State.ActivationCount))
        return true
    else
        warn("[AutoChain][ERROR] Активация '" .. cmd.name .. "': " .. tostring(result))
        return false
    end
end

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 8: ЦЕПОЧКА
-- ═══════════════════════════════════════════════════════════════

local function ScheduleNext()
    if not State.Enabled then return end
    if #State.Commanders == 0 then return end

    -- Убираем удалённые башни
    for i = #State.Commanders, 1, -1 do
        if not State.Commanders[i].model.Parent then
            warn("[AutoChain] Башня удалена: " .. State.Commanders[i].name)
            table.remove(State.Commanders, i)
        end
    end

    if #State.Commanders == 0 then
        warn("[AutoChain] ⚠ Все командиры удалены. Остановка.")
        State.Enabled = false
        return
    end

    if State.QueueIndex > #State.Commanders then
        State.QueueIndex = 1
    end

    local cmd = State.Commanders[State.QueueIndex]
    local waitTime = math.max(0, cmd.readyAt - os.clock())

    DbgLog(string.format("Следующий: %s через %.2fс", cmd.name, waitTime))

    State.ScheduledThread = task.delay(waitTime, function()
        if not State.Enabled then return end

        -- Весь шаг цепочки в pcall — если что-то упало, цепочка не умирает
        local ok, err = pcall(function()
            local activated = Activate(cmd)

            if activated then
                State.QueueIndex = (State.QueueIndex % #State.Commanders) + 1
                local nextCmd = State.Commanders[State.QueueIndex]

                if nextCmd.readyAt == 0 then
                    nextCmd.readyAt = os.clock() + (BUFF_DURATION - ACTIVATION_LEAD)
                else
                    local minNext = os.clock() + (BUFF_DURATION - ACTIVATION_LEAD)
                    nextCmd.readyAt = math.max(nextCmd.readyAt, minNext)
                end

                ScheduleNext()
            else
                -- Активация не прошла (стан / кулдаун) — повтор через 1с
                task.wait(1)
                ScheduleNext()
            end
        end)

        if not ok then
            warn("[AutoChain][ERROR] Шаг цепочки упал: " .. tostring(err))
            -- Пробуем восстановиться через 2с
            task.wait(2)
            ScheduleNext()
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 9: УПРАВЛЕНИЕ
-- ═══════════════════════════════════════════════════════════════

local function StartChain()
    if State.Enabled then return false end

    State.Commanders = ScanCommanders()

    if #State.Commanders == 0 then
        warn("[AutoChain] ⚠ Командиры не найдены!")
        return false
    end

    State.Enabled         = true
    State.QueueIndex      = 1
    State.ActivationCount = 0

    for _, cmd in ipairs(State.Commanders) do
        cmd.readyAt = 0
    end

    warn("[AutoChain] ▶ Цепочка запущена")
    ScheduleNext()
    return true
end

local function StopChain()
    if not State.Enabled then return end
    State.Enabled = false
    if State.ScheduledThread then
        task.cancel(State.ScheduledThread)
        State.ScheduledThread = nil
    end
    warn(string.format("[AutoChain] ⏹ Остановлена. Активаций: %d", State.ActivationCount))
end

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 10: RAYFIELD
-- Загрузка в отдельном pcall — если Rayfield упал, скрипт не умирает
-- ═══════════════════════════════════════════════════════════════

local Rayfield
do
    local ok, result = pcall(function()
        return loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
    end)

    if not ok then
        warn("[AutoChain][ERROR] Rayfield не загрузился: " .. tostring(result))
        warn("[AutoChain] Работаю без UI — используй StartChain() / StopChain() вручную")
        -- Скрипт продолжает работать даже без UI
    else
        Rayfield = result
        warn("[AutoChain] Rayfield: OK")
    end
end

if Rayfield then
    local ok, err = pcall(function()

        local Window = Rayfield:CreateWindow({
            Name            = "AutoChain — TDS: Reanimated",
            LoadingTitle    = "AutoChain v4.0",
            LoadingSubtitle = "Commander Chain",
            ConfigurationSaving = { Enabled = true, FileName = "AutoChain_v4" },
            KeySystem = false,
        })

        local Main = Window:CreateTab("⚔️ AutoChain", nil)

        Main:CreateSection("Управление")

        Main:CreateToggle({
            Name         = "🔗 Commander Chain",
            CurrentValue = false,
            Flag         = "ChainToggle",
            Callback     = function(on)
                if on then
                    local started = StartChain()
                    Rayfield:Notify({
                        Title   = "AutoChain",
                        Content = started
                            and string.format("▶ Запущен! Командиров: %d", #State.Commanders)
                            or  "⚠ Командиры не найдены",
                        Duration = 4,
                        Image   = "rbxassetid://4483345998"
                    })
                else
                    StopChain()
                    Rayfield:Notify({
                        Title    = "AutoChain",
                        Content  = string.format("⏹ Активаций: %d", State.ActivationCount),
                        Duration = 3,
                        Image    = "rbxassetid://4483345998"
                    })
                end
            end,
        })

        Main:CreateButton({
            Name = "🔄 Пересканировать командиров",
            Callback = function()
                local was = State.Enabled
                if was then StopChain() end
                State.Commanders = ScanCommanders()
                Rayfield:Notify({
                    Title    = "Сканирование",
                    Content  = string.format("Найдено: %d (детали в консоли)", #State.Commanders),
                    Duration = 4,
                    Image    = "rbxassetid://4483345998"
                })
                if was and #State.Commanders > 0 then StartChain() end
            end,
        })

        Main:CreateSection("Настройки тайминга")

        Main:CreateSlider({
            Name = "Длительность баффа (сек)",
            Range = {5, 15}, Increment = 0.5, Suffix = "с",
            CurrentValue = BUFF_DURATION, Flag = "BuffDur",
            Callback = function(v) BUFF_DURATION = v end,
        })

        Main:CreateSlider({
            Name = "Упреждение активации (сек)",
            Range = {0.0, 2.0}, Increment = 0.1, Suffix = "с",
            CurrentValue = ACTIVATION_LEAD, Flag = "LeadTime",
            Callback = function(v) ACTIVATION_LEAD = v end,
        })

        Main:CreateSlider({
            Name = "Кулдаун командира (сек)",
            Range = {1, 45}, Increment = 1, Suffix = "с",
            CurrentValue = ABILITY_COOLDOWN, Flag = "AbilityCD",
            Callback = function(v) ABILITY_COOLDOWN = v end,
        })

        local Debug = Window:CreateTab("🔧 Отладка", nil)

        Debug:CreateToggle({
            Name = "Подробный лог (warn)",
            CurrentValue = false, Flag = "DebugLog",
            Callback = function(v) debugMode = v end,
        })

        Debug:CreateButton({
            Name = "📋 Статус → консоль",
            Callback = function()
                local now = os.clock()
                warn("[AutoChain] ══════ Статус ══════")
                warn(string.format("  %s | Активаций: %d",
                    State.Enabled and "▶ АКТИВНА" or "⏹ СТОП",
                    State.ActivationCount))
                for i, cmd in ipairs(State.Commanders) do
                    warn(string.format("  [%d]%s %s (ур.%d) | КД: %.1fс",
                        i, i == State.QueueIndex and "►" or " ",
                        cmd.name, cmd.level,
                        math.max(0, cmd.readyAt - now)))
                end
                warn("[AutoChain] ═══════════════════")
                Rayfield:Notify({ Title="Статус", Content="Напечатано в консоли", Duration=3, Image="rbxassetid://4483345998" })
            end,
        })

        Debug:CreateButton({
            Name = "⚡ Разовая активация (тест)",
            Callback = function()
                local cmds = ScanCommanders()
                local count = 0
                for _, cmd in ipairs(cmds) do
                    if Activate(cmd) then count += 1 end
                    task.wait(0.3)
                end
                Rayfield:Notify({
                    Title   = "Тест",
                    Content = string.format("Активировано: %d / %d", count, #cmds),
                    Duration = 4,
                    Image   = "rbxassetid://4483345998"
                })
            end,
        })

        local Help = Window:CreateTab("❓ Помощь", nil)
        Help:CreateSection("Быстрый старт")
        Help:CreateLabel("1. Разместить 3 Командира (уровень 2+)")
        Help:CreateLabel("2. Нажать '🔄 Пересканировать командиров'")
        Help:CreateLabel("3. Включить '🔗 Commander Chain'")
        Help:CreateSection("Если вылетает при инжекте")
        Help:CreateLabel("→ Инжектируй только после полной загрузки карты")
        Help:CreateLabel("→ Ошибки видны через warn() в Output (не F9)")
        Help:CreateSection("Если есть разрывы в баффе")
        Help:CreateLabel("→ Увеличь 'Упреждение активации' до 1.0–1.5с")

    end)

    if not ok then
        warn("[AutoChain][ERROR] UI упал при создании: " .. tostring(err))
        warn("[AutoChain] Используй StartChain() / StopChain() вручную через консоль")
    end
end

-- Очистка при выходе
Players.PlayerRemoving:Connect(function(p)
    if p == LocalPlayer then
        pcall(StopChain)
    end
end)

warn("[AutoChain] v4.0 — полностью загружен")

-- Конец SafeInit
end

-- ═══════════════════════════════════════════════════════════════
-- ТОЧКА ВХОДА — весь скрипт в одном pcall
-- ═══════════════════════════════════════════════════════════════

local ok, err = pcall(SafeInit)
if not ok then
    warn("╔══════════════════════════════════════╗")
    warn("║     AutoChain — КРИТИЧЕСКАЯ ОШИБКА   ║")
    warn("╠══════════════════════════════════════╣")
    warn("║ " .. tostring(err))
    warn("╠══════════════════════════════════════╣")
    warn("║ Возможные причины:                   ║")
    warn("║ • Инжект в лобби (нет Towers)        ║")
    warn("║ • Игра ещё не загрузилась            ║")
    warn("║ • Нет интернета (Rayfield/HttpGet)   ║")
    warn("║ • Экзекутор не поддерживает HttpGet  ║")
    warn("╚══════════════════════════════════════╝")
end
