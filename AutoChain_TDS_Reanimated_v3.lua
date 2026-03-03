--[[
╔══════════════════════════════════════════════════════════════════════════╗
║       AutoChain v3.0 — TDS: Reanimated  |  ОПТИМИЗИРОВАННАЯ ВЕРСИЯ     ║
║                                                                          ║
║  Ключевые оптимизации:                                                   ║
║  • Убран polling-цикл (шаг 0.05с) → заменён на точный task.delay        ║
║  • Нет RunService.RenderStepped / Heartbeat                              ║
║  • Нет повторного сканирования каждые 5с в фоне                         ║
║  • Минимум pcall — только там где реально нужно                          ║
║  • Удалены все промежуточные task.wait() без причины                     ║
╚══════════════════════════════════════════════════════════════════════════╝
]]

-- ═══════════════════════════════════════════════════════════════
-- СЕРВИСЫ
-- ═══════════════════════════════════════════════════════════════

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer    = Players.LocalPlayer
local Workspace      = game:GetService("Workspace")
local RemoteFunction = ReplicatedStorage:WaitForChild("RemoteFunction")
local TowersFolder   = Workspace:WaitForChild("Towers")

-- ═══════════════════════════════════════════════════════════════
-- КОНСТАНТЫ МЕХАНИКИ
-- ═══════════════════════════════════════════════════════════════

local BUFF_DURATION    = 10.0   -- Длительность баффа (сек)
local ABILITY_COOLDOWN = 30.0   -- Кулдаун командира (сек)
local ABILITY_NAME     = "Call Of Arms"
local COMMANDER_TYPE   = "Commander"

-- Упреждение: активируем следующего за X сек до конца баффа
-- Увеличь если есть разрывы из-за пинга (0.5 → 1.0)
local ACTIVATION_LEAD  = 0.5

-- ═══════════════════════════════════════════════════════════════
-- СОСТОЯНИЕ
-- ═══════════════════════════════════════════════════════════════

local State = {
    Enabled         = false,
    Commanders      = {},   -- { model, name, level, readyAt }
    QueueIndex      = 1,
    ActivationCount = 0,
    ScheduledThread = nil,  -- единственный активный поток
}

local debugMode = false

-- ═══════════════════════════════════════════════════════════════
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ═══════════════════════════════════════════════════════════════

local function IsOwned(model)
    local o = model:FindFirstChild("Owner")
    return o and o.Value == LocalPlayer
end

local function GetType(model)
    local t = model:FindFirstChild("Type")
    return t and t:IsA("StringValue") and t.Value or ""
end

local function GetLevel(model)
    local u = model:FindFirstChild("Upgrade")
    return u and u:IsA("IntValue") and u.Value or 0
end

local function DbgLog(msg)
    if debugMode then print("[AutoChain] " .. msg) end
end

-- ═══════════════════════════════════════════════════════════════
-- СКАНИРОВАНИЕ
-- ═══════════════════════════════════════════════════════════════

local function ScanCommanders()
    local found = {}
    for _, model in ipairs(TowersFolder:GetChildren()) do
        if model:IsA("Model") and IsOwned(model) and GetType(model) == COMMANDER_TYPE then
            table.insert(found, {
                model   = model,
                name    = model.Name,
                level   = GetLevel(model),
                readyAt = 0,  -- 0 = готов немедленно
            })
        end
    end
    -- Высокий уровень — первый в очереди
    table.sort(found, function(a, b) return a.level > b.level end)
    return found
end

-- ═══════════════════════════════════════════════════════════════
-- АКТИВАЦИЯ
-- ═══════════════════════════════════════════════════════════════

-- Активирует командира и возвращает true при успехе.
-- НЕ содержит никаких task.wait внутри.
local function Activate(cmd)
    if not cmd.model or not cmd.model.Parent then
        print("[AutoChain][WARN] Командир '" .. cmd.name .. "' удалён с карты")
        return false
    end

    local ok, result = pcall(
        RemoteFunction.InvokeServer,
        RemoteFunction,
        "Troops", "Abilities", "Activate",
        { Name = ABILITY_NAME, Troop = cmd.model }
    )

    if ok then
        local now     = os.clock()
        cmd.readyAt   = now + ABILITY_COOLDOWN
        State.ActivationCount += 1
        DbgLog(string.format("✓ %s | КД до: %.1fс | Всего: %d",
            cmd.name, ABILITY_COOLDOWN, State.ActivationCount))
        return true
    else
        print("[AutoChain][ERROR] " .. tostring(result))
        return false
    end
