--[[
    AutoChain v5.1 — TDS: Reanimated

    ИСПРАВЛЕНИЕ v5.1:
    pcall() возвращает ok=true даже если сервер ОТКЛОНИЛ запрос.
    Скрипт видел ok=true, считал активацию успешной, писал в лог
    "Активировано" и ставил таймер кулдауна — но на деле ничего не происходило.
    
    Теперь проверяем РЕЗУЛЬТАТ который вернул сервер (result),
    а не только факт что вызов не упал (ok).
    
    Также убрано нижнее ограничение слайдера упреждения (теперь от 0).
]]

local function SafeInit()

-- ═══════════════════════════════════════════════════════════════
-- СЕРВИСЫ
-- ═══════════════════════════════════════════════════════════════

local Players, ReplicatedStorage, Workspace
do
    local ok
    ok, Players           = pcall(game.GetService, game, "Players")
    if not ok then error("GetService Players: " .. tostring(Players)) end
    ok, ReplicatedStorage = pcall(game.GetService, game, "ReplicatedStorage")
    if not ok then error("GetService ReplicatedStorage: " .. tostring(ReplicatedStorage)) end
    ok, Workspace         = pcall(game.GetService, game, "Workspace")
    if not ok then error("GetService Workspace: " .. tostring(Workspace)) end
end

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then error("LocalPlayer не найден") end

local WAIT_TIMEOUT   = 10
local RemoteFunction = ReplicatedStorage:WaitForChild("RemoteFunction", WAIT_TIMEOUT)
if not RemoteFunction then error("RemoteFunction не найден за " .. WAIT_TIMEOUT .. "с") end

local TowersFolder = Workspace:WaitForChild("Towers", WAIT_TIMEOUT)
if not TowersFolder then error("Workspace.Towers не найден — ты в лобби?") end

warn("[AutoChain] Инициализация: OK")

-- ═══════════════════════════════════════════════════════════════
-- КОНСТАНТЫ
-- ═══════════════════════════════════════════════════════════════

local BUFF_DURATION    = 10.0
local ABILITY_COOLDOWN = 34.0
local ABILITY_NAME     = "Call Of Arms"
local COMMANDER_TYPE   = "Commander"
local ACTIVATION_LEAD  = 0.0   -- Упреждение (0 = без упреждения)

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
}

local debugMode = false

-- ═══════════════════════════════════════════════════════════════
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
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
-- СКАНИРОВАНИЕ
-- ═══════════════════════════════════════════════════════════════

