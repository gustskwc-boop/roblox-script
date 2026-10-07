local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VirtualInputManager = nil
pcall(function()
    VirtualInputManager = game:GetService("VirtualInputManager")
end)

local player = Players.LocalPlayer

--[[
=====================================================================
  โครงสร้างไฟล์ (v2)
  1. FEATURE FLAGS
  2. LOGIC หลัก : Pickup / Speed / Bag / Back / E   (แก้ระบบ Back ใหม่)
  3. LOGIC เสริม: Stage / Area / Force Kill / Anti AFK / Scan
  4. CONTROL    : ลูปหลัก
  5. UI ใหม่    : หน้าต่างเดียว มีแท็บ (หลัก/กระเป๋า/วาร์ป/ต่อสู้/ดีบัก)
=====================================================================
]]

-- =====================================================================
-- 1. FEATURE FLAGS
-- =====================================================================

local Feature = {
    Speed = true,
    AutoPickup = true,
    BagHandler = true,
    FullText = true,      -- ตรวจข้อความ "Bag Full" ด้วย (นอกจากตัวเลข x/y)
    EKey = true,
    ForceKill = false,
    AntiAFK = true,
    AutoTrain = false,
}

local UI_NAMES = { "AutoPickupUI", "AutoTrainUI" }

-- =====================================================================
-- 2. LOGIC หลัก
-- =====================================================================

local WALK_SPEED_MULTIPLIER = 3.0
local PICKUP_RANGE = 50
local PICKUP_INTERVAL = 0.2
local COLLECT_DISTANCE = 8
local PROMPT_REFRESH_INTERVAL = 2
local BAG_FULL_COOLDOWN = 3
local E_EVEN_IF_NO_BACK = true

local point1 = nil

local promptCache = {}
local lastPromptRefresh = 0
local bagFullProcessing = false
local bagCooldownUntil = 0
local bagFullCount = 0
local lastBackResult = "ยังไม่เคยกด"

local function getCharacter()
    return player.Character or player.CharacterAdded:Wait()
end

local function getRoot()
    return getCharacter():WaitForChild("HumanoidRootPart")
end

local function setupSpeed()
    local humanoid = getCharacter():WaitForChild("Humanoid")
    humanoid.WalkSpeed = 16 * WALK_SPEED_MULTIPLIER
end

local function getPromptPosition(prompt)
    if not prompt or not prompt.Parent then
        return nil
    end

    local parent = prompt.Parent

    if parent:IsA("BasePart") then
        return parent.Position
    end

    if parent:IsA("Attachment") then
        return parent.WorldPosition
    end

    if parent:IsA("Model") then
        local part = parent:FindFirstChild("HumanoidRootPart")
            or parent.PrimaryPart
            or parent:FindFirstChildWhichIsA("BasePart", true)
        if part then
            return part.Position
        end
    end

    local part = parent:FindFirstChildWhichIsA("BasePart", true)
    if part then
        return part.Position
    end

    return nil
end

local function refreshPromptCache()
    table.clear(promptCache)

    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") then
            table.insert(promptCache, obj)
        end
    end

    lastPromptRefresh = os.clock()
end

workspace.DescendantAdded:Connect(function(obj)
    if obj:IsA("ProximityPrompt") then
        table.insert(promptCache, obj)
    end
end)

workspace.DescendantRemoving:Connect(function(obj)
    if obj:IsA("ProximityPrompt") then
        for i = #promptCache, 1, -1 do
            if promptCache[i] == obj then
                table.remove(promptCache, i)
                break
            end
        end
    end
end)

local function autoPickup()
    local character = player.Character
    if not character then return end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root then return end

    if os.clock() - lastPromptRefresh >= PROMPT_REFRESH_INTERVAL then
        refreshPromptCache()
    end

    local nearestPrompt, nearestPosition = nil, nil
    local nearestDistance = PICKUP_RANGE

    for i = #promptCache, 1, -1 do
        local prompt = promptCache[i]

        if not prompt or not prompt.Parent or not prompt:IsDescendantOf(workspace) then
            table.remove(promptCache, i)
        elseif prompt.Enabled and not prompt:IsDescendantOf(character) then
            local position = getPromptPosition(prompt)
            if position then
                local distance = (root.Position - position).Magnitude
                if distance < nearestDistance then
                    nearestDistance = distance
                    nearestPrompt = prompt
                    nearestPosition = position
                end
            end
        end
    end

    if nearestPrompt and nearestPosition then
        if nearestDistance > COLLECT_DISTANCE then
            humanoid:MoveTo(nearestPosition)
        else
            fireproximityprompt(nearestPrompt)
        end
    end
end

local function doE()
    local root = getRoot()
    if point1 then
        root.CFrame = point1
        print("กลับจุด E สำเร็จ")
        return true
    else
        print("ยังไม่ได้บันทึกจุด E")
        return false
    end
end

-- ---------------------------------------------------------------------
-- GUI HELPERS
-- ---------------------------------------------------------------------

local function isOwnGui(obj)
    for _, name in ipairs(UI_NAMES) do
        if obj:FindFirstAncestor(name) then
            return true
        end
    end
    return false
end

local function isEffectivelyVisible(obj)
    local cur = obj
    while cur do
        if cur:IsA("GuiObject") and not cur.Visible then
            return false
        end
        if cur:IsA("ScreenGui") then
            return cur.Enabled
        end
        cur = cur.Parent
    end
    return true
end

local function stripRichText(text)
    return (string.gsub(tostring(text or ""), "<[^>]+>", ""))
end

local function normalizeText(text)
    text = stripRichText(text)
    text = string.lower(text)
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return text
end

-- ---------------------------------------------------------------------
-- BAG COUNT / BAG FULL
-- ---------------------------------------------------------------------

local bagOverride = nil
local bagCache = nil
local bagCacheTime = 0
local bagMissUntil = 0
local BAG_KEYWORDS = { "bag", "backpack", "inventory", "capacity", "storage", "slots", "carry" }

-- ข้อความที่บอกว่ากระเป๋าเต็ม (ใช้เป็นตัวสำรองเวลาไม่มีตัวเลข x/y)
local FULL_PATTERNS = {
    "bag.-full", "backpack.-full", "inventory.-full", "storage.-full",
    "full.-bag", "กระเป๋าเต็ม", "^%s*full%W*$",
}

local function parseBagText(text)
    text = stripRichText(text)
    text = string.gsub(text, ",", "")
    local current, maximum = string.match(text, "(%d+)%s*/%s*(%d+)")
    if current and maximum then
        return tonumber(current), tonumber(maximum)
    end
    return nil, nil
end

