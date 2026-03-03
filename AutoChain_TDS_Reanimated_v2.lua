--[[
╔══════════════════════════════════════════════════════════════════════════╗
║           AutoChain — Tower Defense Simulator: Reanimated               ║
║           Версия: 2.0.0  |  UI: Rayfield                                ║
║                                                                          ║
║  ПРИНЦИП РАБОТЫ (Commander Chain):                                       ║
║                                                                          ║
║  Бафф "Call Of Arms":                                                    ║
║    • Длительность:  10 секунд                                            ║
║    • Кулдаун:       30 секунд                                            ║
║    • Эффект:        +55% скорость атаки                                  ║
║                                                                          ║
║  Алгоритм (3 командира A, B, C):                                         ║
║    T=0с  → Активируем A  (бафф 10с, CD 30с)                             ║
║    T=10с → Активируем B  (бафф A кончился, бафф B начался)              ║
║    T=20с → Активируем C  (бафф B кончился, бафф C начался)              ║
║    T=30с → Активируем A  (CD у A закончился, цикл замкнулся)            ║
║                                                                          ║
║  Скрипт НЕ опирается на атрибуты кулдауна из игры.                      ║
║  Вместо этого он сам ведёт таймер каждого командира.                     ║
║  Активация следующего происходит ровно через BUFF_DURATION секунд        ║
║  после предыдущей (с небольшим запасом для исключения "дыр").            ║
╚══════════════════════════════════════════════════════════════════════════╝
]]

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 1: СЕРВИСЫ
-- ═══════════════════════════════════════════════════════════════

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer  = Players.LocalPlayer
local Workspace    = game:GetService("Workspace")

local RemoteFunction = ReplicatedStorage:WaitForChild("RemoteFunction")
local TowersFolder   = Workspace:WaitForChild("Towers")

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 2: КОНСТАНТЫ МЕХАНИКИ
-- (Изменяй только если в Reanimated другие цифры)
-- ═══════════════════════════════════════════════════════════════

local BUFF_DURATION    = 10.0   -- Сколько секунд длится бафф "Call Of Arms"
local ABILITY_COOLDOWN = 34.0   -- Кулдаун командира после активации (секунды)
local ABILITY_NAME     = "Call Of Arms"
local COMMANDER_TYPE   = "Commander"

-- За сколько секунд ДО окончания баффа активировать следующего командира.
-- Компенсирует сетевую задержку и лаг сервера.
-- 0.5 = активируем следующего за 0.5с до окончания текущего баффа.
local ACTIVATION_LEAD_TIME = 0.0

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 3: СОСТОЯНИЕ СИСТЕМЫ
-- ═══════════════════════════════════════════════════════════════

local State = {
    Enabled         = false,    -- Работает ли AutoChain прямо сейчас
    Thread          = nil,      -- Ссылка на поток (task.spawn)
    Commanders      = {},       -- Список командиров { model, activatedAt, readyAt }
    QueueIndex      = 1,        -- Индекс следующего командира в очереди
    ActivationCount = 0,        -- Счётчик активаций за сессию
    ChainBroken     = false,    -- Флаг: цепочка была прервана (для UI)
}

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 4: ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ═══════════════════════════════════════════════════════════════

local function Log(msg, level)
    level = level or "INFO"
    -- Выводим только ошибки и предупреждения, чтобы не спамить консоль.
    -- Для полного лога поменяй условие на: if true then
    if level == "ERROR" or level == "WARN" then
        print(string.format("[AutoChain][%s][%s] %s", os.date("%H:%M:%S"), level, tostring(msg)))
    end
end

-- Тихий лог — только для отладки (не засоряет консоль в рабочем режиме)
local debugMode = false
local function LogDebug(msg)
    if debugMode then
        print(string.format("[AutoChain][DEBUG] %s", tostring(msg)))
    end
end

local function IsOwnedByLocalPlayer(model)
    local ownerValue = model:FindFirstChild("Owner")
    if not ownerValue then return false end
    return ownerValue.Value == LocalPlayer
end

local function GetTowerType(model)
    local t = model:FindFirstChild("Type")
    return (t and t:IsA("StringValue")) and t.Value or ""
end

local function GetTowerLevel(model)
    local u = model:FindFirstChild("Upgrade")
    return (u and u:IsA("IntValue")) and u.Value or 0
end

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 5: СКАНИРОВАНИЕ КОМАНДИРОВ
-- ═══════════════════════════════════════════════════════════════