local function ScanCommanders()
    local found = {}
    local ok, err = pcall(function()
        for _, model in ipairs(TowersFolder:GetChildren()) do
            if model:IsA("Model") and IsOwned(model) and GetType(model) == COMMANDER_TYPE then
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

    warn(string.format("[AutoChain] Командиров найдено: %d", #found))
    for i, cmd in ipairs(found) do
        warn(string.format("  [%d] %s (ур.%d)", i, cmd.name, cmd.level))
    end
    return found
end

-- ═══════════════════════════════════════════════════════════════
-- АКТИВАЦИЯ — ИСПРАВЛЕНИЕ v5.1
-- ═══════════════════════════════════════════════════════════════

local function Activate(cmd)
    if not cmd.model or not cmd.model.Parent then
        warn("[AutoChain][WARN] '" .. cmd.name .. "' удалён с карты")
        return false
    end

    local ok, result = pcall(function()
        return RemoteFunction:InvokeServer(
            "Troops", "Abilities", "Activate",
            { Name = ABILITY_NAME, Troop = cmd.model }
        )
    end)

    -- Всегда логируем реальный ответ сервера — полезно для отладки
    DbgLog(string.format(
        "Ответ сервера '%s': ok=%s | result=%s (тип: %s)",
        cmd.name, tostring(ok), tostring(result), type(result)
    ))

    -- Шаг 1: сам вызов упал (сетевая ошибка, неверные аргументы)
    if not ok then
        warn("[AutoChain][ERROR] Вызов упал '" .. cmd.name .. "': " .. tostring(result))
        return false
    end

    -- Шаг 2: сервер явно вернул false — значит отклонил (кулдаун, стан и т.п.)
    if result == false then
        DbgLog(string.format("Сервер отклонил '%s' — кулдаун или стан", cmd.name))
        return false
    end

    -- Шаг 3: сервер вернул строку с ошибкой
    if type(result) == "string" then
        DbgLog(string.format("Сервер вернул строку '%s': %s", cmd.name, result))
        -- Не считаем ошибкой если строка не содержит явного отказа
        -- (некоторые серверы возвращают строку при успехе)
        if result:lower():find("cooldown") or result:lower():find("error") then
            return false
        end
    end

    -- Активация принята сервером (result = true / nil / таблица)
    cmd.cooldownUntil = os.clock() + ABILITY_COOLDOWN
    State.ActivationCount += 1
    warn(string.format("[AutoChain] Активирован: %s (всего: %d)",
        cmd.name, State.ActivationCount))
    return true
end

-- ═══════════════════════════════════════════════════════════════
-- ЦЕПОЧКА
-- ═══════════════════════════════════════════════════════════════

local function ScheduleNext()
    if not State.Enabled then return end
    if #State.Commanders == 0 then return end

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

    -- Ограничение 1: ритм цепочки (когда должен активироваться по баффу)
    local chainWait
    if State.LastChainTime == 0 then
        chainWait = 0
    else
        chainWait = (State.LastChainTime + BUFF_DURATION - ACTIVATION_LEAD) - now
    end

    -- Ограничение 2: кулдаун командира
    local cooldownWait = cmd.cooldownUntil - now

    local waitTime = math.max(0, chainWait, cooldownWait)

    DbgLog(string.format(
        "Следующий[%d]: %s | цепь=%.2fс | кд=%.2fс | ждём=%.2fс",
        State.QueueIndex, cmd.name,
        math.max(0, chainWait),
        math.max(0, cooldownWait),
        waitTime
    ))

    State.ScheduledThread = task.delay(waitTime, function()
        if not State.Enabled then return end

        local ok, err = pcall(function()
            local activated = Activate(cmd)
            if activated then
                State.LastChainTime = os.clock()
                State.QueueIndex = (State.QueueIndex % #State.Commanders) + 1
                ScheduleNext()
            else
                -- Активация отклонена сервером — подождём 1с и попробуем снова
                -- НЕ двигаем QueueIndex — пробуем того же командира
                task.wait(1)
                ScheduleNext()
            end
        end)

        if not ok then
            warn("[AutoChain][ERROR] Шаг цепочки: " .. tostring(err))
            task.wait(2)
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
        warn("[AutoChain] Командиры не найдены!")
        return false
    end
    State.Enabled         = true
    State.QueueIndex      = 1
    State.ActivationCount = 0
    State.LastChainTime   = 0
    for _, cmd in ipairs(State.Commanders) do
        cmd.cooldownUntil = 0
    end
    warn("[AutoChain] Цепочка запущена")
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
    warn(string.format("[AutoChain] Остановлена. Активаций: %d", State.ActivationCount))
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
        warn("[AutoChain] Без UI — StartChain() / StopChain() вручную")
    else
        Rayfield = result
        warn("[AutoChain] Rayfield: OK")
    end
end

if Rayfield then
    local uiOk, uiErr = pcall(function()

        local Window = Rayfield:CreateWindow({
            Name            = "AutoChain — TDS: Reanimated",
            LoadingTitle    = "AutoChain v5.1",
            LoadingSubtitle = "Commander Chain",
            ConfigurationSaving = { Enabled = true, FileName = "AutoChain_v5" },
            KeySystem = false,
        })

        local Main = Window:CreateTab("AutoChain", nil)
        Main:CreateSection("Управление")

        Main:CreateToggle({
            Name = "Commander Chain",
            CurrentValue = false, Flag = "ChainToggle",
            Callback = function(on)
                if on then
                    local started = StartChain()
                    Rayfield:Notify({
                        Title   = "AutoChain",
                        Content = started
                            and string.format("Запущен! Командиров: %d", #State.Commanders)
                            or  "Командиры не найдены",
                        Duration = 4, Image = "rbxassetid://4483345998"
                    })
                else
                    StopChain()
                    Rayfield:Notify({
                        Title    = "AutoChain",
                        Content  = string.format("Остановлен. Активаций: %d", State.ActivationCount),
                        Duration = 3, Image = "rbxassetid://4483345998"
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
                    Title = "Сканирование",
                    Content = string.format("Найдено: %d", #State.Commanders),
                    Duration = 4, Image = "rbxassetid://4483345998"
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

        -- Упреждение от 0 (без упреждения) до 2.0
        Main:CreateSlider({
            Name = "Упреждение активации (сек)",
            Range = {0, 2.0}, Increment = 0.1, Suffix = "с",
            CurrentValue = ACTIVATION_LEAD, Flag = "LeadTime",
            Callback = function(v) ACTIVATION_LEAD = v end,
        })

        Main:CreateSlider({
            Name = "Кулдаун командира (сек)",
            Range = {25, 45}, Increment = 1, Suffix = "с",
            CurrentValue = ABILITY_COOLDOWN, Flag = "AbilityCD",
            Callback = function(v) ABILITY_COOLDOWN = v end,
        })

        local Debug = Window:CreateTab("Отладка", nil)

        Debug:CreateToggle({
            Name = "Подробный лог (warn)",
            CurrentValue = false, Flag = "DebugLog",
            Callback = function(v) debugMode = v end,
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
                    local nextAt = State.LastChainTime + BUFF_DURATION - ACTIVATION_LEAD
                    warn(string.format("  Следующая через: %.1fс", math.max(0, nextAt - now)))
                end
                warn("[AutoChain] ═════════════")
                Rayfield:Notify({
                    Title = "Статус", Content = "Смотри Output / F9",
                    Duration = 3, Image = "rbxassetid://4483345998"
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
                    Title = "Тест",
                    Content = string.format("Активировано: %d / %d", count, #cmds),
                    Duration = 4, Image = "rbxassetid://4483345998"
                })
            end,
        })

        local Help = Window:CreateTab("Помощь", nil)
        Help:CreateSection("Быстрый старт")
        Help:CreateLabel("1. Разместить 3-4 Командира (уровень 2+)")
        Help:CreateLabel("2. Нажать Пересканировать командиров")
        Help:CreateLabel("3. Включить Commander Chain")
        Help:CreateSection("Математика цепочки")
        Help:CreateLabel("КД=34с, Бафф=10с")
        Help:CreateLabel("3 командира: 3x10=30с < 34с (разрыв 4с)")
        Help:CreateLabel("4 командира: 4x10=40с > 34с (100% покрытие)")
        Help:CreateSection("Если есть разрывы")
        Help:CreateLabel("Добавь 4-го командира")
        Help:CreateLabel("Или выкрути Упреждение на нужное значение")

    end)

    if not uiOk then
        warn("[AutoChain][ERROR] UI: " .. tostring(uiErr))
    end
end

Players.PlayerRemoving:Connect(function(p)
    if p == LocalPlayer then pcall(StopChain) end
end)

warn("[AutoChain] v5.1 загружен")

end -- SafeInit

local ok, err = pcall(SafeInit)
if not ok then
    warn("AutoChain КРИТИЧЕСКАЯ ОШИБКА: " .. tostring(err))
    warn("Возможные причины:")
    warn("  - Инжект в лобби (нет Towers)")
    warn("  - Игра ещё не загрузилась")
    warn("  - Нет интернета (HttpGet)")
end