local function collectBagCandidates()
    local result = {}
    local playerGui = player:FindFirstChild("PlayerGui")
    if not playerGui then
        return result
    end

    for _, obj in ipairs(playerGui:GetDescendants()) do
        if (obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox"))
            and not isOwnGui(obj) then

            local current, maximum = parseBagText(obj.Text)

            if current and maximum and maximum > 0 then
                local visible = isEffectivelyVisible(obj)
                local path = string.lower(obj:GetFullName())
                local score = 0

                if visible then score += 100 end

                for _, k in ipairs(BAG_KEYWORDS) do
                    if string.find(path, k, 1, true) then
                        score += 30
                    end
                end

                if string.match(stripRichText(obj.Text), "^%s*[%d,]+%s*/%s*[%d,]+%s*$") then
                    score += 10
                end

                table.insert(result, {
                    obj = obj,
                    current = current,
                    maximum = maximum,
                    score = score,
                    visible = visible,
                })
            end
        end
    end

    table.sort(result, function(a, b)
        return a.score > b.score
    end)

    return result
end

local function getBagCount()
    if bagOverride then
        if bagOverride.Parent then
            local c, m = parseBagText(bagOverride.Text)
            if c and m then
                return c, m
            end
        end
        return nil, nil
    end

    if bagCache and bagCache.Parent
        and os.clock() - bagCacheTime < 3
        and isEffectivelyVisible(bagCache) then

        local c, m = parseBagText(bagCache.Text)
        if c and m then
            return c, m
        end
    end

    -- กันสแกนทั้ง PlayerGui ถี่เกินไปตอนหา label ไม่เจอ
    if os.clock() < bagMissUntil then
        return nil, nil
    end

    local list = collectBagCandidates()
    local best = list[1]

    if best and best.visible then
        bagCache = best.obj
        bagCacheTime = os.clock()
        return best.current, best.maximum
    end

    bagCache = nil
    bagMissUntil = os.clock() + 0.5
    return nil, nil
end

local fullTextCache, fullTextAt = false, 0

local function detectFullText()
    if os.clock() - fullTextAt < 0.4 then
        return fullTextCache
    end
    fullTextAt = os.clock()
    fullTextCache = false

    local playerGui = player:FindFirstChild("PlayerGui")
    if not playerGui then
        return false
    end

    for _, obj in ipairs(playerGui:GetDescendants()) do
        if (obj:IsA("TextLabel") or obj:IsA("TextButton"))
            and obj.Text ~= ""
            and not isOwnGui(obj)
            and isEffectivelyVisible(obj) then

            local t = normalizeText(obj.Text)
            if #t <= 60 then
                for _, p in ipairs(FULL_PATTERNS) do
                    if string.find(t, p) then
                        fullTextCache = true
                        return true
                    end
                end
            end
        end
    end

    return false
end

-- return full:boolean, reason:string
local function isBagFull()
    local current, maximum = getBagCount()

    if current and maximum and current >= maximum then
        return true, ("%d/%d"):format(current, maximum)
    end

    if Feature.FullText and detectFullText() then
        return true, "ข้อความ Bag Full"
    end

    return false, nil
end

-- ---------------------------------------------------------------------
-- FIND / PRESS BACK  (เวอร์ชันใหม่: ให้คะแนนหลายแบบ ไม่ต้องตรงเป๊ะ)
-- ---------------------------------------------------------------------

local function backTextScore(text)
    local t = normalizeText(text)
    if t == "" or #t > 24 then
        return 0
    end

    local ascii = normalizeText((string.gsub(t, "[^%a%s]", "")))

    if t == "back" or ascii == "back" then
        return 3
    end

    if #t <= 12 and string.find(t, "back", 1, true) and not string.find(t, "backpack", 1, true) then
        return 2
    end

    if string.find(t, "กลับ", 1, true) then
        return 1
    end

    return 0
end

local function collectBackCandidates()
    local result = {}
    local playerGui = player:FindFirstChild("PlayerGui")
    if not playerGui then
        return result
    end

    for _, obj in ipairs(playerGui:GetDescendants()) do
        if obj:IsA("GuiObject") and not isOwnGui(obj) then
            local score = 0

            if obj:IsA("TextButton") or obj:IsA("TextLabel") then
                score = backTextScore(obj.Text)
            end

            if obj:IsA("GuiButton") then
                local nm = string.lower(obj.Name)
                if nm == "back" then
                    score = math.max(score, 3)
                elseif string.find(nm, "back", 1, true) and not string.find(nm, "backpack", 1, true) then
                    score = math.max(score, 1)
                end

                if score < 3 then
                    for _, child in ipairs(obj:GetDescendants()) do
                        if child:IsA("TextLabel") or child:IsA("TextButton") then
                            score = math.max(score, backTextScore(child.Text))
                        end
                    end
                end
            end

            if score > 0
                and obj.AbsoluteSize.X > 0 and obj.AbsoluteSize.Y > 0
                and isEffectivelyVisible(obj) then

                if obj:IsA("GuiButton") then
                    score += 10 -- ชอบปุ่มจริงมากกว่า label เฉยๆ
                end

                table.insert(result, { obj = obj, score = score })
            end
        end
    end

    table.sort(result, function(a, b)
        return a.score > b.score
    end)

    return result
end

local function findBackButton()
    local list = collectBackCandidates()
    return list[1] and list[1].obj or nil
end

local function fireOne(btn)
    local fired = false

    if typeof(firesignal) == "function" then
        for _, sigName in ipairs({ "MouseButton1Down", "MouseButton1Up", "MouseButton1Click", "Activated" }) do
            local ok = pcall(function()
                firesignal(btn[sigName])
            end)
            if ok then fired = true end
        end
    end

    if typeof(getconnections) == "function" then
        for _, sigName in ipairs({ "MouseButton1Click", "Activated", "MouseButton1Down", "MouseButton1Up" }) do
            pcall(function()
                for _, conn in ipairs(getconnections(btn[sigName])) do
                    pcall(function() conn:Fire() end)
                    pcall(function()
                        if conn.Function then conn.Function() end
                    end)
                    fired = true
                end
            end)
        end
    end

    pcall(function() btn:Activate() end)

    return fired
end

-- ยิงสัญญาณที่ปุ่ม + ปุ่มลูก + ปุ่มพ่อแม่ (บางเกมผูกอีเวนต์ไว้คนละชั้น)
local function fireButtonSignals(button)
    local fired = fireOne(button)

    for _, d in ipairs(button:GetDescendants()) do
        if d:IsA("GuiButton") then
            if fireOne(d) then fired = true end
        end
    end

    local cur = button.Parent
    for _ = 1, 3 do
        if cur and cur:IsA("GuiButton") then
            fireOne(cur)
        end
        cur = cur and cur.Parent
    end

    return fired
end

-- เลือกปุ่มด้วย GuiService แล้วกด Enter (วิธีเดียวกับการกดด้วยจอยสติ๊ก)
local function selectAndPressEnter(button)
    if not VirtualInputManager then
        return false
    end

    local ok = pcall(function()
        pcall(function() button.Selectable = true end)
        GuiService.SelectedObject = button
        task.wait(0.12)
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
        task.wait(0.05)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Return, false, game)
        task.wait(0.1)
        GuiService.SelectedObject = nil
    end)

    return ok
end

local function autoUsesInset(button)
    local gui = button:FindFirstAncestorOfClass("ScreenGui")
    return not (gui and gui.IgnoreGuiInset)
end

-- mode: "inset" = บวก GuiInset, "noinset" = ไม่บวก
local function realClick(button, mode)
    if not VirtualInputManager then
        return false
    end

    local pos = button.AbsolutePosition + (button.AbsoluteSize / 2)
    local inset = GuiService:GetGuiInset()
    local x, y = pos.X, pos.Y

    if mode == "inset" then
        y += inset.Y
    end

    print(("คลิกจริงที่ (%d, %d) mode=%s inset=%d"):format(x, y, mode, inset.Y))

    local ok = pcall(function()
        VirtualInputManager:SendMouseMoveEvent(x, y, game)
        task.wait(0.05)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
        task.wait(0.08)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end)

    return ok
end

-- ตรวจว่า Back ทำงานจริง: ตัวละครถูกย้าย หรือกระเป๋าไม่เต็มแล้ว
local function backWorked(rootBefore)
    task.wait(0.6)

    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")

    if root and rootBefore and (root.Position - rootBefore).Magnitude > 10 then
        return true
    end

    bagCache = nil
    bagMissUntil = 0
    local c, m = getBagCount()
    if c and m and c < m then
        return true
    end

    return false
end

local function pressBack()
    print("กำลังค้นหาปุ่ม Back...")

    for attempt = 1, 40 do
        local button = findBackButton()

        if button then
            print("พบปุ่ม Back:", button:GetFullName(), "|", button.ClassName)
            print("firesignal:", typeof(firesignal), "| getconnections:", typeof(getconnections),
                "| VirtualInputManager:", tostring(VirtualInputManager ~= nil))

            local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            local rootBefore = root and root.Position

            local autoInset = autoUsesInset(button)
            local primary = autoInset and "inset" or "noinset"
            local alternate = autoInset and "noinset" or "inset"

            local strategies = {
                { "firesignal", function() fireButtonSignals(button) end },
                { "เลือกปุ่ม+Enter", function() selectAndPressEnter(button) end },
                { "คลิกเมาส์ (" .. primary .. ")", function() realClick(button, primary) end },
                { "คลิกเมาส์ (" .. alternate .. ")", function() realClick(button, alternate) end },
            }

            for _, s in ipairs(strategies) do
                print("ลองกด Back ด้วยวิธี:", s[1])
                pcall(s[2])

                if backWorked(rootBefore) then
                    lastBackResult = "✅ กดติดด้วย: " .. s[1]
                    print("กด Back สำเร็จด้วย", s[1])
                    return true
                end

                -- ปุ่มหายไปแล้ว = ถูกกดแล้ว
                if not button.Parent or not isEffectivelyVisible(button) then
                    lastBackResult = "✅ ปุ่มหายหลังกด: " .. s[1]
                    return true
                end
            end

            lastBackResult = "⚠️ ลองครบ 4 วิธีแต่ไม่เห็นผล (ดู F9)"
            warn("กด Back ครบทุกวิธีแล้วแต่ไม่เห็นผล:", button:GetFullName())
            return false
        end

        task.wait(0.05)
    end

    lastBackResult = "❌ ไม่พบปุ่ม Back (ลองกด 🧪 Scan)"
    warn("ไม่พบปุ่ม Back")
    return false
end

local function handleBagFull(reason)
    if bagFullProcessing then
        return
    end

    bagFullProcessing = true
    bagFullCount += 1

    print("==============================")
    print("BAG FULL", tostring(reason))
    print("==============================")

    local ok, err = pcall(function()
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            humanoid:Move(Vector3.zero)
        end

        local pressed = pressBack()

        if pressed then
            task.wait(0.15)
            doE()
            print("Back -> E สำเร็จ")
        else
            warn("กระเป๋าเต็ม (" .. tostring(reason) .. ") แต่กด Back ไม่สำเร็จ")
            if E_EVEN_IF_NO_BACK then
                doE()
            end
        end

        task.wait(0.5)
    end)

    if not ok then
        warn("handleBagFull error:", err)
    end

    bagCooldownUntil = os.clock() + BAG_FULL_COOLDOWN
    bagFullProcessing = false
end