end

-- ═══════════════════════════════════════════════════════════════
-- ЦЕПОЧКА — КЛЮЧЕВАЯ ОПТИМИЗАЦИЯ
-- ═══════════════════════════════════════════════════════════════

--[[
  Вместо цикла с опросом каждые 0.05с используем точный task.wait(N).

  Алгоритм одного шага:
    1. Берём текущего командира из очереди.
    2. Вычисляем через сколько секунд его нужно активировать:
         waitTime = max(0, cmd.readyAt - os.clock())
       Если readyAt=0 — активируем сразу (первый запуск).
    3. task.wait(waitTime) — один точный sleep, без цикла.
    4. Активируем.
    5. Планируем следующую активацию через (BUFF_DURATION - ACTIVATION_LEAD).
    6. Переходим к следующему командиру.

  Поток спит большую часть времени (~9.5с) и просыпается ровно в нужный момент.
  Нагрузка на FPS — практически нулевая.
]]

local function ScheduleNext()
    if not State.Enabled then return end
    if #State.Commanders == 0 then return end

    -- Убираем удалённые башни
    for i = #State.Commanders, 1, -1 do
        if not State.Commanders[i].model.Parent then
            print("[AutoChain] Башня удалена: " .. State.Commanders[i].name)
            table.remove(State.Commanders, i)
        end
    end

    if #State.Commanders == 0 then
        print("[AutoChain] ⚠ Все командиры удалены. Остановка.")
        State.Enabled = false
        return
    end

    -- Корректируем индекс если вышел за пределы
    if State.QueueIndex > #State.Commanders then
        State.QueueIndex = 1
    end

    local cmd = State.Commanders[State.QueueIndex]
    local now = os.clock()

    -- Сколько ждать до активации этого командира
    local waitTime = math.max(0, cmd.readyAt - now)

    DbgLog(string.format("Следующий: %s через %.2fс", cmd.name, waitTime))

    -- Один точный sleep — никаких polling-циклов
    State.ScheduledThread = task.delay(waitTime, function()
        if not State.Enabled then return end

        local activated = Activate(cmd)

        if activated then
            State.QueueIndex = (State.QueueIndex % #State.Commanders) + 1
            -- Планируем активацию следующего командира ровно через
            -- (BUFF_DURATION - ACTIVATION_LEAD) секунд от сейчас
            local nextCmd = State.Commanders[State.QueueIndex]
            -- Чтобы nextCmd ожидал именно нужное время,
            -- временно устанавливаем readyAt с учётом интервала баффа
            -- (не перезаписываем настоящий readyAt кулдауна — он уже установлен)
            -- Вместо этого: следующий task.delay уже вычислит
            -- max(0, nextCmd.readyAt - now), что даст правильную паузу
            -- при нормальной работе цепочки.

            -- НО: для первых витков цепочки nextCmd.readyAt = 0,
            -- значит он активируется немедленно — нам нужна пауза в BUFF_DURATION.
            -- Решение: если nextCmd.readyAt = 0, подставляем нужное время.
            if nextCmd.readyAt == 0 then
                nextCmd.readyAt = os.clock() + (BUFF_DURATION - ACTIVATION_LEAD)
            else
                -- В установившемся режиме: следующий ждёт своего КД.
                -- Но не меньше чем BUFF_DURATION - ACTIVATION_LEAD от сейчас.
                local minNext = os.clock() + (BUFF_DURATION - ACTIVATION_LEAD)
                nextCmd.readyAt = math.max(nextCmd.readyAt, minNext)
            end

            ScheduleNext()
        else
            -- Не получилось — пробуем снова через 1с
            task.wait(1)
            ScheduleNext()
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
        print("[AutoChain] ⚠ Командиры не найдены!")
        return false
    end

    print(string.format("[AutoChain] ▶ Запуск. Командиров: %d", #State.Commanders))
    for i, cmd in ipairs(State.Commanders) do
        cmd.readyAt = 0  -- сброс
        print(string.format("  [%d] %s (ур.%d)", i, cmd.name, cmd.level))
    end

    State.Enabled         = true
    State.QueueIndex      = 1
    State.ActivationCount = 0

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
    print(string.format("[AutoChain] ⏹ Остановлен. Активаций: %d", State.ActivationCount))
end

-- ═══════════════════════════════════════════════════════════════
-- RAYFIELD UI
-- ═══════════════════════════════════════════════════════════════

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name            = "AutoChain — TDS: Reanimated",
    LoadingTitle    = "AutoChain v3.0",
    LoadingSubtitle = "Optimized Commander Chain",
    ConfigurationSaving = { Enabled = true, FileName = "AutoChain_v3" },
    KeySystem = false,
})

-- ── Главная вкладка ──────────────────────────────────────────
local Main = Window:CreateTab("⚔️ AutoChain", nil)

Main:CreateSection("Управление")

Main:CreateToggle({
    Name         = "🔗 Commander Chain",
    CurrentValue = false,
    Flag         = "ChainToggle",
    Callback     = function(on)
        if on then
            local ok = StartChain()
            Rayfield:Notify({
                Title   = "AutoChain",
                Content = ok
                    and string.format("▶ Запущен! Командиров: %d", #State.Commanders)
                    or  "⚠ Командиры не найдены. Разместите башни.",
                Duration = 4,
                Image   = "rbxassetid://4483345998"
            })
        else
            StopChain()
            Rayfield:Notify({
                Title    = "AutoChain",
                Content  = string.format("⏹ Остановлен. Активаций: %d", State.ActivationCount),
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
        local n = #State.Commanders
        Rayfield:Notify({
            Title    = "Сканирование",
            Content  = string.format("Найдено командиров: %d (детали в консоли F9)", n),
            Duration = 4,
            Image    = "rbxassetid://4483345998"
        })
        for i, cmd in ipairs(State.Commanders) do
            print(string.format("[AutoChain]  [%d] %s (ур.%d)", i, cmd.name, cmd.level))
        end
        if was and n > 0 then StartChain() end
    end,
})

-- ── Настройки ────────────────────────────────────────────────
Main:CreateSection("Настройки тайминга")

Main:CreateSlider({
    Name         = "Длительность баффа (сек)",
    Range        = {5, 15},
    Increment    = 0.5,
    Suffix       = "с",
    CurrentValue = BUFF_DURATION,
    Flag         = "BuffDur",
    Callback     = function(v) BUFF_DURATION = v end,
})

Main:CreateSlider({
    Name         = "Упреждение активации (сек)",
    Range        = {0.1, 2.0},
    Increment    = 0.1,
    Suffix       = "с",
    CurrentValue = ACTIVATION_LEAD,
    Flag         = "LeadTime",
    Callback     = function(v) ACTIVATION_LEAD = v end,
})

-- ── Отладка ──────────────────────────────────────────────────
local Debug = Window:CreateTab("🔧 Отладка", nil)

Debug:CreateToggle({
    Name         = "Подробный лог (консоль)",
    CurrentValue = false,
    Flag         = "DebugLog",
    Callback     = function(v) debugMode = v end,
})

Debug:CreateButton({
    Name = "📋 Статус цепочки → консоль",
    Callback = function()
        local now = os.clock()
        print("[AutoChain] ══════ Статус ══════")
        print(string.format("  Цепочка: %s | Активаций: %d",
            State.Enabled and "▶ АКТИВНА" or "⏹ СТОП", State.ActivationCount))
        for i, cmd in ipairs(State.Commanders) do
            local cd = math.max(0, cmd.readyAt - now)
            print(string.format("  [%d]%s %s (ур.%d) | КД: %.1fс",
                i, i == State.QueueIndex and "►" or " ", cmd.name, cmd.level, cd))
        end
        print("[AutoChain] ═══════════════════")
        Rayfield:Notify({ Title="Статус", Content="Напечатано в консоли (F9)", Duration=3, Image="rbxassetid://4483345998" })
    end,
})

Debug:CreateButton({
    Name = "⚡ Разовая активация всех (тест)",
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

-- ── Помощь ───────────────────────────────────────────────────
local Help = Window:CreateTab("❓ Помощь", nil)
Help:CreateSection("Быстрый старт")
Help:CreateLabel("1. Разместить 3 Командира (уровень 2+)")
Help:CreateLabel("2. Нажать '🔄 Пересканировать командиров'")
Help:CreateLabel("3. Включить '🔗 Commander Chain'")
Help:CreateSection("Если есть разрывы в баффе")
Help:CreateLabel("→ Увеличь 'Упреждение активации' до 1.0–1.5с")
Help:CreateSection("Если FPS всё ещё падает")
Help:CreateLabel("→ Отключи 'Подробный лог' в отладке")

-- ═══════════════════════════════════════════════════════════════
-- ОЧИСТКА
-- ═══════════════════════════════════════════════════════════════

Players.PlayerRemoving:Connect(function(p)
    if p == LocalPlayer then StopChain() end
end)

print("[AutoChain] v3.0 загружен — оптимизированная версия.")
