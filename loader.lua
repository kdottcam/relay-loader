--[[
    Relay — public loader

    Usage (paste into any executor):
        loadstring(game:HttpGet("https://raw.githubusercontent.com/kdottcam/relay-loader/main/loader.lua"))()

    Flow:
      1. If a key is already defined (buyer-style `key="..."` above the loadstring) → load Relay straight away.
      2. Else, if a key was saved from a previous session → validate it and load.
      3. Else, show the Relay key UI. On submit the key is checked against relayscripts.vercel.app,
         saved locally, and handed to the Sanctuary loader.

    Sanctuary keeps doing all the real auth/HWID work; this file only gets a key into `key`.
]]

local CONFIG = {
    SanctuaryLoader = "https://cdn.snc.dev/6a9517176bf508256ce22521/loader",
    ApiBase         = "https://relayscripts.vercel.app/api/loader",
    GetKeyUrl       = "https://relayscripts.vercel.app/get-key",
    Website         = "relayscripts.vercel.app",
    Discord         = "discord.gg/relayscripts",
    KeyFolder       = "Relay",
    KeyFile         = "Relay/key.txt",
    KeyPattern      = "^[%w_%-]+$",
    KeyMinLen       = 12,
    KeyMaxLen       = 64,
}

------------------------------------------------------------------------
-- Executor compatibility helpers
------------------------------------------------------------------------
local HttpService  = game:GetService("HttpService")
local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInput    = game:GetService("UserInputService")
local MarketPlace  = game:GetService("MarketplaceService")

local LocalPlayer = Players.LocalPlayer

local requestFn = (syn and syn.request) or (http and http.request) or (fluxus and fluxus.request) or http_request or request
local hasFiles  = typeof(readfile) == "function" and typeof(writefile) == "function" and typeof(isfile) == "function"
local env       = (typeof(getgenv) == "function" and getgenv()) or _G

local function executorName()
    if typeof(identifyexecutor) == "function" then
        local ok, name = pcall(identifyexecutor)
        if ok and typeof(name) == "string" and #name > 0 then return name end
    end
    if typeof(getexecutorname) == "function" then
        local ok, name = pcall(getexecutorname)
        if ok and typeof(name) == "string" and #name > 0 then return name end
    end
    return "Unknown"
end