-- =====================================================================
-- 3. LOGIC เสริม
-- =====================================================================

local function normalizeName(name)
    return (string.gsub(string.lower(name), "[%s_%-]+", ""))
end

local function loadPosFile(file, target)
    pcall(function()
        if typeof(isfile) == "function" and isfile(file) then
            local data = HttpService:JSONDecode(readfile(file))
            for k, v in pairs(data) do
                target[tonumber(k)] = Vector3.new(v[1], v[2], v[3])
            end
        end
    end)
end

local function savePosFile(file, source)
    pcall(function()
        if typeof(writefile) == "function" then
            local data = {}
            for k, v in pairs(source) do
                data[tostring(k)] = { v.X, v.Y, v.Z }
            end
            writefile(file, HttpService:JSONEncode(data))
        end
    end)
end

local function scanNumbered(out, prefixes, suffixes, containers, minN, maxN)
    table.clear(out)

    local all = workspace:GetDescendants()

    for i, inst in ipairs(all) do
        if i % 4000 == 0 then
            task.wait()
        end

        if inst:IsA("Model") or inst:IsA("Folder") or inst:IsA("BasePart") then
            local nm = normalizeName(inst.Name)
            local num = nil

            if string.find(nm, "%d") then
                for _, prefix in ipairs(prefixes) do
                    for _, suf in ipairs(suffixes) do
                        local n = string.match(nm, "^" .. prefix .. "0*(%d+)" .. suf .. "$")
                        if n then
                            num = tonumber(n)
                            break
                        end
                    end
                    if num then break end
                end

                if not num and inst.Parent and containers[normalizeName(inst.Parent.Name)] then
                    local n = string.match(nm, "^0*(%d+)$")
                    if n then
                        num = tonumber(n)
                    end
                end
            end

            if num and num >= minN and num <= maxN then
                out[num] = out[num] or {}
                table.insert(out[num], inst)
            end
        end
    end
end

local function findSpawnPart(inst)
    if inst:IsA("SpawnLocation") then
        return inst
    end

    for _, d in ipairs(inst:GetDescendants()) do
        if d:IsA("SpawnLocation") then
            return d
        end
    end

    for _, d in ipairs(inst:GetDescendants()) do
        if d:IsA("BasePart") then
            local l = string.lower(d.Name)
            if string.find(l, "spawn", 1, true)
                or string.find(l, "teleport", 1, true)
                or string.find(l, "start", 1, true) then
                return d
            end
        end
    end

    return nil
end

local function instanceTeleportPosition(inst)
    local spawn = findSpawnPart(inst)
    if spawn then
        return spawn.Position + Vector3.new(0, spawn.Size.Y / 2 + 4, 0)
    end

    if inst:IsA("BasePart") then
        return inst.Position + Vector3.new(0, inst.Size.Y / 2 + 4, 0)
    end

    if inst:IsA("Model") then
        return inst:GetPivot().Position + Vector3.new(0, 8, 0)
    end

    local part = inst:FindFirstChildWhichIsA("BasePart", true)
    if part then
        return part.Position + Vector3.new(0, part.Size.Y / 2 + 4, 0)
    end

    return nil
end

local function resolveDetected(map, n)
    local list = map[n]
    if not list then
        return nil
    end

    for _, inst in ipairs(list) do
        if inst.Parent and findSpawnPart(inst) then
            return instanceTeleportPosition(inst)
        end
    end

    for _, inst in ipairs(list) do
        if inst.Parent then
            local pos = instanceTeleportPosition(inst)
            if pos then
                return pos
            end
        end
    end

    return nil
end

local function teleportToPosition(pos)
    pcall(function()
        player:RequestStreamAroundAsync(pos)
    end)

    local root = getRoot()
    root.AssemblyLinearVelocity = Vector3.zero
    root.CFrame = CFrame.new(pos)
end

-- ---------------------------------------------------------------------
-- 3.1 STAGE TELEPORT (1 - 27)
-- ---------------------------------------------------------------------

local STAGE_MIN, STAGE_MAX = 1, 27
local STAGE_FILE = "AutoPickup_StagePositions.json"
local stageSaved = {}
local stageDetected = {}

local STAGE_PREFIXES = { "stage", "level", "world", "zone", "area", "map", "island" }
local STAGE_CONTAINERS = {
    stages = true, stage = true, levels = true, worlds = true,
    zones = true, areas = true, maps = true, islands = true,
}

local function scanStages()
    scanNumbered(stageDetected, STAGE_PREFIXES, { "" }, STAGE_CONTAINERS, STAGE_MIN, STAGE_MAX)
end

local function saveStageHere(n)
    stageSaved[n] = getRoot().Position
    savePosFile(STAGE_FILE, stageSaved)
    print(("บันทึกตำแหน่ง Stage %d แล้ว"):format(n))
end

local function clearStageSaved(n)
    stageSaved[n] = nil
    savePosFile(STAGE_FILE, stageSaved)
    print(("ลบตำแหน่งที่บันทึกของ Stage %d แล้ว"):format(n))
end

local function teleportToStage(n)
    local pos = stageSaved[n]
    local source = "saved"

    if not pos then
        if not stageDetected[n] then
            scanStages()
        end
        pos = resolveDetected(stageDetected, n)
        source = "auto"
    end

    if not pos then
        warn(("ไม่พบตำแหน่ง Stage %d -> ไปยืนที่ Stage นั้นแล้วกด 💾 บันทึก"):format(n))
        return false, nil
    end

    teleportToPosition(pos)
    print(("วาร์ปไป Stage %d สำเร็จ (%s)"):format(n, source))
    return true, source
end

-- ---------------------------------------------------------------------
-- 3.2 AUTO TRAIN (Area)
-- ---------------------------------------------------------------------

local TRAIN_AREAS = {
    "Area 1 (Rebirth 0)",
    "Area 2 (Rebirth 2)",
    "Area 3 (Rebirth 5)",
    "Area 4 (Rebirth 9)",
    "Area 5 (Rebirth 12)",
    "Area 6 (Rebirth 15)",
    "Area 7 (Rebirth 18)",
    "Area 8 (Rebirth 21)",
}

local AREA_FILE = "AutoPickup_AreaPositions.json"
local areaSaved = {}
local areaDetected = {}
local SelectedArea = nil
local SelectedAreaIndex = nil

local AREA_PREFIXES = {
    "area", "trainarea", "trainingarea", "trainzone", "trainingzone",
    "train", "training", "zone",
}
local AREA_SUFFIXES = { "", "spawn", "teleport", "tp", "pad", "zone", "train", "start" }
local AREA_CONTAINERS = {
    areas = true, trainareas = true, trainingareas = true,
    trainzones = true, zones = true, training = true, train = true,
}

local function scanAreas()
    scanNumbered(areaDetected, AREA_PREFIXES, AREA_SUFFIXES, AREA_CONTAINERS, 1, #TRAIN_AREAS)
end

local function saveAreaHere(n)
    areaSaved[n] = getRoot().Position
    savePosFile(AREA_FILE, areaSaved)
    print(("บันทึกตำแหน่ง Area %d แล้ว"):format(n))
end

local function clearAreaSaved(n)
    areaSaved[n] = nil
    savePosFile(AREA_FILE, areaSaved)
    print(("ลบตำแหน่งที่บันทึกของ Area %d แล้ว"):format(n))
end

local function teleportToArea(n)
    local pos = areaSaved[n]
    local source = "saved"

    if not pos then
        if not areaDetected[n] then
            scanAreas()
        end
        pos = resolveDetected(areaDetected, n)
        source = "auto"
    end

    if not pos then
        warn(("ไม่พบตำแหน่ง Area %d -> ไปยืนที่ Area นั้นแล้วกด 💾 บันทึก"):format(n))
        return false, nil
    end

    teleportToPosition(pos)
    print(("วาร์ปไป Area %d สำเร็จ (%s)"):format(n, source))
    return true, source
end

player.CharacterAdded:Connect(function()
    if Feature.AutoTrain and SelectedAreaIndex then
        task.wait(2)
        pcall(teleportToArea, SelectedAreaIndex)
    end
end)

-- ---------------------------------------------------------------------
-- 3.3 FORCE KILL
-- ---------------------------------------------------------------------

local KILL_RANGE = 200
local KILL_INTERVAL = 0.15
local KILL_MODE = "OneHit"          -- "OneHit" | "All"
local ENEMY_REFRESH = 1.5
local ENEMY_FOLDER_NAMES = { "Enemies", "Enemy", "Mobs", "Monsters" }

local enemiesFolderCache = nil
local enemyList = {}
local enemyCount = 0
local enemyRefreshAt = 0
local killedCount = 0

local function getEnemiesFolder()
    if enemiesFolderCache and enemiesFolderCache.Parent then
        return enemiesFolderCache
    end

    local folder = nil

    for _, name in ipairs(ENEMY_FOLDER_NAMES) do
        folder = workspace:FindFirstChild(name) or workspace:FindFirstChild(name, true)
        if folder then
            break
        end
    end

    enemiesFolderCache = folder
    return folder
end

local function getModelPosition(model)
    if model:IsA("BasePart") then
        return model.Position
    end

    if model:IsA("Model") then
        local ok, pivot = pcall(function()
            return model:GetPivot()
        end)
        if ok and pivot then
            return pivot.Position
        end
    end

    return nil
end

local function readHealth(model, info)
    local hum = info.hum

    if hum and hum.Parent then
        return hum.Health, hum.MaxHealth
    end

    local hp = model:FindFirstChild("Health")
    if hp and hp:IsA("NumberValue") then
        return hp.Value, nil
    end

    local attr = model:GetAttribute("Health")
    if type(attr) == "number" then
        return attr, model:GetAttribute("MaxHealth")
    end

    return nil, nil
end

local function claimOwnership()
    pcall(function()
        if typeof(sethiddenproperty) == "function" then
            sethiddenproperty(player, "SimulationRadius", math.huge)
        end
    end)
    pcall(function()
        if typeof(setsimulationradius) == "function" then
            setsimulationradius(math.huge, math.huge)
        end
    end)
    pcall(function()
        player.MaximumSimulationRadius = math.huge
    end)
end

local function killEnemy(model, info)
    local hum = info.hum

    if hum then
        pcall(function() hum.Health = 0 end)
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Dead) end)
    end

    local hpValue = model:FindFirstChild("Health")
    if hpValue and hpValue:IsA("NumberValue") then
        pcall(function() hpValue.Value = 0 end)
    end

    if type(model:GetAttribute("Health")) == "number" then
        pcall(function() model:SetAttribute("Health", 0) end)
    end

    pcall(function() model:BreakJoints() end)

    for _, d in ipairs(model:GetDescendants()) do
        if d.Name == "Neck" and (d:IsA("Motor6D") or d:IsA("Weld")) then
            pcall(function() d:Destroy() end)
        end
    end
