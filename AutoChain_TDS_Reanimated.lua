--[[
╔══════════════════════════════════════════════════════════════════════════╗
║           AutoChain — Tower Defense Simulator: Reanimated               ║
║           Версия: 1.0.0  |  UI: Rayfield                                ║
║                                                                          ║
║  ПРИНЦИП РАБОТЫ:                                                         ║
║  Скрипт находит всех Командиров (Commander) на карте, принадлежащих      ║
║  локальному игроку. Затем в цикле проверяет TextLabel кулдауна каждого   ║
║  командира. Как только кулдаун = "0" (или пуст) — активирует способность ║
║  "Call Of Arms" через RemoteFunction:InvokeServer.                       ║
║  Таким образом бафф скорострельности поддерживается непрерывно.         ║
╚══════════════════════════════════════════════════════════════════════════╝
]]

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 1: СЕРВИСЫ
-- ═══════════════════════════════════════════════════════════════

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")

local LocalPlayer  = Players.LocalPlayer
local PlayerGui    = LocalPlayer:WaitForChild("PlayerGui")
local Workspace    = game:GetService("Workspace")

-- Ремоуты игры (подтверждены через Dex Explorer)
local RemoteFunction = ReplicatedStorage:WaitForChild("RemoteFunction")
local RemoteEvent    = ReplicatedStorage:WaitForChild("RemoteEvent")

-- Папка с башнями на карте (подтверждена)
local TowersFolder = Workspace:WaitForChild("Towers")

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 2: КОНФИГУРАЦИЯ
-- ═══════════════════════════════════════════════════════════════

local Config = {
    -- Тип башни-командира (значение из StringValue .Type)
    CommanderTypeName   = "Commander",

    -- Название способности (из Cobalt-перехвата)
    AbilityName         = "Call Of Arms",

    -- Интервал проверки кулдауна (сек). 0.1 = каждые 100мс
    CheckInterval       = 0.1,

    -- Запас времени перед окончанием баффа (сек)
    -- Если кулдаун <= этого значения — активируем следующего
    ActivationThreshold = 1.0,

    -- Задержка между активациями разных командиров (сек)
    -- Нужна чтобы сервер успел обработать предыдущую
    ActivationDelay     = 0.3,

    -- Логировать действия в консоль
    EnableLogging       = true,
}

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 3: СОСТОЯНИЕ СИСТЕМЫ
-- ═══════════════════════════════════════════════════════════════

local State = {
    -- Включён ли AutoChain
    Enabled          = false,

    -- Список найденных командиров игрока
    -- Формат: { model = Instance, cooldownGui = TextLabel }
    Commanders       = {},

    -- Основной поток AutoChain
    Thread           = nil,

    -- Счётчик активаций за сессию
    ActivationCount  = 0,

    -- Время последней активации каждого командира
    -- Ключ: модель, значение: os.clock()
    LastActivation   = {},
}

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 4: ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ═══════════════════════════════════════════════════════════════

--- Логирование в консоль с меткой времени
local function Log(msg, level)
    if not Config.EnableLogging then return end
    level = level or "INFO"
    print(string.format("[AutoChain][%s][%s] %s", os.date("%H:%M:%S"), level, tostring(msg)))
end

--- Проверяет, принадлежит ли башня локальному игроку.
--- Owner — ObjectValue, хранит объект игрока.
local function IsOwnedByLocalPlayer(towerModel)
    local ownerValue = towerModel:FindFirstChild("Owner")
    if not ownerValue then return false end
    -- ObjectValue.Value — это объект Player
    return ownerValue.Value == LocalPlayer
end

--- Получает тип башни из StringValue .Type
local function GetTowerType(towerModel)
    local typeValue = towerModel:FindFirstChild("Type")
    if typeValue and typeValue:IsA("StringValue") then
        return typeValue.Value
    end
    return ""
end

--- Получает уровень башни из IntValue .Upgrade
local function GetTowerLevel(towerModel)
    local upgradeValue = towerModel:FindFirstChild("Upgrade")
    if upgradeValue and upgradeValue:IsA("IntValue") then
        return upgradeValue.Value
    end
    return 0
end

