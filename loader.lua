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
    Backdrop = Color3.fromRGB(4, 4, 8),
    Panel    = Color3.fromRGB(12, 12, 18),
    Card     = Color3.fromRGB(18, 18, 27),
    Input    = Color3.fromRGB(22, 22, 32),
    Stroke   = Color3.fromRGB(36, 36, 50),
    Accent   = Color3.fromRGB(167, 150, 240),
    AccentDk = Color3.fromRGB(128, 112, 205),
    OnAccent = Color3.fromRGB(16, 12, 34),
    Text     = Color3.fromRGB(244, 244, 250),
    Muted    = Color3.fromRGB(132, 132, 150),
    Good     = Color3.fromRGB(120, 224, 165),
    Warn     = Color3.fromRGB(240, 194, 107),
    Bad      = Color3.fromRGB(255, 118, 118),
}

local FONT       = Enum.Font.GothamMedium
local FONT_BOLD  = Enum.Font.GothamBold
local FONT_BLACK = Enum.Font.GothamBlack

-- Lucide icons (https://lucide.dev) via latte-soft/lucide-roblox 48px sprite sheets: { assetId, x, y }
local ICONS = {
    ["key-round"]      = { 16898613509, 967, 306 },
    ["globe"]          = { 16898613509, 771, 563 },
    ["arrow-right"]    = { 16898612629, 453, 820 },
    ["message-circle"] = { 16898613613, 563, 820 },
    ["gamepad-2"]      = { 16898613353, 710, 967 },
    ["monitor"]        = { 16898613613, 404, 820 },
    ["shield-check"]   = { 16898613777, 820, 257 },
    ["link"]           = { 16898613509, 918, 453 },
    ["check"]          = { 16898612819, 710, 869 },
    ["circle-check"]   = { 16898612819, 869, 955 },
    ["circle-alert"]   = { 16898612819, 918, 808 },
    ["triangle-alert"] = { 16898613869, 967, 0 },
    ["loader-circle"]  = { 16898613509, 771, 906 },
    ["x"]              = { 16898613869, 869, 906 },
    ["lock"]           = { 16898613509, 918, 857 },
}

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
local function icon(name, size, color, props)
    local data = ICONS[name] or ICONS["circle-alert"]
    local base = {
        BackgroundTransparency = 1, Image = "rbxassetid://" .. data[1],
        ImageRectSize = Vector2.new(48, 48), ImageRectOffset = Vector2.new(data[2], data[3]),
        ImageColor3 = color or C.Text, Size = UDim2.fromOffset(size, size), ScaleType = Enum.ScaleType.Fit,
    }
    for k, v in pairs(props or {}) do base[k] = v end
    return new("ImageLabel", base)
end
local function setIcon(img, name)
    local data = ICONS[name]
    if not data then return end
    img.Image = "rbxassetid://" .. data[1]
    img.ImageRectOffset = Vector2.new(data[2], data[3])
end

-- Relay logo: two chevrons (white behind, lavender in front), each drawn from two rotated rounded bars.
local function chevron(parent, x, y, height, color)
    -- Roblox rotates around a frame's centre, so place each arm's centre on the diagonal explicitly.
    local thick = math.max(4, math.floor(height * 0.26 + 0.5))
    local arm = height * 0.66
    local d = arm / math.sqrt(2)              -- horizontal/vertical extent of a 45° arm
    local px = d + thick * 0.5                -- x of the chevron's point inside the holder
    local holder = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(math.ceil(d + thick), height), Position = UDim2.fromOffset(x, y), Parent = parent })
    for _, arm_ in ipairs({ { rot = -45, cy = height / 2 - d / 2 }, { rot = 45, cy = height / 2 + d / 2 } }) do
        new("Frame", {
            BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(thick, math.floor(arm + thick * 0.6)),
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(px - d / 2, arm_.cy), Rotation = arm_.rot, Parent = holder,
        }, { corner(thick) })
    end
    return holder
end

local function tween(obj, props, t)
    TweenService:Create(obj, TweenInfo.new(t or 0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

-- Root ------------------------------------------------------------------
local W, H = 540, 372
local parentGui = guiParent()
local existing = parentGui:FindFirstChild("RelayKeySystem")
if existing then existing:Destroy() end

local gui = new("ScreenGui", { Name = "RelayKeySystem", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999, IgnoreGuiInset = true })
local backdrop = new("Frame", { BackgroundColor3 = C.Backdrop, BackgroundTransparency = 0.45, Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, Parent = gui })

local panel = new("Frame", {
    Name = "Panel", BackgroundColor3 = C.Panel, BorderSizePixel = 0,
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(W, H),
    Parent = gui,
}, { corner(18), stroke(C.Stroke, 1) })

-- faint lavender outer ring so the panel lifts off busy game backgrounds
new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 6, 1, 6), ZIndex = 0, Parent = panel }, { corner(21), stroke(C.Accent, 1, 0.85) })

