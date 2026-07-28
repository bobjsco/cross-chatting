-- Cross Connect Chat
-- Messager <-> Sender via webhook.site
-- Messager types -> webhook POST -> Sender GETs -> says in chat
-- Sender sees server chat -> webhook POST -> Messager GETs -> shows in log

repeat task.wait() until game:IsLoaded()

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TextChatService = game:GetService("TextChatService")
local plr = Players.LocalPlayer

-- [[[  CONFIG - EDIT THESE  ]]]
--
-- >> Seconds between each poll cycle
local POLL_RATE = 10
--
-- >> Max length of messages said in chat
local MAX_CHAT_LEN = 200
--
-- >> Your webhook.site token (get a new one from webhook.site, paste here)
local TOKEN = "d30256d0-cc04-4215-b8f2-102a9a8c5aa7"
local POST_URL = "https://webhook.site/" .. TOKEN
local GET_URL = "https://webhook.site/token/" .. TOKEN .. "/requests?sorting=newest"
-- [[[  END CONFIG  ]]]

-- ===== STATE =====
local role = nil
local running = false
local seenIds = {}
local postCooldown = 0
local getCooldown = 0

-- ===== HTTP UTILS =====
local httpFn = (syn and syn.request) or request or (http and http.request)

local function jEncode(t)
    local ok, r = pcall(HttpService.JSONEncode, HttpService, t)
    return ok and r or nil
end

local function jDecode(s)
    local ok, r = pcall(HttpService.JSONDecode, HttpService, s)
    return ok and r or nil
end

local function rawRequest(method, url, body)
    if not httpFn then return nil end
    local req = {
        Url = url, Method = method,
        Headers = {},
    }
    if body then
        req.Body = body
        req.Headers["Content-Type"] = "application/json"
    end
    local ok, r = pcall(httpFn, req)
    if not ok then return nil, r end
    return r
end

-- POST to webhook
local function httpPost(data)
    local body = jEncode(data)
    if not body then return false, "encode failed" end
    local now = tick()
    if now < postCooldown then
        return false, "cooldown (" .. math.ceil(postCooldown - now) .. "s)"
    end
    local r, err = rawRequest("POST", POST_URL, body)
    if not r then return false, tostring(err) end
    local code = r.StatusCode or 0
    if code >= 200 and code < 300 then return true end
    if code == 429 then postCooldown = tick() + 30 end
    return false, "HTTP " .. tostring(code)
end

-- GET stored messages (returns entries array or nil)
-- also sets getLastGetDebug() for debug display
local lastGetDebug = ""
local function httpGet()
    local now = tick()
    if now < getCooldown then
        lastGetDebug = "on cooldown"
        return nil
    end
    local r, err = rawRequest("GET", GET_URL, nil)
    if not r then
        lastGetDebug = "request failed"
        return nil
    end
    lastGetDebug = "HTTP " .. tostring(r.StatusCode)
    if r.StatusCode == 429 then
        getCooldown = tick() + 30
        return nil
    end
    if not r.StatusCode or r.StatusCode < 200 or r.StatusCode >= 300 or not r.Body then
        return nil
    end
    lastGetDebug = r.Body:sub(1, 120)
    local data = jDecode(r.Body)
    if not data then
        lastGetDebug = "not JSON: " .. r.Body:sub(1, 100)
        return nil
    end
    -- try multiple response formats
    local entries = nil
    if type(data.data) == "table" then
        entries = data.data
    elseif type(data.messages) == "table" then
        entries = data.messages
    elseif type(data.results) == "table" then
        entries = data.results
    elseif type(data) == "table" and type(data[1]) == "table" then
        entries = data
    end
    if entries and #entries > 0 then
        lastGetDebug = #entries .. " entries"
        return entries
    end
    -- show what keys the response actually has
    local keys = {}
    for k in pairs(data) do table.insert(keys, k) end
    lastGetDebug = "no entries. keys: " .. table.concat(keys, ", ")
    return nil
end