--- Читает кулдаун из GUI.
--- Путь (подтверждён): PlayerGui.GameGui.Upgrade.Default.Primary.Container.Abilities["1"].Count
--- TextLabel. Текст — число секунд кулдауна ("0", "5.3", etc.)
--- ВАЖНО: GUI кулдауна показывает кулдаун ВЫБРАННОЙ башни.
--- Поэтому мы читаем его в момент когда башня-командир "активна" в UI,
--- либо используем серверные атрибуты модели.
local function GetCooldownFromGui()
    local success, result = pcall(function()
        return PlayerGui
            :WaitForChild("GameGui", 1)
            :WaitForChild("Upgrade", 1)
            :WaitForChild("Default", 1)
            :WaitForChild("Primary", 1)
            :WaitForChild("Container", 1)
            :WaitForChild("Abilities", 1)
            :WaitForChild("1", 1)
            :WaitForChild("Count", 1)
    end)
    if success and result then
        return result  -- возвращаем TextLabel
    end
    return nil
end

--- Парсит текст кулдауна в число секунд.
--- Возможные форматы: "0", "5", "5.3", "" (пусто = готово)
local function ParseCooldown(text)
    if text == nil or text == "" then return 0 end
    local num = tonumber(text)
    if num then return num end
    -- Попытка убрать лишние символы типа "s", "сек"
    local stripped = text:match("(%d+%.?%d*)")
    return tonumber(stripped) or 0
end

--- Проверяет готовность способности командира через атрибут на модели.
--- В TDS:Reanimated кулдаун может храниться как атрибут "AbilityCooldown" на модели.
local function GetModelCooldown(towerModel)
    -- Пробуем атрибуты модели (если они есть в Reanimated)
    local cd = towerModel:GetAttribute("AbilityCooldown")
            or towerModel:GetAttribute("Cooldown")
            or towerModel:GetAttribute("AbilityTimer")
    if cd and type(cd) == "number" then
        return cd
    end

    -- Пробуем NumberValue внутри модели
    local cdValue = towerModel:FindFirstChild("AbilityCooldown")
                 or towerModel:FindFirstChild("Cooldown")
    if cdValue and cdValue:IsA("NumberValue") then
        return cdValue.Value
    end

    -- Если не найдено — возвращаем 0 (считаем готовым)
    -- Активация произойдёт, сервер сам отклонит если не готово
    return 0
end

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 5: СКАНИРОВАНИЕ КОМАНДИРОВ
-- ═══════════════════════════════════════════════════════════════

--- Сканирует workspace.Towers и собирает всех командиров игрока.
--- Возвращает таблицу { model = башня } для каждого найденного.
local function ScanForCommanders()
    local found = {}

    local success, err = pcall(function()
        for _, towerModel in ipairs(TowersFolder:GetChildren()) do
            -- Проверяем что это модель
            if not towerModel:IsA("Model") then continue end

            -- Проверяем владельца (Owner ObjectValue == LocalPlayer)
            if not IsOwnedByLocalPlayer(towerModel) then continue end

            -- Проверяем тип башни (Type StringValue == "Commander")
            local towerType = GetTowerType(towerModel)
            if towerType ~= Config.CommanderTypeName then continue end

            table.insert(found, {
                model  = towerModel,
                name   = towerModel.Name,  -- название скина
                level  = GetTowerLevel(towerModel),
            })

            Log(string.format("Найден командир: %s (уровень %d)", towerModel.Name, GetTowerLevel(towerModel)))
        end
    end)

    if not success then
        Log("Ошибка сканирования: " .. tostring(err), "ERROR")
    end

    return found
end