local scale = new("UIScale", { Parent = panel })
local function fitScale()
    local cam = workspace.CurrentCamera
    if not cam then return end
    local vp = cam.ViewportSize
    scale.Scale = math.max(0.55, math.min(1, (vp.X - 24) / W, (vp.Y - 24) / H))
end
fitScale()
if workspace.CurrentCamera then workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitScale) end

-- Header ------------------------------------------------------------------
local header = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 68), Parent = panel }, { pad(0, 18, 0, 22) })
chevron(header, 0, 20, 28, Color3.fromRGB(250, 250, 252))
chevron(header, 15, 20, 28, C.Accent)
label({ Text = "relay", Font = FONT_BLACK, TextSize = 24, Size = UDim2.fromOffset(80, 30), Position = UDim2.fromOffset(52, 19), Parent = header })
local badge = new("Frame", { BackgroundColor3 = C.Card, BorderSizePixel = 0, Size = UDim2.fromOffset(92, 22), Position = UDim2.fromOffset(126, 23), Parent = header }, { corner(11), stroke(C.Stroke, 1) })
icon("lock", 11, C.Accent, { Position = UDim2.fromOffset(9, 5), Parent = badge })
label({ Text = "KEY SYSTEM", Font = FONT_BOLD, TextSize = 10, TextColor3 = C.Accent, Size = UDim2.new(1, -26, 1, 0), Position = UDim2.fromOffset(25, 0), Parent = badge })

local closeBtn = new("TextButton", { BackgroundColor3 = C.Card, AutoButtonColor = false, Text = "", BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Size = UDim2.fromOffset(30, 30), Position = UDim2.new(1, 0, 0, 19), Parent = header }, { corner(9), stroke(C.Stroke, 1) })
local closeIcon = icon("x", 14, C.Muted, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = closeBtn })
closeBtn.MouseEnter:Connect(function() tween(closeIcon, { ImageColor3 = C.Text }) end)
closeBtn.MouseLeave:Connect(function() tween(closeIcon, { ImageColor3 = C.Muted }) end)
closeBtn.MouseButton1Click:Connect(function() gui:Destroy() end)

-- accent hairline under the header
local hair = new("Frame", { BackgroundColor3 = C.Accent, BorderSizePixel = 0, Size = UDim2.new(1, -44, 0, 1), Position = UDim2.fromOffset(22, 68), Parent = panel })
new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(0.6, 0.75), NumberSequenceKeypoint.new(1, 1) }), Parent = hair })

-- Body --------------------------------------------------------------------
local body = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -69), Position = UDim2.fromOffset(0, 69), Parent = panel }, { pad(18, 22, 20, 22) })

-- Game strip
local gameCard = new("Frame", { BackgroundColor3 = C.Card, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 64), Parent = body }, { corner(12), stroke(C.Stroke, 1) })
local thumb = new("ImageLabel", { BackgroundColor3 = C.Input, BorderSizePixel = 0, Size = UDim2.fromOffset(44, 44), Position = UDim2.fromOffset(10, 10), Image = "", ScaleType = Enum.ScaleType.Crop, Parent = gameCard }, { corner(9) })
local thumbPlaceholder = icon("gamepad-2", 20, C.Muted, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = thumb })
local gameName = label({ Text = "Detecting game…", Font = FONT_BOLD, TextSize = 14, Size = UDim2.new(1, -220, 0, 18), Position = UDim2.fromOffset(64, 14), TextTruncate = Enum.TextTruncate.AtEnd, Parent = gameCard })
local gameStateIcon = icon("loader-circle", 12, C.Muted, { Position = UDim2.fromOffset(64, 36), Parent = gameCard })
local gameState = label({ Text = "Checking support", TextSize = 12, TextColor3 = C.Muted, Size = UDim2.new(1, -240, 0, 16), Position = UDim2.fromOffset(80, 34), Parent = gameCard })

local execChip = new("Frame", { BackgroundColor3 = C.Input, BorderSizePixel = 0, AutomaticSize = Enum.AutomaticSize.X, AnchorPoint = Vector2.new(1, 0.5), Size = UDim2.fromOffset(0, 28), Position = UDim2.new(1, -12, 0.5, 0), Parent = gameCard }, { corner(8), stroke(C.Stroke, 1), pad(0, 10, 0, 10) })
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 6), Parent = execChip })
icon("monitor", 13, C.Muted, { Parent = execChip })
label({ Text = executorName(), Font = FONT_BOLD, TextSize = 12, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 28), Parent = execChip })