end

local function tryKill(model, info)
    local pos = getModelPosition(model)
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")

    if not pos or not root then
        return
    end

    if (pos - root.Position).Magnitude > KILL_RANGE then
        return
    end

    local now = os.clock()
    if info.killedAt and now - info.killedAt < 0.8 then
        return
    end

    info.killedAt = now

    if not info.counted then
        info.counted = true
        killedCount += 1
    end

    killEnemy(model, info)
end

local function dropEnemy(model)
    local info = enemyList[model]
    if info then
        if info.conn then
            info.conn:Disconnect()
        end
        enemyList[model] = nil
    end
end

local function hookEnemy(model, info)
    local hum = info.hum
    if not hum then
        return
    end

    info.maxHp = hum.MaxHealth

    info.conn = hum.HealthChanged:Connect(function(hp)
        if Feature.ForceKill and KILL_MODE == "OneHit" then
            info.maxHp = math.max(info.maxHp or 0, hum.MaxHealth)
            if hp > 0 and hp < info.maxHp then
                tryKill(model, info)
            end
        end
    end)
end

local function refreshEnemies()
    local folder = getEnemiesFolder()
    local seen = {}

    local function add(model)
        if seen[model] then
            return
        end
        seen[model] = true

        if not enemyList[model]
            and model ~= player.Character
            and not Players:GetPlayerFromCharacter(model) then

            local info = { hum = model:FindFirstChildOfClass("Humanoid") }
            enemyList[model] = info
            hookEnemy(model, info)
        end
    end

    local source = folder or workspace

    for _, d in ipairs(source:GetDescendants()) do
        if d:IsA("Humanoid") then
            local m = d.Parent
            if m and m:IsA("Model") then
                add(m)
            end
        end
    end

    if folder then
        for _, c in ipairs(folder:GetChildren()) do
            if c:IsA("Model") and not c:FindFirstChildOfClass("Humanoid") then
                add(c)
            end
        end
    end

    local n = 0
    for model in pairs(enemyList) do
        if not model.Parent or not seen[model] then
            dropEnemy(model)
        else
            n += 1
        end
    end

    enemyCount = n
    enemyRefreshAt = os.clock()
end

local function forceKillEnemies()
    for model, info in pairs(enemyList) do
        if not model.Parent then
            dropEnemy(model)
        else
            local hp, maxHp = readHealth(model, info)

            if hp and hp > 0 then
                info.maxHp = math.max(info.maxHp or 0, maxHp or 0, hp)

                if KILL_MODE == "All" or hp < info.maxHp then
                    tryKill(model, info)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- 3.4 ANTI AFK
-- ---------------------------------------------------------------------

local antiAfkCount = 0

local function antiAfkPulse()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new(0, 0))
    end)
end

player.Idled:Connect(function()
    if Feature.AntiAFK then
        antiAfkCount += 1
        antiAfkPulse()
        print("Anti AFK: ป้องกันการถูกเตะแล้ว (" .. antiAfkCount .. ")")
    end
end)

task.spawn(function()
    while true do
        task.wait(45)
        if Feature.AntiAFK then
            antiAfkPulse()
        end
    end
end)

-- ---------------------------------------------------------------------
-- 3.5 SCAN (ดูผลใน F9)
-- ---------------------------------------------------------------------