-- Находит всех командиров игрока и сортирует их по уровню (выше = первее).
-- Возвращает таблицу объектов:
--   { model, name, level, activatedAt, readyAt }
--     activatedAt — os.clock() момента последней активации (0 = не активировался)
--     readyAt     — os.clock() момента когда снова будет готов
local function ScanCommanders()
    local found = {}

    local ok, err = pcall(function()
        for _, model in ipairs(TowersFolder:GetChildren()) do
            if not model:IsA("Model") then continue end
            if not IsOwnedByLocalPlayer(model) then continue end
            if GetTowerType(model) ~= COMMANDER_TYPE then continue end

            local lvl = GetTowerLevel(model)
            table.insert(found, {
                model       = model,
                name        = model.Name,
                level       = lvl,
                activatedAt = 0,     -- ещё не активировался
                readyAt     = 0,     -- считаем что сразу готов
            })
        end
    end)

    if not ok then
        Log("Ошибка сканирования: " .. tostring(err), "ERROR")
    end

    -- Сортируем: сначала командиры с высоким уровнем
    table.sort(found, function(a, b) return a.level > b.level end)

    -- Проверяем уровни — для стабильной цепочки нужен минимум 2-й уровень
    for _, cmd in ipairs(found) do
        if cmd.level < 2 then
            Log(string.format(
                "Командир '%s' имеет уровень %d < 2. Цепочка может иметь разрывы!",
                cmd.name, cmd.level
            ), "WARN")
        end
    end

    return found
end

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 6: АКТИВАЦИЯ СПОСОБНОСТИ
-- ═══════════════════════════════════════════════════════════════

-- Отправляет запрос на сервер и обновляет таймеры командира.
-- Возвращает true при успехе.
local function ActivateAbility(cmd)
    if not cmd.model or not cmd.model.Parent then
        Log(string.format("Командир '%s' удалён с карты!", cmd.name), "WARN")
        return false
    end

    local now = os.clock()

    -- Защита: не активировать если кулдаун ещё идёт
    -- (на случай если цикл сбился)
    if cmd.activatedAt ~= 0 and (now - cmd.activatedAt) < (ABILITY_COOLDOWN - 1) then
        LogDebug(string.format(
            "Пропуск '%s': кулдаун ещё %.1fс",
            cmd.name, ABILITY_COOLDOWN - (now - cmd.activatedAt)
        ))
        return false
    end

    local ok, result = pcall(function()
        return RemoteFunction:InvokeServer(
            "Troops",
            "Abilities",
            "Activate",
            {
                Name  = ABILITY_NAME,
                Troop = cmd.model
            }
        )
    end)

    if ok then
        cmd.activatedAt = now
        cmd.readyAt     = now + ABILITY_COOLDOWN
        State.ActivationCount += 1
        LogDebug(string.format(
            "Активирован: %s (активаций всего: %d)",
            cmd.name, State.ActivationCount
        ))
        return true
    else
        Log(string.format("Ошибка активации '%s': %s", cmd.name, tostring(result)), "ERROR")
        return false
    end
end

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 7: ГЛАВНЫЙ ЦИКЛ ЦЕПОЧКИ
-- ═══════════════════════════════════════════════════════════════

--[[
  ЛОГИКА ЦИКЛА:

  Представь очередь командиров: [A, B, C, A, B, C, A, B, C ...]

  Шаг 1: Активируем A немедленно (первая активация).
  Шаг 2: Ждём (BUFF_DURATION - ACTIVATION_LEAD_TIME) секунд.
  Шаг 3: Активируем B.
  Шаг 4: Ждём (BUFF_DURATION - ACTIVATION_LEAD_TIME) секунд.
  Шаг 5: Активируем C.
  ... и так по кругу.

  Если командир ещё не готов (readyAt > now), ждём до readyAt.
  Это обрабатывает случай когда командиров < 3 или цепочка сбилась.
]]

