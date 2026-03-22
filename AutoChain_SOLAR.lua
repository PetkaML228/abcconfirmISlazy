--[[
    Commander AutoChain — TDS: S.O.L.A.R
    Версия: 1.1.0 | UI: Rayfield

    МЕХАНИКА ЦЕПОЧКИ:
    • Кулдаун: 50с | Бафф: 10с | Нужно: 5 командиров
    T=0с  → A | T=10с → B | T=20с → C | T=30с → D | T=40с → E
    T=50с → A (кулдаун закончился — цикл замкнулся)

    ОПТИМИЗАЦИЯ v1.1:
    • Убраны task.wait() внутри task.delay колбэков
    • Повторные попытки через новый task.delay (не блокируют поток)
    • Нет накопления зависших потоков при отклонении сервером
]]

local function SafeInit()

-- ═══════════════════════════════════════════════════════════════
-- СЕРВИСЫ
-- ═══════════════════════════════════════════════════════════════

local Players, ReplicatedStorage, Workspace
do
    local ok
    ok, Players           = pcall(game.GetService, game, "Players")
    if not ok then error("Players: " .. tostring(Players)) end
    ok, ReplicatedStorage = pcall(game.GetService, game, "ReplicatedStorage")
    if not ok then error("ReplicatedStorage: " .. tostring(ReplicatedStorage)) end
    ok, Workspace         = pcall(game.GetService, game, "Workspace")
    if not ok then error("Workspace: " .. tostring(Workspace)) end
end

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then error("LocalPlayer не найден") end

-- RemoteFunction — пробуем игровой путь, затем лобби-путь
local RemoteFunction
do
    local Resources = ReplicatedStorage:WaitForChild("Resources", 10)
    if not Resources then error("Resources не найден") end

    local Universal = Resources:FindFirstChild("Universal")
    if Universal then
        local Network = Universal:FindFirstChild("Network")
        if Network then
            RemoteFunction = Network:FindFirstChild("RemoteFunction")
            if RemoteFunction then
                warn("[AutoChain] RF: Resources.Universal.Network")
            end
        end
    end

    if not RemoteFunction then
        local Network = Resources:FindFirstChild("Network")
        if Network then
            RemoteFunction = Network:FindFirstChild("RemoteFunction")
            if RemoteFunction then
                warn("[AutoChain] RF: Resources.Network")
            end
        end
    end

    if not RemoteFunction then error("RemoteFunction не найден") end
end

local TowersFolder = Workspace:WaitForChild("Towers", 10)
if not TowersFolder then error("workspace.Towers не найдена") end

warn("[AutoChain] Инициализация: OK")

-- ═══════════════════════════════════════════════════════════════
-- КОНСТАНТЫ
-- ═══════════════════════════════════════════════════════════════

local ABILITY_NAME     = "Call Of Arms"
local COMMANDER_TYPE   = "Commander"
local BUFF_DURATION    = 10.0
local ABILITY_COOLDOWN = 50.0
local ACTIVATION_LEAD  = 0.0

-- ═══════════════════════════════════════════════════════════════
-- СОСТОЯНИЕ
-- ═══════════════════════════════════════════════════════════════

local State = {
    Enabled         = false,
    Commanders      = {},
    QueueIndex      = 1,
    ActivationCount = 0,
    ScheduledThread = nil,
    LastChainTime   = 0,
    RetryCount      = 0,   -- счётчик подряд идущих неудачных попыток
}

local MAX_RETRIES = 5      -- максимум повторов прежде чем пропустить командира
local debugMode   = false

-- ═══════════════════════════════════════════════════════════════
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ═══════════════════════════════════════════════════════════════

-- Все данные башни в S.O.L.A.R хранятся в атрибутах Replicator
local function GetReplicator(model)
    return model:FindFirstChild("Replicator")
end

local function IsOwned(model)
    local ok, result = pcall(function()
        local rep = GetReplicator(model)
        if not rep then return false end
        local ownerId = rep:GetAttribute("OwnerId")
        if ownerId then return ownerId == LocalPlayer.UserId end
        return rep:GetAttribute("Owner") == LocalPlayer.Name
    end)
    return ok and result
end