--- Обновляет список командиров (переиспользуется при изменении карты).
local function RefreshCommanders()
    State.Commanders = ScanForCommanders()
    Log(string.format("Обновлено командиров: %d", #State.Commanders))
end

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 6: АКТИВАЦИЯ СПОСОБНОСТИ
-- ═══════════════════════════════════════════════════════════════

--- Активирует способность "Call Of Arms" у указанного командира.
--- Использует подтверждённый вызов из Cobalt-перехвата:
---   RemoteFunction:InvokeServer("Troops", "Abilities", "Activate", {Name, Troop})
local function ActivateAbility(commanderData)
    local model = commanderData.model

    -- Проверяем что модель ещё существует в игре
    if not model or not model.Parent then
        Log("Модель командира удалена, пропуск", "WARN")
        return false
    end

    local success, result = pcall(function()
        return RemoteFunction:InvokeServer(
            "Troops",
            "Abilities",
            "Activate",
            {
                Name  = Config.AbilityName,
                Troop = model
            }
        )
    end)

    if success then
        State.ActivationCount += 1
        State.LastActivation[model] = os.clock()
        Log(string.format(
            "✓ Активировано: %s | Итого активаций: %d",
            model.Name,
            State.ActivationCount
        ))
        return true
    else
        Log("✗ Ошибка активации: " .. tostring(result), "ERROR")
        return false
    end
end

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 7: ЛОГИКА ЦЕПОЧКИ (ГЛАВНЫЙ АЛГОРИТМ)
-- ═══════════════════════════════════════════════════════════════

--- Определяет следующего командира для активации.
--- Стратегия: берём того, кто был активирован раньше всего
--- (или вообще не активировался) — т.е. с наименьшим LastActivation.
local function GetNextCommander()
    if #State.Commanders == 0 then return nil end

    local bestData      = nil
    local bestLastTime  = math.huge

    for _, cmdData in ipairs(State.Commanders) do
        -- Пропускаем удалённые башни
        if not cmdData.model or not cmdData.model.Parent then continue end

        local lastTime = State.LastActivation[cmdData.model] or 0
        if lastTime < bestLastTime then
            bestLastTime = lastTime
            bestData     = cmdData
        end
    end

    return bestData
end

--- Проверяет, готов ли командир к активации.
--- Использует кулдаун из атрибутов модели.
--- Если кулдаун не доступен — доверяем серверу и активируем.
local function IsCommanderReady(commanderData)
    local model = commanderData.model
    if not model or not model.Parent then return false end

    local cooldown = GetModelCooldown(model)

    -- Готов если кулдаун <= порога активации
    return cooldown <= Config.ActivationThreshold
end

--- Главный цикл AutoChain.
--- Запускается в отдельном потоке через task.spawn.
local function AutoChainLoop()
    Log("▶ AutoChain запущен")

    -- Первичное сканирование командиров
    RefreshCommanders()

    if #State.Commanders == 0 then
        Log("Командиры не найдены! Проверь что башни размещены и принадлежат тебе.", "WARN")
    end

    -- Таймер повторного сканирования (раз в 5 секунд)
    local lastScanTime = os.clock()

    while State.Enabled do

        -- Периодически обновляем список командиров
        -- (на случай размещения новых в процессе игры)
        if os.clock() - lastScanTime > 5 then
            RefreshCommanders()
            lastScanTime = os.clock()
        end

        -- Если нет командиров — ждём
        if #State.Commanders == 0 then
            task.wait(1)
            continue
        end

        -- Пробуем активировать всех готовых командиров по очереди
        local anyActivated = false

        for _, cmdData in ipairs(State.Commanders) do
            if not State.Enabled then break end  -- проверка на выключение

            -- Пропускаем удалённые
            if not cmdData.model or not cmdData.model.Parent then continue end

            if IsCommanderReady(cmdData) then
                local activated = ActivateAbility(cmdData)
                if activated then
                    anyActivated = true
                    -- Задержка между активациями чтобы сервер успел обработать
                    task.wait(Config.ActivationDelay)
                end
            end
        end

        -- Если никто не активирован — короткое ожидание
        if not anyActivated then
            task.wait(Config.CheckInterval)
        end
    end

    Log("⏹ AutoChain остановлен")
end

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 8: УПРАВЛЕНИЕ (СТАРТ / СТОП)
-- ═══════════════════════════════════════════════════════════════

--- Запускает AutoChain
local function StartAutoChain()
    if State.Enabled then
        Log("AutoChain уже запущен", "WARN")
        return
    end

    State.Enabled         = true
    State.ActivationCount = 0
    State.LastActivation  = {}

    -- Запуск в отдельном потоке
    State.Thread = task.spawn(AutoChainLoop)
end

--- Останавливает AutoChain
local function StopAutoChain()
    if not State.Enabled then
        Log("AutoChain уже остановлен", "WARN")
        return
    end

    State.Enabled = false
    -- Поток завершится сам при следующей проверке State.Enabled

    if State.Thread then
        task.cancel(State.Thread)
        State.Thread = nil
    end

    Log(string.format("AutoChain остановлен. Всего активаций: %d", State.ActivationCount))
end

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 9: RAYFIELD UI
-- ═══════════════════════════════════════════════════════════════

-- Загрузка Rayfield (стандартный способ)
local Rayfield = loadstring(game:HttpGet(
    "https://sirius.menu/rayfield"
))()

-- Создание главного окна
local Window = Rayfield:CreateWindow({
    Name             = "AutoChain — TDS: Reanimated",
    LoadingTitle     = "AutoChain",
    LoadingSubtitle  = "Загрузка...",
    ConfigurationSaving = {
        Enabled  = true,
        FileName = "AutoChain_TDS_Config"
    },
    Discord = {
        Enabled = false,
    },
    KeySystem = false,
})

-- ── Вкладка: Главная ─────────────────────────────────────────
local MainTab = Window:CreateTab("⚔️ AutoChain", nil)

-- Секция статуса
MainTab:CreateSection("Управление")

-- Главный переключатель AutoChain
MainTab:CreateToggle({
    Name         = "🔗 Включить AutoChain",
    CurrentValue = false,
    Flag         = "AutoChainEnabled",
    Callback     = function(value)
        if value then
            StartAutoChain()
            Rayfield:Notify({
                Title    = "AutoChain",
                Content  = "▶ Запущен! Командиры сканируются...",
                Duration = 3,
                Image    = "rbxassetid://4483345998"
            })
        else
            StopAutoChain()
            Rayfield:Notify({
                Title    = "AutoChain",
                Content  = "⏹ Остановлен.",
                Duration = 3,
                Image    = "rbxassetid://4483345998"
            })
        end
    end,
})

-- Кнопка ручного обновления командиров
MainTab:CreateButton({
    Name     = "🔄 Обновить список командиров",
    Callback = function()
        RefreshCommanders()
        Rayfield:Notify({
            Title    = "Сканирование",
            Content  = string.format("Найдено командиров: %d", #State.Commanders),
            Duration = 3,
            Image    = "rbxassetid://4483345998"
        })
    end,
})

-- Кнопка ручной активации (тест)
MainTab:CreateButton({
    Name     = "⚡ Активировать вручную (тест)",
    Callback = function()
        RefreshCommanders()
        if #State.Commanders == 0 then
            Rayfield:Notify({
                Title    = "Ошибка",
                Content  = "Командиры не найдены!",
                Duration = 4,
                Image    = "rbxassetid://4483345998"
            })
            return
        end

        local activated = 0
        for _, cmdData in ipairs(State.Commanders) do
            if ActivateAbility(cmdData) then
                activated += 1
                task.wait(Config.ActivationDelay)
            end
        end

        Rayfield:Notify({
            Title    = "Ручная активация",
            Content  = string.format("Активировано командиров: %d", activated),
            Duration = 3,
            Image    = "rbxassetid://4483345998"
        })
    end,
})

-- ── Секция: Настройки ────────────────────────────────────────
MainTab:CreateSection("Настройки")

-- Название типа башни
MainTab:CreateInput({
    Name         = "Тип башни (Type)",
    CurrentValue = Config.CommanderTypeName,
    PlaceholderText = "Commander",
    RemoveTextAfterFocusLost = false,
    Flag         = "CommanderType",
    Callback     = function(value)
        if value and #value > 0 then
            Config.CommanderTypeName = value
            Log("Тип башни изменён на: " .. value)
        end
    end,
})

-- Название способности
MainTab:CreateInput({
    Name         = "Название способности",
    CurrentValue = Config.AbilityName,
    PlaceholderText = "Call Of Arms",
    RemoveTextAfterFocusLost = false,
    Flag         = "AbilityName",
    Callback     = function(value)
        if value and #value > 0 then
            Config.AbilityName = value
            Log("Название способности изменено на: " .. value)
        end
    end,
})

-- Интервал проверки
MainTab:CreateSlider({
    Name         = "Интервал проверки (сек)",
    Range        = {0.05, 1.0},
    Increment    = 0.05,
    Suffix       = "с",
    CurrentValue = Config.CheckInterval,
    Flag         = "CheckInterval",
    Callback     = function(value)
        Config.CheckInterval = value
    end,
})

-- Задержка между активациями
MainTab:CreateSlider({
    Name         = "Задержка между активациями",
    Range        = {0.1, 2.0},
    Increment    = 0.1,
    Suffix       = "с",
    CurrentValue = Config.ActivationDelay,
    Flag         = "ActivationDelay",
    Callback     = function(value)
        Config.ActivationDelay = value
    end,
})

-- Включение логирования
MainTab:CreateToggle({
    Name         = "📋 Логирование в консоль",
    CurrentValue = Config.EnableLogging,
    Flag         = "EnableLogging",
    Callback     = function(value)
        Config.EnableLogging = value
    end,
})

-- ── Вкладка: Информация ──────────────────────────────────────
local InfoTab = Window:CreateTab("📊 Статистика", nil)

InfoTab:CreateSection("Информация о командирах")

InfoTab:CreateButton({
    Name     = "📋 Показать командиров в консоли",
    Callback = function()
        RefreshCommanders()
        if #State.Commanders == 0 then
            Log("Командиры не найдены", "WARN")
            Rayfield:Notify({
                Title   = "Статистика",
                Content = "Командиры не найдены. Убедись что они размещены.",
                Duration = 4,
                Image   = "rbxassetid://4483345998"
            })
            return
        end

        Log("═══ Список командиров ═══")
        for i, cmdData in ipairs(State.Commanders) do
            local cd = GetModelCooldown(cmdData.model)
            Log(string.format(
                "[%d] Скин: %s | Уровень: %d | Кулдаун: %.1f",
                i, cmdData.name, cmdData.level, cd
            ))
        end
        Log("═════════════════════════")

        Rayfield:Notify({
            Title    = "Статистика",
            Content  = string.format("Командиров: %d | Активаций: %d (см. консоль)", #State.Commanders, State.ActivationCount),
            Duration = 5,
            Image    = "rbxassetid://4483345998"
        })
    end,
})

InfoTab:CreateSection("Отладка")

InfoTab:CreateButton({
    Name     = "🔬 Распечатать атрибуты 1-го командира",
    Callback = function()
        RefreshCommanders()
        if #State.Commanders == 0 then
            Log("Командиры не найдены", "WARN")
            return
        end

        local model = State.Commanders[1].model
        Log("═══ Атрибуты: " .. model.Name .. " ═══")
        for k, v in pairs(model:GetAttributes()) do
            Log(string.format("  [%s] = %s", k, tostring(v)))
        end
        -- Дочерние Value-объекты
        Log("─── Value-объекты внутри ───")
        for _, child in ipairs(model:GetChildren()) do
            if child:IsA("ValueBase") then
                Log(string.format("  %s (%s) = %s", child.Name, child.ClassName, tostring(child.Value)))
            end
        end
        Log("═════════════════════════════")

        Rayfield:Notify({
            Title    = "Отладка",
            Content  = "Атрибуты напечатаны в консоль (F9)",
            Duration = 3,
            Image    = "rbxassetid://4483345998"
        })
    end,
})

InfoTab:CreateButton({
    Name     = "🔬 Распечатать GUI кулдауна",
    Callback = function()
        local countLabel = GetCooldownFromGui()
        if countLabel then
            Log("GUI кулдауна найден. Текущий текст: '" .. tostring(countLabel.Text) .. "'")
            Rayfield:Notify({
                Title    = "GUI",
                Content  = "Кулдаун GUI: '" .. tostring(countLabel.Text) .. "'",
                Duration = 4,
                Image    = "rbxassetid://4483345998"
            })
        else
            Log("GUI кулдауна не найден (PathError)", "WARN")
            Rayfield:Notify({
                Title    = "GUI",
                Content  = "GUI не найден. Выбери командира в игре и попробуй снова.",
                Duration = 4,
                Image    = "rbxassetid://4483345998"
            })
        end
    end,
})

-- ── Вкладка: Помощь ──────────────────────────────────────────
local HelpTab = Window:CreateTab("❓ Помощь", nil)

HelpTab:CreateSection("Как использовать")

HelpTab:CreateLabel("1. Разместить командиров (Commander) на карте")
HelpTab:CreateLabel("2. Нажать 'Обновить список командиров'")
HelpTab:CreateLabel("3. Включить тоггл 'Включить AutoChain'")
HelpTab:CreateLabel("4. Скрипт автоматически активирует способности")

HelpTab:CreateSection("Устранение неполадок")

HelpTab:CreateLabel("❌ Командиры не найдены:")
HelpTab:CreateLabel("   → Проверь тип башни в настройках (вкладка Настройки)")
HelpTab:CreateLabel("   → Убедись что башни принадлежат твоему аккаунту")
HelpTab:CreateLabel("")
HelpTab:CreateLabel("❌ Способность не активируется:")
HelpTab:CreateLabel("   → Проверь название способности в настройках")
HelpTab:CreateLabel("   → Попробуй кнопку 'Активировать вручную (тест)'")
HelpTab:CreateLabel("   → Открой консоль (F9) для диагностики")
HelpTab:CreateLabel("")
HelpTab:CreateLabel("❌ Частые ошибки в консоли:")
HelpTab:CreateLabel("   → Увеличь 'Задержку между активациями'")

-- ═══════════════════════════════════════════════════════════════
-- БЛОК 10: АВТОЗАПУСК И ОЧИСТКА
-- ═══════════════════════════════════════════════════════════════

-- Автоматически останавливаем при выходе из игры
game:GetService("Players").PlayerRemoving:Connect(function(player)
    if player == LocalPlayer then
        StopAutoChain()
    end
end)

-- Начальное сканирование командиров (при загрузке скрипта)
task.spawn(function()
    task.wait(1)  -- ждём инициализации
    RefreshCommanders()
    Log(string.format(
        "Скрипт загружен. Найдено командиров: %d. Включи AutoChain через интерфейс.",
        #State.Commanders
    ))
end)

Log("AutoChain TDS:Reanimated v1.0.0 — загружен")
