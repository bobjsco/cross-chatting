-- Cross Connect Chat
-- Messager <-> Sender via HTTP relay (webhooksite.net)
-- Messager types -> webhook -> Sender says in chat
-- Sender sees server chat -> webhook -> Messager sees it in log

repeat task.wait() until game:IsLoaded()

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TextChatService = game:GetService("TextChatService")
local plr = Players.LocalPlayer

-- [[[  CONFIG - EDIT THESE  ]]]
-- 
-- >> Which webhook index to POST your messages to (1-6)
--    Set to 0 to post to ALL webhooks (slower but guaranteed)
local POST_TO_INDEX = 2
--
-- >> Seconds between each poll cycle
local POLL_RATE = 15
--
-- >> Max length of messages said in chat
local MAX_CHAT_LEN = 200
--
-- >> Your webhook URLs (add/remove as needed)
local HOOK_URLS = {
    "https://webhooksite.net/d77052fe-7174-45c9-a38f-5eee5335de78",
    "https://webhooksite.net/de51eeda-2767-4a70-aa60-5f8b0ba1f0f8",
    "https://webhooksite.net/0b38ca68-4c02-42da-9f0a-e3503014d854",
    "https://webhooksite.net/1ff3ea11-1718-47dc-ba92-56e0a3dbb448",
    "https://webhooksite.net/dbfc4771-a107-4337-a426-88ead62c8c1e",
    "https://webhooksite.net/c526ec75-c83b-4527-bd6c-12b4006b4d4e",
}
-- [[[  END CONFIG  ]]]

-- ===== STATE =====
local role = nil
local running = false
local seenIds = {}
local postCooldowns = {}  -- per-URL cooldowns
local getCooldowns = {}
for i = 1, #HOOK_URLS do
    postCooldowns[i] = 0
    getCooldowns[i] = 0
end
local postRRIndex = 1  -- round-robin for chat relay posts

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

-- POST cc messages to specific index or all
local function httpPostCC(data)
    local body = jEncode(data)
    if not body then return false, "encode failed" end
    if POST_TO_INDEX > 0 and POST_TO_INDEX <= #HOOK_URLS then
        -- post to ONE specific webhook
        local i = POST_TO_INDEX
        local now = tick()
        if now < postCooldowns[i] then
            return false, "cooldown (" .. math.ceil(postCooldowns[i] - now) .. "s)"
        end
        local r, err = rawRequest("POST", HOOK_URLS[i], body)
        if not r then return false, tostring(err) end
        local code = r.StatusCode or 0
        if code >= 200 and code < 300 then return true, r end
        if code == 429 then postCooldowns[i] = tick() + 30 end
        return false, "HTTP " .. tostring(code)
    end
    -- POST_TO_INDEX == 0: post to ALL
    local anyOk = false
    local lastErr = ""
    for i, url in ipairs(HOOK_URLS) do
        local now = tick()
        if now < postCooldowns[i] then
            lastErr = "url" .. i .. " cooldown"
            continue
        end
        local r, err = rawRequest("POST", url, body)
        if not r then
            lastErr = tostring(err)
            continue
        end
        local code = r.StatusCode or 0
        if code >= 200 and code < 300 then
            anyOk = true
        elseif code == 429 then
            postCooldowns[i] = tick() + 30
            lastErr = "url" .. i .. " rate limited"
        else
            lastErr = "url" .. i .. " HTTP " .. code
        end
    end
    return anyOk, lastErr
end