-- Key row
label({ Text = "LICENSE KEY", Font = FONT_BOLD, TextSize = 10, TextColor3 = C.Muted, Size = UDim2.new(1, 0, 0, 14), Position = UDim2.fromOffset(2, 82), Parent = body })
local statusPill = label({ Text = "KEY REQUIRED", Font = FONT_BOLD, TextSize = 10, TextColor3 = C.Warn, Size = UDim2.new(0.5, 0, 0, 14), Position = UDim2.new(0.5, -2, 0, 82), TextXAlignment = Enum.TextXAlignment.Right, Parent = body })

local inputFrame = new("Frame", { BackgroundColor3 = C.Input, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 48), Position = UDim2.fromOffset(0, 100), Parent = body }, { corner(12), stroke(C.Stroke, 1) })
local inputStroke = inputFrame:FindFirstChildOfClass("UIStroke")
icon("key-round", 16, C.Muted, { Position = UDim2.fromOffset(15, 16), Parent = inputFrame })
local input = new("TextBox", {
    BackgroundTransparency = 1, Font = FONT, TextSize = 14, TextColor3 = C.Text, PlaceholderColor3 = C.Muted,
    PlaceholderText = "Paste your Relay key", Text = "", ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left,
    Size = UDim2.new(1, -166, 1, 0), Position = UDim2.fromOffset(42, 0), Parent = inputFrame,
})
local submit = new("TextButton", { BackgroundColor3 = C.Accent, AutoButtonColor = false, Text = "", BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5), Size = UDim2.fromOffset(112, 36), Position = UDim2.new(1, -6, 0.5, 0), Parent = inputFrame }, { corner(9) })
local submitText = label({ Text = "Submit", Font = FONT_BOLD, TextSize = 13, TextColor3 = C.OnAccent, Size = UDim2.new(1, -36, 1, 0), Position = UDim2.fromOffset(16, 0), Parent = submit })
local submitIcon = icon("arrow-right", 14, C.OnAccent, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), Parent = submit })

-- Status line
local statusIcon = icon("circle-alert", 13, C.Muted, { Position = UDim2.fromOffset(2, 158), ImageTransparency = 1, Parent = body })
local status = label({ Text = "", TextSize = 12, TextColor3 = C.Muted, Size = UDim2.new(1, -22, 0, 32), Position = UDim2.fromOffset(21, 156), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Parent = body })

-- Footer pills
local footer = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), Position = UDim2.new(0, 0, 1, -40), Parent = body })
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), VerticalAlignment = Enum.VerticalAlignment.Center, Parent = footer })

local function pill(iconName, text, primary)
    local btn = new("TextButton", { BackgroundColor3 = primary and C.Card or C.Panel, AutoButtonColor = false, Text = "", BorderSizePixel = 0, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 36), Parent = footer }, { corner(10), stroke(primary and C.AccentDk or C.Stroke, 1), pad(0, 14, 0, 12) })
    new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8), Parent = btn })
    local ic = icon(iconName, 14, primary and C.Accent or C.Muted, { Parent = btn })
    local tx = label({ Text = text, Font = FONT_BOLD, TextSize = 12, TextColor3 = primary and C.Text or C.Muted, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 36), Parent = btn })
    btn.MouseEnter:Connect(function() tween(btn, { BackgroundColor3 = C.Input }) end)
    btn.MouseLeave:Connect(function() tween(btn, { BackgroundColor3 = primary and C.Card or C.Panel }) end)
    return btn, ic, tx
end

local function copyPill(iconName, text, value, doneText)
    local btn, ic, tx = pill(iconName, text, false)
    btn.MouseButton1Click:Connect(function()
        if typeof(setclipboard) ~= "function" then return end
        pcall(setclipboard, value)
        setIcon(ic, "check"); ic.ImageColor3 = C.Good; tx.Text = doneText
        task.delay(1.5, function() setIcon(ic, iconName); ic.ImageColor3 = C.Muted; tx.Text = text end)
    end)
    return btn
end

local getKey, getKeyIcon, getKeyText = pill("globe", "Get a key", true)
copyPill("message-circle", "Discord", CONFIG.Discord, "Invite copied")
copyPill("link", "Website", CONFIG.Website, "Link copied")

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
        setIcon(gameStateIcon, "circle-check"); gameStateIcon.ImageColor3 = C.Good
        gameState.Text = "Supported"; gameState.TextColor3 = C.Good
    elseif next(supportedGames) == nil then
        setIcon(gameStateIcon, "circle-alert"); gameStateIcon.ImageColor3 = C.Muted
        gameState.Text = "Support list unavailable"; gameState.TextColor3 = C.Muted
    else
        setIcon(gameStateIcon, "triangle-alert"); gameStateIcon.ImageColor3 = C.Warn
        gameState.Text = "Not supported"; gameState.TextColor3 = C.Warn
    end
    pcall(function()
        thumb.Image = "rbxthumb://type=GameIcon&id=" .. placeId .. "&w=150&h=150"
        thumbPlaceholder.Visible = false
    end)