local function ChainLoop()
    print("[AutoChain] ▶ Запущен. Командиров: " .. #State.Commanders)

    -- Сбрасываем индекс очереди
    State.QueueIndex    = 1
    State.ChainBroken   = false

    -- ── Первая активация (сразу активируем первого командира) ──
    local first = State.Commanders[State.QueueIndex]
    if first then
        ActivateAbility(first)
        State.QueueIndex = (State.QueueIndex % #State.Commanders) + 1
    end

    -- ── Основной цикл ──
    while State.Enabled do

        -- Проверяем что командиры ещё на карте
        -- (игрок мог продать башню)
        local validCommanders = {}
        for _, cmd in ipairs(State.Commanders) do
            if cmd.model and cmd.model.Parent then
                table.insert(validCommanders, cmd)
            end
        end

        if #validCommanders ~= #State.Commanders then
            print(string.format(
                "[AutoChain] Командиров изменилось: %d → %d. Пересканирование...",
                #State.Commanders, #validCommanders
            ))
            State.Commanders = validCommanders
            if #State.Commanders == 0 then
                print("[AutoChain] ⚠ Командиры закончились! Остановка.")
                State.Enabled = false
                break
            end
            -- Корректируем индекс
            if State.QueueIndex > #State.Commanders then
                State.QueueIndex = 1
            end
        end

        -- Следующий командир в очереди
        local nextCmd = State.Commanders[State.QueueIndex]

        -- Ждём нужное время перед активацией следующего:
        --   • Либо (BUFF_DURATION - ACTIVATION_LEAD_TIME) от момента
        --     активации предыдущего — чтобы не было разрывов в баффе.
        --   • Либо до readyAt следующего — чтобы не активировать на кулдауне.

        -- Время когда нужно активировать следующего:
        --   = activatedAt предыдущего + BUFF_DURATION - ACTIVATION_LEAD_TIME
        local prevIndex = ((State.QueueIndex - 2) % #State.Commanders) + 1
        local prevCmd   = State.Commanders[prevIndex]

        local activateNextAt
        if prevCmd.activatedAt == 0 then
            -- Предыдущий ещё не активировался — активируем сразу
            activateNextAt = os.clock()
        else
            activateNextAt = prevCmd.activatedAt + BUFF_DURATION - ACTIVATION_LEAD_TIME
        end

        -- Также не можем активировать раньше чем закончится кулдаун
        local notBeforeTime = nextCmd.readyAt

        -- Ждём максимум из двух ограничений
        local waitUntil = math.max(activateNextAt, notBeforeTime)
        local waitTime  = waitUntil - os.clock()

        if waitTime > 0 then
            -- Ждём нужное время, проверяя каждые 0.05с не выключили ли нас
            local waited = 0
            while waited < waitTime and State.Enabled do
                local step = math.min(1, waitTime - waited)
                task.wait(step)
                waited += step
            end
        end

        if not State.Enabled then break end

        -- Активируем следующего командира
        local success = ActivateAbility(nextCmd)

        if not success then
            -- Если не получилось активировать (кулдаун, удалён и т.д.)
            -- делаем небольшую паузу и пробуем ещё раз
            State.ChainBroken = true
            LogDebug("Цепочка прервана, ожидание...")
            task.wait(1)
        else
            State.ChainBroken = false
            -- Переходим к следующему в очереди
            State.QueueIndex = (State.QueueIndex % #State.Commanders) + 1
        end
    end

    print(string.format("[AutoChain] ⏹ Остановлен. Активаций за сессию: %d", State.ActivationCount))
end

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 8: УПРАВЛЕНИЕ
-- ═══════════════════════════════════════════════════════════════

local function StartAutoChain()
    if State.Enabled then return end

    -- Сканируем командиров перед запуском
    State.Commanders = ScanCommanders()

    if #State.Commanders == 0 then
        print("[AutoChain] ⚠ Командиры не найдены! Разместите башни и попробуйте снова.")
        return false
    end

    if #State.Commanders < 3 then
        print(string.format(
            "[AutoChain] ⚠ Найдено командиров: %d. Для идеальной цепочки нужно 3.",
            #State.Commanders
        ))
    end

    State.Enabled         = true
    State.ActivationCount = 0
    State.QueueIndex      = 1

    -- Сбрасываем таймеры всех командиров
    for _, cmd in ipairs(State.Commanders) do
        cmd.activatedAt = 0
        cmd.readyAt     = 0
    end

    State.Thread = task.spawn(ChainLoop)
    return true
end

local function StopAutoChain()
    if not State.Enabled then return end
    State.Enabled = false
    if State.Thread then
        task.cancel(State.Thread)
        State.Thread = nil
    end
end

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 9: RAYFIELD UI
-- ═══════════════════════════════════════════════════════════════

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name            = "AutoChain — TDS: Reanimated",
    LoadingTitle    = "AutoChain v2.0",
    LoadingSubtitle = "Commander Chain System",
    ConfigurationSaving = {
        Enabled  = true,
        FileName = "AutoChain_Config"
    },
    KeySystem = false,
})

-- ── Вкладка: Главная ─────────────────────────────────────────
local MainTab = Window:CreateTab("⚔️ AutoChain", nil)

MainTab:CreateSection("Управление цепочкой")

MainTab:CreateToggle({
    Name         = "🔗 Включить Commander Chain",
    CurrentValue = false,
    Flag         = "AutoChainToggle",
    Callback     = function(value)
        if value then
            local ok = StartAutoChain()
            if ok then
                Rayfield:Notify({
                    Title    = "AutoChain",
                    Content  = string.format("▶ Запущен! Командиров в очереди: %d", #State.Commanders),
                    Duration = 4,
                    Image    = "rbxassetid://4483345998"
                })
            else
                -- Если командиры не найдены — возвращаем тоггл назад
                Rayfield:Notify({
                    Title    = "Ошибка",
                    Content  = "Командиры не найдены. Разместите башни и попробуйте снова.",
                    Duration = 5,
                    Image    = "rbxassetid://4483345998"
                })
            end
        else
            StopAutoChain()
            Rayfield:Notify({
                Title    = "AutoChain",
                Content  = string.format("⏹ Остановлен. Активаций: %d", State.ActivationCount),
                Duration = 3,
                Image    = "rbxassetid://4483345998"
            })
        end
    end,
})

MainTab:CreateButton({
    Name     = "🔄 Пересканировать командиров",
    Callback = function()
        local wasEnabled = State.Enabled
        if wasEnabled then StopAutoChain() end

        State.Commanders = ScanCommanders()

        local msg = string.format("Найдено командиров: %d", #State.Commanders)
        if #State.Commanders > 0 then
            local names = {}
            for _, cmd in ipairs(State.Commanders) do
                table.insert(names, string.format("%s (ур.%d)", cmd.name, cmd.level))
            end
            print("[AutoChain] Командиры: " .. table.concat(names, ", "))
        end

        Rayfield:Notify({
            Title    = "Сканирование",
            Content  = msg .. ". Детали в консоли (F9).",
            Duration = 4,
            Image    = "rbxassetid://4483345998"
        })

        if wasEnabled and #State.Commanders > 0 then
            StartAutoChain()
        end
    end,
})

-- ── Настройки тайминга ───────────────────────────────────────
MainTab:CreateSection("Настройки тайминга")

MainTab:CreateSlider({
    Name         = "Длительность баффа (сек)",
    Range        = {5, 15},
    Increment    = 0.5,
    Suffix       = "с",
    CurrentValue = BUFF_DURATION,
    Flag         = "BuffDuration",
    Callback     = function(v)
        BUFF_DURATION = v
    end,
})

MainTab:CreateSlider({
    Name         = "Упреждение активации (сек)",
    Range        = {0.0, 2.0},
    Increment    = 0.1,
    Suffix       = "с",
    CurrentValue = ACTIVATION_LEAD_TIME,
    Flag         = "LeadTime",
    Callback     = function(v)
        ACTIVATION_LEAD_TIME = v
    end,
})

-- ── Вкладка: Статус ──────────────────────────────────────────
local StatusTab = Window:CreateTab("📊 Статус", nil)

StatusTab:CreateSection("Информация о цепочке")

StatusTab:CreateButton({
    Name     = "📋 Показать статус цепочки",
    Callback = function()
        if #State.Commanders == 0 then
            Rayfield:Notify({
                Title    = "Статус",
                Content  = "Командиры не найдены. Сначала нажми 'Пересканировать'.",
                Duration = 4,
                Image    = "rbxassetid://4483345998"
            })
            return
        end

        local now = os.clock()
        print("[AutoChain] ══════ Статус цепочки ══════")
        print(string.format("[AutoChain] Цепочка: %s | Активаций: %d",
            State.Enabled and "▶ АКТИВНА" or "⏹ СТОП",
            State.ActivationCount
        ))

        for i, cmd in ipairs(State.Commanders) do
            local cdLeft = math.max(0, cmd.readyAt - now)
            local marker = (i == State.QueueIndex) and "◄ СЛЕДУЮЩИЙ" or ""
            print(string.format(
                "[AutoChain]  [%d] %s (ур.%d) | КД: %.1fс %s",
                i, cmd.name, cmd.level, cdLeft, marker
            ))
        end
        print("[AutoChain] ═══════════════════════════")

        Rayfield:Notify({
            Title    = "Статус",
            Content  = string.format(
                "%s | Командиров: %d | Активаций: %d",
                State.Enabled and "▶ АКТИВНА" or "⏹ СТОП",
                #State.Commanders,
                State.ActivationCount
            ),
            Duration = 5,
            Image    = "rbxassetid://4483345998"
        })
    end,
})

-- ── Вкладка: Отладка ─────────────────────────────────────────
local DebugTab = Window:CreateTab("🔧 Отладка", nil)

DebugTab:CreateSection("Инструменты")

DebugTab:CreateToggle({
    Name         = "Подробный лог в консоль",
    CurrentValue = false,
    Flag         = "DebugMode",
    Callback     = function(v)
        debugMode = v
    end,
})

DebugTab:CreateButton({
    Name     = "⚡ Тест: активировать всех ОДИН РАЗ",
    Callback = function()
        local cmds = ScanCommanders()
        if #cmds == 0 then
            Rayfield:Notify({ Title="Тест", Content="Командиры не найдены!", Duration=3, Image="rbxassetid://4483345998" })
            return
        end
        local count = 0
        for _, cmd in ipairs(cmds) do
            local ok = ActivateAbility(cmd)
            if ok then count += 1 end
            task.wait(0.3)
        end
        Rayfield:Notify({
            Title   = "Тест активации",
            Content = string.format("Активировано %d из %d командиров", count, #cmds),
            Duration = 4,
            Image   = "rbxassetid://4483345998"
        })
    end,
})

DebugTab:CreateButton({
    Name     = "🔬 Атрибуты первого командира → консоль",
    Callback = function()
        local cmds = ScanCommanders()
        if #cmds == 0 then
            print("[AutoChain] Командиры не найдены")
            return
        end
        local model = cmds[1].model
        print("[AutoChain] ══════ Атрибуты: " .. model.Name .. " ══════")
        local attrs = model:GetAttributes()
        if next(attrs) then
            for k, v in pairs(attrs) do
                print(string.format("  Attr [%s] = %s (%s)", k, tostring(v), type(v)))
            end
        else
            print("  (атрибутов нет)")
        end
        print("[AutoChain] ── Value-объекты ──")
        for _, child in ipairs(model:GetChildren()) do
            if child:IsA("ValueBase") then
                print(string.format("  %s (%s) = %s", child.Name, child.ClassName, tostring(child.Value)))
            end
        end
        print("[AutoChain] ═══════════════════════════════")
        Rayfield:Notify({ Title="Отладка", Content="Атрибуты в консоли (F9)", Duration=3, Image="rbxassetid://4483345998" })
    end,
})

-- ── Вкладка: Помощь ──────────────────────────────────────────
local HelpTab = Window:CreateTab("❓ Помощь", nil)

HelpTab:CreateSection("Быстрый старт")
HelpTab:CreateLabel("1. Разместить 3 Командира (уровень 2+)")
HelpTab:CreateLabel("2. Нажать '🔄 Пересканировать командиров'")
HelpTab:CreateLabel("3. Включить '🔗 Включить Commander Chain'")
HelpTab:CreateLabel("4. Цепочка запущена — бафф не прерывается")

HelpTab:CreateSection("Почему нужно 3 командира?")
HelpTab:CreateLabel("Бафф: 10с, Кулдаун: 30с")
HelpTab:CreateLabel("T=0с  → Активируем A")
HelpTab:CreateLabel("T=10с → Активируем B (бафф A кончился)")
HelpTab:CreateLabel("T=20с → Активируем C (бафф B кончился)")
HelpTab:CreateLabel("T=30с → Снова A (КД закончился — цикл!)")

HelpTab:CreateSection("Устранение неполадок")
HelpTab:CreateLabel("❌ Командиры не найдены:")
HelpTab:CreateLabel("   → Убедись что Tower Type = 'Commander'")
HelpTab:CreateLabel("   → Башни должны принадлежать твоему аккаунту")
HelpTab:CreateLabel("❌ Цепочка прерывается:")
HelpTab:CreateLabel("   → Увеличь 'Упреждение активации' до 1.0с")
HelpTab:CreateLabel("   → Проверь уровни командиров (нужен ур.2+)")

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 10: АВТООЧИСТКА
-- ═══════════════════════════════════════════════════════════════

Players.PlayerRemoving:Connect(function(p)
    if p == LocalPlayer then StopAutoChain() end
end)

print("[AutoChain] v2.0 загружен. Открой интерфейс и нажми 'Пересканировать командиров'.")
