--[[
    AutoSkip — TDS: S.O.L.A.R
    Версия: 1.1.0

    ПРИНЦИП РАБОТЫ:
    Skip.Need всегда = 0 в этой игре.
    Сервер принимает скип в любой момент между волнами (result=true).
    Поэтому слушаем изменение Wave в State и сразу отправляем скип.
    Также отправляем скип по таймеру на случай если Wave не меняется.
]]

local function SafeInit()

-- ═══════════════════════════════════════════════════════════════
-- СЕРВИСЫ
-- ═══════════════════════════════════════════════════════════════

local Players, ReplicatedStorage
do
    local ok
    ok, Players           = pcall(game.GetService, game, "Players")
    if not ok then error("Players: " .. tostring(Players)) end
    ok, ReplicatedStorage = pcall(game.GetService, game, "ReplicatedStorage")
    if not ok then error("ReplicatedStorage: " .. tostring(ReplicatedStorage)) end
end

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then error("LocalPlayer не найден") end

-- RemoteFunction
local RemoteFunction
do
    local Resources = ReplicatedStorage:WaitForChild("Resources", 10)
    if not Resources then error("Resources не найден") end

    local Universal = Resources:FindFirstChild("Universal")
    if Universal then
        local Network = Universal:FindFirstChild("Network")
        if Network then
            RemoteFunction = Network:FindFirstChild("RemoteFunction")
        end
    end

    if not RemoteFunction then
        local Network = Resources:FindFirstChild("Network")
        if Network then
            RemoteFunction = Network:FindFirstChild("RemoteFunction")
        end
    end

    if not RemoteFunction then error("RemoteFunction не найден") end
end

-- Timer.Enabled из State — true когда идёт отсчёт между волнами
local StateFolder = ReplicatedStorage:WaitForChild("State", 10)
if not StateFolder then error("State не найден") end

local TimerFolder = StateFolder:WaitForChild("Timer", 10)
if not TimerFolder then error("State.Timer не найден") end

local TimerEnabled = TimerFolder:WaitForChild("Enabled", 5)
if not TimerEnabled then error("Timer.Enabled не найден") end

warn("[AutoSkip] Инициализация: OK")

-- ═══════════════════════════════════════════════════════════════
-- СОСТОЯНИЕ
-- ═══════════════════════════════════════════════════════════════

local State = {
    Enabled     = false,
    Connections = {},   -- все подключения для отключения при стопе
    Thread      = nil,  -- поток таймера
    SkipCount   = 0,
    LastSkipTime = 0,   -- защита от спама
}

local SKIP_COOLDOWN = 3.0  -- минимум секунд между скипами

-- ═══════════════════════════════════════════════════════════════
-- ЛОГИКА СКИПА
-- ═══════════════════════════════════════════════════════════════

local function SendSkip(reason)
    if not State.Enabled then return false end

    -- Защита от спама
    local now = os.clock()
    if now - State.LastSkipTime < SKIP_COOLDOWN then
        return false
    end

    local ok, result = pcall(function()
        return RemoteFunction:InvokeServer("Voting", "Skip")
    end)

    if ok and result ~= false then
        State.SkipCount   += 1
        State.LastSkipTime = os.clock()
        warn(string.format("[AutoSkip] Скип #%d (%s)", State.SkipCount, reason or ""))
        return true
    end

    return false
end

local function StartAutoSkip()
    if State.Enabled then return end
    State.Enabled      = true
    State.LastSkipTime = 0

    -- Сразу пробуем скипнуть текущую волну
    task.delay(0.3, function()
        if State.Enabled then SendSkip("старт") end
    end)

    -- Слушаем Timer.Enabled — как только становится true
    -- значит начался отсчёт между волнами и скип доступен
    local timerConn = TimerEnabled.Changed:Connect(function(value)
        if not State.Enabled then return end
        if value == true then
            -- Небольшая задержка чтобы сервер успел открыть голосование
            task.delay(0.2, function()
                if State.Enabled then SendSkip("таймер включился") end
            end)
        end
    end)
    table.insert(State.Connections, timerConn)

    -- Таймер-подстраховка: каждые 5с пробуем скипнуть
    -- на случай если Wave не меняется но скип доступен
    State.Thread = task.spawn(function()
        while State.Enabled do
            task.wait(5)
            if State.Enabled then
                SendSkip("таймер")
            end
        end
    end)

    warn("[AutoSkip] ▶ Запущен")
end

local function StopAutoSkip()
    if not State.Enabled then return end
    State.Enabled = false

    for _, conn in ipairs(State.Connections) do
        conn:Disconnect()
    end
    State.Connections = {}

    if State.Thread then
        task.cancel(State.Thread)
        State.Thread = nil
    end

    warn(string.format("[AutoSkip] ⏹ Остановлен. Скипов: %d", State.SkipCount))
end

-- ═══════════════════════════════════════════════════════════════
-- UI — ПЕРЕТАСКИВАЕМАЯ КНОПКА
-- ═══════════════════════════════════════════════════════════════

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name           = "AutoSkipGui"
ScreenGui.ResetOnSpawn   = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder   = 99
ScreenGui.IgnoreGuiInset = true
ScreenGui.Parent         = LocalPlayer:WaitForChild("PlayerGui")

local Frame = Instance.new("Frame")
Frame.Name               = "Frame"
Frame.Size               = UDim2.new(0, 160, 0, 44)
Frame.Position           = UDim2.new(0, 20, 0.5, 0)
Frame.BackgroundColor3   = Color3.fromRGB(30, 30, 30)
Frame.BorderSizePixel    = 0
Frame.Active             = true
Frame.Parent             = ScreenGui