-- POST to ONE url round-robin (for chat relay - spreads load)
local function httpPostOne(data)
    local body = jEncode(data)
    if not body then return false, "encode failed" end
    for attempt = 1, #HOOK_URLS do
        local idx = ((postRRIndex - 1) % #HOOK_URLS) + 1
        postRRIndex = postRRIndex + 1
        local url = HOOK_URLS[idx]
        local now = tick()
        if now < postCooldowns[idx] then continue end
        local r, err = rawRequest("POST", url, body)
        if not r then continue end
        local code = r.StatusCode or 0
        if code >= 200 and code < 300 then
            return true
        end
        if code == 429 then
            postCooldowns[idx] = tick() + 30
        end
    end
    return false, "all urls rate limited"
end

-- GET from one url (per-URL cooldown)
local function httpGetOne(idx)
    local now = tick()
    if now < getCooldowns[idx] then return nil end
    local url = HOOK_URLS[idx]
    local r, err = rawRequest("GET", url, nil)
    if not r then return nil end
    if r.StatusCode and r.StatusCode >= 200 and r.StatusCode < 300 and r.Body then
        return r.Body
    end
    if r.StatusCode == 429 then
        getCooldowns[idx] = tick() + 30
    end
    return nil
end
-- ===== CHAT: SAY IN GAME =====
local function sayChat(text)
    if #text > MAX_CHAT_LEN then
        text = text:sub(1, MAX_CHAT_LEN - 3) .. "..."
    end
    local ce = game.ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
    if ce and ce:FindFirstChild("SayMessageRequest") then
        ce.SayMessageRequest:FireServer(text, "All")
        return true
    end
    local head = plr.Character and plr.Character:FindFirstChild("Head")
    if head then
        game:GetService("Chat"):Chat(head, text)
        return true
    end
    return false
end

-- ===== CHAT HOOK (shared) =====
-- Returns a function that hooks TextChatService and calls onMsg(from, text)
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
-- Handles both t="cc" (cross-connect) and t="cr" (chat relay) messages
local function processEntries(entries, addMsg, isSender, wantCC, wantCR)
    local lastCC = nil
    for _, entry in ipairs(entries) do
        local eid = tostring(entry.id or entry._id or "")
        if #eid == 0 then eid = tostring(entry) end
        if not seenIds[eid] then
            local content = entry.content or entry.body or entry.Body
            if content then
                local msgData = jDecode(content)
                if msgData then
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
                                    addMsg("[Said] " .. chatMsg, C_GREEN)
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

-- ===== PARSE WEBHOOK RESPONSE (flexible) =====
local function parseEntries(data)
    if type(data.data) == "table" then return data.data end
    if type(data.messages) == "table" then return data.messages end
    if type(data.results) == "table" then return data.results end
    if type(data) == "table" and type(data[1]) == "table" then return data end
    return nil
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
    Text = "6 webhooks loaded (auto-rotate)",
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
        local ok, err = httpPostCC({
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

    -- ===== CHAT LOGGER: local + relay from Sender =====
    local chatHooked = hookChat(function(from, text)
        addMsg("[Chat] " .. from .. ": " .. text, C_DIM)
    end)
    if chatHooked then
        addMsg("[System] Chat logger active", C_GREEN)
    else
        addMsg("[System] Chat logger failed", C_RED)
    end

    -- ===== POLL: receive cc messages + chat relay from Sender =====
    running = true
    local firstPoll = true
    task.spawn(function()
        while running do
            task.wait(POLL_RATE)
            -- poll all URLs, collect entries
            for i = 1, #HOOK_URLS do
                local response = httpGetOne(i)
                if not response then continue end
                local data = jDecode(response)
                if not data then
                    if firstPoll and i == 1 then
                        addMsg("[Debug] raw: " .. tostring(response):sub(1, 80), C_VDIM)
                    end
                    continue
                end
                local entries = parseEntries(data)
                if not entries then
                    if firstPoll and i == 1 then
                        local keys = {}
                        for k, v in pairs(data) do
                            table.insert(keys, tostring(k) .. "=" .. type(v))
                        end
                        addMsg("[Debug] keys: " .. table.concat(keys, ", "), C_VDIM)
                    end
                    continue
                end
                processEntries(entries, addMsg, false, false, true)
            end
            firstPoll = false
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

    -- ===== CHAT LOGGER + RELAY: log locally AND send to Messager =====
    local chatHooked = hookChat(function(from, text)
        addMsg("[Chat] " .. from .. ": " .. text, C_DIM)
        -- relay this chat message to the Messager via webhook
        httpPostOne({
            t = "cr", n = from, m = text, ts = tick()
        })
    end)
    if chatHooked then
        addMsg("[System] Chat logger + relay active", C_GREEN)
    else
        addMsg("[System] Chat logger failed", C_RED)
    end

    -- ===== POLL: receive cc messages from Messager =====
    running = true
    local firstPoll = true
    task.spawn(function()
        while running do
            task.wait(POLL_RATE)
            for i = 1, #HOOK_URLS do
                local response = httpGetOne(i)
                if not response then continue end
                local data = jDecode(response)
                if not data then
                    if firstPoll and i == 1 then
                        addMsg("[Debug] raw: " .. tostring(response):sub(1, 80), C_VDIM)
                    end
                    continue
                end
                local entries = parseEntries(data)
                if not entries then
                    if firstPoll and i == 1 then
                        local keys = {}
                        for k, v in pairs(data) do
                            table.insert(keys, tostring(k) .. "=" .. type(v))
                        end
                        addMsg("[Debug] keys: " .. table.concat(keys, ", "), C_VDIM)
                    end
                    continue
                end
                local lastFrom = processEntries(entries, addMsg, true, true, false)
                if lastFrom then
                    statusLabel.Text = "Last: " .. lastFrom .. " (" .. os.date("%H:%M:%S") .. ")"
                end
            end
            firstPoll = false
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