local function scanGame()
    print("================ SCAN START ================")

    local bags = collectBagCandidates()
    print("[BAG] ตัวเลขรูปแบบ x/y ที่เจอ:", #bags)
    for i, b in ipairs(bags) do
        if i > 15 then break end
        print(("  #%d score=%d visible=%s %d/%d  %s"):format(
            i, b.score, tostring(b.visible), b.current, b.maximum, b.obj:GetFullName()))
    end
    print("[BAG] ข้อความ Bag Full ตอนนี้:", tostring(detectFullText()))

    local backs = collectBackCandidates()
    print("[BACK] ปุ่ม/ข้อความ Back ที่เจอตอนนี้:", #backs)
    for i, b in ipairs(backs) do
        if i > 8 then break end
        print(("  #%d score=%d %s  %s"):format(i, b.score, b.obj.ClassName, b.obj:GetFullName()))
    end
    if #backs == 0 then
        print("  (ไม่พบ - ให้เปิดหน้าจอที่มีปุ่ม Back ค้างไว้แล้วกด Scan ใหม่)")
    end

    local ef = getEnemiesFolder()
    if ef then
        print("[ENEMIES]", ef:GetFullName(), "ลูก:", #ef:GetChildren())
    else
        print("[ENEMIES] ไม่พบโฟลเดอร์ Enemies/Enemy/Mobs/Monsters")
    end

    scanAreas()
    local foundAreas = 0
    for n = 1, #TRAIN_AREAS do
        if areaDetected[n] then
            foundAreas += 1
            print(("[AREA %d] %s"):format(n, areaDetected[n][1]:GetFullName()))
        end
    end
    print("[AREA] ตรวจเจอ", foundAreas, "/", #TRAIN_AREAS)

    scanStages()
    local found = 0
    for n = STAGE_MIN, STAGE_MAX do
        if stageDetected[n] then
            found += 1
            print(("[STAGE %d] %s"):format(n, stageDetected[n][1]:GetFullName()))
        end
    end
    print("[STAGE] ตรวจเจอ", found, "/", STAGE_MAX)

    local remotes = 0
    for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
            remotes += 1
            if remotes <= 60 then
                print("[REMOTE]", d.ClassName, d:GetFullName())
            end
        end
    end

    print("================ SCAN END ================")
end

-- =====================================================================
-- 4. CONTROL
-- =====================================================================

local function applySpeed()
    local character = player.Character
    if not character then return end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end

    humanoid.WalkSpeed = Feature.Speed and (16 * WALK_SPEED_MULTIPLIER) or 16
end

local function savePointHere()
    point1 = getRoot().CFrame
    print("บันทึกจุด E แล้ว")
end

local function clearPoint()
    point1 = nil
    print("ลบจุด E แล้ว")
end

setupSpeed()
refreshPromptCache()
loadPosFile(STAGE_FILE, stageSaved)
loadPosFile(AREA_FILE, areaSaved)

player.CharacterAdded:Connect(function()
    task.wait(1)
    if Feature.Speed then
        setupSpeed()
    end
end)

-- MAIN LOOP (Bag / Pickup)
task.spawn(function()
    while true do
        local ok, err = pcall(function()
            local handled = false

            if Feature.BagHandler and os.clock() >= bagCooldownUntil then
                local full, reason = isBagFull()
                if full then
                    handled = true
                    handleBagFull(reason)
                end
            end

            if not handled and Feature.AutoPickup then
                autoPickup()
            end
        end)

        if not ok then
            warn("MainLoop error:", err)
        end

        task.wait(PICKUP_INTERVAL)
    end
end)

-- FORCE KILL LOOP
task.spawn(function()
    local lastOwn = 0

    while true do
        if Feature.ForceKill then
            local ok, err = pcall(function()
                local now = os.clock()

                if now - enemyRefreshAt > ENEMY_REFRESH then
                    refreshEnemies()
                end

                if now - lastOwn > 5 then
                    claimOwnership()
                    lastOwn = now
                end

                forceKillEnemies()
            end)

            if not ok then
                warn("ForceKill error:", err)
            end
        end

        task.wait(KILL_INTERVAL)
    end
end)

-- E KEY
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if not Feature.EKey then return end

    if input.KeyCode == Enum.KeyCode.E then
        if not point1 then
            savePointHere()
        else
            doE()
        end
    end
end)

-- =====================================================================
-- 5. UI ใหม่ (หน้าต่างเดียว + แท็บด้านซ้าย)
-- =====================================================================

local THEME = {
    Bg = Color3.fromRGB(10, 6, 18),
    Side = Color3.fromRGB(16, 9, 30),
    Panel = Color3.fromRGB(22, 12, 38),
    Card = Color3.fromRGB(28, 16, 48),
    Stroke = Color3.fromRGB(84, 50, 150),
    Text = Color3.fromRGB(242, 234, 255),
    Sub = Color3.fromRGB(165, 145, 205),
    Accent = Color3.fromRGB(145, 75, 255),
    Accent2 = Color3.fromRGB(215, 120, 255),
    On = Color3.fromRGB(160, 90, 255),
    Off = Color3.fromRGB(52, 40, 80),
    Danger = Color3.fromRGB(255, 70, 120),
    Good = Color3.fromRGB(120, 255, 190),
    Warn = Color3.fromRGB(255, 200, 90),
    Mid = Color3.fromRGB(110, 60, 200),
}

local TOGGLE_KEY = Enum.KeyCode.RightShift
local GLOW_IMAGE = "rbxassetid://5028857084"

local function create(class, props, children)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        inst[k] = v
    end
    for _, c in ipairs(children or {}) do
        c.Parent = inst
    end
    return inst
end

local function corner(r)
    return create("UICorner", { CornerRadius = UDim.new(0, r) })
end

local function stroke(color, thickness, transparency)
    return create("UIStroke", {
        Color = color,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    })
end

local function gradient(c1, c2, rot)
    return create("UIGradient", {
        Color = ColorSequence.new(c1, c2),
        Rotation = rot or 0,
    })
end

local function padding(p)
    return create("UIPadding", {
        PaddingTop = UDim.new(0, p), PaddingBottom = UDim.new(0, p),
        PaddingLeft = UDim.new(0, p), PaddingRight = UDim.new(0, p),
    })
end

local function tween(obj, props, t)
    TweenService:Create(
        obj,
        TweenInfo.new(t or 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        props
    ):Play()
end

local function neonStroke(thickness)
    local g = Instance.new("UIGradient")
    g.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, THEME.Accent),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(34, 14, 66)),
        ColorSequenceKeypoint.new(1, THEME.Accent2),
    })

    local s = create("UIStroke", {
        Color = Color3.new(1, 1, 1),
        Thickness = thickness or 1.5,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, { g })

    TweenService:Create(
        g,
        TweenInfo.new(5, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1),
        { Rotation = 360 }
    ):Play()

    return s
end

local function glow(color, transparency, spread)
    spread = spread or 12
    return create("ImageLabel", {
        Name = "Glow",
        BackgroundTransparency = 1,
        Image = GLOW_IMAGE,
        ImageColor3 = color,
        ImageTransparency = transparency or 0.5,
        ScaleType = Enum.ScaleType.Slice,
        SliceCenter = Rect.new(24, 24, 276, 276),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.new(1, spread * 2, 1, spread * 2),
        ZIndex = 0,
    })
end

local function breathe(img, from, to, seconds)
    img.ImageTransparency = from
    TweenService:Create(
        img,
        TweenInfo.new(seconds or 2.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
        { ImageTransparency = to }
    ):Play()
end

local function makeDraggable(handle, target)
    local dragging, dragStart, startPos = false, nil, nil

    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = target.Position
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            target.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y
            )
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

-- ล้าง UI เก่า
local parentGui = (typeof(gethui) == "function" and gethui()) or player:WaitForChild("PlayerGui")
for _, name in ipairs(UI_NAMES) do
    local old = parentGui:FindFirstChild(name)
    if old then old:Destroy() end
end

local screen = create("ScreenGui", {
    Name = "AutoPickupUI",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 999,
})
screen.Parent = parentGui

local WIN_W, WIN_H = 560, 410
local HEADER_H = 46

local rootFrame = create("Frame", {
    Name = "Root",
    Size = UDim2.fromOffset(WIN_W, WIN_H),
    Position = UDim2.new(0.5, -WIN_W / 2, 0.5, -WIN_H / 2),
    BackgroundTransparency = 1,
    Parent = screen,
})

-- ย่อหน้าต่างอัตโนมัติบนจอเล็ก/มือถือ
do
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    local scale = math.clamp(math.min(vp.X / (WIN_W + 40), vp.Y / (WIN_H + 40)), 0.55, 1)
    create("UIScale", { Scale = scale, Parent = rootFrame })
end

local rootGlow = glow(THEME.Accent, 0.55, 24)
rootGlow.Parent = rootFrame
breathe(rootGlow, 0.5, 0.78, 2.6)

local main = create("Frame", {
    Name = "Main",
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = THEME.Bg,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Parent = rootFrame,
}, {
    corner(16),
    neonStroke(1.6),
    gradient(Color3.fromRGB(26, 12, 48), Color3.fromRGB(6, 4, 12), 90),
})

-- ---------- Header ----------
local header = create("Frame", {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, HEADER_H),
    BackgroundColor3 = THEME.Panel,
    BorderSizePixel = 0,
    Parent = main,
}, {
    gradient(Color3.fromRGB(78, 28, 150), Color3.fromRGB(14, 8, 30), 0),
})

create("Frame", {
    Size = UDim2.new(1, 0, 0, 1),
    Position = UDim2.new(0, 0, 1, -1),
    BackgroundColor3 = THEME.Accent2,
    BorderSizePixel = 0,
    Parent = header,
}, {
    create("UIGradient", {
        Color = ColorSequence.new(THEME.Accent, THEME.Accent2),
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.5, 0),
            NumberSequenceKeypoint.new(1, 1),
        }),
    }),
})

create("TextLabel", {
    Text = "🚀  AUTO PICKUP",
    Font = Enum.Font.GothamBlack,
    TextSize = 17,
    TextColor3 = THEME.Text,
    TextXAlignment = Enum.TextXAlignment.Left,
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(16, 6),
    Size = UDim2.new(1, -120, 0, 20),
    Parent = header,
})

create("TextLabel", {
    Text = "RightShift = ซ่อน/แสดง  •  ลากหัวข้อเพื่อย้าย",
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextColor3 = Color3.fromRGB(210, 195, 245),
    TextXAlignment = Enum.TextXAlignment.Left,
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(16, 26),
    Size = UDim2.new(1, -120, 0, 14),
    Parent = header,
})

local function headerButton(text, xOffset, color)
    return create("TextButton", {
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 16,
        TextColor3 = THEME.Text,
        BackgroundColor3 = color,
        BackgroundTransparency = 0.35,
        AutoButtonColor = false,
        Size = UDim2.fromOffset(28, 28),
        Position = UDim2.new(1, xOffset, 0, 9),
        Parent = header,
    }, { corner(8) })
end

local btnMin = headerButton("–", -68, Color3.fromRGB(190, 150, 255))
local btnClose = headerButton("✕", -34, THEME.Danger)

makeDraggable(header, rootFrame)

-- ---------- Sidebar ----------
local sidebar = create("Frame", {
    Name = "Sidebar",
    Position = UDim2.fromOffset(0, HEADER_H),
    Size = UDim2.new(0, 120, 1, -HEADER_H),
    BackgroundColor3 = THEME.Side,
    BackgroundTransparency = 0.2,
    BorderSizePixel = 0,
    Parent = main,
}, {
    create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
    padding(8),
})

local pages, tabButtons = {}, {}
local tabOrder = 0

local function selectTab(key)
    for k, page in pairs(pages) do
        page.Visible = (k == key)
    end
    for k, b in pairs(tabButtons) do
        local on = (k == key)
        tween(b, { BackgroundTransparency = on and 0.15 or 1 })
        b.TextColor3 = on and THEME.Text or THEME.Sub
    end
end

