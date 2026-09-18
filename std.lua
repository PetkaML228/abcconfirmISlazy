-- Slop Tower Defense / Fluent Hub V2
-- Remotes и координаты: baseline пользователя; реальный Roblox/Delta здесь не проверен.
-- Первый запуск V2 после V1: полностью переподключитесь к серверу.
-- Хук не читает ответы сервера: запись содержит попытки вызовов, а не доказанные покупки.
-- Внутри hook: только снимок аргументов/кэшированных данных. Никаких Roblox :методов.
-- Исходный вызов выполняется РОВНО ОДИН РАЗ: return previous(self, ...).
-- Запись: Start -> ручные Spawn/Upgrade -> Stop -> дождаться очереди -> Save.
-- Play: свежий матч, та же карта и набор башен. Порог = Cash ДО ручного вызова.
-- Макросы: SlopTowerDefenseHub/macros/*.json. Удаление: копия в trash + удаление оригинала.
-- Auto Leave имеет приоритет над Replay; один запрос на показ EndScreen.
-- После смены Place запустите файл снова. queue_on_teleport не устанавливается.
-- AntiMacro оставлен в исходной опциональной схеме; протокол не подтверждён.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local WS = game:GetService("Workspace")
local Http = game:GetService("HttpService")
local VU = game:GetService("VirtualUser")
local LP = Players.LocalPlayer
assert(LP, "Запустите скрипт после входа в игру")
assert(type(loadstring) == "function", "Нет loadstring")
local G = (type(getgenv) == "function" and getgenv()) or _G
local ROOT = "SlopTowerDefenseHub"
local LIMIT = { Steps = 5000, Bytes = 4 * 1024 * 1024, Nodes = 50000, Depth = 16 }
local MAPS = {
    "Area 51", "Base", "BrainrotEndless", "Cooking Stove", "Crossroads", "Desert",
    "Doomspire", "Dungeon", "FairyEndless", "GardenEndless", "Gold Base", "Happy Home",
    "Kitchen Table", "KitchenEndless", "Level 1", "Level 2", "Level 3", "Night Base",
    "NightPlot", "Plot", "Raid", "RetroEndless", "RichPlot", "Ruined City",
    "SpaceEndless", "Summer Raid", "SummerEndless", "The Fridge", "Toilet City", "ToiletEndless",
}
local ELEVATORS = { "Elevator1", "Elevator2", "Elevator3", "Elevator4", "Elevator5", "Elevator6" }
local ELEVATOR_POS = {
    Elevator6 = Vector3.new(-11, 61, 100),
    Elevator1 = Vector3.new(-10, 70.5, 142),
}

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end
local function safeName(v)
    return type(v) == "string" and #v >= 1 and #v <= 64 and v:match("^[%w_%-]+$") ~= nil
end
local function array(t, maximum)
    assert(type(t) == "table", "Ожидался массив")
    local n, count = #t, 0
    assert(n <= maximum, "Слишком большой массив")
    for k in pairs(t) do
        assert(type(k) == "number" and k % 1 == 0 and k >= 1 and k <= n, "Повреждён массив")
        count = count + 1
    end
    assert(count == n, "Пропуски в массиве")
    return n
end
local function budget(b, depth)
    b.n = b.n + 1
    assert(depth <= LIMIT.Depth and b.n <= LIMIT.Nodes, "Превышен лимит сериализации")
end
local function encode(v, b, depth, seen)
    b, depth, seen = b or { n = 0 }, depth or 0, seen or {}
    budget(b, depth)
    local ty = typeof(v)
    if ty == "nil" then return { t = "nil" } end
    if ty == "boolean" or ty == "string" then return { t = ty, v = v } end
    if ty == "number" then assert(finite(v), "Неконечное число"); return { t = ty, v = v } end
    if ty == "CFrame" then return { t = "CFrame", v = { v:GetComponents() } } end
    if ty == "Vector3" then return { t = "Vector3", v = { v.X, v.Y, v.Z } } end
    if ty == "Vector2" then return { t = "Vector2", v = { v.X, v.Y } } end
    assert(ty == "table", "Неподдерживаемый аргумент: " .. ty)
    assert(not seen[v], "Циклическая таблица")
    seen[v] = true
    local entries = {}
    for k, value in next, v do
        assert(type(k) == "string" or type(k) == "number" or type(k) == "boolean", "Неверный ключ")
        entries[#entries + 1] = { encode(k, b, depth + 1, seen), encode(value, b, depth + 1, seen) }
    end
    seen[v] = nil
    return { t = "table", v = entries }
end
local function decode(node, b, depth)
    b, depth = b or { n = 0 }, depth or 0
    budget(b, depth)
    assert(type(node) == "table" and type(node.t) == "string", "Повреждён аргумент")
    local t, v = node.t, node.v
    if t == "nil" then return nil end
    if t == "string" or t == "boolean" then assert(type(v) == t, "Неверный тип"); return v end
    if t == "number" then assert(finite(v), "Неверное число"); return v end
    if t == "CFrame" or t == "Vector3" or t == "Vector2" then
        local n = t == "CFrame" and 12 or (t == "Vector3" and 3 or 2)
        assert(array(v, n) == n, "Неверная размерность")
        for _, x in ipairs(v) do assert(finite(x), "Неверная координата") end
        if t == "CFrame" then return CFrame.new(table.unpack(v)) end
        if t == "Vector3" then return Vector3.new(table.unpack(v)) end
        return Vector2.new(table.unpack(v))
    end
    assert(t == "table", "Неизвестный тип")
    array(v, LIMIT.Nodes)
    local out = {}
    for _, pair in ipairs(v) do
        assert(array(pair, 2) == 2, "Неверная пара")
        local k = decode(pair[1], b, depth + 1)
        local value = decode(pair[2], b, depth + 1)
        assert(type(k) == "string" or type(k) == "number" or type(k) == "boolean", "Неверный ключ")
        assert(value ~= nil and out[k] == nil, "Повторный ключ или nil")
        out[k] = value
    end
    return out
end
local function encodeArgs(args)
    local out, b = {}, { n = 0 }
    for i = 1, args.n do out[i] = encode(args[i], b) end
    return out
end
local function decodeArgs(args)
    local out, b = { n = #args }, { n = 0 }
    for i = 1, #args do out[i] = decode(args[i], b) end
    return out
end
local function validateMacro(data)
    assert(type(data) == "table" and data.format == "STD-MONEY" and data.version == 1,
        "Ожидался STD-MONEY версии 1")
    assert(finite(data.placeId) and finite(data.gameId), "Нет идентификатора игры")
    array(data.steps, LIMIT.Steps)
    local ids = {}
    for i, s in ipairs(data.steps) do
        assert(type(s) == "table" and finite(s.cash) and s.cash >= 0, "Неверный Cash: " .. i)
        assert(type(s.id) == "string" and #s.id <= 40 and s.id:match("^T%d+$"), "Неверный ID")
        if s.kind == "Spawn" then
            assert(not ids[s.id], "Повторный Spawn ID")
            assert(array(s.args, 5) == 5, "Spawn: нужно 5 аргументов")
            local a = decodeArgs(s.args)
            assert(type(a[1]) == "string" and #a[1] > 0 and typeof(a[2]) == "CFrame"
                and type(a[3]) == "boolean" and type(a[4]) == "string" and type(a[5]) == "table",
                "Неожиданная сигнатура SpawnTower")
            ids[s.id] = true
        elseif s.kind == "Upgrade" then
            assert(ids[s.id], "Upgrade без записанного Spawn: " .. s.id)
            assert(type(s.name) == "string" and #s.name > 0, "Нет имени UpgradeTower")
        else error("Неизвестное действие: " .. tostring(s.kind)) end
    end
    return data
end
local function emptyMacro()
    return { format = "STD-MONEY", version = 1, placeId = game.PlaceId,
        gameId = game.GameId, recordingMode = "calls-only", steps = {} }
end

-- V1 уже мог испортить цепочку __namecall. Не пытаемся снимать чужие hooks.
local legacy = G.__STD_NAMECALL_V1
assert(not (type(legacy) == "table" and legacy.installed),
    "Обнаружен hook V1. Полностью переподключитесь к серверу и запустите только V2")
local oldHub = G.__STD_HUB_V2 or G.__STD_HUB_V1
if type(oldHub) == "table" and type(oldHub.Destroy) == "function" then
    local old = oldHub.State
    assert(not old or (not old.pumping and (old.pending or 0) == 0 and not next(old.locks or {})),
        "Предыдущий хаб ещё занят; дождитесь завершения или переподключитесь")
    oldHub.Destroy("Повторный запуск")
end
local okUI, Fluent = pcall(function()
    return loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
end)
assert(okUI and type(Fluent) == "table", "Не удалось загрузить Fluent: " .. tostring(Fluent))
local S = {
    alive = true, recording = false, playing = false, pumping = false,
    playEpoch = 0, recordEpoch = 0, pending = 0, cursor = 1, nextId = 0,
    entries = {}, recRefs = {}, recOwners = {}, playRefs = {}, rawQueue = {},
    queueHead = 1, queueTail = 0, drainScheduled = false, recordCalls = 0,
    cash = nil, cashVersion = 0, connections = {}, locks = {}, workers = {},
    towerSet = {}, towerFolder = nil, recordEnabled = false,
    macro = emptyMacro(), lastError = "Нет", antiStatus = "Ожидание Check",
    lastElevator = -math.huge,
}
local hub = { State = S }
G.__STD_HUB_V2 = hub
local options = Fluent.Options
local function opt(id, fallback)
    local item = options[id]
    if item and item.Value ~= nil then return item.Value end
    return fallback
end
local function notify(message)
    if S.alive and not Fluent.Unloaded then
        pcall(function() Fluent:Notify({ Title = "Slop TD Hub V2", Content = tostring(message), Duration = 6 }) end)
    end
end
local notices = {}
local function problem(key, message)
    S.lastError = tostring(message)
    local now = os.clock()
    if not notices[key] or now - notices[key] > 12 then
        notices[key] = now
        warn("[Slop TD Hub] " .. tostring(message))
        notify(message)
    end
end
local function connect(signal, callback)
    local c = signal:Connect(callback)
    S.connections[#S.connections + 1] = c
    return c
end
local function remote(group, name, class)
    local folder = RS:FindFirstChild(group)
    local r = folder and folder:FindFirstChild(name)
    return r and r:IsA(class) and r or nil
end
local function fire(group, name, ...)
    local r = remote(group, name, "RemoteEvent")
    if not r then return false, "Нет " .. group .. "." .. name end
    return pcall(r.FireServer, r, ...)
end
local function towers() return WS:FindFirstChild("Towers") end
local function towerModel(obj)
    local folder = towers()
    if not folder or typeof(obj) ~= "Instance" then return nil end
    while obj and obj.Parent ~= folder do obj = obj.Parent end
    return obj and obj:IsA("Model") and obj or nil
end
local function pivot(model)
    if not model then return nil end
    local ok, cf = pcall(model.GetPivot, model)
    return ok and cf or nil
end
local function snapshotTowers()
    local set, folder = {}, towers()
    if folder then for _, child in ipairs(folder:GetChildren()) do set[child] = true end end
    return set
end
local function nearestNew(cf, before, tolerance)
    local folder, found = towers(), nil
    if not folder then return nil end
    for _, child in ipairs(folder:GetChildren()) do
        if child:IsA("Model") and not before[child] then
            local p = pivot(child)
            if p and (p.Position - cf.Position).Magnitude <= tolerance then
                if found then return nil, "Неоднозначная позиция башни" end
                found = child
            end
        end
    end
    return found
end
local function fingerprint(model)
    if not model or not model.Parent then return "removed" end
    local fields = {}
    for k, v in pairs(model:GetAttributes()) do fields[#fields + 1] = "A:" .. k .. ":" .. tostring(v) end
    for _, obj in ipairs(model:GetDescendants()) do
        if obj:IsA("NumberValue") or obj:IsA("IntValue") or obj:IsA("StringValue") or obj:IsA("BoolValue") then
            fields[#fields + 1] = obj:GetFullName() .. ":" .. tostring(obj.Value)
        end
    end
    table.sort(fields)
    return table.concat(fields, "|")
end
local function refreshCash()
    local value = LP:FindFirstChild("Cash")
    if value and not (value:IsA("IntValue") or value:IsA("NumberValue")) then value = nil end
    if value ~= S.cash then
        if S.cashConnection then S.cashConnection:Disconnect() end
        S.cash, S.cashConnection = value, nil
        S.cashVersion = S.cashVersion + 1
        if value then
            S.cashConnection = value:GetPropertyChangedSignal("Value"):Connect(function()
                S.cashVersion = S.cashVersion + 1
                if hub.Pump then hub.Pump() end
            end)
        end
    end
end
local function cashNow()
    refreshCash()
    return S.cash and S.cash.Value or nil
end
local function waitUntil(predicate, seconds, valid)
    local deadline = os.clock() + seconds
    repeat
        if not S.alive or (valid and not valid()) then return nil, "Остановлено" end
        local result, detail = predicate()
        if result then return result, detail end
        if detail then return nil, detail end
        task.wait(0.05)
    until os.clock() >= deadline
    return nil, "Истёк срок подтверждения"
end

local dispatcher = G.__STD_NAMECALL_V2
local internal = setmetatable({}, { __mode = "k" })
local function refreshRecordCache()
    -- Все Roblox-методы выполняются ВНЕ hook.
    S.spawnRemote = remote("Functions", "SpawnTower", "RemoteFunction")
    S.upgradeRemote = remote("Functions", "UpgradeTower", "RemoteFunction")
    if dispatcher then
        dispatcher.spawnRemote, dispatcher.upgradeRemote = S.spawnRemote, S.upgradeRemote
    end
    local folder = towers()
    if folder ~= S.towerFolder then
        if S.towerAdded then S.towerAdded:Disconnect() end
        if S.towerRemoved then S.towerRemoved:Disconnect() end
        S.towerFolder, S.towerSet = folder, {}
        if folder then
            S.towerAdded = folder.ChildAdded:Connect(function(child) S.towerSet[child] = true end)
            S.towerRemoved = folder.ChildRemoved:Connect(function(child) S.towerSet[child] = nil end)
            S.towerSet = snapshotTowers()
        end
    end
end

-- BEGIN RAW SNAPSHOT: без Roblox :методов, сериализации CFrame и пользовательских metamethods.
local function copyRaw(v, b, depth, seen)
    budget(b, depth)
    if type(v) == "string" then
        b.bytes = b.bytes + #v
        assert(b.bytes <= LIMIT.Bytes, "Слишком большой снимок аргументов")
    end
    if type(v) ~= "table" then return v end
    assert(getmetatable(v) == nil, "Таблица с metatable не поддерживается записью")
    assert(not seen[v], "Циклический аргумент")
    seen[v] = true
    local out = {}
    for k, value in next, v do
        assert(type(k) == "string" or type(k) == "number" or type(k) == "boolean", "Неверный ключ")
        out[copyRaw(k, b, depth + 1, seen)] = copyRaw(value, b, depth + 1, seen)
    end
    seen[v] = nil
    return out
end
local function captureCall(r, args)
    if not S.alive or not S.recording or internal[coroutine.running()] then return end
    assert(S.recordCalls < LIMIT.Steps, "Достигнут лимит шагов")
    local money = S.cash and S.cash.Value -- только чтение свойства кэшированного Instance
    assert(finite(money) and money >= 0, "Cash недоступен")
    local kind = r == S.spawnRemote and "Spawn" or "Upgrade"
    local copied = { n = args.n }
    local b = { n = 0, bytes = 0 }
    for i = 1, args.n do copied[i] = copyRaw(args[i], b, 0, {}) end
    local before = {}
    if kind == "Spawn" then
        for model in next, S.towerSet do before[model] = true end
    end
    S.recordCalls = S.recordCalls + 1
    S.queueTail = S.queueTail + 1
    S.rawQueue[S.queueTail] = {
        kind = kind, args = copied, cash = money, before = before, epoch = S.recordEpoch,
    }
    S.pending = S.pending + 1
    if not S.drainScheduled then
        S.drainScheduled = true
        task.defer(hub.DrainRecording)
    end
end
-- END RAW SNAPSHOT

-- BEGIN TRANSPARENT HOOK
local function installHook()
    if type(dispatcher) == "table" and dispatcher.installed and dispatcher.protocol == "raw-direct-v2" then
        S.recordEnabled = true
        return true
    end
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        return false, "Нужны hookmetamethod и getnamecallmethod"
    end
    local d = { protocol = "raw-direct-v2", installed = false }
    local previous
    local ok, err = pcall(function()
        previous = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            local capture = d.capture
            if capture and method == "InvokeServer"
                and (self == d.spawnRemote or self == d.upgradeRemote) then
                -- Защищён ТОЛЬКО наблюдатель. Ошибка записи не становится ошибкой игры.
                local good, failure = pcall(capture, self, table.pack(...))
                if not good then
                    d.capture = nil
                    d.fault = tostring(failure) -- UI покажет ошибку позже, вне hook.
                end
            end
            -- Не передавать args-таблицу; не вызывать previous через ':'; не pcall(previous).
            -- self и исходные ... нетронуты, включая nil. Возврат tuple напрямую.
            return previous(self, ...)
        end)
        assert(type(previous) == "function", "hookmetamethod не вернул исходную функцию")
    end)
    if not ok then return false, tostring(err) end
    d.installed, dispatcher = true, d
    G.__STD_NAMECALL_V2 = d
    S.recordEnabled = true
    refreshRecordCache()
    return true
end
-- END TRANSPARENT HOOK

local function recordingError(message)
    S.recording, S.recordBroken = false, true
    problem("record", "Запись остановлена: " .. tostring(message))
end
local function findRecordedId(model)
    local known = S.recRefs[model]
    if known then return known end
    local p = pivot(model)
    assert(p, "Нет позиции прокачиваемой башни")
    local found
    for _, step in ipairs(S.entries) do
        if step.kind == "Spawn" then
            local cf = decode(step.args[2])
            local owner = S.recOwners[step.id]
            if (cf.Position - p.Position).Magnitude <= 0.8
                and (not owner or owner == model or not owner.Parent) then
                assert(not found, "Несколько записанных башен в одной позиции")
                found = step.id
            end
        end
    end
    assert(found, "Башня отсутствует в записи; начните запись до Spawn")
    S.recRefs[model], S.recOwners[found] = found, model
    return found
end
local function processSnapshot(raw)
    local a, step = raw.args, nil
    if raw.kind == "Spawn" then
        assert(a.n == 5 and type(a[1]) == "string" and #a[1] > 0 and typeof(a[2]) == "CFrame"
            and type(a[3]) == "boolean" and type(a[4]) == "string" and type(a[5]) == "table",
            "SpawnTower: сигнатура отличается от baseline")
        local encoded = encodeArgs(a) -- здесь можно вызывать CFrame:GetComponents().
        S.nextId = S.nextId + 1
        step = { kind = "Spawn", id = "T" .. S.nextId, cash = raw.cash, args = encoded }
        local model = nearestNew(a[2], raw.before, 0.8)
        if model then S.recRefs[model], S.recOwners[step.id] = step.id, model end
    else
        assert(a.n == 2 and type(a[2]) == "string" and #a[2] > 0, "UpgradeTower: другая сигнатура")
        local target = towerModel(a[1])
        assert(target, "Аргумент UpgradeTower больше не является доступной башней")
        step = { kind = "Upgrade", id = findRecordedId(target), cash = raw.cash, name = a[2] }
    end
    S.entries[#S.entries + 1] = step
end
function hub.DrainRecording()
    -- Один FIFO consumer; отложенные данные не зависят от флага recording после Stop.
    local failed = false
    while S.queueHead <= S.queueTail do
        local raw = S.rawQueue[S.queueHead]
        S.rawQueue[S.queueHead] = nil
        S.queueHead = S.queueHead + 1
        S.pending = math.max(0, S.pending - 1)
        if not failed and S.alive and raw and raw.epoch == S.recordEpoch then
            local ok, err = pcall(processSnapshot, raw)
            if not ok then
                failed = true
                recordingError(err)
            end
        end
    end
    S.queueHead, S.queueTail, S.drainScheduled = 1, 0, false
end

-- Только СОБСТВЕННЫЕ InvokeServer хаба используют pcall и timeout.
local function invoke(key, r, args, valid)
    if S.locks[key] then return nil, "Предыдущий запрос ещё выполняется: " .. key end
    local ticket = { done = false }
    S.locks[key] = ticket
    task.spawn(function()
        local thread = coroutine.running()
        internal[thread] = true
        ticket.result = table.pack(pcall(function() return r:InvokeServer(table.unpack(args, 1, args.n)) end))
        internal[thread] = nil
        ticket.done = true
        if S.locks[key] == ticket then S.locks[key] = nil end
    end)
    local ready, err = waitUntil(function() return ticket.done end, 12, valid)
    if not ready then return nil, err .. "; запрос нельзя безопасно повторить" end
    if not ticket.result[1] then return nil, "Ошибка InvokeServer: " .. tostring(ticket.result[2]) end
    if ticket.result[2] == false then return nil, "Сервер вернул false" end
    return ticket.result
end
local function stopPlayback(message)
    S.playing = false
    S.playEpoch = S.playEpoch + 1
    if message then notify(message) end
end
local function idleRequired()
    assert(not S.recording and not S.playing and not S.pumping and S.pending == 0
        and not S.drainScheduled and not S.locks.tower, "Остановите операцию и дождитесь очереди/запроса")
end
local function currentMacro()
    assert(S.pending == 0 and not S.drainScheduled, "Дождитесь обработки очереди записи")
    assert(not S.recordBroken and not (dispatcher and dispatcher.fault),
        "Запись неполная из-за ошибки. Начните новую запись или загрузите файл")
    if #S.entries == 0 then return validateMacro(S.macro) end
    local data = emptyMacro()
    data.steps = S.entries
    return validateMacro(data)
end
local function confirmStep(step, response, before, target, priorFingerprint, valid)
    local returned = towerModel(response[2])
    local position = step.kind == "Spawn" and decode(step.args[2]) or S.playRefs[step.id].cf
    local model, err = waitUntil(function()
        if returned and returned.Parent == towers() and not before[returned] then return returned end
        local replacement, ambiguous = nearestNew(position, before, 0.8)
        if ambiguous then return nil, ambiguous end
        if replacement then return replacement end
        if step.kind == "Upgrade" and target and target.Parent == towers() then
            if response[2] == true or fingerprint(target) ~= priorFingerprint then return target end
        end
        return nil
    end, 8, valid)
    if not model then return nil, err .. ": нет подтверждённой башни/прокачки" end
    S.playRefs[step.id] = { model = model, cf = pivot(model) or position }
    return true
end
local function playStep(step, valid)
    local r = remote("Functions", step.kind == "Spawn" and "SpawnTower" or "UpgradeTower", "RemoteFunction")
    if not r then return nil, "RemoteFunction отсутствует" end
    local args, target, previousFingerprint
    if step.kind == "Spawn" then
        args = decodeArgs(step.args)
    else
        local ref = S.playRefs[step.id]
        target = ref and ref.model
        if not target or target.Parent ~= towers() then return nil, "Потеряна башня " .. step.id end
        args = table.pack(target, step.name)
        previousFingerprint = fingerprint(target)
    end
    local before, money = snapshotTowers(), cashNow()
    if not finite(money) or money < step.cash then return nil, "Баланс изменился до отправки" end
    local revision = S.cashVersion
    if not valid() then return nil, "Остановлено" end
    local result, err = invoke("tower", r, args, valid)
    if not result then return nil, err end
    local confirmed, confirmError = confirmStep(step, result, before, target, previousFingerprint, valid)
    if not confirmed then return nil, confirmError end
    if opt("WaitCashSync", true) and money > 0 and S.cashVersion == revision then
        local updated = waitUntil(function() return S.cashVersion ~= revision end, 8, valid)
        if not updated then return nil, "Cash не обновился; остановка без повтора" end
    end
    return true
end
function hub.Pump()
    if not S.alive or not S.playing or S.pumping then return end
    S.pumping = true
    local epoch = S.playEpoch
    local function valid() return S.alive and S.playing and S.playEpoch == epoch end
    task.spawn(function()
        local ok, err = pcall(function()
            while valid() do
                local step = S.macro.steps[S.cursor]
                if not step then stopPlayback("Макрос завершён"); return end
                local money = cashNow()
                if not finite(money) or money < step.cash then return end
                local done, message = playStep(step, valid)
                if not done then
                    if valid() then
                        stopPlayback()
                        problem("play", "Шаг " .. S.cursor .. ": " .. tostring(message))
                    end
                    return
                end
                if not valid() then return end
                S.cursor = S.cursor + 1
            end
        end)
        S.pumping = false
        if not ok and valid() then stopPlayback(); problem("play", err) end
    end)
end
local function resetMemory()
    S.recordEpoch = S.recordEpoch + 1
    S.entries, S.recRefs, S.recOwners, S.playRefs = {}, {}, {}, {}
    S.nextId, S.cursor, S.recordCalls, S.recordBroken = 0, 1, 0, false
    S.macro = emptyMacro()
    if dispatcher then dispatcher.fault = nil end
end
local function startRecord()
    idleRequired()
    assert(cashNow() ~= nil and towers(), "Нет Cash/workspace.Towers; войдите в матч")
    refreshRecordCache()
    assert(S.spawnRemote and S.upgradeRemote, "Нет SpawnTower/UpgradeTower")
    local ok, err = installHook()
    assert(ok, err)
    resetMemory()
    S.towerSet = snapshotTowers()
    dispatcher.capture = captureCall
    S.recording = true
    notify("Запись попыток вызовов включена. Cash сохраняется до вызова; не записывайте отклонённые покупки")
end
local function startPlayback()
    idleRequired()
    local data = currentMacro()
    assert(#data.steps > 0, "Макрос пуст")
    assert(data.gameId == game.GameId and data.placeId == game.PlaceId, "Макрос записан в другом PlaceId/GameId")
    assert(cashNow() ~= nil and towers(), "Нет Cash/workspace.Towers")
    S.macro, S.cursor, S.playRefs = data, 1, {}
    S.playEpoch = S.playEpoch + 1
    S.playing = true
    hub.Pump()
end

local fileOK = type(isfile) == "function" and type(isfolder) == "function"
    and type(makefolder) == "function" and type(readfile) == "function"
    and type(writefile) == "function" and type(listfiles) == "function"
local deleteOK = fileOK and type(delfile) == "function"
local function ensureFolder(path)
    local partial = ""
    for part in path:gmatch("[^/]+") do
        partial = partial == "" and part or partial .. "/" .. part
        if not isfolder(partial) then makefolder(partial) end
    end
end
local function macroPath(name)
    assert(safeName(name), "Имя: латиница, цифры, _ и -, до 64 символов")
    return ROOT .. "/macros/" .. name .. ".json"
end
local macroDropdown
local function refreshMacros(preferred)
    if not fileOK then return {} end
    ensureFolder(ROOT .. "/macros")
    local names, found = {}, {}
    for _, path in ipairs(listfiles(ROOT .. "/macros")) do
        if type(path) == "string" then
            local basename = path:gsub("\\", "/"):match("([^/]+)$")
            local name = basename and basename:match("^(.-)%.json$")
            -- Полный путь из listfiles не используется для чтения/удаления.
            if safeName(name) and not found[name] and isfile(macroPath(name)) then
                found[name] = true
                names[#names + 1] = name
            end
        end
    end
    table.sort(names)
    if macroDropdown then
        local chosen = preferred or macroDropdown.Value
        macroDropdown:SetValues(names)
        macroDropdown:SetValue(found[chosen] and chosen or names[1])
        macroDropdown:Display() -- очищает подпись даже при пустом списке Fluent.
    end
    return names
end
local function selectedName()
    local name = macroDropdown and macroDropdown.Value
    assert(safeName(name), "Выберите сохранённый макрос")
    return name
end
local function saveMacro(name)
    assert(fileOK, "Файловые функции недоступны")
    assert(not S.recording, "Сначала Stop Recording")
    local text = Http:JSONEncode(currentMacro())
    assert(#text <= LIMIT.Bytes, "Файл слишком большой")
    ensureFolder(ROOT .. "/macros")
    local path = macroPath(name)
    writefile(path, text)
    assert(isfile(path) and readfile(path) == text, "Не удалось проверить запись файла")
    refreshMacros(name)
    notify("Сохранено: " .. path)
end
local function loadMacro(name)
    assert(fileOK, "Файловые функции недоступны")
    idleRequired()
    local path = macroPath(name)
    assert(isfile(path), "Файл не найден: " .. path)
    local text = readfile(path)
    assert(#text <= LIMIT.Bytes, "Файл слишком большой")
    local data = validateMacro(Http:JSONDecode(text))
    -- Память заменяется только после успешной валидации.
    resetMemory()
    S.macro = data
    options.MacroName:SetValue(name)
    notify("Загружен " .. name .. "; шагов: " .. #data.steps)
end
local function deleteMacro(name)
    assert(deleteOK, "Удаление недоступно: нет delfile")
    idleRequired()
    local path = macroPath(name)
    assert(isfile(path), "Файл уже отсутствует")
    local text = readfile(path)
    assert(#text <= LIMIT.Bytes, "Файл слишком большой для резервной копии")
    ensureFolder(ROOT .. "/trash")
    local backup = ROOT .. "/trash/" .. name .. "_" .. Http:GenerateGUID(false) .. ".json"
    assert(not isfile(backup), "Коллизия имени резервной копии")
    writefile(backup, text)
    assert(isfile(backup) and readfile(backup) == text, "Копия не подтверждена; исходный файл не удалён")
    delfile(path)
    assert(not isfile(path), "Исполнитель не удалил файл; резервная копия сохранена")
    refreshMacros()
    notify("Удалён из списка. Копия: " .. backup .. ". Макрос в памяти не изменён")
end

local camera = WS.CurrentCamera
local viewport = camera and camera.ViewportSize or Vector2.new(800, 600)
local Window = Fluent:CreateWindow({
    Title = "Slop Tower Defense", SubTitle = "Money-based Hub V2",
    TabWidth = 150, Size = UDim2.fromOffset(math.min(650, math.max(340, viewport.X - 20)),
        math.min(500, math.max(300, viewport.Y - 30))),
    Acrylic = false, Theme = "Dark", MinimizeKey = Enum.KeyCode.LeftControl,
})
local Tabs = {
    Macro = Window:AddTab({ Title = "Macro Recorder", Icon = "" }),
    Lobby = Window:AddTab({ Title = "Autoplay & Lobby", Icon = "" }),
    Main = Window:AddTab({ Title = "Main Game Settings", Icon = "" }),
    Misc = Window:AddTab({ Title = "Misc", Icon = "" }),
    Configs = Window:AddTab({ Title = "Configs", Icon = "" }),
}
local function action(fn)
    return function()
        if not S.alive then return end
        local ok, err = pcall(fn)
        if not ok then problem("action", err) end
    end
end
local function button(tab, title, callback, description)
    return tab:AddButton({ Title = title, Description = description, Callback = action(callback) })
end
local function toggle(tab, id, title, description)
    return tab:AddToggle(id, { Title = title, Description = description, Default = false })
end
local function confirm(title, content, callback)
    Window:Dialog({ Title = title, Content = content, Buttons = {
        { Title = "Подтвердить", Callback = action(callback) },
        { Title = "Отмена", Callback = function() end },
    } })
end
local statusParagraph = Tabs.Macro:AddParagraph({ Title = "Состояние", Content = "Ожидание" })
Tabs.Macro:AddParagraph({ Title = "Запись без вмешательства в ответы", Content =
    "Записываются попытки InvokeServer, не результаты. Очередь = снимки, не сетевые запросы. " ..
    "Cash — баланс до действия. После Stop дождитесь завершения ручной покупки; Play — только в свежем матче." })
Tabs.Macro:AddInput("MacroName", { Title = "Имя для сохранения / загрузки вручную", Default = "default", Finished = false })
Tabs.Macro:AddToggle("WaitCashSync", { Title = "Ждать репликацию Cash после покупки", Default = true,
    Description = "Для бесплатных действий может потребоваться отключение." })
button(Tabs.Macro, "Start Recording", function()
    idleRequired()
    if #S.entries > 0 or #S.macro.steps > 0 then
        confirm("Новая запись", "Заменить макрос в памяти? Файл не изменится.", startRecord)
    else startRecord() end
end)
button(Tabs.Macro, "Stop Recording", function()
    S.recording = false
    notify("Запись выключена. Уже снятые аргументы будут обработаны; дождитесь завершения ручных покупок")
end)
button(Tabs.Macro, "Play Macro (из памяти)", startPlayback)
button(Tabs.Macro, "Stop Macro", function() stopPlayback("Остановлено; отправленные запросы не отзываются") end)
button(Tabs.Macro, "Clear Macro", function()
    confirm("Clear Macro", "Очистить память? Файлы останутся.", function()
        idleRequired()
        resetMemory()
        notify("Макрос в памяти очищен")
    end)
end)
button(Tabs.Macro, "Save Macro to File", function()
    assert(fileOK, "Файловые функции недоступны")
    local name = opt("MacroName", "default")
    local path = macroPath(name)
    if isfile(path) then
        confirm("Перезапись", "Заменить файл " .. name .. "?", function() saveMacro(name) end)
    else saveMacro(name) end
end)
local function requestLoad(name, play)
    idleRequired()
    local function run()
        loadMacro(name)
        if play then startPlayback() end
    end
    if #S.entries > 0 or #S.macro.steps > 0 then
        confirm(play and "Загрузить и запустить" or "Загрузить", "Заменить макрос в памяти файлом " .. name .. "?", run)
    else run() end
end
button(Tabs.Macro, "Load Macro from File (по имени)", function() requestLoad(opt("MacroName", "default"), false) end)
macroDropdown = Tabs.Macro:AddDropdown("SavedMacro", {
    Title = "Сохранённые макросы", Values = {}, Multi = false, AllowNull = true,
})
macroDropdown:OnChanged(function(name)
    if safeName(name) then options.MacroName:SetValue(name) end
end)
button(Tabs.Macro, "Refresh: обновить список", function()
    local names = refreshMacros()
    notify(fileOK and ("Файлов: " .. #names) or "Файловые функции недоступны")
end)
button(Tabs.Macro, "Загрузить выбранный макрос", function() requestLoad(selectedName(), false) end)
button(Tabs.Macro, "Запустить выбранный макрос", function() requestLoad(selectedName(), true) end,
    "Читает выбранный файл заново, затем запускает с первого шага; нужен свежий матч.")
button(Tabs.Macro, "Удалить выбранный макрос", function()
    assert(deleteOK, "Удаление недоступно: нет delfile")
    idleRequired()
    local name = selectedName()
    confirm("Удалить макрос", "Удалить " .. name .. " из macros? Копия останется в SlopTowerDefenseHub/trash.",
        function() deleteMacro(name) end)
end)
if fileOK then action(refreshMacros)() end

Tabs.Lobby:AddDropdown("LobbyMode", { Title = "Режим", Values = { "Survival", "Raid" }, Default = "Survival" })
toggle(Tabs.Lobby, "ManualElevator", "Выбирать лифт вручную", "Иначе режим определяет Elevator1 / Elevator6")
Tabs.Lobby:AddDropdown("Elevator", { Title = "Лифт вручную", Values = ELEVATORS, Default = "Elevator6" })
Tabs.Lobby:AddParagraph({ Title = "Маршруты", Content =
    "Survival: Elevator6 (-11, 61, 100). Raid: Elevator1 (-10, 70.5, 142). Elevator2–5: только Remote." })
Tabs.Lobby:AddInput("LobbyPlaceId", { Title = "PlaceId лобби", Default = "", Numeric = true, Finished = false })
button(Tabs.Lobby, "Запомнить текущий PlaceId как лобби", function()
    options.LobbyPlaceId:SetValue(tostring(game.PlaceId))
    notify("PlaceId лобби установлен. Сохраните конфиг")
end, "Нажимайте только в лобби.")
toggle(Tabs.Lobby, "AutoElevator", "Auto Enter Elevator", "Только в указанном PlaceId; интервал 12 секунд")
toggle(Tabs.Lobby, "MoveToElevator", "Перемещать персонажа к лифту", "Координаты есть только для Elevator1 / Elevator6")
toggle(Tabs.Lobby, "AutoReplay", "Auto Replay / EndScreen", "EndDecision(true); уступает приоритет Auto Leave")
toggle(Tabs.Lobby, "AutoLeave", "Auto Leave to Lobby upon Game End", "ExitGame:FireServer() без аргументов; приоритет над Replay")
Tabs.Lobby:AddParagraph({ Title = "Конец матча", Content =
    "Один общий шлюз: Exit либо Replay один раз на показ EndScreen. Переключение опций после отправки не отправляет вторую команду. " ..
    "Сбой телепортации: повтор автоматом не выполняется; используйте игровой интерфейс." })
toggle(Tabs.Main, "AutoMap", "Auto Vote Map")
Tabs.Main:AddDropdown("Map", { Title = "Карта", Values = MAPS, Default = "Area 51" })
toggle(Tabs.Main, "AutoDifficulty", "Auto Vote Difficulty")
Tabs.Main:AddDropdown("Difficulty", { Title = "Сложность", Values = { "Normal", "Hard", "Nightmare" }, Default = "Normal" })
toggle(Tabs.Main, "AutoSpeed", "Auto Game Speed", "Попытки раз в 3 секунды, только если скорость отличается")
Tabs.Main:AddSlider("Speed", { Title = "Скорость", Default = 1, Min = 1, Max = 5, Rounding = 0 })
toggle(Tabs.Misc, "AntiMacro", "Anti-Macro: отвечать на Check", "Исходное предположение: Check(key: string). Принятие ответа не подтверждено")
Tabs.Misc:AddSlider("AntiArg", { Title = "Номер аргумента Check с ключом", Default = 1, Min = 1, Max = 10, Rounding = 0 })
Tabs.Misc:AddInput("AntiField", { Title = "Путь к ключу внутри таблицы", Default = "", Finished = false })
toggle(Tabs.Misc, "AntiMulti", "Разрешить несколько аргументов Check", "Только после проверки реальной сигнатуры")
local antiParagraph = Tabs.Misc:AddParagraph({ Title = "AntiMacro.Check", Content = S.antiStatus })
toggle(Tabs.Misc, "AntiAFK", "Anti-AFK (VirtualUser)")
toggle(Tabs.Misc, "AutoWalk", "Auto-walk", "Боковой шаг каждые 2 секунды; при работе лифта приостанавливается")
local diagnostics = Tabs.Misc:AddParagraph({ Title = "Диагностика", Content = "Ожидание" })

local function worker(name, callback)
    if S.workers[name] or not S.alive then return end
    S.workers[name] = true
    task.spawn(function()
        local ok, err = pcall(callback)
        S.workers[name] = nil
        if not ok and S.alive then problem(name, err) end
    end)
end
local function gameGui()
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    return pg and pg:FindFirstChild("GameGui") or nil
end
local function visible(obj)
    if not obj or not obj:IsA("GuiObject") then return false end
    local current = obj
    while current and current ~= LP do
        if current:IsA("GuiObject") and not current.Visible then return false end
        if current:IsA("ScreenGui") and not current.Enabled then return false end
        current = current.Parent
    end
    return obj:IsDescendantOf(LP)
end
local gates = {}
local function guiGate(key, frameName, enabled, selection, eventName, argument)
    local gui = gameGui()
    local frame = gui and gui:FindFirstChild(frameName)
    local gate = gates[key]
    if not gate or gate.frame ~= frame then
        if gate and gate.connection then gate.connection:Disconnect() end
        gate = { frame = frame, sent = nil, lastAttempt = -math.huge }
        gates[key] = gate
        if frame and frame:IsA("GuiObject") then
            gate.connection = frame:GetPropertyChangedSignal("Visible"):Connect(function()
                if not frame.Visible then gate.sent = nil end
            end)
        end
    end
    if not enabled or not visible(frame) then gate.sent = nil; return end
    if gate.sent == selection or os.clock() - gate.lastAttempt < 2 then return end
    gate.lastAttempt = os.clock()
    local ok, err = fire("Events", eventName, argument)
    if ok then gate.sent = selection else problem(key, err) end
end

-- BEGIN END GATE
local endGate = { active = false, sent = nil, lastAttempt = -math.huge }
local function endCycle()
    local gui = gameGui()
    local frame = gui and gui:FindFirstChild("EndScreen")
    if frame ~= endGate.frame then
        if endGate.connection then endGate.connection:Disconnect() end
        endGate.frame, endGate.connection = frame, nil
        if frame and frame:IsA("GuiObject") then
            endGate.connection = frame:GetPropertyChangedSignal("Visible"):Connect(function()
                if not frame.Visible then endGate.active = false end
            end)
        end
    end
    if not visible(frame) then
        endGate.active, endGate.sent = false, nil
        return
    end
    if not endGate.active then
        endGate.active, endGate.sent, endGate.lastAttempt = true, nil, -math.huge
    end
    if S.playing then stopPlayback("Матч завершён; макрос остановлен") end
    if S.recording then
        S.recording = false
        notify("Матч завершён; запись остановлена")
    end
    if endGate.sent then return end
    local decision = opt("AutoLeave", false) and "Exit" or (opt("AutoReplay", false) and "Replay" or nil)
    if not decision or os.clock() - endGate.lastAttempt < 2 then return end
    endGate.lastAttempt = os.clock()
    local eventName = decision == "Exit" and "ExitGame" or "EndDecision"
    local r = remote("Events", eventName, "RemoteEvent")
    if not r then problem("end", "Нет Events." .. eventName); return end
    -- Отмечаем попытку ДО отправки. При неопределённом исходе не повторяем.
    endGate.sent = decision
    local ok, err
    if decision == "Exit" then
        ok, err = pcall(function() r:FireServer() end) -- ноль аргументов, не nil/false/таблица
    else
        ok, err = pcall(function() r:FireServer(true) end)
    end
    if not ok then problem("end", "Команда конца матча не подтверждена: " .. tostring(err)) end
end
-- END END GATE

local function extractToken(args, index, field, allowMultiple)
    if not allowMultiple and args.n ~= 1 then return nil end
    local value = args[index]
    if field ~= "" then
        if not field:match("^[%w_]+[%.%w_]*$") or field:find("..", 1, true) or field:sub(-1) == "." then return nil end
        for part in field:gmatch("[^.]+") do
            if type(value) ~= "table" then return nil end
            value = value[part]
        end
    end
    if type(value) == "string" and #value > 0 then return value end
    return nil
end
local antiConnection, antiRemote
local lastTokens, tokenQueue = {}, {}
local function describePayload(args)
    local parts = {}
    for i = 1, math.min(args.n, 10) do
        local value = args[i]
        local desc = tostring(i) .. ":" .. typeof(value)
        if type(value) == "table" then
            local types, count = {}, 0
            for k, v in pairs(value) do
                count = count + 1
                if count > 8 then break end
                types[#types + 1] = typeof(k) .. "->" .. typeof(v)
            end
            table.sort(types)
            desc = desc .. "{" .. table.concat(types, ",") .. "}"
        end
        parts[#parts + 1] = desc
    end
    return "Аргументов: " .. args.n .. "; " .. table.concat(parts, "; ")
end
local function bindAntiMacro()
    local events = RS:FindFirstChild("Events")
    local folder = events and events:FindFirstChild("AntiMacro")
    local check = folder and folder:FindFirstChild("Check")
    if check and not check:IsA("RemoteEvent") then check = nil end
    if check == antiRemote then return end
    if antiConnection then antiConnection:Disconnect(); antiConnection = nil end
    antiRemote = check
    lastTokens, tokenQueue = {}, {}
    if not check then S.antiStatus = "AntiMacro.Check отсутствует"; return end
    S.antiStatus = "Check найден; ожидание события"
    antiConnection = check.OnClientEvent:Connect(function(...)
        if not S.alive then return end
        local args = table.pack(...)
        local ok, err = pcall(function()
            S.antiStatus = describePayload(args)
            if not opt("AntiMacro", false) then return end
            local key = extractToken(args, tonumber(opt("AntiArg", 1)) or 1,
                opt("AntiField", ""), opt("AntiMulti", false))
            if not key then problem("anti-shape", "Check: формат ключа не подтверждён; ответ не отправлен"); return end
            if lastTokens[key] then return end
            local respond = folder:FindFirstChild("Respond")
            if not respond or not respond:IsA("RemoteEvent") then problem("anti-remote", "Нет AntiMacro.Respond"); return end
            respond:FireServer(key)
            lastTokens[key] = true
            tokenQueue[#tokenQueue + 1] = key
            if #tokenQueue > 32 then lastTokens[table.remove(tokenQueue, 1)] = nil end
            S.antiStatus = S.antiStatus .. " | Ответ отправлен; принятие не подтверждено"
        end)
        if not ok then problem("anti", err) end
    end)
end
local function inConfiguredLobby() return tonumber(opt("LobbyPlaceId", "")) == game.PlaceId end
local function elevatorCycle()
    if not opt("AutoElevator", false) or S.recording or S.playing then return end
    if not inConfiguredLobby() then problem("lobby-place", "Укажите PlaceId лобби"); return end
    if os.clock() - S.lastElevator < 12 then return end
    S.lastElevator = os.clock()
    local name = opt("ManualElevator", false) and opt("Elevator", "Elevator6")
        or (opt("LobbyMode", "Survival") == "Raid" and "Elevator1" or "Elevator6")
    local enter = remote("Events", "EnterElevator", "RemoteEvent")
    local start = remote("Events", "StartElevator", "RemoteEvent")
    if not enter or not start then problem("elevator", "Remotes лифта отсутствуют"); return end
    local function enabled()
        return S.alive and opt("AutoElevator", false) and inConfiguredLobby() and not S.recording and not S.playing
    end
    worker("elevator", function()
        if not enabled() then return end
        if opt("MoveToElevator", false) then
            local pos = ELEVATOR_POS[name]
            if not pos then problem("elevator-pos", "Для " .. name .. " координаты неизвестны; только Remote") end
            local character = LP.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")
            if pos then
                assert(hrp, "Нет HumanoidRootPart")
                hrp.CFrame = CFrame.new(pos)
                task.wait(0.25)
            end
        end
        if not enabled() then return end
        enter:FireServer(name)
        task.wait(0.8)
        if enabled() then start:FireServer(name) end
    end)
end
local speedAttempt = -math.huge
local function speedCycle()
    if not opt("AutoSpeed", false) or S.locks.speed or S.workers.speed then return end
    local info = WS:FindFirstChild("Info")
    local value = info and info:FindFirstChild("SpeedGame")
    local speed = math.clamp(math.floor(tonumber(opt("Speed", 1)) or 1), 1, 5)
    if not value or not (value:IsA("NumberValue") or value:IsA("IntValue")) then return end
    if value.Value == speed or os.clock() - speedAttempt < 3 then return end
    local r = remote("Functions", "ChangeSpeed", "RemoteFunction")
    if not r then return end
    speedAttempt = os.clock()
    worker("speed", function()
        local result, err = invoke("speed", r, table.pack(speed), function() return opt("AutoSpeed", false) end)
        if not result and S.alive then problem("speed", err) end
    end)
end
local walkAt, walkSign = -math.huge, 1
local function walkCycle()
    if not opt("AutoWalk", false) or S.workers.walk or S.workers.elevator then return end
    if opt("AutoElevator", false) and inConfiguredLobby() then return end
    if os.clock() - walkAt < 2 then return end
    walkAt = os.clock()
    local character = LP.Character
    local hum = character and character:FindFirstChildOfClass("Humanoid")
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if not hum or not hrp or hum.Health <= 0 or hum.Sit or hum.MoveDirection.Magnitude > 0.05 then return end
    walkSign = -walkSign
    local direction = hrp.CFrame.RightVector * walkSign
    local destination = hrp.Position + Vector3.new(direction.X, 0, direction.Z) * 1.5
    worker("walk", function()
        if not S.alive or not opt("AutoWalk", false) then return end
        S.walkHumanoid = hum
        hum:MoveTo(destination)
        task.wait(0.35)
        if hum.Parent and LP.Character == character then hum:Move(Vector3.zero, false) end
        S.walkHumanoid = nil
    end)
end
local function releaseVU()
    if S.vuHeld then
        S.vuHeld = false
        pcall(function() VU:Button2Up(Vector2.zero, (WS.CurrentCamera and WS.CurrentCamera.CFrame) or CFrame.new()) end)
    end
end
connect(LP.Idled, function()
    if not S.alive or not opt("AntiAFK", false) then return end
    worker("afk", function()
        if not S.alive or not opt("AntiAFK", false) then return end
        VU:CaptureController()
        VU:Button2Down(Vector2.zero, (WS.CurrentCamera and WS.CurrentCamera.CFrame) or CFrame.new())
        S.vuHeld = true
        task.wait(0.15)
        releaseVU()
    end)
end)
function hub.Destroy(reason)
    if not S.alive then return end
    S.alive, S.recording, S.playing = false, false, false
    S.playEpoch, S.recordEpoch = S.playEpoch + 1, S.recordEpoch + 1
    if dispatcher and dispatcher.capture == captureCall then dispatcher.capture = nil end
    for _, c in ipairs(S.connections) do pcall(c.Disconnect, c) end
    for _, gate in pairs(gates) do if gate.connection then gate.connection:Disconnect() end end
    if endGate.connection then endGate.connection:Disconnect() end
    if S.cashConnection then S.cashConnection:Disconnect() end
    if S.towerAdded then S.towerAdded:Disconnect() end
    if S.towerRemoved then S.towerRemoved:Disconnect() end
    if antiConnection then antiConnection:Disconnect() end
    if S.walkHumanoid and S.walkHumanoid.Parent then pcall(S.walkHumanoid.Move, S.walkHumanoid, Vector3.zero, false) end
    releaseVU()
    if S.mobileGui then S.mobileGui:Destroy() end
    table.clear(S.rawQueue)
    S.pending, S.queueHead, S.queueTail, S.drainScheduled = 0, 1, 0, false
    table.clear(lastTokens)
    table.clear(tokenQueue)
    if not Fluent.Unloaded then pcall(function() Fluent:Destroy() end) end
    -- Tombstone остаётся в G: незавершённые собственные InvokeServer удерживают locks.
end
button(Tabs.Misc, "Unload Hub", function() hub.Destroy("Выгрузка") end)
local okMobile, mobileError = pcall(function()
    local pg = LP:FindFirstChildOfClass("PlayerGui") or LP:WaitForChild("PlayerGui", 5)
    assert(pg, "Нет PlayerGui")
    local screen = Instance.new("ScreenGui")
    S.mobileGui = screen
    screen.Name, screen.ResetOnSpawn, screen.DisplayOrder = "STDHubToggle", false, 10000
    screen.Parent = pg
    local b = Instance.new("TextButton")
    b.Size, b.Position = UDim2.fromOffset(76, 34), UDim2.new(1, -86, 0, 8)
    b.Text, b.TextSize = "Slop Hub", 13
    b.BackgroundColor3, b.TextColor3 = Color3.fromRGB(35, 35, 40), Color3.new(1, 1, 1)
    b.Parent = screen
    local corner = Instance.new("UICorner")
    corner.CornerRadius, corner.Parent = UDim.new(0, 8), b
    connect(b.Activated, action(function() Window:Minimize() end))
end)
if not okMobile then problem("mobile", mobileError) end
local SaveManager, InterfaceManager
local managersReady = false
if fileOK then
    local ok, err = pcall(function()
        ensureFolder(ROOT .. "/macros")
        SaveManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/SaveManager.lua"))()
        InterfaceManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/InterfaceManager.lua"))()
        SaveManager:SetLibrary(Fluent)
        InterfaceManager:SetLibrary(Fluent)
        SaveManager:IgnoreThemeSettings()
        SaveManager:SetIgnoreIndexes({ "SavedMacro" }) -- список файлов не является настройкой конфига.
        InterfaceManager:SetFolder(ROOT)
        SaveManager:SetFolder(ROOT .. "/configs")
        local originalSave, originalLoad = SaveManager.Save, SaveManager.Load
        function SaveManager:Save(name)
            if not safeName(name) then return false, "Имя: латиница, цифры, _ или -" end
            local good, result, message = pcall(originalSave, self, name)
            if not good then return false, tostring(result) end
            return result, message
        end
        function SaveManager:Load(name)
            if not safeName(name) then return false, "Недопустимое имя конфига" end
            local good, result, message = pcall(originalLoad, self, name)
            if not good then return false, tostring(result) end
            return result, message
        end
        InterfaceManager:BuildInterfaceSection(Tabs.Configs)
        SaveManager:BuildConfigSection(Tabs.Configs)
        managersReady = true
    end)
    if not ok then problem("configs", "Конфиги недоступны: " .. tostring(err)) end
else
    Tabs.Configs:AddParagraph({ Title = "Нет файловых функций", Content =
        "Нужны readfile/writefile/isfile/isfolder/makefolder/listfiles. Для удаления дополнительно delfile." })
end
Tabs.Configs:AddParagraph({ Title = "Автозагрузка", Content =
    "Create config -> выбрать -> Set as autoload. Макросы хранятся отдельно. Запись и Play автоматически не запускаются. " ..
    "При включённых обоих режимах завершения выбирается Auto Leave. После смены Place перезапустите скрипт." })
-- ЗАМЕНА исходного блока do с persistentKey = "__STD_AUTOMACRO_ROUND_V1".
-- Конец заменяемого участка: end перед комментарием -- КОНЕЦ ВСТАВКИ.
-- Вставить ВМЕСТО этого участка, НЕ запускать отдельным файлом в Delta.
-- Остальной хаб, включая Window:SelectTab(1), autoload и return hub, оставить.
-- Требуется свежий вход на сервер. Roblox/Delta здесь не тестировались.
-- cash в старом макросе = баланс записи, НЕ цена. requiredCash = ручной порог.
-- Хук записи не изменяется. Автоповторов покупок после ошибки нет.
do
    local A = {
        alive = true, ready = false, loading = false, configFailed = false,
        launching = false, syncing = false, evaluating = false,
        waveObject = nil, waveConnection = nil, status = "Инициализация",
        runEpoch = nil, phase = "Ожидание", reason = "", log = {},
        startedAt = nil, startWave = nil, firstSentAt = nil, firstSentWave = nil,
        lastConfirmedAt = nil, runThreshold = nil, lastDetail = nil,
    }
    local persistentKey = "__STD_AUTOMACRO_ROUND_V2"
    local gate = G[persistentKey]
    if type(gate) ~= "table" or gate.placeId ~= game.PlaceId
        or gate.gameId ~= game.GameId or gate.jobId ~= game.JobId then
        gate = {
            placeId = game.PlaceId, gameId = game.GameId, jobId = game.JobId,
            lastWave = nil, zeroSeen = false, endSeen = false,
            consumed = false, round = 1, reason = nil,
        }
        G[persistentKey] = gate
    end

    -- BEGIN PURE HELPERS
    local function observedToken(args)
        if args.n ~= 4 or type(args[1]) ~= "string" or #args[1] == 0 then return nil end
        if not finite(args[2]) or not finite(args[3]) or not finite(args[4]) then return nil end
        return args[1]
    end
    local function stepThreshold(step)
        local explicit = step.requiredCash
        if explicit ~= nil then
            assert(finite(explicit) and explicit >= 0, "Неверный requiredCash")
            return explicit, "ручной порог/цена"
        end
        assert(finite(step.cash) and step.cash >= 0, "Неверный cash")
        return step.cash, "баланс при записи, НЕ цена"
    end
    local function observeRound(g, wave, ended, lobby)
        if lobby then
            g.zeroSeen, g.lastWave = true, nil
            return false
        end
        if ended then
            g.endSeen = true
            if finite(wave) and wave % 1 == 0 then
                if wave <= 0 or (wave == 1 and finite(g.lastWave) and g.lastWave > 1) then
                    g.zeroSeen = true
                end
                g.lastWave = wave
            end
            return false
        end
        if not finite(wave) or wave % 1 ~= 0 then return false end
        if wave <= 0 then
            g.zeroSeen, g.lastWave = true, wave
            return false
        end
        if wave == 1 then
            local fresh = g.zeroSeen or (finite(g.lastWave) and g.lastWave > 1)
            if fresh then
                g.round = g.round + 1
                g.consumed, g.reason, g.endSeen = false, nil, false
            end
            g.zeroSeen, g.lastWave = false, wave
            return not g.endSeen and not g.consumed
        end
        g.zeroSeen, g.lastWave = false, wave
        return false
    end
    local function delayRemaining(lastConfirmedAt, delay, now)
        if not lastConfirmedAt then return 0 end
        return math.max(0, lastConfirmedAt + delay - now)
    end
    -- END PURE HELPERS

    local baseValidate = validateMacro
    validateMacro = function(data)
        local result = baseValidate(data)
        for _, step in ipairs(result.steps) do stepThreshold(step) end
        return result
    end
    local function readWave()
        local info = WS:FindFirstChild("Info")
        local obj = info and info:FindFirstChild("Wave")
        if obj and not (obj:IsA("IntValue") or obj:IsA("NumberValue")) then obj = nil end
        return obj, obj and obj.Value or nil
    end
    local function endVisible()
        local gui = gameGui()
        return visible(gui and gui:FindFirstChild("EndScreen"))
    end
    local function trace(event, detail)
        local _, wave = readWave()
        local balance = S.cash and S.cash.Value
        local line = string.format("t=%.3f wave=%s cash=%s step=%s %s %s",
            os.clock(), tostring(wave), tostring(balance), tostring(S.cursor),
            event, detail or "")
        if #A.log >= 300 then table.remove(A.log, 1) end
        A.log[#A.log + 1] = line
        print("[STD Playback] " .. line)
    end
    local function phase(name, detail)
        detail = detail or ""
        if A.phase ~= name or A.reason ~= detail then
            A.phase, A.reason = name, detail
            trace(name, detail)
        end
    end

    -- Исправление формы Check, наблюдавшейся в предоставленном логе.
    -- Значения 2..4 не интерпретируются; токен не пишется в журнал.
    -- Принятие сервером не выводится из успешного FireServer.
    bindAntiMacro = function()
        local events = RS:FindFirstChild("Events")
        local folder = events and events:FindFirstChild("AntiMacro")
        local check = folder and folder:FindFirstChild("Check")
        if check and not check:IsA("RemoteEvent") then check = nil end
        if check == antiRemote then return end
        if antiConnection then antiConnection:Disconnect(); antiConnection = nil end
        antiRemote = check
        lastTokens, tokenQueue = {}, {}
        if not check then S.antiStatus = "AntiMacro.Check отсутствует"; return end
        S.antiStatus = "Ожидание Check(string, number, number, number)"
        antiConnection = check.OnClientEvent:Connect(function(...)
            if not S.alive or not A.alive then return end
            local args = table.pack(...)
            local ok, err = pcall(function()
                S.antiStatus = describePayload(args)
                if not opt("AntiMacro", false) then
                    S.antiStatus = S.antiStatus .. " | автоответ выключен"
                    return
                end
                local token = observedToken(args)
                if not token then
                    problem("anti-shape-v2", "Check отличается от наблюдавшейся формы; ответ не отправлен")
                    return
                end
                if lastTokens[token] then
                    S.antiStatus = "Повтор Check с уже обработанным ключом; повторного Respond нет"
                    return
                end
                local respond = folder:FindFirstChild("Respond")
                if not respond or not respond:IsA("RemoteEvent") then
                    problem("anti-remote-v2", "Нет AntiMacro.Respond")
                    return
                end
                -- Фиксируем попытку ДО отправки; после неопределённого исхода не повторяем.
                lastTokens[token] = true
                tokenQueue[#tokenQueue + 1] = token
                if #tokenQueue > 32 then lastTokens[table.remove(tokenQueue, 1)] = nil end
                respond:FireServer(token)
                S.antiStatus = "Respond отправлен с args[1]; принятие сервером не подтверждено"
            end)
            if not ok then problem("anti-v2", err) end
        end)
    end
    Tabs.Misc:AddParagraph({ Title = "Исправленный AntiMacro",
        Content = "Обрабатывается Check(string, number, number, number); Respond получает только args[1]. " ..
            "Старые AntiArg/AntiField/AntiMulti больше не используются. Включите Anti-Macro до нового Check. " ..
            "Отправка не доказывает принятие ответа; GUI автоматически не скрывается." })

    Tabs.Macro:AddSlider("StepDelay", { Title = "Step delay, секунд", Default = 0.25,
        Min = 0, Max = 2, Rounding = 2,
        Description = "После подтверждения шага до отправки следующего. 0 не отменяет сетевое ожидание." })
    Tabs.Macro:AddSlider("CashSyncTimeout", { Title = "Таймаут ожидания Cash, секунд", Default = 2,
        Min = 0.25, Max = 8, Rounding = 2,
        Description = "Только при WaitCashSync. Таймаут останавливает макрос, НЕ повторяет покупку." })
    local playbackParagraph = Tabs.Macro:AddParagraph({ Title = "Причина ожидания", Content = "Ожидание" })
    button(Tabs.Macro, "Сохранить журнал воспроизведения", function()
        assert(fileOK, "Недоступны файловые функции")
        ensureFolder(ROOT)
        local path = ROOT .. "/STD_Playback_diagnostic.txt"
        local text = table.concat(A.log, "\n")
        writefile(path, text)
        assert(isfile(path) and readfile(path) == text, "Не подтверждена запись журнала")
        notify("Журнал: " .. path)
    end)
    Tabs.Macro:AddParagraph({ Title = "Цена и записанный баланс — разные значения",
        Content = "Старый cash не меняется автоматически. Для запуска по цене задайте ниже проверенный " ..
            "порог каждому нужному шагу и сохраните макрос. Без requiredCash используется старый cash. " ..
            "Цена не вычисляется из разницы Cash: во время покупки мог прийти доход." })
    Tabs.Macro:AddInput("EditCashStep", { Title = "Номер шага для изменения порога", Default = "1", Finished = true })
    Tabs.Macro:AddInput("EditRequiredCash", { Title = "Проверенная цена / нужный порог Cash", Default = "", Finished = true })
    if managersReady and SaveManager then
        SaveManager:SetIgnoreIndexes({ "EditCashStep", "EditRequiredCash", "AutoMacroPick" })
    end
    local function editingStep()
        idleRequired()
        local data = currentMacro()
        local index = tonumber(opt("EditCashStep", ""))
        assert(finite(index) and index % 1 == 0 and data.steps[index], "Нет такого номера шага")
        return data.steps[index], index
    end
    button(Tabs.Macro, "Показать порог выбранного шага", function()
        local step, index = editingStep()
        local threshold, source = stepThreshold(step)
        options.EditRequiredCash:SetValue(tostring(threshold))
        notify("Шаг " .. index .. ": " .. step.kind .. " " .. step.id .. "; " .. threshold .. " (" .. source .. ")")
    end)
    button(Tabs.Macro, "Задать порог шага в памяти", function()
        local step, index = editingStep()
        local value = tonumber(opt("EditRequiredCash", ""))
        assert(finite(value) and value >= 0, "Введите неотрицательный числовой порог")
        step.requiredCash = value
        notify("Шаг " .. index .. ": requiredCash=" .. value .. ". Теперь сохраните макрос в файл")
    end)
    button(Tabs.Macro, "Вернуть шагу баланс записи", function()
        local step, index = editingStep()
        step.requiredCash = nil
        notify("Шаг " .. index .. ": снова используется cash=" .. step.cash .. ". Сохраните файл")
    end)

    -- Сохраняем существующие invoke/confirmStep/locks. Это НЕ доказательство
    -- правильности эвристики fingerprint: поле уровня конкретной игры неизвестно.
    playStep = function(step, valid)
        local threshold = stepThreshold(step)
        local r = remote("Functions", step.kind == "Spawn" and "SpawnTower" or "UpgradeTower", "RemoteFunction")
        if not r then return nil, "RemoteFunction отсутствует" end
        local args, target, priorFingerprint
        if step.kind == "Spawn" then
            args = decodeArgs(step.args)
        else
            local ref = S.playRefs[step.id]
            target = ref and ref.model
            if not target or target.Parent ~= towers() then return nil, "Потеряна башня " .. step.id end
            args = table.pack(target, step.name)
            priorFingerprint = fingerprint(target)
        end
        local before, money = snapshotTowers(), cashNow()
        if not finite(money) or money < threshold then return nil, "Баланс изменился до отправки" end
        if not valid() then return nil, "Остановлено" end
        local revision = S.cashVersion
        if not A.firstSentAt then
            A.firstSentAt = os.clock()
            local _, wave = readWave()
            A.firstSentWave = wave
            trace("FIRST_SEND", "после PLAY_START прошло " .. string.format("%.3f", A.firstSentAt - A.startedAt) .. " с")
        end
        phase("INVOKE", step.kind .. " " .. step.id)
        local response, err = invoke("tower", r, args, valid)
        if not response then return nil, err end
        phase("CONFIRM", "ожидание башни/прокачки")
        local confirmed, confirmError = confirmStep(step, response, before, target, priorFingerprint, valid)
        if not confirmed then return nil, confirmError end
        -- Нулевой ЯВНЫЙ порог можно использовать для подтверждённо бесплатного шага.
        -- Сам cash==0 из старого файла не доказывает бесплатность.
        if opt("WaitCashSync", true) and step.requiredCash ~= 0 and S.cashVersion == revision then
            phase("CASH_SYNC", "ожидание репликации; действие уже отправлено")
            local timeout = tonumber(opt("CashSyncTimeout", 2)) or 2
            local updated, syncError = waitUntil(function()
                return S.cashVersion ~= revision
            end, math.clamp(timeout, 0.25, 8), valid)
            if not updated then
                return nil, "Cash не обновился: " .. tostring(syncError) .. "; шаг НЕ будет повторён"
            end
        end
        trace("STEP_DONE", step.kind .. " " .. step.id)
        return true
    end

    -- Один worker владеет всей сессией, включая ожидание денег и StepDelay.
    -- Событие Cash не создаёт параллельный Pump и не теряется при S.pumping=true:
    -- действующий worker перечитывает Cash на следующем такте планировщика.
    hub.Pump = function()
        if not S.alive or not A.alive or not S.playing or S.pumping then return end
        S.pumping = true
        local epoch = S.playEpoch
        local function valid() return S.alive and A.alive and S.playing and S.playEpoch == epoch end
        if A.runEpoch ~= epoch then
            A.runEpoch = epoch
            A.startedAt, A.firstSentAt, A.firstSentWave = os.clock(), nil, nil
            A.lastConfirmedAt, A.runThreshold = nil, nil
            local _, wave = readWave()
            A.startWave = wave
            observeRound(gate, wave, endVisible(), inConfiguredLobby())
            gate.consumed = true
            gate.reason = A.launching and "Автозапуск выполнен" or "Ручное воспроизведение уже запускалось"
            trace("PLAY_START", A.launching and "auto" or "manual")
        end
        task.spawn(function()
            local ok, err = pcall(function()
                while valid() do
                    if endVisible() then stopPlayback("Матч завершён"); return end
                    local step = S.macro.steps[S.cursor]
                    if not step then
                        phase("DONE", "макрос завершён")
                        stopPlayback("Макрос завершён")
                        return
                    end
                    local threshold, source = stepThreshold(step)
                    A.runThreshold = threshold
                    local delay = math.clamp(tonumber(opt("StepDelay", 0.25)) or 0.25, 0, 2)
                    local remaining = delayRemaining(A.lastConfirmedAt, delay, os.clock())
                    local money = cashNow()
                    if remaining > 0 then
                        phase("STEP_DELAY", "между подтверждением и следующим запросом")
                        task.wait()
                    elseif not finite(money) or money < threshold then
                        phase("WAIT_CASH", "нужно " .. threshold .. " (" .. source .. ")")
                        task.wait()
                    else
                        local done, failure = playStep(step, valid)
                        if not done then
                            if valid() then
                                phase("ERROR", tostring(failure))
                                stopPlayback()
                                problem("play-v2", "Шаг " .. S.cursor .. ": " .. tostring(failure))
                            end
                            return
                        end
                        if not valid() then return end
                        A.lastConfirmedAt = os.clock()
                        S.cursor = S.cursor + 1
                    end
                end
            end)
            S.pumping = false
            if not ok and valid() then
                phase("ERROR", tostring(err))
                stopPlayback()
                problem("play-v2", err)
            elseif not valid() and A.phase ~= "DONE" and A.phase ~= "ERROR" then
                phase("STOPPED", "отправленные запросы не отзываются")
            end
        end)
    end

    local autoParagraph = Tabs.Macro:AddParagraph({ Title = "Автозапуск макроса", Content = "Инициализация" })
    Tabs.Macro:AddInput("AutoMacroName", { Title = "Файл автозапуска (без .json)", Default = "", Finished = true })
    local pick = Tabs.Macro:AddDropdown("AutoMacroPick", {
        Title = "Выбрать файл автозапуска", Values = {}, Multi = false, AllowNull = true,
    })
    Tabs.Macro:AddToggle("AutoMacroEnabled", { Title = "Автозапуск на первой волне", Default = false,
        Description = "Только Wave==1. Ожидание готовности не расходует попытку. Ошибка файла — без повтора." })
    Tabs.Macro:AddParagraph({ Title = "Автозапуск и первый запрос",
        Content = "PLAY_START означает включение плеера. FIRST_SEND — реальную отправку первого шага. " ..
            "Даже при старте на волне 1 запрос ждёт порог денег. Если хаб загружен после волны 1, " ..
            "запускать этот матч задним числом нельзя. После телепорта запустите хаб заново." })
    local function syncPick(names)
        A.syncing = true
        local ok, err = pcall(function()
            local name, found = opt("AutoMacroName", ""), false
            for _, candidate in ipairs(names) do if candidate == name then found = true; break end end
            pick:SetValues(names)
            pick:SetValue(found and name or nil)
            pick:Display()
        end)
        A.syncing = false
        if not ok then error(err) end
    end
    local originalRefresh = refreshMacros
    refreshMacros = function(preferred)
        local names = originalRefresh(preferred)
        syncPick(names)
        return names
    end
    pick:OnChanged(function(name)
        if not A.syncing and safeName(name) then options.AutoMacroName:SetValue(name) end
    end)
    options.AutoMacroName:OnChanged(function()
        if not A.syncing then action(refreshMacros)() end
    end)
    action(refreshMacros)()

    -- Синхронная загрузка Fluent; AutoMacroEnabled применяется последним.
    if managersReady and SaveManager then
        SaveManager:SetIgnoreIndexes({ "AutoMacroPick" })
        function SaveManager:Load(name)
            if not safeName(name) then return false, "Недопустимое имя конфига" end
            if A.loading or A.launching then return false, "Загрузка уже выполняется" end
            if S.recording or S.playing or S.pumping or S.pending > 0 or S.drainScheduled or next(S.locks) then
                return false, "Остановите запись/макрос и дождитесь запросов"
            end
            A.loading, A.configFailed = true, true
            local good, err = pcall(function()
                local path = self.Folder .. "/settings/" .. name .. ".json"
                assert(isfile(path), "Файл конфига отсутствует")
                local text = readfile(path)
                assert(#text <= LIMIT.Bytes, "Конфиг слишком большой")
                local data = Http:JSONDecode(text)
                assert(type(data) == "table", "Повреждён конфиг")
                array(data.objects, 512)
                local autoName, autoEnabled, seen = "", false, {}
                for _, entry in ipairs(data.objects) do
                    assert(type(entry) == "table" and type(entry.idx) == "string"
                        and type(entry.type) == "string", "Повреждён элемент конфига")
                    assert(not seen[entry.idx], "Дублирующаяся настройка: " .. entry.idx)
                    seen[entry.idx] = true
                    if entry.idx == "AutoMacroName" then
                        assert(entry.type == "Input" and type(entry.text) == "string"
                            and (entry.text == "" or safeName(entry.text)), "Неверное имя автомакроса")
                        autoName = entry.text
                    elseif entry.idx == "AutoMacroEnabled" then
                        assert(entry.type == "Toggle" and type(entry.value) == "boolean", "Неверный флаг автомакроса")
                        autoEnabled = entry.value
                    elseif entry.idx == "StepDelay" or entry.idx == "CashSyncTimeout" then
                        local value = tonumber(entry.value)
                        local low = entry.idx == "StepDelay" and 0 or 0.25
                        local high = entry.idx == "StepDelay" and 2 or 8
                        assert(entry.type == "Slider" and finite(value) and value >= low and value <= high,
                            "Неверный интервал: " .. entry.idx)
                    end
                    if self.Options[entry.idx] and not self.Ignore[entry.idx] then
                        assert(self.Options[entry.idx].Type == entry.type, "Тип настройки не совпадает: " .. entry.idx)
                    end
                end
                options.AutoMacroEnabled:SetValue(false)
                options.StepDelay:SetValue(0.25)
                options.CashSyncTimeout:SetValue(2)
                for _, entry in ipairs(data.objects) do
                    if entry.idx ~= "AutoMacroName" and entry.idx ~= "AutoMacroEnabled"
                        and not self.Ignore[entry.idx] then
                        local parser = self.Parser[entry.type]
                        if parser and self.Options[entry.idx] then parser.Load(entry.idx, entry) end
                    end
                end
                options.AutoMacroName:SetValue(autoName)
                refreshMacros()
                options.AutoMacroEnabled:SetValue(autoEnabled)
            end)
            A.loading, A.configFailed = false, not good
            if not good then
                pcall(function() options.AutoMacroEnabled:SetValue(false) end)
                A.status = "Ошибка конфига; автозапуск заблокирован"
                return false, tostring(err)
            end
            return true
        end
        -- Upstream LoadAutoloadConfig не возвращает ошибку self:Load вызывающему.
        -- Здесь сохраняем состояние ошибки для барьера запуска.
        function SaveManager:LoadAutoloadConfig()
            local good, loaded, detail = pcall(function()
                local path = self.Folder .. "/settings/autoload.txt"
                if not isfile(path) then return true, nil end
                local name = readfile(path)
                assert(#name <= 128, "Повреждён autoload.txt")
                name = name:match("^%s*(.-)%s*$")
                local ok, err = self:Load(name)
                return ok, ok and name or err
            end)
            if not good or not loaded then
                A.configFailed = true
                pcall(function() options.AutoMacroEnabled:SetValue(false) end)
                problem("autoload-v2", good and detail or loaded)
                return false
            end
            if detail then notify("Конфиг загружен: " .. detail) end
            return true
        end
    end

    local evaluate
    local function attachWave(obj)
        if obj == A.waveObject then return end
        if A.waveConnection then A.waveConnection:Disconnect() end
        A.waveObject, A.waveConnection = obj, nil
        if obj then
            A.waveConnection = obj:GetPropertyChangedSignal("Value"):Connect(function() evaluate() end)
        end
    end
    local function userBusy()
        return S.recording or S.playing or S.pumping or S.pending > 0 or S.drainScheduled
    end
    local function attempt()
        if not A.alive or not S.alive then return end
        local obj, wave = readWave()
        attachWave(obj)
        local lobby, ended = inConfiguredLobby(), endVisible()
        local eligible = observeRound(gate, wave, ended, lobby)
        if not A.ready or A.loading then A.status = "Ожидание завершения загрузки конфига"; return end
        if A.configFailed then A.status = "Ошибка конфига: автозапуск заблокирован"; return end
        if not opt("AutoMacroEnabled", false) then A.status = "Выключен"; return end
        if lobby then A.status = "Лобби: ожидание матча"; return end
        if ended then A.status = "Конец матча: ожидание новой волны 1"; return end
        if not eligible then
            A.status = gate.consumed and (gate.reason or "Попытка этого матча обработана")
                or ("Ожидание первой волны; Wave=" .. tostring(wave))
            return
        end
        if userBusy() then
            gate.consumed, gate.reason = true, "Пропуск: ручная запись/воспроизведение уже выполняется"
            A.status = gate.reason
            return
        end
        -- Недостающая репликация и занятый запрос не расходуют разрешение.
        -- Как только Wave станет >1, запоздалого старта не будет.
        local cash = cashNow()
        if not finite(cash) or cash < 0 or not towers()
            or not remote("Functions", "SpawnTower", "RemoteFunction")
            or not remote("Functions", "UpgradeTower", "RemoteFunction")
            or S.locks.tower or S.workers.elevator then
            A.status = "Волна 1: ожидание готовности Cash/Towers/remotes/запроса"
            return
        end
        gate.consumed, gate.reason = true, "Попытка запуска"
        A.launching = true
        local ok, err = pcall(function()
            local name = opt("AutoMacroName", "")
            assert(fileOK, "Недоступны файловые функции")
            assert(safeName(name), "Не выбран файл автозапуска")
            local path = macroPath(name)
            assert(isfile(path), "Файл отсутствует: " .. path)
            local text = readfile(path)
            assert(#text <= LIMIT.Bytes, "Файл макроса слишком большой")
            local data = validateMacro(Http:JSONDecode(text))
            assert(#data.steps > 0, "Макрос пуст")
            assert(data.placeId == game.PlaceId and data.gameId == game.GameId, "Другой PlaceId/GameId")
            idleRequired()
            local _, currentWave = readWave()
            assert(A.alive and S.alive and currentWave == 1 and not endVisible()
                and not inConfiguredLobby(), "Первая волна уже закончилась")
            resetMemory()
            S.macro = data
            options.MacroName:SetValue(name)
            startPlayback()
            gate.reason = "Запущен " .. name .. "; первая отправка зависит от порога Cash"
            notify("Автозапуск: " .. name)
        end)
        A.launching = false
        if not ok then
            gate.reason = "Ошибка автозапуска: " .. tostring(err)
            problem("auto-macro-v2", gate.reason)
        end
        A.status = gate.reason
    end
    evaluate = function()
        if A.evaluating then return end
        A.evaluating = true
        local ok, err = pcall(attempt)
        A.evaluating = false
        if not ok then
            A.status = "Ошибка наблюдателя: " .. tostring(err)
            problem("auto-observer-v2", err)
        end
    end
    local originalDestroy = hub.Destroy
    hub.Destroy = function(...)
        A.alive = false
        if A.waveConnection then A.waveConnection:Disconnect(); A.waveConnection = nil end
        return originalDestroy(...)
    end
    function hub.CompleteAutoMacroStartup()
        A.ready = true
        evaluate()
    end
    task.defer(function()
        local lastAuto
        while A.alive and S.alive and not Fluent.Unloaded do
            evaluate()
            local ok, err = pcall(function()
                if A.status ~= lastAuto then autoParagraph:SetDesc(A.status); lastAuto = A.status end
                local _, wave = readWave()
                local step = S.playing and S.macro.steps[S.cursor] or nil
                local threshold, source
                if step then threshold, source = stepThreshold(step) end
                local text = A.phase .. " | " .. A.reason .. "\nWave=" .. tostring(wave)
                    .. " | Cash=" .. tostring(cashNow()) .. " | шаг=" .. tostring(S.cursor)
                    .. (step and (" | нужен Cash=" .. threshold .. " (" .. source .. ")") or "")
                    .. "\nPLAY_START: волна " .. tostring(A.startWave)
                    .. " | FIRST_SEND: волна " .. tostring(A.firstSentWave)
                if text ~= A.lastDetail then playbackParagraph:SetDesc(text); A.lastDetail = text end
            end)
            if not ok then problem("auto-status-v2", err) end
            task.wait(0.05)
        end
    end)
end

-- КОНЕЦ ВСТАВКИ. Далее остаётся исходный Window:SelectTab(1).
Window:SelectTab(1)
refreshCash()
refreshRecordCache()
bindAntiMacro()
local statusAt = 0
local lastStatus, lastDiagnostic, lastAnti = "", "", ""
local function setParagraph(paragraph, text)
    if paragraph and type(paragraph.SetDesc) == "function" then paragraph:SetDesc(text) end
end
-- Фоновые ошибки разделены: сбой одного модуля не отключает остальные.
local function safeCycle(key, fn)
    local ok, err = pcall(fn)
    if not ok then problem(key, err) end
end
local function statusCycle()
    if os.clock() - statusAt < 1 then return end
    statusAt = os.clock()
    local count = #S.entries > 0 and #S.entries or #S.macro.steps
    local mode = S.recording and "Запись" or (S.playing and "Воспроизведение" or "Ожидание")
    local nextStep = S.playing and S.macro.steps[S.cursor] or nil
    local text = mode .. " | шагов: " .. count .. " | позиция: " .. S.cursor .. " | Cash: " .. tostring(cashNow())
        .. " | очередь снимков: " .. S.pending .. (nextStep and (" | порог: " .. nextStep.cash) or "")
    local ps = LP:FindFirstChild("PlayerScripts")
    local client = ps and ps:FindFirstChild("AntiMacroClient")
    local info = WS:FindFirstChild("Info")
    local wave = info and info:FindFirstChild("Wave")
    local diagnosticText = "Файлы: " .. tostring(fileOK) .. " | Удаление: " .. tostring(deleteOK)
        .. " | Hook установлен: " .. tostring(S.recordEnabled) .. " | AntiMacroClient: " .. tostring(client ~= nil)
        .. " | Wave: " .. tostring(wave and wave.Value) .. "\nПоследняя проблема: " .. S.lastError
    if text ~= lastStatus then setParagraph(statusParagraph, text); lastStatus = text end
    if diagnosticText ~= lastDiagnostic then setParagraph(diagnostics, diagnosticText); lastDiagnostic = diagnosticText end
    if S.antiStatus ~= lastAnti then setParagraph(antiParagraph, S.antiStatus); lastAnti = S.antiStatus end
end
task.spawn(function()
    while S.alive and not Fluent.Unloaded do
        safeCycle("cash", refreshCash)
        safeCycle("record-cache", refreshRecordCache)
        if dispatcher and dispatcher.fault then
            local fault = dispatcher.fault
            dispatcher.fault = nil
            recordingError(fault)
        end
        safeCycle("anti-bind", bindAntiMacro)
        safeCycle("map", function()
            guiGate("map", "Voting", opt("AutoMap", false), opt("Map", "Area 51"), "VoteForMap", opt("Map", "Area 51"))
        end)
        safeCycle("difficulty", function()
            guiGate("difficulty", "ComplicationVoting", opt("AutoDifficulty", false), opt("Difficulty", "Normal"),
                "VoteForComplication", opt("Difficulty", "Normal"))
        end)
        safeCycle("end", endCycle)
        safeCycle("elevator", elevatorCycle)
        safeCycle("speed", speedCycle)
        safeCycle("walk", walkCycle)
        safeCycle("pump", hub.Pump)
        safeCycle("status", statusCycle)
        task.wait(0.25)
    end
    hub.Destroy("Окно закрыто")
end)
if managersReady then
    local ok, err = pcall(function() SaveManager:LoadAutoloadConfig() end)
    if not ok then problem("autoload", err) end
end
hub.CompleteAutoMacroStartup()
notify("V2 загружен. Хук установится при Start Recording. Требуется проверка в реальном Delta/Roblox.")
return hub