local function guiParent()
    if typeof(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then return hui end
    end
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core then
        local test = Instance.new("Folder")
        local okParent = pcall(function() test.Parent = core end)
        test:Destroy()
        if okParent then return core end
    end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local function readSavedKey()
    if not hasFiles then return nil end
    local ok, data = pcall(function()
        if isfile(CONFIG.KeyFile) then return readfile(CONFIG.KeyFile) end
    end)
    if ok and typeof(data) == "string" then
        data = data:gsub("%s+", "")
        if #data > 0 then return data end
    end
    return nil
end

local function saveKey(key)
    if not hasFiles then return end
    pcall(function()
        if typeof(makefolder) == "function" and typeof(isfolder) == "function" and not isfolder(CONFIG.KeyFolder) then
            makefolder(CONFIG.KeyFolder)
        end
        writefile(CONFIG.KeyFile, key)
    end)
end

local function clearSavedKey()
    if not hasFiles then return end
    pcall(function()
        if typeof(delfile) == "function" and isfile(CONFIG.KeyFile) then delfile(CONFIG.KeyFile) end
    end)
end

local function keyLooksValid(key)
    return typeof(key) == "string"
        and #key >= CONFIG.KeyMinLen
        and #key <= CONFIG.KeyMaxLen
        and key:match(CONFIG.KeyPattern) ~= nil
end

-- Returns: ok(boolean), message(string), retryable(boolean)
local function validateKey(key)
    if not requestFn then
        -- No HTTP request function: we can't pre-check, let Sanctuary decide.
        return true, "Skipping pre-check (no request function).", true
    end
    local ok, res = pcall(requestFn, {
        Url = CONFIG.ApiBase .. "/validate",
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = HttpService:JSONEncode({ key = key }),
    })
    if not ok or typeof(res) ~= "table" then
        return true, "Relay API unreachable, trying anyway…", true
    end
    local okJson, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
    if not okJson or typeof(data) ~= "table" then
        return true, "Relay API returned bad data, trying anyway…", true
    end
    if data.valid == true then
        return true, data.message or "Key accepted.", false
    end
    return false, data.message or "That key was rejected.", data.retry == true
end

local function fetchConfig()
    local ok, body = pcall(function() return game:HttpGet(CONFIG.ApiBase .. "/config") end)
    if not ok or typeof(body) ~= "string" then return nil end
    local okJson, data = pcall(HttpService.JSONDecode, HttpService, body)
    if okJson and typeof(data) == "table" then return data end
    return nil
end

local function loadRelay(k)
    -- The Sanctuary loader reads the global `key`; set it everywhere it might look.
    env.key = k
    pcall(function() getfenv(0).key = k end)
    key = k
    local ok, err = pcall(function()
        loadstring(game:HttpGet(CONFIG.SanctuaryLoader))()
    end)
    return ok, err
end

------------------------------------------------------------------------
-- Fast paths: buyer-style key or saved key
------------------------------------------------------------------------
if keyLooksValid(env.key) then
    loadRelay(env.key)
    return
end

local remote = fetchConfig() or {}
if typeof(remote.links) == "table" then
    CONFIG.GetKeyUrl = remote.links.getKey or CONFIG.GetKeyUrl
    CONFIG.Website   = remote.links.website or CONFIG.Website
    CONFIG.Discord   = remote.links.discord or CONFIG.Discord
end

local supportedGames = {}
if typeof(remote.games) == "table" then
    for _, entry in ipairs(remote.games) do
        if typeof(entry) == "table" and entry.placeId then
            supportedGames[tostring(entry.placeId)] = entry.name or "Supported game"
        end
    end
end

local savedKeyError
do
    local saved = readSavedKey()
    if saved and keyLooksValid(saved) then
        local ok, message, retryable = validateKey(saved)
        if ok then
            local loaded, err = loadRelay(saved)
            if loaded then return end
            clearSavedKey()
            savedKeyError = "Saved key was rejected, enter a new one."
            warn("[Relay] loader error: " .. tostring(err))
        elseif not retryable then
            clearSavedKey()
            savedKeyError = message
        else
            savedKeyError = message
        end
    elseif saved then
        clearSavedKey()
    end
end

------------------------------------------------------------------------
-- Key UI
------------------------------------------------------------------------
local C = {
    Backdrop = Color3.fromRGB(8, 8, 12),
    Panel    = Color3.fromRGB(18, 18, 26),
    Panel2   = Color3.fromRGB(23, 23, 32),
    Input    = Color3.fromRGB(28, 28, 38),
    Stroke   = Color3.fromRGB(40, 40, 54),
    Accent   = Color3.fromRGB(167, 150, 240),
    AccentDk = Color3.fromRGB(122, 106, 200),
    Text     = Color3.fromRGB(242, 242, 247),
    Muted    = Color3.fromRGB(138, 138, 153),
    Good     = Color3.fromRGB(126, 226, 168),
    Warn     = Color3.fromRGB(240, 194, 107),
    Bad      = Color3.fromRGB(255, 122, 122),
}

local FONT      = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold

local function new(class, props, children)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do inst[k] = v end
    for _, child in ipairs(children or {}) do child.Parent = inst end
    return inst
end

local function corner(radius) return new("UICorner", { CornerRadius = UDim.new(0, radius) }) end
local function stroke(color, thickness, transparency)
    return new("UIStroke", { Color = color or C.Stroke, Thickness = thickness or 1, Transparency = transparency or 0, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end
local function pad(t, r, b, l)
    return new("UIPadding", { PaddingTop = UDim.new(0, t), PaddingRight = UDim.new(0, r), PaddingBottom = UDim.new(0, b), PaddingLeft = UDim.new(0, l) })
end
local function label(props)
    local base = { BackgroundTransparency = 1, Font = FONT, TextColor3 = C.Text, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, Text = "" }
    for k, v in pairs(props) do base[k] = v end
    return new("TextLabel", base)
end

-- Root ------------------------------------------------------------------
local existing = guiParent():FindFirstChild("RelayKeySystem")
if existing then existing:Destroy() end

local gui = new("ScreenGui", { Name = "RelayKeySystem", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999, IgnoreGuiInset = true })

local backdrop = new("Frame", { BackgroundColor3 = C.Backdrop, BackgroundTransparency = 0.35, Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, Parent = gui })

local panel = new("Frame", {
    Name = "Panel", BackgroundColor3 = C.Panel, BorderSizePixel = 0,
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(620, 340),
    Parent = gui,
}, { corner(16), stroke(C.Stroke, 1) })

-- Scale down on small (mobile) viewports
local scale = new("UIScale", { Parent = panel })
local function fitScale()
    local cam = workspace.CurrentCamera
    if not cam then return end
    local vp = cam.ViewportSize
    local s = math.min(1, (vp.X - 24) / 620, (vp.Y - 24) / 340)
    scale.Scale = math.max(0.55, s)
end
fitScale()
if workspace.CurrentCamera then workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitScale) end

-- Left column --------------------------------------------------------------
local left = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(0.58, 0, 1, 0), Parent = panel }, { pad(26, 22, 22, 28) })