local function addTab(key, label)
    tabOrder += 1

    local b = create("TextButton", {
        Text = label,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = THEME.Sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        AutoButtonColor = false,
        BackgroundColor3 = THEME.Accent,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 38),
        LayoutOrder = tabOrder,
        Parent = sidebar,
    }, { corner(10), create("UIPadding", { PaddingLeft = UDim.new(0, 12) }) })

    b.MouseEnter:Connect(function()
        if not pages[key].Visible then tween(b, { BackgroundTransparency = 0.7 }, 0.12) end
    end)
    b.MouseLeave:Connect(function()
        if not pages[key].Visible then tween(b, { BackgroundTransparency = 1 }, 0.12) end
    end)

    local page = create("ScrollingFrame", {
        Name = key,
        Position = UDim2.fromOffset(128, HEADER_H + 8),
        Size = UDim2.new(1, -136, 1, -(HEADER_H + 16)),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = THEME.Accent,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Visible = false,
        Parent = main,
    }, {
        create("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }),
        create("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 6) }),
    })

    pages[key] = page
    tabButtons[key] = b
    b.MouseButton1Click:Connect(function() selectTab(key) end)

    return page
end

-- ---------- ชิ้นส่วน UI ----------
local order = 0
local function nextOrder()
    order += 1
    return order
end

local function newCard(page, title)
    local c = create("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = THEME.Card,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
        Parent = page,
    }, {
        corner(12),
        stroke(THEME.Stroke, 1, 0.5),
        gradient(Color3.fromRGB(38, 20, 66), Color3.fromRGB(20, 11, 36), 90),
        create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
        padding(10),
    })

    if title then
        create("TextLabel", {
            Text = title,
            Font = Enum.Font.GothamBold,
            TextSize = 13,
            TextColor3 = THEME.Accent2,
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 0, 18),
            LayoutOrder = nextOrder(),
            Parent = c,
        })
    end

    return c
end

local function addLabel(parent, text, size, color, bold)
    return create("TextLabel", {
        Text = text,
        Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham,
        TextSize = size or 12,
        TextColor3 = color or THEME.Sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, (size or 12) + 4),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = nextOrder(),
        Parent = parent,
    })
end

local function addToggle(parent, emoji, title, desc, featureKey, onChanged)
    local row = create("Frame", {
        Size = UDim2.new(1, 0, 0, 44),
        BackgroundTransparency = 1,
        LayoutOrder = nextOrder(),
        Parent = parent,
    })

    create("TextLabel", {
        Text = emoji,
        TextSize = 20,
        BackgroundTransparency = 1,
        Size = UDim2.fromOffset(28, 44),
        Parent = row,
    })

    create("TextLabel", {
        Text = title,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = THEME.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(34, 5),
        Size = UDim2.new(1, -92, 0, 18),
        Parent = row,
    })

    create("TextLabel", {
        Text = desc,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = THEME.Sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(34, 23),
        Size = UDim2.new(1, -92, 0, 16),
        Parent = row,
    })

    local holder = create("Frame", {
        Size = UDim2.fromOffset(44, 22),
        Position = UDim2.new(1, -48, 0.5, -11),
        BackgroundTransparency = 1,
        Parent = row,
    })

    local tGlow = glow(THEME.Accent, Feature[featureKey] and 0.4 or 1, 8)
    tGlow.Parent = holder

    local track = create("TextButton", {
        Text = "",
        AutoButtonColor = false,
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Feature[featureKey] and THEME.On or THEME.Off,
        Parent = holder,
    }, { corner(11) })

    local knob = create("Frame", {
        Size = UDim2.fromOffset(16, 16),
        Position = Feature[featureKey] and UDim2.fromOffset(25, 3) or UDim2.fromOffset(3, 3),
        BackgroundColor3 = Color3.new(1, 1, 1),
        Parent = track,
    }, { corner(8) })

    track.MouseButton1Click:Connect(function()
        Feature[featureKey] = not Feature[featureKey]
        local on = Feature[featureKey]
        tween(track, { BackgroundColor3 = on and THEME.On or THEME.Off })
        tween(knob, { Position = on and UDim2.fromOffset(25, 3) or UDim2.fromOffset(3, 3) })
        tween(tGlow, { ImageTransparency = on and 0.4 or 1 }, 0.25)
        if onChanged then onChanged(on) end
    end)

    return row
end

local function addSlider(parent, label, min, max, step, initial, fmt, onChanged)
    local holder = create("Frame", {
        Size = UDim2.new(1, 0, 0, 38),
        BackgroundTransparency = 1,
        LayoutOrder = nextOrder(),
        Parent = parent,
    })

    create("TextLabel", {
        Text = label,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextColor3 = THEME.Sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
        Size = UDim2.new(0.6, 0, 0, 16),
        Parent = holder,
    })

    local valueLabel = create("TextLabel", {
        Text = string.format(fmt, initial),
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = THEME.Accent2,
        TextXAlignment = Enum.TextXAlignment.Right,
        BackgroundTransparency = 1,
        Position = UDim2.fromScale(0.6, 0),
        Size = UDim2.new(0.4, 0, 0, 16),
        Parent = holder,
    })

    local bar = create("Frame", {
        Position = UDim2.fromOffset(0, 24),
        Size = UDim2.new(1, 0, 0, 6),
        BackgroundColor3 = THEME.Off,
        Parent = holder,
    }, { corner(3) })

    local fill = create("Frame", {
        Size = UDim2.fromScale((initial - min) / (max - min), 1),
        BackgroundColor3 = THEME.Accent,
        Parent = bar,
    }, { corner(3), gradient(THEME.Accent, THEME.Accent2, 0) })

    local knob = create("Frame", {
        Size = UDim2.fromOffset(14, 14),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale((initial - min) / (max - min), 0.5),
        BackgroundColor3 = Color3.new(1, 1, 1),
        Parent = bar,
    }, { corner(7), stroke(THEME.Accent2, 2, 0) })

    local hit = create("TextButton", {
        Text = "",
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(0, 16),
        Size = UDim2.new(1, 0, 0, 22),
        Parent = holder,
    })

    local function setFromX(x)
        local rel = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
        local value = min + rel * (max - min)
        value = math.floor(value / step + 0.5) * step
        value = math.clamp(value, min, max)
        local pct = (value - min) / (max - min)
        fill.Size = UDim2.fromScale(pct, 1)
        knob.Position = UDim2.fromScale(pct, 0.5)
        valueLabel.Text = string.format(fmt, value)
        onChanged(value)
    end

    local sliding = false
    hit.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            sliding = true
            setFromX(input.Position.X)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            setFromX(input.Position.X)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            sliding = false
        end
    end)
end

-- defs = { {text, color, w, callback}, ... }  (w รวมกัน = 1)
local function addButtons(parent, defs, height)
    local row = create("Frame", {
        Size = UDim2.new(1, 0, 0, height or 34),
        BackgroundTransparency = 1,
        LayoutOrder = nextOrder(),
        Parent = parent,
    })

    local buttons = {}
    local x = 0

    for i, d in ipairs(defs) do
        local holder = create("Frame", {
            Position = UDim2.new(x, 0, 0, 0),
            Size = UDim2.new(d.w, -4, 1, 0),
            BackgroundTransparency = 1,
            Parent = row,
        })
        x += d.w

        local bGlow = glow(d.color, 0.88, 6)
        bGlow.Parent = holder

        local b = create("TextButton", {
            Text = d.text,
            Font = Enum.Font.GothamBold,
            TextSize = 12,
            TextColor3 = THEME.Text,
            TextWrapped = true,
            AutoButtonColor = false,
            BackgroundColor3 = d.color,
            Size = UDim2.fromScale(1, 1),
            Parent = holder,
        }, { corner(10), stroke(THEME.Accent2, 1, 0.7) })

        b.MouseEnter:Connect(function()
            tween(b, { BackgroundTransparency = 0.15 })
            tween(bGlow, { ImageTransparency = 0.5 })
        end)
        b.MouseLeave:Connect(function()
            tween(b, { BackgroundTransparency = 0 })
            tween(bGlow, { ImageTransparency = 0.88 })
        end)
        b.MouseButton1Click:Connect(d.callback)

        buttons[i] = b
    end

    return buttons
end