-- ===== CHAT: SAY IN GAME (same method as IY/Arc's spam) =====
local isLegacyChat = (TextChatService.ChatVersion == Enum.ChatVersion.LegacyChatService)

local function sayChat(text)
    if #text > MAX_CHAT_LEN then
        text = text:sub(1, MAX_CHAT_LEN - 3) .. "..."
    end
    local ok = pcall(function()
        if isLegacyChat then
            game.ReplicatedStorage.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(text, "All")
        else
            TextChatService.TextChannels.RBXGeneral:SendAsync(text)
        end
    end)
    return ok
end

-- ===== CHAT HOOK (shared) =====
local function hookChat(onMsg)
    local ok = pcall(function()
        TextChatService.MessageReceived:Connect(function(msg)
            local player = Players:GetPlayerByUserId(msg.TextSource.UserId)
            if player then
                local from = player.DisplayName or player.Name
                local text = msg.Text or ""
                if text ~= "" then
                    onMsg(from, text)
                end
            end
        end)
    end)
    if not ok then
        local chatEvents = game.ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
        if chatEvents and chatEvents:FindFirstChild("OnNewMessage") then
            chatEvents.OnNewMessage.OnClientEvent:Connect(function(msgData)
                local from = msgData.FromSpeaker or msgData.FromDisplayName or "???"
                local text = msgData.Message or ""
                if text ~= "" then
                    onMsg(from, text)
                end
            end)
            ok = true
        end
    end
    return ok
end

-- ===== PROCESS ENTRIES FROM WEBHOOK =====
local function processEntries(entries, addMsg, isSender, wantCC, wantCR)
    local lastCC = nil
    for _, entry in ipairs(entries) do
        local eid = tostring(entry.uuid or entry.id or entry._id or "")
        if #eid == 0 then eid = tostring(entry) end
        if not seenIds[eid] then
            local content = entry.content or entry.body or entry.Body
            if content then
                local msgData = type(content) == "string" and jDecode(content) or content
                if msgData and type(msgData) == "table" then
                    if msgData.t == "cc" and msgData.m then
                        if wantCC then
                            seenIds[eid] = true
                            local fromName = msgData.n or "Unknown"
                            local message = msgData.m
                            addMsg(fromName .. ": " .. message, C_TEXT)
                            if isSender then
                                local chatMsg = fromName .. " said: " .. message
                                local ok = sayChat(chatMsg)
                                if ok then
                                    addMsg("[Said in chat] " .. chatMsg, C_GREEN)
                                else
                                    addMsg("[Error] Could not say in chat", C_RED)
                                end
                            end
                            lastCC = fromName
                        end
                    elseif msgData.t == "cr" and msgData.m then
                        if wantCR then
                            seenIds[eid] = true
                            local fromName = msgData.n or "???"
                            addMsg("[Server] " .. fromName .. ": " .. msgData.m, C_DIM)
                        end
                    end
                end
            end
        end
    end
    return lastCC
end

-- ===== GUI HELPERS =====
local function mk(cls, props, parent)
    local i = Instance.new(cls)
    for k, v in pairs(props or {}) do i[k] = v end
    if parent then i.Parent = parent end
    return i
end

local function crnr(p, r)
    mk("UICorner", {CornerRadius = UDim.new(0, r or 8)}, p)
end

local function strk(p, c, t)
    return mk("UIStroke", {Color = c, Thickness = t or 1.5}, p)
end

-- ===== SCREEN GUI =====
local gui = mk("ScreenGui", {
    Name = "CrossConnect", ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling
})
pcall(function() gui.Parent = game.CoreGui end)
if not gui.Parent then gui.Parent = plr:WaitForChild("PlayerGui") end

local C_BG = Color3.fromRGB(20, 20, 28)
local C_DARK = Color3.fromRGB(26, 26, 28)
local C_INPUT = Color3.fromRGB(30, 32, 44)
local C_LOG = Color3.fromRGB(15, 15, 22)
local C_ORANGE = Color3.fromRGB(255, 100, 50)
local C_ORANGE_L = Color3.fromRGB(255, 150, 80)
local C_GREEN = Color3.fromRGB(0, 240, 130)
local C_RED = Color3.fromRGB(255, 80, 80)
local C_TEXT = Color3.fromRGB(220, 225, 240)
local C_DIM = Color3.fromRGB(140, 145, 160)
local C_VDIM = Color3.fromRGB(80, 85, 100)

-- ========================================
-- SETUP SCREEN
-- ========================================

local setup = mk("Frame", {
    Size = UDim2.new(0, 330, 0, 260),
    Position = UDim2.new(0.5, -165, 0.5, -130),
    BackgroundColor3 = C_BG, BorderSizePixel = 0,
    Active = true, Draggable = true
}, gui)
crnr(setup); strk(setup, C_ORANGE)

mk("TextLabel", {
    Size = UDim2.new(1, 0, 0, 32), Position = UDim2.new(0, 0, 0, 10),
    BackgroundTransparency = 1, Text = "CROSS CONNECT",
    TextColor3 = C_ORANGE_L, Font = Enum.Font.GothamBold,
    TextSize = 16, Parent = setup
})

mk("TextLabel", {
    Size = UDim2.new(1, 0, 0, 16), Position = UDim2.new(0, 0, 0, 42),
    BackgroundTransparency = 1, Text = "Select your role",
    TextColor3 = C_DIM, Font = Enum.Font.Gotham,
    TextSize = 11, Parent = setup
})

-- Role buttons
local selectedRole = nil
local roleBtns = {}

local function makeRoleBtn(name, xPos)
    local btn = mk("TextButton", {
        Size = UDim2.new(0, 145, 0, 38), Position = UDim2.new(0, xPos, 0, 68),
        BackgroundColor3 = C_INPUT, Text = name,
        TextColor3 = C_TEXT, Font = Enum.Font.GothamBold,
        TextSize = 12, AutoButtonColor = false, Parent = setup
    })
    crnr(btn, 6); strk(btn, C_VDIM, 1)
    roleBtns[name] = btn
    btn.MouseButton1Click:Connect(function()
        selectedRole = name
        for n, b in pairs(roleBtns) do
            local sel = (n == name)
            b.BackgroundColor3 = sel and Color3.fromRGB(20, 50, 35) or C_INPUT
            b.TextColor3 = sel and C_GREEN or C_TEXT
        end
    end)
end

makeRoleBtn("MESSAGER", 14)
makeRoleBtn("SENDER", 171)
roleBtns["SENDER"].Position = UDim2.new(1, -159, 0, 68)

-- Status
local statusLbl = mk("TextLabel", {
    Size = UDim2.new(1, -24, 0, 16), Position = UDim2.new(0, 12, 0, 118),
    BackgroundTransparency = 1, Text = "",
    TextColor3 = C_RED, Font = Enum.Font.Gotham,
    TextSize = 10, TextXAlignment = Enum.TextXAlignment.Center, Parent = setup
})

-- Connect button
local btnConn = mk("TextButton", {
    Size = UDim2.new(1, -24, 0, 36), Position = UDim2.new(0, 12, 0, 145),
    BackgroundColor3 = C_INPUT, Text = "CONNECT",
    TextColor3 = C_GREEN, Font = Enum.Font.GothamBold,
    TextSize = 12, AutoButtonColor = false, Parent = setup
})
crnr(btnConn, 6); strk(btnConn, C_GREEN, 1)

-- Webhook display
mk("TextLabel", {
    Size = UDim2.new(1, -24, 0, 30), Position = UDim2.new(0, 12, 0, 195),
    BackgroundTransparency = 1,
    Text = "Webhook connected",
    TextColor3 = C_VDIM, Font = Enum.Font.Gotham,
    TextSize = 9, TextXAlignment = Enum.TextXAlignment.Center, Parent = setup
})

-- ========================================
-- MESSAGER GUI
-- ========================================

local function initMessager()
    local main = mk("Frame", {
        Size = UDim2.new(0, 330, 0, 420),
        Position = UDim2.new(0, 10, 1, -430),
        BackgroundColor3 = C_BG, BorderSizePixel = 0,
        Active = true, Draggable = true
    }, gui)
    mk("UICorner", {CornerRadius = UDim.new(0, 8)}, main)
    mk("UIStroke", {Color = C_ORANGE, Thickness = 1.5}, main)

    mk("Frame", {
        Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = C_DARK,
        BorderSizePixel = 0, Parent = main
    })
    mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1,
        Text = "  CROSS CONNECT - MESSAGER",
        TextColor3 = C_ORANGE_L, Font = Enum.Font.GothamBold,
        TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, Parent = main
    })

    local chatLog = mk("ScrollingFrame", {
        Size = UDim2.new(1, -10, 1, -70), Position = UDim2.new(0, 5, 0, 33),
        BackgroundColor3 = C_LOG, BorderSizePixel = 0,
        ScrollBarThickness = 4, ScrollBarImageColor3 = C_VDIM,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = main
    })
    crnr(chatLog, 4)
    mk("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 3), Parent = chatLog})
    mk("UIPadding", {
        PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
        PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), Parent = chatLog
    })

    local logOrder = 0
    local function addMsg(text, color)
        mk("TextLabel", {
            Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1,
            Text = text, TextColor3 = color or C_TEXT,
            Font = Enum.Font.Gotham, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
            LayoutOrder = logOrder, Parent = chatLog
        })
        logOrder = logOrder + 1
        task.defer(function() chatLog.CanvasPosition = Vector2.new(0, 99999) end)
    end

    addMsg("[System] Connected as Messager", C_GREEN)
    addMsg("[System] Type a message below", C_DIM)

    local inputBox = mk("TextBox", {
        Size = UDim2.new(1, -60, 0, 28), Position = UDim2.new(0, 5, 1, -33),
        BackgroundColor3 = C_INPUT, Text = "",
        PlaceholderText = "Type a message...",
        PlaceholderColor3 = C_VDIM,
        TextColor3 = C_TEXT, Font = Enum.Font.Gotham,
        TextSize = 11, ClearTextOnFocus = false, Parent = main
    })
    crnr(inputBox, 5)

    local sendBtn = mk("TextButton", {
        Size = UDim2.new(0, 50, 0, 28), Position = UDim2.new(1, -55, 1, -33),
        BackgroundColor3 = C_ORANGE, Text = "SEND",
        TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold,
        TextSize = 10, AutoButtonColor = false, Parent = main
    })
    crnr(sendBtn, 5)

    local function send()
        local text = inputBox.Text:match("^%s*(.-)%s*$")
        if not text or #text == 0 then return end
        inputBox.Text = ""
        addMsg("You: " .. text, C_TEXT)
        local ok, err = httpPost({
            t = "cc", n = plr.DisplayName, m = text, ts = tick()
        })
        if ok then
            addMsg("[Sent] Message delivered", C_GREEN)
        else
            addMsg("[Error] Send failed: " .. tostring(err), C_RED)
        end
    end

    sendBtn.MouseButton1Click:Connect(send)
    inputBox.FocusLost:Connect(function(enter) if enter then send() end end)

    -- ===== CHAT LOGGER =====
    local chatHooked = hookChat(function(from, text)
        addMsg("[Chat] " .. from .. ": " .. text, C_DIM)
    end)
    if chatHooked then
        addMsg("[System] Chat logger active", C_GREEN)
    else
        addMsg("[System] Chat logger failed", C_RED)
    end

    -- ===== POLL: receive chat relay (cr) from Sender =====
    running = true
    local pollCount = 0
    task.spawn(function()
        while running do
            task.wait(POLL_RATE)
            pollCount = pollCount + 1
            local debugMode = (pollCount <= 5)
            local entries = httpGet()
            if not entries then
                if debugMode then
                    addMsg("[Debug] GET: " .. lastGetDebug, C_VDIM)
                end
                continue
            end
            if debugMode then
                addMsg("[Debug] " .. #entries .. " entries", C_VDIM)
            end
            processEntries(entries, addMsg, false, false, true)
        end
    end)
end

-- ========================================
-- SENDER GUI
-- ========================================

local function initSender()
    local main = mk("Frame", {
        Size = UDim2.new(0, 330, 0, 340),
        Position = UDim2.new(0, 10, 1, -350),
        BackgroundColor3 = C_BG, BorderSizePixel = 0,
        Active = true, Draggable = true
    }, gui)
    mk("UICorner", {CornerRadius = UDim.new(0, 8)}, main)
    mk("UIStroke", {Color = C_ORANGE, Thickness = 1.5}, main)

    mk("Frame", {
        Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = C_DARK,
        BorderSizePixel = 0, Parent = main
    })
    mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1,
        Text = "  CROSS CONNECT - SENDER",
        TextColor3 = C_ORANGE_L, Font = Enum.Font.GothamBold,
        TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, Parent = main
    })

    local statusLabel = mk("TextLabel", {
        Size = UDim2.new(1, -10, 0, 18), Position = UDim2.new(0, 5, 0, 33),
        BackgroundTransparency = 1, Text = "Listening for messages...",
        TextColor3 = C_GREEN, Font = Enum.Font.GothamBold,
        TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left, Parent = main
    })

    local msgLog = mk("ScrollingFrame", {
        Size = UDim2.new(1, -10, 1, -58), Position = UDim2.new(0, 5, 0, 55),
        BackgroundColor3 = C_LOG, BorderSizePixel = 0,
        ScrollBarThickness = 4, ScrollBarImageColor3 = C_VDIM,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = main
    })
    crnr(msgLog, 4)
    mk("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 3), Parent = msgLog})
    mk("UIPadding", {
        PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
        PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), Parent = msgLog
    })

    local logOrder = 0
    local function addMsg(text, color)
        mk("TextLabel", {
            Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1,
            Text = text, TextColor3 = color or C_TEXT,
            Font = Enum.Font.Gotham, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
            LayoutOrder = logOrder, Parent = msgLog
        })
        logOrder = logOrder + 1
        task.defer(function() msgLog.CanvasPosition = Vector2.new(0, 99999) end)
    end

    addMsg("[System] Connected as Sender", C_GREEN)
    addMsg("[System] Waiting for messages...", C_DIM)

    -- ===== CHAT LOGGER + RELAY =====
    local chatHooked = hookChat(function(from, text)
        addMsg("[Chat] " .. from .. ": " .. text, C_DIM)
        httpPost({
            t = "cr", n = from, m = text, ts = tick()
        })
    end)
    if chatHooked then
        addMsg("[System] Chat logger + relay active", C_GREEN)
    else
        addMsg("[System] Chat logger failed", C_RED)
    end

    -- ===== POLL: receive cc messages from Messager & SAY IN CHAT =====
    running = true
    local pollCount = 0
    task.spawn(function()
        while running do
            task.wait(POLL_RATE)
            pollCount = pollCount + 1
            local debugMode = (pollCount <= 5)
            local entries = httpGet()
            if not entries then
                if debugMode then
                    addMsg("[Debug] GET: " .. lastGetDebug, C_VDIM)
                end
                continue
            end
            if debugMode then
                addMsg("[Debug] " .. #entries .. " entries", C_VDIM)
            end
            local lastFrom = processEntries(entries, addMsg, true, true, false)
            if lastFrom then
                statusLabel.Text = "Last: " .. lastFrom .. " (" .. os.date("%H:%M:%S") .. ")"
            end
        end
    end)
end

-- ========================================
-- CONNECT HANDLER
-- ========================================

btnConn.MouseButton1Click:Connect(function()
    if not selectedRole then
        statusLbl.Text = "Select a role first!"
        statusLbl.TextColor3 = C_RED
        return
    end
    role = selectedRole
    setup.Visible = false
    if role == "MESSAGER" then
        initMessager()
    else
        initSender()
    end
end)