local logoRow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44), Parent = left })
local chevrons = label({ Text = "»", Font = FONT_BOLD, TextSize = 40, TextColor3 = C.Accent, Size = UDim2.fromOffset(34, 44), Position = UDim2.fromOffset(0, -4), Parent = logoRow })
label({ Text = "relay", Font = FONT_BOLD, TextSize = 26, Size = UDim2.new(1, -40, 0, 26), Position = UDim2.fromOffset(40, 2), Parent = logoRow })
label({ Text = "Key system", TextColor3 = C.Muted, TextSize = 12, Size = UDim2.new(1, -40, 0, 16), Position = UDim2.fromOffset(40, 27), Parent = logoRow })

label({ Text = "LICENSE KEY", TextColor3 = C.Muted, TextSize = 11, Font = FONT_BOLD, Size = UDim2.new(1, 0, 0, 14), Position = UDim2.fromOffset(0, 74), Parent = left })

local inputFrame = new("Frame", { BackgroundColor3 = C.Input, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 44), Position = UDim2.fromOffset(0, 92), Parent = left }, { corner(10), stroke(C.Stroke, 1) })
local inputStroke = inputFrame:FindFirstChildOfClass("UIStroke")
label({ Text = "⚿", TextSize = 16, TextColor3 = C.Muted, Size = UDim2.fromOffset(28, 44), Position = UDim2.fromOffset(12, 0), TextXAlignment = Enum.TextXAlignment.Center, Parent = inputFrame })
local input = new("TextBox", {
    BackgroundTransparency = 1, Font = FONT, TextSize = 14, TextColor3 = C.Text, PlaceholderColor3 = C.Muted,
    PlaceholderText = "Paste your Relay key", Text = "", ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left,
    Size = UDim2.new(1, -52, 1, 0), Position = UDim2.fromOffset(42, 0), Parent = inputFrame,
})

local submit = new("TextButton", {
    BackgroundColor3 = C.Accent, AutoButtonColor = false, Text = "", BorderSizePixel = 0,
    Size = UDim2.new(0.5, -6, 0, 42), Position = UDim2.fromOffset(0, 150), Parent = left,
}, { corner(10) })
label({ Text = "➜   Submit", Font = FONT_BOLD, TextSize = 14, TextColor3 = Color3.fromRGB(20, 16, 40), Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Parent = submit })

local getKey = new("TextButton", {
    BackgroundColor3 = C.Panel2, AutoButtonColor = false, Text = "", BorderSizePixel = 0,
    Size = UDim2.new(0.5, -6, 0, 42), Position = UDim2.new(0.5, 6, 0, 150), Parent = left,
}, { corner(10), stroke(C.Stroke, 1) })
local getKeyText = label({ Text = "🌐   Get a key", Font = FONT_BOLD, TextSize = 14, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Parent = getKey })

local status = label({ Text = "", TextSize = 12, TextColor3 = C.Muted, Size = UDim2.new(1, 0, 0, 34), Position = UDim2.fromOffset(0, 200), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Parent = left })