-- Dropdown แบบเปิดในบรรทัด (ไม่ทับของอื่น)
local function addDropdown(parent, placeholder, items, onSelect)
    local box = create("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = nextOrder(),
        Parent = parent,
    }, {
        create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
    })

    local btn = create("TextButton", {
        Text = "",
        AutoButtonColor = false,
        BackgroundColor3 = THEME.Panel,
        Size = UDim2.new(1, 0, 0, 34),
        LayoutOrder = 1,
        Parent = box,
    }, { corner(8), stroke(THEME.Accent, 1, 0.5) })

    local txt = create("TextLabel", {
        Text = placeholder,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextColor3 = THEME.Sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(10, 0),
        Size = UDim2.new(1, -34, 1, 0),
        Parent = btn,
    })

    local arrow = create("TextLabel", {
        Text = "▼",
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = THEME.Accent2,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(1, -16, 0.5, 0),
        Size = UDim2.fromOffset(16, 16),
        Parent = btn,
    })

    local list = create("Frame", {
        Visible = false,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = THEME.Bg,
        BorderSizePixel = 0,
        LayoutOrder = 2,
        Parent = box,
    }, {
        corner(8),
        stroke(THEME.Accent, 1, 0.3),
        create("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
        padding(4),
    })

    local open = false
    local itemButtons = {}

    local function setOpen(v)
        open = v
        list.Visible = v
        tween(arrow, { Rotation = v and 180 or 0 }, 0.15)
    end

    for i, name in ipairs(items) do
        local item = create("TextButton", {
            Text = name,
            Font = Enum.Font.Gotham,
            TextSize = 12,
            TextColor3 = THEME.Sub,
            TextXAlignment = Enum.TextXAlignment.Left,
            AutoButtonColor = false,
            BackgroundColor3 = THEME.Card,
            Size = UDim2.new(1, 0, 0, 26),
            LayoutOrder = i,
            Parent = list,
        }, { corner(6), create("UIPadding", { PaddingLeft = UDim.new(0, 8) }) })

        itemButtons[i] = item

        item.MouseEnter:Connect(function() tween(item, { BackgroundColor3 = THEME.Stroke }, 0.1) end)
        item.MouseLeave:Connect(function() tween(item, { BackgroundColor3 = THEME.Card }, 0.1) end)
        item.MouseButton1Click:Connect(function()
            txt.Text = name
            txt.TextColor3 = THEME.Text
            for j, b in ipairs(itemButtons) do
                b.TextColor3 = (j == i) and THEME.Accent2 or THEME.Sub
            end
            setOpen(false)
            onSelect(name, i)
        end)
    end

    btn.MouseButton1Click:Connect(function() setOpen(not open) end)
end

-- =====================================================================
-- หน้า: 🏠 หลัก
-- =====================================================================

local pageMain = addTab("main", "🏠  หลัก")
local pageBag = addTab("bag", "🎒  กระเป๋า")
local pageTp = addTab("tp", "🗺️  วาร์ป")
local pageCombat = addTab("combat", "⚔️  ต่อสู้")
local pageDebug = addTab("debug", "🧪  ดีบัก")

local bagLabel, pointLabel, killLabel, afkLabel, backLabel
do
    local c = newCard(pageMain, "📊  สถานะ")
    bagLabel = addLabel(c, "🎒  กระเป๋า:  -- / --", 14, THEME.Text, true)
    pointLabel = addLabel(c, "📍  จุด E:  ยังไม่ได้บันทึก", 12, THEME.Sub)
    backLabel = addLabel(c, "↩️  Back ล่าสุด: -", 12, THEME.Sub)
    killLabel = addLabel(c, "☠️  Enemies: -", 12, THEME.Sub)
    afkLabel = addLabel(c, "🛡️  Anti AFK: -", 12, THEME.Sub)
end

do
    local c = newCard(pageMain, "⚡  ความเร็ว")
    addToggle(c, "⚡", "เพิ่มความเร็ววิ่ง", "คูณความเร็วเดินตามค่าที่ตั้ง", "Speed", function()
        applySpeed()
    end)
    addSlider(c, "ตัวคูณความเร็ว", 1, 10, 0.5, WALK_SPEED_MULTIPLIER, "x%.1f", function(v)
        WALK_SPEED_MULTIPLIER = v
        if Feature.Speed then applySpeed() end
    end)
end

do
    local c = newCard(pageMain, "🧲  เก็บของอัตโนมัติ")
    addToggle(c, "🧲", "Auto Pickup", "วิ่งไปเก็บและกดของใกล้ตัว", "AutoPickup")
    addSlider(c, "ระยะค้นหา", 10, 200, 5, PICKUP_RANGE, "%d studs", function(v) PICKUP_RANGE = v end)
    addSlider(c, "ระยะที่เริ่มกดเก็บ", 2, 20, 1, COLLECT_DISTANCE, "%d studs", function(v) COLLECT_DISTANCE = v end)
    addSlider(c, "ความถี่ (วินาที)", 0.05, 1, 0.05, PICKUP_INTERVAL, "%.2f s", function(v) PICKUP_INTERVAL = v end)
end

-- =====================================================================
-- หน้า: 🎒 กระเป๋า
-- =====================================================================

local bagStatus2
local pickerBox

local function closeBagPicker()
    if pickerBox then
        pickerBox.Visible = false
        for _, ch in ipairs(pickerBox:GetChildren()) do
            if ch:IsA("TextButton") then ch:Destroy() end
        end
    end
end

local function openBagPicker()
    closeBagPicker()
    pickerBox.Visible = true

    local list = collectBagCandidates()

    local function entry(text, onClick, ord)
        local b = create("TextButton", {
            Text = text,
            Font = Enum.Font.Gotham,
            TextSize = 11,
            TextColor3 = THEME.Text,
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundColor3 = THEME.Card,
            AutoButtonColor = false,
            Size = UDim2.new(1, 0, 0, 30),
            LayoutOrder = ord,
            Parent = pickerBox,
        }, { corner(8), create("UIPadding", { PaddingLeft = UDim.new(0, 8) }) })
        b.MouseEnter:Connect(function() tween(b, { BackgroundColor3 = THEME.Stroke }, 0.1) end)
        b.MouseLeave:Connect(function() tween(b, { BackgroundColor3 = THEME.Card }, 0.1) end)
        b.MouseButton1Click:Connect(function()
            onClick()
            closeBagPicker()
        end)
    end

    entry("🤖  Auto (เลือกให้อัตโนมัติ)", function()
        bagOverride = nil
        bagCache = nil
        bagMissUntil = 0
        print("Bag source: Auto")
    end, 0)

    for i, c in ipairs(list) do
        if i > 20 then break end
        local parentName = c.obj.Parent and c.obj.Parent.Name or "?"
        entry(
            ("%d/%d  •  %s.%s%s"):format(c.current, c.maximum, parentName, c.obj.Name,
                c.visible and "" or "  (ซ่อนอยู่)"),
            function()
                bagOverride = c.obj
                bagCache = nil
                print("Bag source:", c.obj:GetFullName())
            end,
            i
        )
    end
end

do
    local c = newCard(pageBag, "🎒  กระเป๋าเต็ม → กด Back → วาร์ปจุด E")
    addToggle(c, "🎒", "Bag Full Handler", "เต็มแล้วกด Back แล้วกลับจุด E", "BagHandler")
    addToggle(c, "💬", "ตรวจข้อความ Bag Full", "เผื่อเกมไม่มีตัวเลข x/y", "FullText")
    bagStatus2 = addLabel(c, "สถานะ: -", 12, THEME.Sub)

    addButtons(c, {
        { text = "🧪 ทดสอบกด Back", color = THEME.Accent, w = 0.5, callback = function()
            task.spawn(function()
                lastBackResult = "กำลังกด..."
                pressBack()
            end)
        end },
        { text = "🧪 ทดสอบ Back → E", color = THEME.Mid, w = 0.5, callback = function()
            task.spawn(function()
                bagFullProcessing = false
                handleBagFull("ทดสอบ")
            end)
        end },
    })
end

do
    local c = newCard(pageBag, "🔎  Label กระเป๋า (ถ้าตรวจไม่เจอ)")
    addLabel(c, "ปกติเลือกอัตโนมัติ ถ้าตัวเลขไม่ตรง ให้กดเลือก Label ที่เป็นกระเป๋าเอง", 11, THEME.Sub)
    addButtons(c, {
        { text = "🔎 เลือก Label", color = THEME.Accent, w = 0.62, callback = openBagPicker },
        { text = "🤖 Auto", color = THEME.Mid, w = 0.38, callback = function()
            bagOverride = nil
            bagCache = nil
            bagMissUntil = 0
            closeBagPicker()
            print("Bag source: Auto")
        end },
    })

    pickerBox = create("Frame", {
        Visible = false,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = nextOrder(),
        Parent = c,
    }, {
        create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
    })
end

do
    local c = newCard(pageBag, "📍  จุด E")
    addToggle(c, "⌨️", "ปุ่มลัด E", "กด E = บันทึก / กด E ซ้ำ = วาร์ปกลับ", "EKey")
    addButtons(c, {
        { text = "💾 บันทึกจุด", color = THEME.Accent, w = 0.36, callback = savePointHere },
        { text = "🌀 วาร์ปกลับ", color = THEME.Mid, w = 0.34, callback = doE },
        { text = "🗑️ ลบ", color = THEME.Danger, w = 0.30, callback = clearPoint },
    })
end

-- =====================================================================
-- หน้า: 🗺️ วาร์ป  (Stage + Area)
-- =====================================================================

do
    local c = newCard(pageTp, "🗺️  วาร์ป Stage (1 - 27)")
    local selectedStage = 1

    local stageLabel = addLabel(c, "Stage ที่เลือก:  1", 13, THEME.Text, true)

    local grid = create("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = nextOrder(),
        Parent = c,
    }, {
        create("UIGridLayout", {
            CellSize = UDim2.fromOffset(32, 26),
            CellPadding = UDim2.fromOffset(4, 4),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
    })

    local stageButtons = {}

    local function refreshStageButtons()
        stageLabel.Text = ("Stage ที่เลือก:  %d  %s"):format(
            selectedStage, stageSaved[selectedStage] and "💾 (มีตำแหน่งที่บันทึก)" or "")
        for n, b in pairs(stageButtons) do
            tween(b, { BackgroundColor3 = (n == selectedStage) and THEME.Accent or THEME.Panel })
            b.TextColor3 = stageSaved[n] and THEME.Good or THEME.Text
        end
    end

    for n = STAGE_MIN, STAGE_MAX do
        local b = create("TextButton", {
            Text = tostring(n),
            Font = Enum.Font.GothamBold,
            TextSize = 12,
            TextColor3 = THEME.Text,
            AutoButtonColor = false,
            BackgroundColor3 = THEME.Panel,
            LayoutOrder = n,
            Parent = grid,
        }, { corner(6), stroke(THEME.Stroke, 1, 0.6) })
        stageButtons[n] = b
        b.MouseButton1Click:Connect(function()
            selectedStage = n
            refreshStageButtons()
        end)
    end

    addButtons(c, {
        { text = "🌀 วาร์ปไป Stage นี้", color = THEME.Mid, w = 1, callback = function()
            task.spawn(teleportToStage, selectedStage)
        end },
    })

    addButtons(c, {
        { text = "💾 บันทึกตำแหน่งตรงนี้", color = THEME.Accent, w = 0.64, callback = function()
            saveStageHere(selectedStage)
            refreshStageButtons()
        end },
        { text = "🗑️ ลบ", color = THEME.Danger, w = 0.36, callback = function()
            clearStageSaved(selectedStage)
            refreshStageButtons()
        end },
    }, 30)

    refreshStageButtons()
end

do
    local c = newCard(pageTp, "🏋️  Auto Train (Area)")
    local trainStatus = addLabel(c, "เลือก Area เพื่อวาร์ปทันที", 11, THEME.Sub, true)

    local function setTrainStatus(text, color)
        trainStatus.Text = text
        trainStatus.TextColor3 = color or THEME.Sub
    end

    local function doTeleportArea()
        if not SelectedAreaIndex then
            setTrainStatus("⚠️ เลือก Area ก่อน", THEME.Warn)
            return
        end

        setTrainStatus("กำลังวาร์ป...", THEME.Accent2)

        local ok, source = teleportToArea(SelectedAreaIndex)

        if ok then
            setTrainStatus(
                source == "saved" and "✅ วาร์ปแล้ว (ตำแหน่งที่บันทึก)" or "✅ วาร์ปแล้ว (ตรวจเจอในเกม)",
                THEME.Good)
        else
            setTrainStatus("❌ ไม่พบ Area → ไปยืนที่นั่นแล้วกด 💾", THEME.Danger)
        end
    end

    addDropdown(c, "Select Area...", TRAIN_AREAS, function(name, index)
        SelectedArea = name
        SelectedAreaIndex = index
        print("Selected Area: " .. name)
        task.spawn(doTeleportArea)
    end)

    addButtons(c, {
        { text = "🌀 วาร์ป", color = THEME.Mid, w = 0.34, callback = function()
            task.spawn(doTeleportArea)
        end },
        { text = "💾 บันทึกที่นี่", color = THEME.Accent, w = 0.42, callback = function()
            if not SelectedAreaIndex then
                setTrainStatus("⚠️ เลือก Area ก่อนบันทึก", THEME.Warn)
                return
            end
            saveAreaHere(SelectedAreaIndex)
            setTrainStatus(("💾 บันทึกตำแหน่ง Area %d แล้ว"):format(SelectedAreaIndex), THEME.Good)
        end },
        { text = "🗑️", color = THEME.Danger, w = 0.24, callback = function()
            if not SelectedAreaIndex then return end
            clearAreaSaved(SelectedAreaIndex)
            setTrainStatus(("🗑️ ลบตำแหน่ง Area %d แล้ว"):format(SelectedAreaIndex), THEME.Sub)
        end },
    })

    addToggle(c, "🏋️", "Auto Train", "วาร์ปกลับ Area เมื่อเกิดใหม่", "AutoTrain", function(on)
        if on then task.spawn(doTeleportArea) end
    end)
end

-- =====================================================================
-- หน้า: ⚔️ ต่อสู้
-- =====================================================================

do
    local c = newCard(pageCombat, "☠️  Force Kill Stage Enemies")
    addToggle(c, "☠️", "Force Kill", "ศัตรูโดนตีทีเดียว = ตายทันที", "ForceKill", function()
        enemyRefreshAt = 0
    end)

    local btns
    local function renderMode()
        btns[1].BackgroundColor3 = (KILL_MODE == "OneHit") and THEME.Accent or THEME.Panel
        btns[2].BackgroundColor3 = (KILL_MODE == "All") and THEME.Accent or THEME.Panel
    end

    btns = addButtons(c, {
        { text = "⚔️ ตีทีเดียวตาย", color = THEME.Accent, w = 0.55, callback = function()
            KILL_MODE = "OneHit"
            renderMode()
        end },
        { text = "💀 ฆ่าทั้งหมด", color = THEME.Panel, w = 0.45, callback = function()
            KILL_MODE = "All"
            renderMode()
        end },
    }, 32)
    renderMode()

    addSlider(c, "ระยะฆ่า (รอบตัวคุณ)", 20, 1000, 10, KILL_RANGE, "%d studs", function(v)
        KILL_RANGE = v
    end)
end

do
    local c = newCard(pageCombat, "🛡️  Anti AFK")
    addToggle(c, "🛡️", "Anti AFK", "กันโดนเตะเมื่อไม่ได้ขยับ", "AntiAFK")
end

-- =====================================================================
-- หน้า: 🧪 ดีบัก
-- =====================================================================

do
    local c = newCard(pageDebug, "🧪  ตรวจข้อมูลเกม")
    addLabel(c, "กด Scan แล้วเปิด F9 (Developer Console) เพื่อดูผล เช่น ปุ่ม Back ที่เจอ, Label กระเป๋า, Area, Stage", 11, THEME.Sub)
    addButtons(c, {
        { text = "🧪 Scan ข้อมูลเกม (ดูผลใน F9)", color = Color3.fromRGB(70, 40, 130), w = 1, callback = function()
            task.spawn(scanGame)
        end },
    }, 36)
end

-- =====================================================================
-- อัปเดตสถานะ
-- =====================================================================

task.spawn(function()
    while screen.Parent do
        local cur, max = getBagCount()
        local full = (cur and max and cur >= max) or false

        if cur and max then
            bagLabel.Text = ("🎒  กระเป๋า:  %d / %d"):format(cur, max)
        else
            bagLabel.Text = "🎒  กระเป๋า:  -- / --"
        end
        bagLabel.TextColor3 = full and THEME.Danger or THEME.Text

        pointLabel.Text = point1 and "📍  จุด E:  บันทึกแล้ว ✅" or "📍  จุด E:  ยังไม่ได้บันทึก"
        backLabel.Text = "↩️  Back ล่าสุด: " .. lastBackResult

        bagStatus2.Text = ("กระเป๋า: %s  •  เต็ม %d ครั้ง\nBack ล่าสุด: %s"):format(
            (cur and max) and (cur .. "/" .. max) or "ไม่พบตัวเลข",
            bagFullCount,
            lastBackResult)

        local ef = getEnemiesFolder()
        local total = Feature.ForceKill and enemyCount or (ef and #ef:GetChildren() or 0)
        killLabel.Text = ("☠️  Enemies: %s  •  สั่งฆ่าแล้ว %d  •  %s"):format(
            (ef or Feature.ForceKill) and (total .. " ตัว") or "ไม่พบโฟลเดอร์",
            killedCount,
            KILL_MODE == "OneHit" and "ตีทีเดียวตาย" or "ฆ่าทั้งหมด")

        afkLabel.Text = Feature.AntiAFK
            and ("🛡️  Anti AFK: ทำงาน (กันเตะ %d ครั้ง)"):format(antiAfkCount)
            or "🛡️  Anti AFK: ปิดอยู่"

        task.wait(0.4)
    end
end)

-- =====================================================================
-- ย่อ / ปิด / ปุ่มลอย / คีย์ลัด
-- =====================================================================

local launcher = create("TextButton", {
    Text = "🚀",
    TextSize = 20,
    AutoButtonColor = false,
    BackgroundColor3 = THEME.Panel,
    Size = UDim2.fromOffset(44, 44),
    Position = UDim2.new(0, 12, 0, 110),
    Visible = false,
    Parent = screen,
}, { corner(22), neonStroke(1.5) })

local function setWindowVisible(v)
    rootFrame.Visible = v
    launcher.Visible = not v
    if not v then closeBagPicker() end
end

local minimized = false

btnMin.MouseButton1Click:Connect(function()
    minimized = not minimized
    if minimized then
        tween(rootFrame, { Size = UDim2.fromOffset(WIN_W, HEADER_H) }, 0.22)
        btnMin.Text = "+"
    else
        tween(rootFrame, { Size = UDim2.fromOffset(WIN_W, WIN_H) }, 0.22)
        btnMin.Text = "–"
    end
end)

btnClose.MouseButton1Click:Connect(function() setWindowVisible(false) end)
launcher.MouseButton1Click:Connect(function() setWindowVisible(true) end)

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == TOGGLE_KEY then
        setWindowVisible(not rootFrame.Visible)
    end
end)

selectTab("main")

rootFrame.Size = UDim2.fromOffset(WIN_W, 0)
tween(rootFrame, { Size = UDim2.fromOffset(WIN_W, WIN_H) }, 0.35)