end)

-- Interactions ---------------------------------------------------------------
local function setStatus(text, color, iconName)
    status.Text = text
    status.TextColor3 = color or C.Muted
    statusIcon.ImageTransparency = (#text > 0) and 0 or 1
    statusIcon.ImageColor3 = color or C.Muted
    setIcon(statusIcon, iconName or "circle-alert")
end

local function setState(text, color)
    statusPill.Text = text
    statusPill.TextColor3 = color
end

submit.MouseEnter:Connect(function() tween(submit, { BackgroundColor3 = C.AccentDk }) end)
submit.MouseLeave:Connect(function() tween(submit, { BackgroundColor3 = C.Accent }) end)
input.Focused:Connect(function() tween(inputStroke, { Color = C.Accent }) end)

getKey.MouseButton1Click:Connect(function()
    if typeof(setclipboard) == "function" then
        pcall(setclipboard, CONFIG.GetKeyUrl)
        setIcon(getKeyIcon, "check"); getKeyIcon.ImageColor3 = C.Good; getKeyText.Text = "Link copied"
        task.delay(1.5, function() setIcon(getKeyIcon, "globe"); getKeyIcon.ImageColor3 = C.Accent; getKeyText.Text = "Get a key" end)
        setStatus("Open the copied link in your browser to get a free or paid key.", C.Muted, "globe")
    else
        setStatus("Get a key at " .. CONFIG.GetKeyUrl, C.Muted, "globe")
    end
end)

local busy = false
local function trySubmit()
    if busy then return end
    local k = input.Text:gsub("%s+", "")
    if #k == 0 then setStatus("Enter your Relay key first.", C.Bad, "circle-alert") return end
    if not keyLooksValid(k) then setStatus("That key is not in a valid format.", C.Bad, "circle-alert") return end

    busy = true
    setStatus("Checking key…", C.Muted, "loader-circle")
    setState("CHECKING", C.Muted)
    submitText.Text = "Checking"; setIcon(submitIcon, "loader-circle")

    local ok, message = validateKey(k)
    if not ok then
        busy = false
        setStatus(message, C.Bad, "circle-alert")
        setState("REJECTED", C.Bad)
        submitText.Text = "Submit"; setIcon(submitIcon, "arrow-right")
        tween(inputStroke, { Color = C.Bad }); task.delay(0.8, function() tween(inputStroke, { Color = C.Stroke }) end)
        return
    end

    setStatus("Key accepted, loading Relay…", C.Good, "shield-check")
    setState("ACCEPTED", C.Good)
    submitText.Text = "Loading"; setIcon(submitIcon, "check")
    saveKey(k)
    task.wait(0.45)

    tween(panel, { BackgroundTransparency = 1 }, 0.2)
    tween(backdrop, { BackgroundTransparency = 1 }, 0.2)
    task.wait(0.2)
    gui:Destroy()

    local loaded, err = loadRelay(k)
    if not loaded then
        clearSavedKey()
        warn("[Relay] Sanctuary loader error: " .. tostring(err))
    end
end
submit.MouseButton1Click:Connect(trySubmit)
input.FocusLost:Connect(function(enter) tween(inputStroke, { Color = C.Stroke }); if enter then task.spawn(trySubmit) end end)

-- Drag by the header
do
    local dragging, dragStart, startPos
    header.InputBegan:Connect(function(io)
        if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = io.Position; startPos = panel.Position
        end
    end)
    header.InputEnded:Connect(function(io)
        if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
    UserInput.InputChanged:Connect(function(io)
        if dragging and (io.UserInputType == Enum.UserInputType.MouseMovement or io.UserInputType == Enum.UserInputType.Touch) then
            local d = io.Position - dragStart
            panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

if savedKeyError then setStatus(savedKeyError, C.Warn, "triangle-alert") else setStatus(hasFiles and "Your key is saved after the first successful load." or "This executor can't save files, so you'll re-enter your key each session.", C.Muted, "lock") end

-- Intro animation
panel.BackgroundTransparency = 1
backdrop.BackgroundTransparency = 1
gui.Parent = parentGui
tween(panel, { BackgroundTransparency = 0 }, 0.22)
tween(backdrop, { BackgroundTransparency = 0.45 }, 0.22)