label({ Text = hasFiles and "Your key is saved after the first successful load." or "This executor can't save files, you'll need to re-enter your key each time.",
    TextSize = 11, TextColor3 = C.Muted, Size = UDim2.new(1, 0, 0, 30), Position = UDim2.new(0, 0, 1, -32), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Bottom, Parent = left })

-- Divider ------------------------------------------------------------------
new("Frame", { BackgroundColor3 = C.Stroke, BorderSizePixel = 0, Size = UDim2.new(0, 1, 1, -44), Position = UDim2.new(0.58, 0, 0, 22), Parent = panel })

-- Right column ---------------------------------------------------------------
local right = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(0.42, 0, 1, 0), Position = UDim2.fromScale(0.58, 0), Parent = panel }, { pad(26, 26, 22, 22) })

label({ Text = "DETECTED GAME", TextColor3 = C.Muted, TextSize = 11, Font = FONT_BOLD, Size = UDim2.new(1, 0, 0, 14), Parent = right })

local gameCard = new("Frame", { BackgroundColor3 = C.Panel2, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 58), Position = UDim2.fromOffset(0, 20), Parent = right }, { corner(10), stroke(C.Stroke, 1) })
local thumb = new("ImageLabel", { BackgroundColor3 = C.Input, BorderSizePixel = 0, Size = UDim2.fromOffset(40, 40), Position = UDim2.fromOffset(9, 9), Image = "", ScaleType = Enum.ScaleType.Crop, Parent = gameCard }, { corner(8) })
local gameName = label({ Text = "Detecting…", Font = FONT_BOLD, TextSize = 13, Size = UDim2.new(1, -62, 0, 18), Position = UDim2.fromOffset(58, 12), TextTruncate = Enum.TextTruncate.AtEnd, Parent = gameCard })
local gameState = label({ Text = "", TextSize = 12, TextColor3 = C.Muted, Size = UDim2.new(1, -62, 0, 16), Position = UDim2.fromOffset(58, 31), Parent = gameCard })

local function infoRow(y, key, value, valueColor)
    label({ Text = key, TextSize = 12, TextColor3 = C.Muted, Size = UDim2.new(0.5, 0, 0, 18), Position = UDim2.fromOffset(0, y), Parent = right })
    return label({ Text = value, TextSize = 12, TextColor3 = valueColor or C.Text, Font = FONT_BOLD, Size = UDim2.new(0.5, 0, 0, 18), Position = UDim2.new(0.5, 0, 0, y), TextXAlignment = Enum.TextXAlignment.Right, Parent = right })
end
infoRow(92, "Executor", executorName())
local statusValue = infoRow(114, "Status", "Key required", C.Warn)

new("Frame", { BackgroundColor3 = C.Stroke, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromOffset(0, 146), Parent = right })