local function GetType(model)
    local ok, result = pcall(function()
        local rep = GetReplicator(model)
        if not rep then return "" end
        return rep:GetAttribute("Type") or ""
    end)
    return ok and result or ""
end

local function GetLevel(model)
    local ok, result = pcall(function()
        local rep = GetReplicator(model)
        if not rep then return 0 end
        return rep:GetAttribute("Upgrade") or 0
    end)
    return ok and result or 0
end

local function DbgLog(msg)
    if debugMode then warn("[AutoChain][DBG] " .. tostring(msg)) end
end

-- ═══════════════════════════════════════════════════════════════
-- СКАНИРОВАНИЕ
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
                    model         = model,
                    name          = model.Name,
                    level         = GetLevel(model),
                    cooldownUntil = 0,
                })
            end
        end
    end)
    if not ok then warn("[AutoChain][ERROR] Сканирование: " .. tostring(err)) end

    table.sort(found, function(a, b) return a.level > b.level end)

    warn(string.format("[AutoChain] Командиров: %d", #found))
    for i, cmd in ipairs(found) do
        warn(string.format("  [%d] %s (ур.%d)", i, cmd.name, cmd.level))
    end
    if #found > 0 and #found < 5 then
        warn(string.format("[AutoChain][WARN] %d/5 командиров — разрыв %.0fс",
            #found, ABILITY_COOLDOWN - (#found * BUFF_DURATION)))
    end
    return found
end

-- ═══════════════════════════════════════════════════════════════
-- АКТИВАЦИЯ
-- ═══════════════════════════════════════════════════════════════

local function Activate(cmd)
    if not cmd.model or not cmd.model.Parent then
        warn("[AutoChain][WARN] '" .. cmd.name .. "' удалён")
        return false
    end

    local ok, result = pcall(function()
        return RemoteFunction:InvokeServer(
            "Troops", "Abilities", "Activate",
            { Name = ABILITY_NAME, Troop = cmd.model }
        )
    end)

    DbgLog(string.format("'%s': ok=%s result=%s",
        cmd.name, tostring(ok), tostring(result)))

    if not ok then
        warn("[AutoChain][ERROR] Вызов: " .. tostring(result))
        return false
    end
    if result == false then
        DbgLog("Отклонено: " .. cmd.name)
        return false
    end
    if type(result) == "string"
    and (result:lower():find("cooldown") or result:lower():find("error")) then
        DbgLog("Ошибка сервера: " .. result)
        return false
    end

    cmd.cooldownUntil = os.clock() + ABILITY_COOLDOWN
    State.ActivationCount += 1
    State.RetryCount = 0
    warn(string.format("[AutoChain] ✓ %s (всего: %d)", cmd.name, State.ActivationCount))
    return true
end

-- ═══════════════════════════════════════════════════════════════
-- ЦЕПОЧКА — ОПТИМИЗИРОВАННАЯ
--
-- Ключевое изменение v1.1:
-- Повторные попытки планируются через task.delay(1, ScheduleNext)
-- вместо task.wait(1) внутри колбэка.
-- task.wait() БЛОКИРУЕТ поток и при накоплении даёт просадку FPS.
-- task.delay() создаёт новый лёгкий отложенный вызов и
-- немедленно освобождает текущий поток.
-- ═══════════════════════════════════════════════════════════════

local function ScheduleNext()
    if not State.Enabled then return end
    if #State.Commanders == 0 then return end

    -- Убираем удалённые башни
    for i = #State.Commanders, 1, -1 do
        if not State.Commanders[i].model.Parent then
            warn("[AutoChain] Удалена: " .. State.Commanders[i].name)
            table.remove(State.Commanders, i)
        end
    end

    if #State.Commanders == 0 then
        warn("[AutoChain] Все командиры удалены. Остановка.")
        State.Enabled = false
        return
    end

    if State.QueueIndex > #State.Commanders then
        State.QueueIndex = 1
    end

    local cmd = State.Commanders[State.QueueIndex]
    local now = os.clock()

    -- Ограничение 1: ритм цепочки
    local chainWait = State.LastChainTime == 0
        and 0
        or (State.LastChainTime + BUFF_DURATION - ACTIVATION_LEAD) - now

    -- Ограничение 2: кулдаун командира
    local cooldownWait = cmd.cooldownUntil - now

    local waitTime = math.max(0, chainWait, cooldownWait)

    DbgLog(string.format("[%d] %s | цепь=%.2fс кд=%.2fс ждём=%.2fс",
        State.QueueIndex, cmd.name,
        math.max(0, chainWait), math.max(0, cooldownWait), waitTime))

    -- Один точный sleep — поток не блокируется между активациями
    State.ScheduledThread = task.delay(waitTime, function()
        if not State.Enabled then return end

        local ok, err = pcall(function()
            local activated = Activate(cmd)

            if activated then
                -- Успех — двигаемся дальше по очереди
                State.LastChainTime = os.clock()
                State.RetryCount    = 0
                State.QueueIndex    = (State.QueueIndex % #State.Commanders) + 1
                ScheduleNext()
            else
                State.RetryCount += 1
                if State.RetryCount >= MAX_RETRIES then
                    -- Слишком много неудач подряд — пропускаем командира
                    warn(string.format(
                        "[AutoChain][WARN] %d неудач подряд, пропуск '%s'",
                        MAX_RETRIES, cmd.name))
                    State.RetryCount = 0
                    State.QueueIndex = (State.QueueIndex % #State.Commanders) + 1
                end
                -- Повтор через 1с — task.delay не блокирует поток
                State.ScheduledThread = task.delay(1, function()
                    if State.Enabled then ScheduleNext() end
                end)
            end
        end)

        if not ok then
            warn("[AutoChain][ERROR] Шаг: " .. tostring(err))
            -- Восстановление через 2с — тоже через task.delay
            State.ScheduledThread = task.delay(2, function()
                if State.Enabled then ScheduleNext() end
            end)
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════
-- УПРАВЛЕНИЕ
-- ═══════════════════════════════════════════════════════════════

local function StartChain()
    if State.Enabled then return false end
    State.Commanders = ScanCommanders()
    if #State.Commanders == 0 then
        warn("[AutoChain] Командиры не найдены!")
        return false
    end
    State.Enabled         = true
    State.QueueIndex      = 1
    State.ActivationCount = 0
    State.LastChainTime   = 0
    State.RetryCount      = 0
    for _, cmd in ipairs(State.Commanders) do
        cmd.cooldownUntil = 0
    end
    warn("[AutoChain] ▶ Запущена")
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
-- RAYFIELD UI
-- ═══════════════════════════════════════════════════════════════

local Rayfield
do
    local ok, result = pcall(function()
        return loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
    end)
    if not ok then
        warn("[AutoChain][ERROR] Rayfield: " .. tostring(result))
        warn("[AutoChain] StartChain() / StopChain() — вручную")
    else
        Rayfield = result
        warn("[AutoChain] Rayfield: OK")
    end
end

if not Rayfield then return end

local uiOk, uiErr = pcall(function()

    local Window = Rayfield:CreateWindow({
        Name            = "AutoChain — TDS: S.O.L.A.R",
        LoadingTitle    = "AutoChain v1.1",
        LoadingSubtitle = "Commander Chain",
        ConfigurationSaving = { Enabled = true, FileName = "AutoChain_SOLAR" },
        KeySystem = false,
    })

    -- ── Главная ─────────────────────────────────────────────────
    local Main = Window:CreateTab("AutoChain", nil)
    Main:CreateSection("Управление")

    Main:CreateToggle({
        Name         = "Commander Chain",
        CurrentValue = false,
        Flag         = "ChainToggle",
        Callback     = function(on)
            if on then
                local started = StartChain()
                Rayfield:Notify({
                    Title   = "AutoChain",
                    Content = started
                        and string.format("Запущен! Командиров: %d", #State.Commanders)
                        or  "Командиры не найдены",
                    Duration = 4,
                })
            else
                StopChain()
                Rayfield:Notify({
                    Title    = "AutoChain",
                    Content  = string.format("Остановлен. Активаций: %d", State.ActivationCount),
                    Duration = 3,
                })
            end
        end,
    })

    Main:CreateButton({
        Name = "Пересканировать командиров",
        Callback = function()
            local was = State.Enabled
            if was then StopChain() end
            State.Commanders = ScanCommanders()
            Rayfield:Notify({
                Title   = "Сканирование",
                Content = string.format("Найдено: %d", #State.Commanders),
                Duration = 4,
            })
            if was and #State.Commanders > 0 then StartChain() end
        end,
    })

    Main:CreateSection("Настройки тайминга")

    Main:CreateSlider({
        Name         = "Длительность баффа (сек)",
        Range        = {5, 20}, Increment = 0.5, Suffix = "с",
        CurrentValue = BUFF_DURATION, Flag = "BuffDur",
        Callback     = function(v) BUFF_DURATION = v end,
    })

    Main:CreateSlider({
        Name         = "Упреждение активации (сек)",
        Range        = {0, 2.0}, Increment = 0.1, Suffix = "с",
        CurrentValue = ACTIVATION_LEAD, Flag = "LeadTime",
        Callback     = function(v) ACTIVATION_LEAD = v end,
    })

    Main:CreateSlider({
        Name         = "Кулдаун командира (сек)",
        Range        = {30, 70}, Increment = 1, Suffix = "с",
        CurrentValue = ABILITY_COOLDOWN, Flag = "AbilityCD",
        Callback     = function(v) ABILITY_COOLDOWN = v end,
    })

    -- ── Отладка ──────────────────────────────────────────────────
    local Debug = Window:CreateTab("Отладка", nil)

    Debug:CreateToggle({
        Name         = "Подробный лог (warn)",
        CurrentValue = false, Flag = "DebugLog",
        Callback     = function(v) debugMode = v end,
    })

    Debug:CreateButton({
        Name = "Статус цепочки",
        Callback = function()
            local now = os.clock()
            warn("[AutoChain] ═══ Статус ═══")
            warn(string.format("  %s | Активаций: %d",
                State.Enabled and "АКТИВНА" or "СТОП",
                State.ActivationCount))
            for i, cmd in ipairs(State.Commanders) do
                warn(string.format("  [%d]%s %s (ур.%d) | КД: %.1fс",
                    i, i == State.QueueIndex and ">" or " ",
                    cmd.name, cmd.level,
                    math.max(0, cmd.cooldownUntil - now)))
            end
            if State.LastChainTime ~= 0 then
                warn(string.format("  Следующая через: %.1fс",
                    math.max(0, State.LastChainTime + BUFF_DURATION - ACTIVATION_LEAD - now)))
            end
            warn("[AutoChain] ═════════════")
            Rayfield:Notify({
                Title   = "Статус",
                Content = "Смотри Output / F9",
                Duration = 3,
            })
        end,
    })

    Debug:CreateButton({
        Name = "Разовая активация (тест)",
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
            })
        end,
    })

    -- ── Помощь ───────────────────────────────────────────────────
    local Help = Window:CreateTab("Помощь", nil)

    Help:CreateSection("Быстрый старт")
    Help:CreateLabel("1. Разместить 5 Командиров")
    Help:CreateLabel("2. Нажать Пересканировать командиров")
    Help:CreateLabel("3. Включить Commander Chain")

    Help:CreateSection("Математика цепочки")
    Help:CreateLabel("КД=50с | Бафф=10с")
    Help:CreateLabel("5 командиров: 5x10=50с = 100% покрытие")
    Help:CreateLabel("4 командира:  4x10=40с → разрыв 10с")

    Help:CreateSection("Если есть разрывы")
    Help:CreateLabel("Добавь командиров до 5")
    Help:CreateLabel("Или увеличь Упреждение на 0.5-1.0с")

end)

if not uiOk then
    warn("[AutoChain][ERROR] UI: " .. tostring(uiErr))
end

Players.PlayerRemoving:Connect(function(p)
    if p == LocalPlayer then pcall(StopChain) end
end)

warn("[AutoChain] S.O.L.A.R v1.1 загружен")

end -- SafeInit

local ok, err = pcall(SafeInit)
if not ok then
    warn("КРИТИЧЕСКАЯ ОШИБКА: " .. tostring(err))
    warn("Причины: лобби / не загружена игра / нет интернета")
end