local Corner = Instance.new("UICorner")
Corner.CornerRadius = UDim.new(0, 8)
Corner.Parent       = Frame

local Stroke = Instance.new("UIStroke")
Stroke.Color     = Color3.fromRGB(60, 60, 60)
Stroke.Thickness = 1
Stroke.Parent    = Frame

-- Цветная полоска слева — индикатор состояния
local StatusBar = Instance.new("Frame")
StatusBar.Size             = UDim2.new(0, 4, 1, 0)
StatusBar.Position         = UDim2.new(0, 0, 0, 0)
StatusBar.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
StatusBar.BorderSizePixel  = 0
StatusBar.Parent           = Frame

local StatusBarCorner = Instance.new("UICorner")
StatusBarCorner.CornerRadius = UDim.new(0, 8)
StatusBarCorner.Parent       = StatusBar

local Icon = Instance.new("TextLabel")
Icon.Size               = UDim2.new(0, 30, 1, 0)
Icon.Position           = UDim2.new(0, 10, 0, 0)
Icon.BackgroundTransparency = 1
Icon.Text               = "⏭"
Icon.TextColor3         = Color3.fromRGB(200, 200, 200)
Icon.TextSize           = 18
Icon.Font               = Enum.Font.GothamBold
Icon.Parent             = Frame

local Label = Instance.new("TextLabel")
Label.Size              = UDim2.new(1, -50, 0, 22)
Label.Position          = UDim2.new(0, 44, 0, 4)
Label.BackgroundTransparency = 1
Label.Text              = "AutoSkip: OFF"
Label.TextColor3        = Color3.fromRGB(200, 200, 200)
Label.TextSize          = 13
Label.Font              = Enum.Font.GothamBold
Label.TextXAlignment    = Enum.TextXAlignment.Left
Label.Parent            = Frame

local Counter = Instance.new("TextLabel")
Counter.Size            = UDim2.new(1, -50, 0, 14)
Counter.Position        = UDim2.new(0, 44, 1, -18)
Counter.BackgroundTransparency = 1
Counter.Text            = "Скипов: 0"
Counter.TextColor3      = Color3.fromRGB(120, 120, 120)
Counter.TextSize        = 11
Counter.Font            = Enum.Font.Gotham
Counter.TextXAlignment  = Enum.TextXAlignment.Left
Counter.Parent          = Frame

local Button = Instance.new("TextButton")
Button.Size             = UDim2.new(1, 0, 1, 0)
Button.BackgroundTransparency = 1
Button.Text             = ""
Button.ZIndex           = 2
Button.Parent           = Frame

-- ── Обновление UI ───────────────────────────────────────────

local function UpdateUI()
    Counter.Text = "Скипов: " .. State.SkipCount
    if State.Enabled then
        Label.Text                 = "AutoSkip: ON"
        Label.TextColor3           = Color3.fromRGB(255, 255, 255)
        StatusBar.BackgroundColor3 = Color3.fromRGB(100, 220, 100)
        Stroke.Color               = Color3.fromRGB(100, 220, 100)
        Frame.BackgroundColor3     = Color3.fromRGB(35, 35, 35)
    else
        Label.Text                 = "AutoSkip: OFF"
        Label.TextColor3           = Color3.fromRGB(200, 200, 200)
        StatusBar.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
        Stroke.Color               = Color3.fromRGB(60, 60, 60)
        Frame.BackgroundColor3     = Color3.fromRGB(30, 30, 30)
    end
end

-- Обновляем счётчик после каждого скипа
local _sendSkip = SendSkip
SendSkip = function(reason)
    local result = _sendSkip(reason)
    if result then UpdateUI() end
    return result
end

-- ── Клик ────────────────────────────────────────────────────

Button.MouseButton1Click:Connect(function()
    if State.Enabled then
        StopAutoSkip()
    else
        StartAutoSkip()
    end
    UpdateUI()
end)

-- ── Перетаскивание ──────────────────────────────────────────

local UIS         = game:GetService("UserInputService")
local dragging    = false
local dragStart   = nil
local frameStart  = nil

Button.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging   = true
        dragStart  = input.Position
        frameStart = Frame.Position
    end
end)

Button.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

UIS.InputChanged:Connect(function(input)
    if not dragging then return end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement
    and input.UserInputType ~= Enum.UserInputType.Touch then return end

    local delta    = input.Position - dragStart
    local viewport = workspace.CurrentCamera.ViewportSize
    local size     = Frame.AbsoluteSize

    local newX = math.clamp(frameStart.X.Offset + delta.X, 0, viewport.X - size.X)
    local newY = math.clamp(frameStart.Y.Offset + delta.Y, 0, viewport.Y - size.Y)

    Frame.Position = UDim2.new(0, newX, 0, newY)
end)

-- Фиксируем начальную позицию в пикселях
task.defer(function()
    local abs = Frame.AbsolutePosition
    Frame.Position = UDim2.new(0, abs.X, 0, abs.Y)
end)

-- ── Очистка ─────────────────────────────────────────────────

Players.PlayerRemoving:Connect(function(p)
    if p == LocalPlayer then
        pcall(StopAutoSkip)
        pcall(function() ScreenGui:Destroy() end)
    end
end)

UpdateUI()
warn("[AutoSkip] v1.1 загружен")

end -- SafeInit

local ok, err = pcall(SafeInit)
if not ok then
    warn("КРИТИЧЕСКАЯ ОШИБКА: " .. tostring(err))
    warn("Причины: не загружена игра / лобби / нет интернета")
end