local function linkRow(y, icon, title, value)
    local btn = new("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.new(1, 0, 0, 40), Position = UDim2.fromOffset(0, y), Parent = right })
    label({ Text = icon, TextSize = 16, TextColor3 = C.Muted, Size = UDim2.fromOffset(24, 40), TextXAlignment = Enum.TextXAlignment.Center, Parent = btn })
    label({ Text = title, Font = FONT_BOLD, TextSize = 13, Size = UDim2.new(1, -30, 0, 18), Position = UDim2.fromOffset(32, 3), Parent = btn })
    local sub = label({ Text = value, TextSize = 12, TextColor3 = C.Muted, Size = UDim2.new(1, -30, 0, 16), Position = UDim2.fromOffset(32, 21), Parent = btn })
    btn.MouseButton1Click:Connect(function()
        if typeof(setclipboard) == "function" then
            pcall(setclipboard, value)
            local old = sub.Text
            sub.Text = "Copied to clipboard"
            sub.TextColor3 = C.Good
            task.delay(1.6, function() sub.Text = old; sub.TextColor3 = C.Muted end)
        end
    end)
    return btn
end
linkRow(158, "💬", "Discord", CONFIG.Discord)
linkRow(204, "🌐", "Website", CONFIG.Website)

-- Game detection -------------------------------------------------------------
task.spawn(function()
    local placeId = tostring(game.PlaceId)
    local supportedName = supportedGames[placeId]
    local name = supportedName
    if not name then
        local ok, info = pcall(MarketPlace.GetProductInfo, MarketPlace, game.PlaceId)
        name = (ok and info and info.Name) or ("Place " .. placeId)
    end
    gameName.Text = name
    if supportedName then
        gameState.Text = "Supported"; gameState.TextColor3 = C.Good
    elseif next(supportedGames) == nil then
        gameState.Text = "Support list unavailable"; gameState.TextColor3 = C.Muted
    else
        gameState.Text = "Not supported"; gameState.TextColor3 = C.Warn
    end
    pcall(function()
        thumb.Image = "rbxthumb://type=GameIcon&id=" .. placeId .. "&w=150&h=150"
    end)
end)

-- Interactions ---------------------------------------------------------------
local function setStatus(text, color)
    status.Text = text
    status.TextColor3 = color or C.Muted
end

local function tween(obj, props, t)
    TweenService:Create(obj, TweenInfo.new(t or 0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

submit.MouseEnter:Connect(function() tween(submit, { BackgroundColor3 = C.AccentDk }) end)
submit.MouseLeave:Connect(function() tween(submit, { BackgroundColor3 = C.Accent }) end)
getKey.MouseEnter:Connect(function() tween(getKey, { BackgroundColor3 = C.Input }) end)
getKey.MouseLeave:Connect(function() tween(getKey, { BackgroundColor3 = C.Panel2 }) end)
input.Focused:Connect(function() tween(inputStroke, { Color = C.Accent }) end)

getKey.MouseButton1Click:Connect(function()
    if typeof(setclipboard) == "function" then
        pcall(setclipboard, CONFIG.GetKeyUrl)
        getKeyText.Text = "Link copied!"
        task.delay(1.6, function() getKeyText.Text = "🌐   Get a key" end)
        setStatus("Open the copied link in your browser to get a free or paid key.", C.Muted)
    else
        setStatus("Get a key at " .. CONFIG.GetKeyUrl, C.Muted)
    end
end)

local busy = false
local function trySubmit()
    if busy then return end
    local key = input.Text:gsub("%s+", "")
    if #key == 0 then setStatus("Enter your Relay key first.", C.Bad) return end
    if not keyLooksValid(key) then setStatus("That key is not in a valid format.", C.Bad) return end

    busy = true
    setStatus("Checking key…", C.Muted)
    statusValue.Text = "Checking"; statusValue.TextColor3 = C.Muted

    local ok, message = validateKey(key)
    if not ok then
        busy = false
        setStatus(message, C.Bad)
        statusValue.Text = "Rejected"; statusValue.TextColor3 = C.Bad
        return
    end

    setStatus("Key accepted, loading Relay…", C.Good)
    statusValue.Text = "Loading"; statusValue.TextColor3 = C.Good
    saveKey(key)
    task.wait(0.4)

    tween(panel, { BackgroundTransparency = 1 }, 0.2)
    tween(backdrop, { BackgroundTransparency = 1 }, 0.2)
    task.wait(0.2)
    gui:Destroy()

    local loaded, err = loadRelay(key)
    if not loaded then
        clearSavedKey()
        warn("[Relay] Sanctuary loader error: " .. tostring(err))
    end
end
submit.MouseButton1Click:Connect(trySubmit)
input.FocusLost:Connect(function(enter) tween(inputStroke, { Color = C.Stroke }); if enter then task.spawn(trySubmit) end end)

-- Drag the panel
do
    local dragging, dragStart, startPos
    panel.InputBegan:Connect(function(io)
        if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = io.Position; startPos = panel.Position
        end
    end)
    panel.InputEnded:Connect(function(io)
        if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
    UserInput.InputChanged:Connect(function(io)
        if dragging and (io.UserInputType == Enum.UserInputType.MouseMovement or io.UserInputType == Enum.UserInputType.Touch) then
            local d = io.Position - dragStart
            panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

if savedKeyError then setStatus(savedKeyError, C.Warn) end

-- Intro animation
panel.BackgroundTransparency = 1
backdrop.BackgroundTransparency = 1
gui.Parent = guiParent()
tween(panel, { BackgroundTransparency = 0 }, 0.25)
tween(backdrop, { BackgroundTransparency = 0.35 }, 0.25)
